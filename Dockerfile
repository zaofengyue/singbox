FROM alpine:latest
RUN apk add --no-cache curl tar python3 openssl ca-certificates
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
