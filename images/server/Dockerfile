FROM golang:1.26-alpine AS builder
RUN apk add --no-cache git

# Copy local module sources to paths matching go.mod replace directives
COPY temporal/temporal /deps/temporal
COPY temporal-configmap-dynconfig /deps/temporal-configmap-dynconfig
COPY temporal-helm-superchart/images/server /app

WORKDIR /app
ENV GOWORK=off
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -o temporal-server .

FROM alpine:latest
RUN apk add --no-cache bash ca-certificates tzdata netcat-openbsd && \
    addgroup -S temporal && adduser -S temporal -G temporal
COPY --from=builder /app/temporal-server /usr/local/bin/temporal-server
COPY temporal-helm-superchart/images/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
USER temporal
ENV USER=temporal
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
