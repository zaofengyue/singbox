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

const (
	magicCookie uint32 = 0x2112A442

	// STUN message types
	mtAllocateRequest       uint16 = 0x0003
	mtAllocateSuccess       uint16 = 0x0103
	mtAllocateError         uint16 = 0x0113
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
	atXorPeerAddress     uint16 = 0x0012
	atRealm              uint16 = 0x0014
	atNonce              uint16 = 0x0015
	atRequestedTransport uint16 = 0x0019
	atConnectionID       uint16 = 0x002A
)

type stunMessage struct {
	MsgType uint16
	Length  uint16
	TxID    [12]byte
	Raw     []byte
	Attrs   map[uint16][]byte
}

type TurnClient struct {
	Server   string
	Username string
	Password string
	Timeout  time.Duration
}

// relayConn 封装数据连接和控制连接。根据 RFC 6062 规范，控制连接必须在整个数据中继期间保持存活，
// 当数据连接关闭时一并关闭控制连接，避免 Coturn 提早强制释放 Allocation。
type relayConn struct {
	net.Conn
	ctrlConn net.Conn
	once     sync.Once
}

func (c *relayConn) Close() error {
	var err error
	c.once.Do(func() {
		err = c.Conn.Close()
		if c.ctrlConn != nil {
			_ = c.ctrlConn.Close()
		}
	})
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
		if offset+4+attrLen > len(data) {
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

func (tc *TurnClient) DialRelay(ctx context.Context, targetIP net.IP, targetPort int) (net.Conn, error) {
	d := net.Dialer{Timeout: tc.Timeout, KeepAlive: 30 * time.Second}
	ctrlConn, err := d.DialContext(ctx, "tcp", tc.Server)
	if err != nil {
		return nil, fmt.Errorf("connect to turn server failed: %w", err)
	}

	var success bool
	defer func() {
		if !success {
			_ = ctrlConn.Close()
		}
	}()

	_ = ctrlConn.SetDeadline(time.Now().Add(tc.Timeout))

	tpAttr := buildAttr(atRequestedTransport, []byte{6, 0, 0, 0}) // TCP = 6
	tid := newTxID()
	req := buildStunMsg(mtAllocateRequest, tid, tpAttr)
	if _, err := ctrlConn.Write(req); err != nil {
		return nil, fmt.Errorf("write allocate request failed: %w", err)
	}

	resp, err := readStun(ctrlConn)
	if err != nil {
		return nil, fmt.Errorf("read allocate response failed: %w", err)
	}

	var key []byte
	var authAttrs [][]byte

	if resp.MsgType == mtAllocateError {
		errVal, ok := resp.Attrs[atErrorCode]
		errCode := 0
		if ok && len(errVal) >= 4 {
			errCode = int(errVal[2]&7)*100 + int(errVal[3])
		}
		if errCode == 401 && tc.Username != "" {
			realm := string(resp.Attrs[atRealm])
			nonce := resp.Attrs[atNonce]
			sum := md5.Sum([]byte(fmt.Sprintf("%s:%s:%s", tc.Username, realm, tc.Password)))
			key = sum[:]

			authAttrs = [][]byte{
				buildAttr(atUsername, []byte(tc.Username)),
				buildAttr(atRealm, []byte(realm)),
				buildAttr(atNonce, nonce),
			}

			tid = newTxID()
			req = signStunMsg(buildStunMsg(mtAllocateRequest, tid, append([][]byte{tpAttr}, authAttrs...)...), key)
			if _, err := ctrlConn.Write(req); err != nil {
				return nil, fmt.Errorf("write authed allocate request failed: %w", err)
			}

			resp, err = readStun(ctrlConn)
			if err != nil {
				return nil, fmt.Errorf("read authed allocate response failed: %w", err)
			}
		}
	}

	if resp.MsgType != mtAllocateSuccess {
		return nil, fmt.Errorf("allocate failed with msg type: 0x%04x", resp.MsgType)
	}

	// 2. CreatePermission
	tid = newTxID()
	xorPeer := buildXorPeerAddress(targetIP, targetPort, tid)
	peerAttr := buildAttr(atXorPeerAddress, xorPeer)

	permReq := signStunMsg(buildStunMsg(mtCreatePermRequest, tid, append([][]byte{peerAttr}, authAttrs...)...), key)
	if _, err := ctrlConn.Write(permReq); err != nil {
		return nil, fmt.Errorf("write create permission failed: %w", err)
	}
	permResp, err := readStun(ctrlConn)
	if err != nil || permResp.MsgType != mtCreatePermSuccess {
		return nil, fmt.Errorf("create permission failed: %v", err)
	}

	// 3. Connect
	tid = newTxID()
	connReq := signStunMsg(buildStunMsg(mtConnectRequest, tid, append([][]byte{peerAttr}, authAttrs...)...), key)
	if _, err := ctrlConn.Write(connReq); err != nil {
		return nil, fmt.Errorf("write connect request failed: %w", err)
	}
	connResp, err := readStun(ctrlConn)
	if err != nil || connResp.MsgType != mtConnectSuccess {
		return nil, fmt.Errorf("connect request failed: %v", err)
	}

	cid, ok := connResp.Attrs[atConnectionID]
	if !ok || len(cid) != 4 {
		return nil, errors.New("missing or invalid connection-id attribute in connect response")
	}

	// 4. Second TCP connection for ConnectionBind
	dataConn, err := d.DialContext(ctx, "tcp", tc.Server)
	if err != nil {
		return nil, fmt.Errorf("connect data connection to turn failed: %w", err)
	}

	_ = dataConn.SetDeadline(time.Now().Add(tc.Timeout))
	tid = newTxID()
	cidAttr := buildAttr(atConnectionID, cid)
	bindReq := signStunMsg(buildStunMsg(mtConnectionBindRequest, tid, append([][]byte{cidAttr}, authAttrs...)...), key)
	if _, err := dataConn.Write(bindReq); err != nil {
		_ = dataConn.Close()
		return nil, fmt.Errorf("write connection bind failed: %w", err)
	}

	bindResp, err := readStun(dataConn)
	if err != nil || bindResp.MsgType != mtConnectionBindSuccess {
		_ = dataConn.Close()
		return nil, fmt.Errorf("connection bind failed: %v", err)
	}

	// 清除超时限制，允许正常长连接流通
	_ = dataConn.SetDeadline(time.Time{})
	_ = ctrlConn.SetDeadline(time.Time{})

	success = true
	return &relayConn{Conn: dataConn, ctrlConn: ctrlConn}, nil
}

// SOCKS5 Implementation
type SocksServer struct {
	ListenAddr string
	Turn       *TurnClient
}

func (s *SocksServer) handleConnection(clientConn net.Conn) {
	defer clientConn.Close()

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
	// Reply NO_AUTH (0x00)
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
		// Resolve domain (prefer IPv4 for broader TURN server compatibility)
		ips, err := net.LookupIP(host)
		if err != nil || len(ips) == 0 {
			_, _ = clientConn.Write([]byte{0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Host unreachable
			return
		}
		for _, ip := range ips {
			if ip4 := ip.To4(); ip4 != nil {
				targetIP = ip4
				break
			}
		}
		if targetIP == nil {
			targetIP = ips[0]
		}
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

	// Connect to TURN
	ctx, cancel := context.WithTimeout(context.Background(), s.Turn.Timeout)
	defer cancel()

	relayConn, err := s.Turn.DialRelay(ctx, targetIP, targetPort)
	if err != nil {
		log.Printf("[turn2socks] Relay to %s:%d failed: %v", host, targetPort, err)
		_, _ = clientConn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Connection refused
		return
	}
	defer relayConn.Close()

	// SOCKS5 success reply
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
		_, _ = io.Copy(relayConn, clientConn)
		closeWrite(relayConn)
	}()

	go func() {
		defer wg.Done()
		_, _ = io.Copy(clientConn, relayConn)
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
	turnUser := flag.String("user", "", "TURN username (optional)")
	turnPass := flag.String("pass", "", "TURN password (optional)")
	timeoutSec := flag.Int("timeout", 10, "Relay connection timeout in seconds")
	flag.Parse()

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
