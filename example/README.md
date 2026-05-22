# docker-compose-patterns — exemplo completo

Demo minimalista que aplica todos os padrões do documento `README_PT-BR.md`:

- **Multi-stage Dockerfile** (Node, Go).
- **`docker-compose.yml` (espelho de prod)** + **`docker-compose.override.yml.example` (dev)**.
- **Duas redes** (`internal` privada do projeto + `catraca` externa entre projetos).
- **BFF** como única fronteira pública pro `backend`.
- **Internal token** entre BFF e backend.
- **Volume anônimo** pra `node_modules` no override.
- **Volume nomeado** pra persistir o Mongo.
- **`Makefile`** com bootstrap idempotente (`make setup`) e debug de rede (`make ip SVC=...`).

## A stack

| Serviço     | Tecnologia          | O que faz                                                  |
|-------------|---------------------|------------------------------------------------------------|
| `frontend`  | `nginx` + HTML/JS   | Página com um botão. Clique = request via BFF.             |
| `bff`       | Node + Express      | Cookie de sessão (HTTPOnly), agrega resposta, fala com backend usando `X-Internal-Token`. |
| `backend`   | Go + `net/http`     | Persiste o contador global no Mongo. Rejeita request sem token. |
| `database`  | MongoDB             | Guarda o contador. Não exposto pra fora.                   |

A demo é um **contador**:

- **`global`** — incrementado por qualquer um, persistido no Mongo. Refresh mantém. Abre numa janela anônima e o valor segue lá (compartilhado entre sessões).
- **`mine`** — quantas vezes a **sua** sessão clicou. Mantido em memória pelo BFF, atrelado ao cookie HTTPOnly. Numa janela anônima começa do zero (cookie novo).

## Subindo o stack

```bash
# Primeira vez:
make setup     # cria .env + docker-compose.override.yml + network 'catraca'
make up        # sobe tudo com hot reload

open http://localhost:3001
```

Clique no botão. Se o `global` está incrementando e `mine` também, toda a chain funcionou.

## Vendo a topologia

```bash
make ips                  # lista IP de cada serviço em cada network
make ip SVC=backend       # IP só do backend
make sh SVC=bff           # shell dentro do bff
make logs SVC=backend     # logs do backend
```

## Simulando o ambiente de produção

```bash
make prod-like
```

Sobe usando **só** o `docker-compose.yml` (sem o override). Isso significa:

- Imagens buildadas localmente são usadas como se viessem do registry (`localhost/exemplo/...:latest`).
- **A porta do backend não existe.** Tente `curl localhost:8080/counter` e veja: connection refused. O único jeito de chegar no backend é via BFF.
- Tente `curl -H "X-Internal-Token: errado" http://<IP-do-backend>:8080/counter` (use `make ip SVC=backend` pra pegar o IP em dev): 401.

> Em produção real, esse compose vira manifest de Kubernetes/Swarm. O que rodaria no servidor seria o orquestrador, não o `docker compose up`. Aqui usamos pra **validar localmente** que o stack se comporta como em prod.

## Testando o `--scale`

```bash
docker compose up -d --scale backend=3
make ips                 # vê backend-1, backend-2, backend-3 cada um com IP próprio
```

DNS interno faz round-robin entre as réplicas. Como o estado mora no Mongo, todas compartilham o mesmo contador (incrementos contam pra todas). Útil pra testar comportamento sob carga ou validar que o serviço é stateless.

## Estrutura

```
example/
├── README.md                            # você está aqui
├── Makefile                             # bootstrap + atalhos do dia a dia
├── .env.sample
├── .gitignore
├── docker-compose.yml                   # espelho de prod
├── docker-compose.override.yml.example  # template de dev
├── frontend/
│   ├── .docker/build/Dockerfile         # single-stage: só nginx + index.html
│   ├── .dockerignore
│   └── index.html                       # vanilla JS, sem build step
├── bff/
│   ├── .docker/build/Dockerfile         # multi-stage Node
│   ├── .dockerignore
│   ├── package.json
│   └── server.js                        # ~90 linhas: Express + cookie + composição
├── backend/
│   ├── .docker/build/Dockerfile         # multi-stage Go (scratch no final)
│   ├── .dockerignore
│   ├── .air.toml                        # hot reload em dev
│   ├── go.mod
│   └── cmd/server/main.go               # ~90 linhas: net/http + Mongo + token middleware
└── database/
    └── init.js                          # seed: cria contador zerado
```

## Comandos do Makefile

```
make help              # lista tudo
make setup             # bootstrap (env + override + network)
make up                # docker compose up -d
make down              # docker compose down
make prod-like         # sobe sem override (simula prod)
make logs SVC=bff      # tail -f de um serviço
make rebuild SVC=bff   # build --no-cache
make sh SVC=backend    # exec sh
make ip SVC=backend    # IP do serviço em cada network
make ips               # IPs de todos
make clean             # down + remove volumes anônimos
make network           # cria a network 'catraca' (idempotente)
make network-rm        # remove a network 'catraca'
make sync-override     # puxa atualização do .yml.example pro local
make reset-override    # apaga override local
```

## Aprendizado por trás de cada peça

| Padrão | Onde aparece neste exemplo |
|--------|----------------------------|
| Multi-stage Dockerfile com `target: dev` | `backend/.docker/build/Dockerfile`, `bff/.docker/build/Dockerfile` |
| BFF como fronteira pública | `bff/server.js`, backend sem `ports:` no compose |
| Internal token entre serviços | `INTERNAL_TOKEN` no `.env`, middleware no backend |
| Cookie HTTPOnly | `bff/server.js` → `ensureSession` |
| Composição de resposta | `bff/server.js` → `global` (backend) + `mine` (BFF) |
| Network `internal` privada | `database` só na `internal`, sem acesso externo |
| Network `catraca` external | Permite outros projetos baterem em `http://bff:3000` |
| DNS interno por nome | `BACKEND_URL=http://backend:8080`, `DATABASE_URL=mongodb://database:27017` |
| Volume nomeado pra persistência | `database-data:/data/db` |
| Volume anônimo pra `node_modules` | `bff` no override: `/app/node_modules` |
| Bind mount pra hot reload | `bff` e `backend` montam código do host |
| `.dockerignore` corta peso | `node_modules`, `.docker`, `tmp/` |
| Defaults com `${VAR:-fallback}` | Todos os `ports:` e `env`s |
| Sem `container_name:` | Permite `--scale` |
| Pin de versão (sem `latest` em imagens base) | `golang:1.25-alpine`, `node:22-alpine`, `mongo:7.0.14`, `nginx:1.27-alpine` |

## Próximos passos

Esse repo é template. Pra adaptar pro seu projeto real:

1. Renomeie `exemplo/...` nas imagens pro seu namespace de registry.
2. Troque `INTERNAL_TOKEN` por algo gerado (`openssl rand -hex 32`) e mova pro seu secret manager em prod.
3. Adicione `healthcheck:` e `depends_on: condition: service_healthy` se precisar de ordem de subida garantida.
4. Adicione `logging:` com `max-size` / `max-file` antes de ir pra prod.
5. Configure `mem_limit:` se for rodar várias stacks na mesma máquina.

Tudo isso está coberto em detalhe no `README_PT-BR.md`.
