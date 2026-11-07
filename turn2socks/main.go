package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const version = "turn2socks v1.1.0 (RFC 6062 TCP Relay)"

const (
	magicCookie uint32 = 0x2112A442

	// STUN message types
	mtAllocateRequest       uint16 = 0x0003
	mtAllocateSuccess       uint16 = 0x0103
	mtAllocateError         uint16 = 0x0113
	mtRefreshRequest        uint16 = 0x0004
	mtRefreshSuccess        uint16 = 0x0104
	mtCreatePermRequest     uint16 = 0x0008
	mtCreatePermSuccess     uint16 = 0x0108
	mtConnectRequest        uint16 = 0x000A
	mtConnectSuccess        uint16 = 0x010A
	mtConnectionBindRequest uint16 = 0x000B
	mtConnectionBindSuccess uint16 = 0x010B

	// STUN attributes
	atUsername           uint16 = 0x0006
	atMessageIntegrity   uint16 = 0x0008
	atErrorCode          uint16 = 0x0009
	atLifetime           uint16 = 0x000D
	atXorPeerAddress     uint16 = 0x0012
	atRealm              uint16 = 0x0014
	atNonce              uint16 = 0x0015
	atRequestedTransport uint16 = 0x0019
	atConnectionID       uint16 = 0x002A

	defaultLifetime = 600 * time.Second
	maxSkipMessages = 16 // 等待匹配响应时最多跳过的无关报文数 (如 indication)
)

type stunMessage struct {
	MsgType uint16
	Length  uint16
	TxID    [12]byte
	Raw     []byte
	Attrs   map[uint16][]byte
}

func isErrorResponse(t uint16) bool { return t&0x0110 == 0x0110 }

// stunErrorInfo 解析 ERROR-CODE 属性，返回 (错误码, 原因短语)。
func stunErrorInfo(m *stunMessage) (int, string) {
	v, ok := m.Attrs[atErrorCode]
	if !ok || len(v) < 4 {
		return 0, ""
	}
	return int(v[2]&7)*100 + int(v[3]), string(v[4:])
}

// describeResp 把服务器的响应转成可读文本，用于错误信息。
func describeResp(m *stunMessage) string {
	if isErrorResponse(m.MsgType) {
		if code, reason := stunErrorInfo(m); code != 0 {
			return fmt.Sprintf("%d %s", code, reason)
		}
	}
	return fmt.Sprintf("unexpected message type 0x%04x", m.MsgType)
}

func newTxID() [12]byte {
	var tid [12]byte
	_, _ = rand.Read(tid[:])
	return tid
}

func buildAttr(attrType uint16, val []byte) []byte {
	l := len(val)
	pad := (4 - (l % 4)) % 4
	b := make([]byte, 4+l+pad)
	binary.BigEndian.PutUint16(b[0:2], attrType)
	binary.BigEndian.PutUint16(b[2:4], uint16(l))
	copy(b[4:], val)
	return b
}

func buildStunMsg(msgType uint16, txID [12]byte, attrs ...[]byte) []byte {
	var body bytes.Buffer
	for _, a := range attrs {
		body.Write(a)
	}
	bodyBytes := body.Bytes()
	h := make([]byte, 20)
	binary.BigEndian.PutUint16(h[0:2], msgType)
	binary.BigEndian.PutUint16(h[2:4], uint16(len(bodyBytes)))
	binary.BigEndian.PutUint32(h[4:8], magicCookie)
	copy(h[8:20], txID[:])
	return append(h, bodyBytes...)
}

func signStunMsg(msg []byte, key []byte) []byte {
	if len(key) == 0 {
		return msg
	}
	signedMsg := make([]byte, len(msg))
	copy(signedMsg, msg)

	origLen := binary.BigEndian.Uint16(signedMsg[2:4])
	binary.BigEndian.PutUint16(signedMsg[2:4], origLen+24)

	mac := hmac.New(sha1.New, key)
	mac.Write(signedMsg)
	miVal := mac.Sum(nil)

	miAttr := buildAttr(atMessageIntegrity, miVal)
	return append(signedMsg, miAttr...)
}

func parseStunMsg(data []byte) (*stunMessage, error) {
	if len(data) < 20 {
		return nil, errors.New("stun packet too short")
	}
	cookie := binary.BigEndian.Uint32(data[4:8])
	if cookie != magicCookie {
		return nil, errors.New("invalid stun magic cookie")
	}
	msgType := binary.BigEndian.Uint16(data[0:2])
	length := binary.BigEndian.Uint16(data[2:4])
	if int(length)+20 > len(data) {
		return nil, errors.New("stun packet length mismatch")
	}

	msg := &stunMessage{
		MsgType: msgType,
		Length:  length,
		Raw:     data[:20+length],
		Attrs:   make(map[uint16][]byte),
	}
	copy(msg.TxID[:], data[8:20])

	offset := 20
	end := 20 + int(length)
	for offset+4 <= end {
		attrType := binary.BigEndian.Uint16(data[offset : offset+2])
		attrLen := int(binary.BigEndian.Uint16(data[offset+2 : offset+4]))
		if offset+4+attrLen > end {
			break
		}
		val := make([]byte, attrLen)
		copy(val, data[offset+4:offset+4+attrLen])
		msg.Attrs[attrType] = val

		pad := (4 - (attrLen % 4)) % 4
		offset += 4 + attrLen + pad
	}
	return msg, nil
}

func readStun(r io.Reader) (*stunMessage, error) {
	hdr := make([]byte, 20)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, err
	}
	cookie := binary.BigEndian.Uint32(hdr[4:8])
	if cookie != magicCookie {
		return nil, errors.New("invalid stun magic cookie in stream")
	}
	length := binary.BigEndian.Uint16(hdr[2:4])
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	full := append(hdr, body...)
	return parseStunMsg(full)
}

// buildXorPeerAddress 编码 XOR-PEER-ADDRESS。
// 注意：IPv6 地址的异或掩码包含"本次请求"的事务 ID，所以每个请求都必须用自己的 txID 重新编码。
func buildXorPeerAddress(ip net.IP, port int, txID [12]byte) []byte {
	if ip4 := ip.To4(); ip4 != nil {
		b := make([]byte, 8)
		b[0] = 0
		b[1] = 1 // IPv4
		xorPort := uint16(port) ^ 0x2112
		binary.BigEndian.PutUint16(b[2:4], xorPort)

		cookieBytes := make([]byte, 4)
		binary.BigEndian.PutUint32(cookieBytes, magicCookie)
		for i := 0; i < 4; i++ {
			b[4+i] = ip4[i] ^ cookieBytes[i]
		}
		return b
	}

	ip16 := ip.To16()
	b := make([]byte, 20)
	b[0] = 0
	b[1] = 2 // IPv6
	xorPort := uint16(port) ^ 0x2112
	binary.BigEndian.PutUint16(b[2:4], xorPort)

	xorPad := make([]byte, 16)
	binary.BigEndian.PutUint32(xorPad[0:4], magicCookie)
	copy(xorPad[4:16], txID[:])
	for i := 0; i < 16; i++ {
		b[4+i] = ip16[i] ^ xorPad[i]
	}
	return b
}

// ───────────────────────── TURN 客户端 (RFC 5766 / RFC 6062) ─────────────────────────

// authInfo 是长期凭据机制所需的认证信息快照。
type authInfo struct {
	user  string
	realm string
	nonce []byte
	key   []byte // MD5(user:realm:pass)，无认证时为 nil
}

func (a authInfo) attrs() [][]byte {
	if a.key == nil {
		return nil
	}
	return [][]byte{
		buildAttr(atUsername, []byte(a.user)),
		buildAttr(atRealm, []byte(a.realm)),
		buildAttr(atNonce, a.nonce),
	}
}

// session 表示一条 TURN 控制连接及其上的 TCP Allocation。
// RFC 6062 要求控制连接在整个数据中继期间保持存活；一个 Allocation 上可以发起多个 Connect，
// 因此所有 SOCKS 连接共用同一个 session，由后台协程定期 Refresh。
type session struct {
	ctrl     net.Conn
	auth     authInfo
	lifetime time.Duration
	stop     chan struct{}
	once     sync.Once
}

func (s *session) close() {
	s.once.Do(func() {
		close(s.stop)
		_ = s.ctrl.Close()
	})
}

// sessionError 表示"会话已不可用"(连接断开、服务器已丢弃 Allocation 等)，调用方可以重建会话后重试。
type sessionError struct{ err error }

func (e *sessionError) Error() string { return e.err.Error() }
func (e *sessionError) Unwrap() error { return e.err }

type TurnClient struct {
	Server   string
	Username string
	Password string
	Timeout  time.Duration

	mu   sync.Mutex // 保护 sess，并串行化控制连接上的"请求-响应"
	sess *session
}

// relayConn 是已完成 ConnectionBind 的数据连接。控制连接由 TurnClient 统一维护，这里只负责数据连接。
type relayConn struct {
	net.Conn
	once sync.Once
}

func (c *relayConn) Close() error {
	var err error
	c.once.Do(func() { err = c.Conn.Close() })
	return err
}

func (c *relayConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

func (c *relayConn) CloseRead() error {
	if cr, ok := c.Conn.(interface{ CloseRead() error }); ok {
		return cr.CloseRead()
	}
	return nil
}

func (tc *TurnClient) dial(ctx context.Context) (net.Conn, error) {
	d := net.Dialer{Timeout: tc.Timeout, KeepAlive: 30 * time.Second}
	return d.DialContext(ctx, "tcp", tc.Server)
}

func (tc *TurnClient) makeAuth(realm string, nonce []byte) authInfo {
	if tc.Username == "" {
		return authInfo{}
	}
	sum := md5.Sum([]byte(tc.Username + ":" + realm + ":" + tc.Password))
	return authInfo{user: tc.Username, realm: realm, nonce: nonce, key: sum[:]}
}

// exchange 在连接上发送一个请求并等待事务 ID 匹配的响应 (自动跳过无关报文)。
func exchange(c net.Conn, req []byte, tid [12]byte, timeout time.Duration) (*stunMessage, error) {
	_ = c.SetDeadline(time.Now().Add(timeout))
	defer c.SetDeadline(time.Time{})
	if _, err := c.Write(req); err != nil {
		return nil, err
	}
	for i := 0; i < maxSkipMessages; i++ {
		m, err := readStun(c)
		if err != nil {
			return nil, err
		}
		if m.TxID == tid {
			return m, nil
		}
	}
	return nil, errors.New("no matching stun response")
}

// roundTrip 在会话控制连接上发送一个请求。遇到 438 (Stale Nonce) 时自动更新 nonce 并重试一次。
// 调用者必须持有 tc.mu。连接级错误会以 *sessionError 返回。
func (tc *TurnClient) roundTrip(s *session, msgType uint16, mk func(tid [12]byte) [][]byte) (*stunMessage, error) {
	for attempt := 0; attempt < 2; attempt++ {
		tid := newTxID()
		attrs := append(mk(tid), s.auth.attrs()...)
		req := signStunMsg(buildStunMsg(msgType, tid, attrs...), s.auth.key)
		resp, err := exchange(s.ctrl, req, tid, tc.Timeout)
		if err != nil {
			return nil, &sessionError{err}
		}
		if isErrorResponse(resp.MsgType) {
			if code, _ := stunErrorInfo(resp); code == 438 && s.auth.key != nil {
				if n, ok := resp.Attrs[atNonce]; ok {
					realm := s.auth.realm
					if r, ok := resp.Attrs[atRealm]; ok {
						realm = string(r)
					}
					s.auth = tc.makeAuth(realm, n)
					continue
				}
			}
		}
		return resp, nil
	}
	return nil, errors.New("stale nonce: retries exhausted")
}

func lifetimeFrom(m *stunMessage, def time.Duration) time.Duration {
	if v, ok := m.Attrs[atLifetime]; ok && len(v) == 4 {
		if sec := binary.BigEndian.Uint32(v); sec > 0 {
			return time.Duration(sec) * time.Second
		}
	}
	return def
}

// newSession 建立控制连接并完成带认证的 Allocate。
func (tc *TurnClient) newSession(ctx context.Context) (*session, error) {
	c, err := tc.dial(ctx)
	if err != nil {
		return nil, fmt.Errorf("connect to turn server failed: %w", err)
	}
	s := &session{ctrl: c, stop: make(chan struct{}), lifetime: defaultLifetime}
	fail := func(err error) (*session, error) {
		s.close()
		return nil, err
	}

	tp := buildAttr(atRequestedTransport, []byte{6, 0, 0, 0}) // TCP = 6
	mk := func([12]byte) [][]byte { return [][]byte{tp} }

	resp, err := tc.roundTrip(s, mtAllocateRequest, mk)
	if err != nil {
		return fail(fmt.Errorf("allocate request failed: %w", err))
	}
	if isErrorResponse(resp.MsgType) {
		code, _ := stunErrorInfo(resp)
		if code == 401 && tc.Username != "" {
			s.auth = tc.makeAuth(string(resp.Attrs[atRealm]), resp.Attrs[atNonce])
			resp, err = tc.roundTrip(s, mtAllocateRequest, mk)
			if err != nil {
				return fail(fmt.Errorf("authenticated allocate request failed: %w", err))
			}
		}
	}
	if resp.MsgType != mtAllocateSuccess {
		return fail(fmt.Errorf("allocate failed: %s", describeResp(resp)))
	}
	s.lifetime = lifetimeFrom(resp, defaultLifetime)
	return s, nil
}

// ensureSessionLocked 返回可用会话，必要时新建并启动 Refresh 协程。调用者必须持有 tc.mu。
func (tc *TurnClient) ensureSessionLocked(ctx context.Context) (*session, error) {
	if tc.sess != nil {
		return tc.sess, nil
	}
	s, err := tc.newSession(ctx)
	if err != nil {
		return nil, err
	}
	tc.sess = s
	go tc.refreshLoop(s)
	return s, nil
}

func (tc *TurnClient) dropLocked(s *session) {
	if tc.sess == s {
		tc.sess = nil
	}
	s.close()
}

// refreshLoop 按生命周期的一半定期发送 Refresh，防止 Allocation 到期后服务器回收中继连接。
func (tc *TurnClient) refreshLoop(s *session) {
	interval := s.lifetime / 2
	if interval < time.Second {
		interval = time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
		}
		tc.mu.Lock()
		if tc.sess != s {
			tc.mu.Unlock()
			return
		}
		want := make([]byte, 4)
		binary.BigEndian.PutUint32(want, uint32(defaultLifetime/time.Second))
		resp, err := tc.roundTrip(s, mtRefreshRequest, func([12]byte) [][]byte {
			return [][]byte{buildAttr(atLifetime, want)}
		})
		if err != nil || resp.MsgType != mtRefreshSuccess {
			if err != nil {
				log.Printf("[turn2socks] refresh failed: %v", err)
			} else {
				log.Printf("[turn2socks] refresh rejected: %s", describeResp(resp))
			}
			tc.dropLocked(s)
			tc.mu.Unlock()
			return
		}
		s.lifetime = lifetimeFrom(resp, s.lifetime)
		tc.mu.Unlock()
	}
}

// Close 关闭当前会话 (控制连接)，其下所有中继数据连接随之终止。
func (tc *TurnClient) Close() {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	if tc.sess != nil {
		tc.dropLocked(tc.sess)
	}
}

// respError 把非成功响应转成错误；437 (Allocation Mismatch) 表示服务器已丢弃该 Allocation，需要重建会话。
func (tc *TurnClient) respError(s *session, op string, resp *stunMessage) error {
	err := fmt.Errorf("%s failed: %s", op, describeResp(resp))
	if code, _ := stunErrorInfo(resp); code == 437 {
		tc.dropLocked(s)
		return &sessionError{err}
	}
	return err
}

// connect 在共享的 Allocation 上执行 CreatePermission + Connect，返回 CONNECTION-ID 与当前认证信息。
func (tc *TurnClient) connect(ctx context.Context, ip net.IP, port int) ([]byte, authInfo, error) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	s, err := tc.ensureSessionLocked(ctx)
	if err != nil {
		return nil, authInfo{}, err
	}
	// 每个请求都用自己的事务 ID 重新编码 XOR-PEER-ADDRESS (IPv6 的异或掩码依赖事务 ID)
	peerAttr := func(tid [12]byte) [][]byte {
		return [][]byte{buildAttr(atXorPeerAddress, buildXorPeerAddress(ip, port, tid))}
	}

	resp, err := tc.roundTrip(s, mtCreatePermRequest, peerAttr)
	if err != nil {
		tc.dropLocked(s)
		return nil, authInfo{}, err
	}
	if resp.MsgType != mtCreatePermSuccess {
		return nil, authInfo{}, tc.respError(s, "create permission", resp)
	}

	resp, err = tc.roundTrip(s, mtConnectRequest, peerAttr)
	if err != nil {
		tc.dropLocked(s)
		return nil, authInfo{}, err
	}
	if resp.MsgType != mtConnectSuccess {
		return nil, authInfo{}, tc.respError(s, "connect", resp)
	}
	cid, ok := resp.Attrs[atConnectionID]
	if !ok || len(cid) != 4 {
		return nil, authInfo{}, errors.New("missing or invalid connection-id attribute in connect response")
	}
	return append([]byte(nil), cid...), s.auth, nil
}

// bind 新建一条 TCP 连接并发送 ConnectionBind，成功后该连接即成为到目标的透明数据通道。
func (tc *TurnClient) bind(ctx context.Context, cid []byte, auth authInfo) (net.Conn, error) {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		conn, err := tc.dial(ctx)
		if err != nil {
			return nil, fmt.Errorf("connect data connection to turn failed: %w", err)
		}
		tid := newTxID()
		attrs := append([][]byte{buildAttr(atConnectionID, cid)}, auth.attrs()...)
		req := signStunMsg(buildStunMsg(mtConnectionBindRequest, tid, attrs...), auth.key)
		resp, err := exchange(conn, req, tid, tc.Timeout)
		if err != nil {
			_ = conn.Close()
			return nil, fmt.Errorf("connection bind failed: %w", err)
		}
		if resp.MsgType == mtConnectionBindSuccess {
			return &relayConn{Conn: conn}, nil
		}
		_ = conn.Close()
		lastErr = fmt.Errorf("connection bind failed: %s", describeResp(resp))
		if code, _ := stunErrorInfo(resp); code == 438 && auth.key != nil {
			if n, ok := resp.Attrs[atNonce]; ok {
				auth = tc.makeAuth(auth.realm, n)
				continue
			}
		}
		return nil, lastErr
	}
	return nil, lastErr
}

// DialRelay 通过 TURN 服务器建立到 targetIP:targetPort 的 TCP 中继连接 (RFC 6062)。
// 多次调用共享同一个 Allocation；会话失效时会自动重建并重试一次。
func (tc *TurnClient) DialRelay(ctx context.Context, targetIP net.IP, targetPort int) (net.Conn, error) {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		cid, auth, err := tc.connect(ctx, targetIP, targetPort)
		if err != nil {
			lastErr = err
			var se *sessionError
			if errors.As(err, &se) {
				continue
			}
			return nil, err
		}
		return tc.bind(ctx, cid, auth)
	}
	return nil, lastErr
}

// ───────────────────────── SOCKS5 服务 ─────────────────────────

type SocksServer struct {
	ListenAddr string
	Turn       *TurnClient
}

func (s *SocksServer) handleConnection(clientConn net.Conn) {
	defer clientConn.Close()

	// 握手阶段限时 15 秒，防止慢速/恶意连接占用资源
	_ = clientConn.SetDeadline(time.Now().Add(15 * time.Second))

	// 1. Negotiation
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(clientConn, hdr); err != nil {
		return
	}
	if hdr[0] != 0x05 {
		return
	}
	numMethods := int(hdr[1])
	methods := make([]byte, numMethods)
	if _, err := io.ReadFull(clientConn, methods); err != nil {
		return
	}
	var noAuthSupported bool
	for _, m := range methods {
		if m == 0x00 {
			noAuthSupported = true
			break
		}
	}
	if !noAuthSupported {
		_, _ = clientConn.Write([]byte{0x05, 0xFF}) // No acceptable methods
		return
	}
	if _, err := clientConn.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	// 2. Request
	reqHdr := make([]byte, 4)
	if _, err := io.ReadFull(clientConn, reqHdr); err != nil {
		return
	}
	if reqHdr[0] != 0x05 || reqHdr[1] != 0x01 { // Only CONNECT supported
		_, _ = clientConn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	var targetIP net.IP
	var host string
	switch reqHdr[3] {
	case 0x01: // IPv4
		ip := make([]byte, 4)
		if _, err := io.ReadFull(clientConn, ip); err != nil {
			return
		}
		targetIP = net.IP(ip)
		host = targetIP.String()
	case 0x03: // Domain
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(clientConn, lenBuf); err != nil {
			return
		}
		domain := make([]byte, lenBuf[0])
		if _, err := io.ReadFull(clientConn, domain); err != nil {
			return
		}
		host = string(domain)
	case 0x04: // IPv6
		ip := make([]byte, 16)
		if _, err := io.ReadFull(clientConn, ip); err != nil {
			return
		}
		targetIP = net.IP(ip)
		host = targetIP.String()
	default:
		_, _ = clientConn.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Address type not supported
		return
	}

	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(clientConn, portBuf); err != nil {
		return
	}
	targetPort := int(binary.BigEndian.Uint16(portBuf))

	// 请求读取完毕：取消握手 deadline，后续的解析/中继建立各自带独立超时
	_ = clientConn.SetDeadline(time.Time{})

	ctx, cancel := context.WithTimeout(context.Background(), s.Turn.Timeout)
	defer cancel()

	if targetIP == nil { // 域名：带超时解析 (优先 IPv4，以获得更好的 TURN 服务器兼容性)
		addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
		if err != nil || len(addrs) == 0 {
			_, _ = clientConn.Write([]byte{0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Host unreachable
			return
		}
		for _, a := range addrs {
			if ip4 := a.IP.To4(); ip4 != nil {
				targetIP = ip4
				break
			}
		}
		if targetIP == nil {
			targetIP = addrs[0].IP
		}
	}

	rc, err := s.Turn.DialRelay(ctx, targetIP, targetPort)
	if err != nil {
		log.Printf("[turn2socks] Relay to %s:%d failed: %v", host, targetPort, err)
		_, _ = clientConn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Connection refused
		return
	}
	defer rc.Close()

	// SOCKS5 success reply
	_ = clientConn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := clientConn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	_ = clientConn.SetDeadline(time.Time{})

	// Bi-directional pipe with half-close support
	var wg sync.WaitGroup
	wg.Add(2)

	closeWrite := func(c net.Conn) {
		type closeWriter interface {
			CloseWrite() error
		}
		if cw, ok := c.(closeWriter); ok {
			_ = cw.CloseWrite()
		} else {
			_ = c.Close()
		}
	}

	go func() {
		defer wg.Done()
		_, _ = io.Copy(rc, clientConn)
		closeWrite(rc)
	}()

	go func() {
		defer wg.Done()
		_, _ = io.Copy(clientConn, rc)
		closeWrite(clientConn)
	}()

	wg.Wait()
}

func (s *SocksServer) Run(ctx context.Context) error {
	l, err := net.Listen("tcp", s.ListenAddr)
	if err != nil {
		return err
	}
	defer l.Close()
	defer s.Turn.Close()
	log.Printf("[turn2socks] SOCKS5 server listening on %s -> TURN %s", s.ListenAddr, s.Turn.Server)

	go func() {
		<-ctx.Done()
		_ = l.Close()
	}()

	for {
		conn, err := l.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				log.Printf("[turn2socks] accept error: %v", err)
				time.Sleep(100 * time.Millisecond)
				continue
			}
		}
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.SetKeepAlive(true)
			_ = tc.SetKeepAlivePeriod(30 * time.Second)
		}
		go s.handleConnection(conn)
	}
}

func main() {
	listenAddr := flag.String("listen", "127.0.0.1:10808", "Local SOCKS5 listen address")
	turnServer := flag.String("turn", "", "TURN server address (host:port)")
	turnUser := flag.String("user", "", "TURN username (optional, or env TURN_USER)")
	turnPass := flag.String("pass", "", "TURN password (optional, or env TURN_PASS)")
	timeoutSec := flag.Int("timeout", 10, "Relay connection timeout in seconds")
	showVersion := flag.Bool("v", false, "Show version")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	if *turnUser == "" {
		*turnUser = os.Getenv("TURN_USER")
	}
	if *turnPass == "" {
		*turnPass = os.Getenv("TURN_PASS")
	}

	if *turnServer == "" {
		fmt.Fprintf(os.Stderr, "Usage: turn2socks -turn <host:port> [-listen <addr:port>] [-user <user>] [-pass <pass>]\n")
		flag.PrintDefaults()
		os.Exit(1)
	}

	// Ensure port in turnServer
	if _, _, err := net.SplitHostPort(*turnServer); err != nil {
		*turnServer = net.JoinHostPort(*turnServer, "3478")
	}

	tc := &TurnClient{
		Server:   *turnServer,
		Username: *turnUser,
		Password: *turnPass,
		Timeout:  time.Duration(*timeoutSec) * time.Second,
	}

	server := &SocksServer{
		ListenAddr: *listenAddr,
		Turn:       tc,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("[turn2socks] shutting down...")
		cancel()
	}()

	if err := server.Run(ctx); err != nil && !errors.Is(err, net.ErrClosed) {
		log.Fatalf("[turn2socks] server terminated: %v", err)
	}
}
