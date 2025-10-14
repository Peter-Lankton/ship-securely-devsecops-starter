# --- build stage ---
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/server ./main.go

# --- runtime stage ---
FROM alpine:3.20
RUN adduser -D -u 10001 appuser
WORKDIR /home/appuser
COPY --from=build /out/server /usr/local/bin/server
USER appuser
EXPOSE 3000
ENV PORT=3000
ENTRYPOINT ["/usr/local/bin/server"]
