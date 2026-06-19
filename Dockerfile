FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    curl \
    tar \
    python3 \
    openssl \
    ca-certificates \
    netcat-openbsd \
    iproute2

WORKDIR /app

COPY singbox.sh /app/singbox.sh
RUN chmod +x /app/singbox.sh

EXPOSE 3000

CMD ["/app/singbox.sh"]
