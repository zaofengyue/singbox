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

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 3000

CMD ["/app/entrypoint.sh"]
