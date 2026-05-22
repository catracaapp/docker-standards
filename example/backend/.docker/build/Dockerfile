# =====================================================================
# Multi-stage Dockerfile: dev (Air, hot reload) → build (compila binário) → runtime (scratch)
# =====================================================================

FROM golang:1.25-alpine AS dev
RUN go install github.com/air-verse/air@latest
WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# Em dev o bind mount do override sobrescreve esse snapshot → hot reload
# pega edições no host. Sem bind mount, a imagem continua rodando
# contra esse snapshot — autocontida.
CMD ["air", "-c", ".air.toml"]

# ---------------------------------------------------------------------

FROM dev AS build
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/build/server ./cmd/server

# ---------------------------------------------------------------------

FROM scratch AS runner
# certificados CA: necessário para chamadas HTTPS de saída (driver Mongo, etc.)
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /app/build/server /server
EXPOSE 8080
# Como scratch não tem shell/curl/wget, o próprio binário expõe o
# subcomando `healthcheck` (ver cmd/server/main.go). Quem buildar essa
# imagem direto via `docker build` herda esse healthcheck.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/server", "healthcheck"]
ENTRYPOINT ["/server"]
