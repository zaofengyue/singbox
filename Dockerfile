FROM alpine:latest
RUN apk add --no-cache curl tar python3
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
