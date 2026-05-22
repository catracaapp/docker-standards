# Padrões de Docker — Catraca

Este documento descreve as convenções de Docker, Compose, Makefile e ignores que adotamos nos projetos da Catraca. O objetivo é dar contexto a quem entra novo no time (e à comunidade que quiser adotar o mesmo padrão) e justificar **por que** cada decisão existe, não só o que ela faz.

> 🇺🇸 English version: [README.md](./README.md)

## Stack de exemplo usada ao longo do documento

Toda a parte prática usa uma stack genérica de quatro camadas:

| Serviço      | Tecnologia    | Papel                                                  | Exposição pública |
|--------------|---------------|--------------------------------------------------------|-------------------|
| `frontend`   | Next.js       | UI no navegador (SSR + client)                         | Sim (HTTPS)       |
| `bff`        | NestJS        | Backend-for-frontend: agrega/adapta o `backend`        | Sim (HTTPS)       |
| `backend`    | Go            | API de domínio (regras de negócio, persistência)       | **Não** em prod   |
| `database`   | MongoDB       | Persistência do `backend`                              | **Não** nunca     |

Por cima, uma **network externa compartilhada** chamada `catraca` conecta cada projeto deste e de outros repositórios. Em produção, só `frontend` e `bff` aparecem para o mundo externo; `backend` e `database` ficam invisíveis. Em dev, o override expõe a porta do `backend` para Postman/debug.

### Por que tem um BFF entre o frontend e o backend?

O BFF (Backend-for-frontend) é uma camada de fachada: ele recebe as requisições do navegador via HTTPS e fala com o `backend` por dentro da rede do Docker. Em produção, o `backend` não tem `ports:` declaradas — ninguém de fora consegue alcançá-lo, e o BFF é a única fronteira pública entre o mundo externo e o domínio. Outras vantagens (compor respostas pro frontend, concentrar auth e rate limit) aparecem naturalmente, mas a motivação primária no nosso padrão é essa: **proteger o backend atrás de uma camada extra**.

> Daqui pra frente: "BFF" é a camada NestJS que expõe HTTPS pro mundo, "backend" é a API Go interna, "database" é o Mongo. Padrão originalmente descrito por [Phil Calçado](https://philcalcado.com/2015/09/18/the_back_end_for_front_end_pattern_bff.html) e [Sam Newman](https://samnewman.io/patterns/architectural/bff/).

---

## 1. Visão geral da arquitetura de arquivos

Todos os projetos seguem a mesma estrutura mínima:

```
projeto/
├── .docker/
│   ├── build/
│   │   └── Dockerfile                  # único Dockerfile, multi-stage
│   ├── data/                           # volumes locais (ignorados no git)
│   └── .gitignore                      # ignora `data/` dentro do próprio .docker
├── .dockerignore                       # corta peso e segredos do build context
├── .gitignore
├── Makefile                            # bootstrap + atalhos do dia a dia
├── .env.sample                         # template versionado das envs
├── .env                                # cópia local (gitignorada), gerada pelo make
├── docker-compose.yml                  # stack base que simula localmente o ambiente de prod
├── docker-compose.override.yml.example # template versionado do override
└── docker-compose.override.yml         # cópia local do default (gitignorada)
```

Essa repetição é proposital: ao trocar de repositório, o desenvolvedor encontra os mesmos pontos nos mesmos lugares.

---

## 2. A pasta `.docker/`

### Por que existe

A pasta `.docker/` agrupa **tudo que pertence ao Docker mas não ao código da aplicação**:

- `build/Dockerfile` — receita de build.
- `data/` — bind mounts locais (banco, redis, etc.).
- Subpastas opcionais para stateful (`grafana/`, `redis_data/`, …) quando o compose precisa montar.

### Vantagens

1. **Raiz do projeto limpa.** Sem 4-5 arquivos `Dockerfile.*`, `docker-entrypoint.sh`, configs avulsas poluindo a listagem do `ls`.
2. **Escopo único de ignore.** Como tudo de Docker mora em `.docker/`, basta uma linha no `.dockerignore` (`.docker`) para evitar que o diretório de build, dados e provisionamento volte como contexto e infle a imagem.
3. **Volumes versionáveis vs. dados voláteis convivem.** O `.docker/build/Dockerfile` entra no git; o `.docker/data/` fica de fora via `.docker/.gitignore` interno (com uma linha apenas: `data`). Isso evita poluir o `.gitignore` raiz com regras de baixo nível.
4. **Caminho previsível para o Compose.** Todo `docker-compose.override.yml` aponta `dockerfile: .docker/build/Dockerfile`. Não há ambiguidade sobre "qual Dockerfile usar?".

---

## 3. Multi-stage Dockerfile

Antes de falar de Compose, precisamos do Dockerfile certo. Todos os projetos usam Dockerfile **multi-stage** para servir o mesmo arquivo em dev e em produção. Sem isso, você acaba com `Dockerfile.dev` e `Dockerfile.prod` divergindo ao longo do tempo.

Um "stage" é uma seção do Dockerfile iniciada por `FROM ... AS <nome>`. Cada stage pode copiar arquivos de stages anteriores via `COPY --from=<stage>`. No fim, só o último stage vira a imagem padrão; os intermediários servem de fonte para o cache de build.

### Exemplo Node (frontend Next.js / bff NestJS)

```dockerfile
FROM node:22-alpine AS base

# 1. deps — só instala node_modules
FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci

# 2. dev — hot reload (start:dev no NestJS, next dev no Next.js)
FROM base AS dev
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
EXPOSE 3000
CMD ["npm", "run", "start:dev"]

# 3. builder — gera o build de produção
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# 4. runner — imagem final mínima, com usuário não-root
FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup --system --gid 1001 nodejs && adduser --system --uid 1001 app
COPY --from=builder --chown=app:nodejs /app/dist ./dist
COPY --from=builder --chown=app:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=app:nodejs /app/package.json ./
USER app
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

> No Next.js, troque o `runner` para usar o `standalone output` (feature do Next.js que empacota só o estritamente necessário pra runtime): `COPY /app/.next/standalone ./` + `COPY /app/.next/static ./.next/static`. Gera uma imagem ainda menor, sem `node_modules` no runtime.

### Exemplo Go (backend)

```dockerfile
FROM golang:1.25-alpine AS dev
RUN go install github.com/air-verse/air@latest
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
CMD ["air", "-c", ".air.toml"]

FROM dev AS build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/build/server ./cmd/server

FROM scratch
# certificados CA: necessário para chamadas HTTPS de saída
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
# tzdata: se o app usa time.LoadLocation ("America/Sao_Paulo", etc.)
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
# /etc/passwd: necessário se for rodar como USER non-root
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /app/build/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
```

> **Alternativa moderna:** em vez de montar `scratch` à mão, considere `gcr.io/distroless/static-debian12:nonroot` (Google) ou `cgr.dev/chainguard/static` (Chainguard). Ambos já trazem `ca-certificates`, `tzdata`, usuário não-root e recebem atualizações de segurança, sem você precisar lembrar de copiar 3 arquivos do build stage. `scratch` continua válido quando cada megabyte importa ou quando o requisito é "zero camadas além do seu binário".

### Vantagens do multi-stage

1. **Um Dockerfile, vários alvos.**
   - `target: dev` no Compose override → roda hot reload.
   - Sem `target` no compose principal → builda até o último stage (`runner` ou `scratch`) e usa a imagem leve de produção.
   Isso elimina a duplicação `Dockerfile.dev` + `Dockerfile.prod`.

2. **Cache reutilizado entre stages.** O stage `deps` só roda `npm ci` (ou `go mod download`) quando `package.json`/`package-lock.json` (ou `go.mod`/`go.sum`) mudam. Mudanças em código (`COPY . .` no `builder`) não invalidam a camada de dependências.

3. **Imagem final enxuta.**
   - Backend Go termina em `FROM scratch` (só binário estático + certificados CA). Resultado: imagem na casa de **dezenas de MB**, sem shell, sem package manager, sem CVE de pacote do sistema.
   - Frontend Next.js com `standalone output` copia só o estritamente necessário, sem `node_modules` no runtime.

4. **Segurança por construção.**
   - Usuário não-root no runtime.
   - Sem `npm`/`apk`/`bash` na imagem final → menor superfície de ataque.
   - `CGO_ENABLED=0` no Go → binário estático sem dependências de libc, roda em qualquer base mínima.

5. **Build de múltiplos binários numa só imagem.** Em projetos Go com vários `cmd/*` (ex.: `server`, `worker`, `scheduler`), basta iterar dentro do stage `build` e gerar todos os binários. O `docker-compose.yml` então roda **a mesma imagem com `command` diferente** (N serviços, um build).

---

## 4. Networks Docker

Com o Dockerfile resolvido, o próximo bloco fundamental é como os containers se conectam.

### Duas redes, três zonas de exposição

Cada projeto declara **duas redes** no compose, e a combinação delas com a presença/ausência de `ports:` dá origem a três zonas de visibilidade:

| Zona              | Quem entra                         | Como se alcança                     |
|-------------------|------------------------------------|--------------------------------------|
| Pública (host)    | Serviços com `ports:` declaradas   | `localhost:PORTA` no navegador       |
| `catraca` (entre projetos) | Serviços listados em `networks: [catraca]` | Outros containers da `catraca` resolvem pelo nome do serviço |
| `internal` (do projeto) | Tudo que está no compose do projeto | Só os próprios containers do compose se enxergam |

Bancos de dados ficam **apenas em `internal`**. BFF e frontend ficam em `internal` + `catraca`. O `backend` também em ambas, mas sem `ports:` em produção.

### Por que duas redes em vez de uma

- **Isolamento.** O `database` deste projeto não precisa (e não deve) ser visível para outros projetos da empresa. Mantendo-o só na rede `internal`, ele fica inacessível a partir de outros repos mesmo que estejam todos rodando.
- **Superfície de ataque menor.** Containers que não exportam serviço público (banco, cache, worker) ficam apenas na rede interna. Só apps que precisam falar com outros projetos entram na `catraca`.
- **Independência de ordem de subida.** Como a `catraca` é `external`, você sobe os projetos em qualquer ordem: quando o segundo subir, ele já enxerga o primeiro via DNS interno do Docker.
- **DNS gratuito entre projetos.** Dentro da `catraca`, qualquer serviço resolve pelo nome (`bff`, `backend`, `gateway`…), sem precisar de IP estático, `/etc/hosts` ou config de descoberta. Como isso funciona exatamente está na seção 5.

### Declaração no compose

```yaml
networks:
  internal:                        # Compose prefixa com COMPOSE_PROJECT_NAME → vira "<projeto>_internal"
  catraca:
    external: true
    name: catraca                  # `name:` desativa o prefixo e usa o nome literal no daemon
```

Cada serviço escolhe as redes que participa:

```yaml
services:
  frontend:
    networks: [catraca]            # só pública + catraca; não fala com db direto
  bff:
    networks: [internal, catraca]  # fala com backend interno + outros projetos
  backend:
    networks: [internal, catraca]  # internal pra database, catraca pra ser chamado
  database:
    networks: [internal]           # NUNCA na catraca: banco é privado ao projeto
```

### Criação idempotente da network externa

A network externa precisa existir **antes** de qualquer `docker compose up`, senão o Compose falha com `network catraca declared as external, but could not be found`. O Makefile do projeto resolve isso com um alvo idempotente:

```makefile
EXTERNAL_NETWORK := catraca

.PHONY: network
network: ## Cria a network externa `catraca` se ainda não existir
	@if docker network inspect $(EXTERNAL_NETWORK) >/dev/null 2>&1; then \
		echo "✓ Network '$(EXTERNAL_NETWORK)' já existe"; \
	else \
		echo "→ Criando network '$(EXTERNAL_NETWORK)'..."; \
		docker network create --driver bridge $(EXTERNAL_NETWORK); \
		echo "✓ Network '$(EXTERNAL_NETWORK)' criada"; \
	fi
```

Detalhes:

- **Idempotente.** `docker network inspect` retorna 0 se a network existe e ≠0 caso contrário. O `make` só cria quando precisa.
- **`--driver bridge`** explícito: é o default, mas torna a intenção clara (sem `overlay`/`macvlan`). _Nota: `--attachable` só é relevante em redes `overlay` no modo Swarm; em `bridge` single-host ele é no-op._
- **Dependência transitiva.** Os alvos `setup`, `up` e `prod-like` listam `network` como pré-requisito, então o desenvolvedor nunca esquece de criá-la.
- **Não removida pelo `clean`.** `docker compose down -v` derruba só os recursos do projeto; a network externa fica de pé porque outros projetos dependem dela. Para remover, `make network-rm` (e só roda se ninguém estiver conectado).

### Quem está em qual zona

| Serviço     | Porta exposta no host | Rede `catraca` | Rede `internal` |
|-------------|----------------------|----------------|-----------------|
| `frontend`  | ✓ `3001:3000`         | ✓              | ✗               |
| `bff`       | ✓ `3000:3000`         | ✓              | ✓               |
| `backend`   | ✗ (só em dev override)| ✓              | ✓               |
| `database`  | ✗                     | ✗              | ✓               |

Lendo a tabela: o `frontend` é alcançável pelo navegador e por outros projetos da `catraca`, mas não enxerga o `database`. O `database` só é enxergado pelo `backend` (porque ambos estão na `internal`); ninguém de fora consegue chegar nele, nem na mesma máquina via outro projeto.

### Como uma request percorre tudo

```
navegador
   │  HTTPS localhost:3000
   ▼
[ bff ]  ──► http://backend:8080   (via catraca ou internal — ambos resolvem)
   ▲
   │
[ backend ]  ──► mongodb://database:27017   (via internal)
                      ▲
                      │
                [ database ]
```

O `frontend` faz o mesmo caminho pra navegação pública: navegador → `localhost:3001` → frontend → `http://bff:3000` (via catraca) → backend → database.

### Por que isso é importante

1. **Plug-and-play entre repos.** Para o `bff` chamar um serviço de outro projeto, você não muda config, não cria IP. Basta garantir que ambos estão na `catraca` e usa `http://nome-do-servico:porta`.
2. **Segurança em camadas.** Banco invisível mesmo se outro app na mesma máquina for comprometido. Backend invisível se o BFF não vazar.
3. **Paridade dev ↔ produção.** Em produção pode trocar `catraca` por uma overlay/Swarm/Kubernetes service-mesh sem mudar a estrutura do compose; só a forma de criar a network muda.
4. **Onboarding seguro.** Quem clona o repo pela primeira vez não precisa lembrar de `docker network create catraca`. O `make setup` (e `make up`) garante.

---

## 5. DNS interno do Docker: como serviços se enxergam

Networks só são úteis porque vêm com **DNS automático**. Quando um container precisa falar com outro, ele usa um *hostname*, não um IP. Esse hostname é o **nome do serviço no `docker-compose.yml`**.

### O nome do serviço é o hostname

Sempre que você declara:

```yaml
services:
  backend:
    ...
```

o Docker cria automaticamente uma entrada de DNS para `backend` resolvível por qualquer container que esteja na mesma network. Não há `/etc/hosts` para editar, não há configuração de DNS para fazer. O Docker mantém um resolver embutido (escutando em `127.0.0.11` via TCP+UDP de cada container) que responde a queries pelos nomes dos serviços.

> Esse DNS embutido só existe em **user-defined networks** (qualquer network que você crie no compose ou via `docker network create`). A network `bridge` default original não tem resolução por nome. Outro motivo para sempre declarar suas próprias networks.

Então o BFF chamando o backend é literalmente:

```
http://backend:8080
```

A porta `8080` aí é a porta **interna** do container do backend (a do `EXPOSE 8080` no Dockerfile), não a porta do host. Isso vale mesmo que o backend não tenha `ports:` declaradas: porta interna existe sempre, é só a publicação para o host que é opcional.

### Por que `localhost` NÃO funciona entre containers

Erro recorrente em onboarding: configurar o BFF com `BACKEND_URL=http://localhost:8080`. Não funciona, porque:

- `localhost` dentro de um container resolve para a interface de rede só visível pra ele mesmo (`127.0.0.1` daquele container).
- O backend não está rodando dentro do container do BFF; está em outro container, com sua própria interface de rede e seu próprio `localhost`.
- A porta `8080` que aparece em `localhost:8080` do **seu host (laptop)** só existe porque você declarou `ports: "8080:8080"` no compose; isso é uma ponte do host pro container, não algo que outros containers usam.

Resumo de quem fala com quem e como:

| Origem                                  | Como chega no `backend`               |
|------------------------------------------|---------------------------------------|
| Outro container na **mesma network**    | `http://backend:8080` (DNS do Docker) |
| Seu navegador / Postman no **host**     | `http://localhost:8080` (só funciona se o serviço expôs `ports:`) |
| Container que NÃO está na mesma network | Não consegue alcançar (mesmo se rodando lado a lado) |

### Porta interna vs porta exposta

Numa linha como:

```yaml
ports:
  - "${BFF_PORT:-3000}:3000"
```

- Número da **esquerda** = porta no HOST.
- Número da **direita** = porta DENTRO do container.

Outros containers sempre usam a porta **interna** (direita). Só o host (navegador, Postman, `curl localhost`) usa a porta externa (esquerda).

Exemplo prático: se você quiser rodar dois projetos no mesmo host e ambos os BFFs escutam em 3000, basta mudar o lado esquerdo no override local de um deles:

```yaml
bff:
  ports:
    - "3100:3000"   # host:container — só muda a porta do host
```

O bff continua escutando em 3000 internamente. Outros containers chamam `http://bff:3000` sem mudar nada. Só o seu navegador agora precisa de `http://localhost:3100`.

### Networks definem quem se enxerga

DNS só funciona dentro de uma network compartilhada. Se o `bff` está em `[internal, catraca]` e o `backend` também em `[internal, catraca]`, eles se enxergam por qualquer uma das duas. Se você esquece de colocar o backend na `catraca`, projetos de outros repos não vão alcançá-lo mesmo que estejam rodando no mesmo Docker daemon.

Regras práticas de resolução:

- Mesma network → resolve direto pelo nome do serviço.
- Networks diferentes (mesmo daemon) → não resolve.
- Network `external: true` (`catraca`) → todos os projetos que entram nela compartilham resolução, como se fossem um stack só.

### Falando com algo FORA do Docker: `host.docker.internal`

Às vezes você precisa que um container alcance algo rodando **no host** (não em outro container). Alguns exemplos:

- Um banco que você instalou localmente sem container.
- Um proxy de auth (Keycloak, mitmproxy) aberto numa porta do seu laptop.
- Um serviço de terceiros que você está mockando no host.

No **Docker Desktop (Mac/Windows)**, o hostname `host.docker.internal` já resolve automaticamente para o gateway do host. Basta usar `http://host.docker.internal:PORTA` no código.

No **Linux nativo**, esse hostname não existe por padrão. Para criar o mapeamento (disponível desde o Docker Engine **20.10**), você adiciona a linha no serviço que precisar:

```yaml
services:
  backend:
    extra_hosts:
      - host.docker.internal:host-gateway   # cria o mapping no Linux
```

> **Não é padrão da stack.** Isso NÃO deve entrar no `docker-compose.yml` nem no `docker-compose.override.yml.example` como hábito. É uma dica para quando você bater num caso específico de cruzar a barreira container → host. Quando precisar, declare apenas no serviço específico, idealmente no seu `docker-compose.override.yml` local (que está gitignorado), e remova quando terminar.

**Pegadinha comum:** `host-gateway` resolve para o IP do bridge do Docker (tipicamente `172.17.0.1` em Linux). Para o container conseguir conectar, o serviço no host precisa estar bindado em `0.0.0.0` (todas as interfaces), não só em `127.0.0.1`: caso contrário a conexão é recusada. Se você roda algo tipo `python -m http.server 8000` (que faz bind em `0.0.0.0` por default) funciona; se roda algo bindado em `127.0.0.1` (vários servers de dev fazem isso por padrão), não.

---

## 6. `docker-compose.yml` vs `docker-compose.override.yml`

Agora que você sabe o que é multi-stage, network e DNS, dá pra olhar pro Compose sem mistério. Esta é a peça central do padrão.

> **Importante:** não fazemos deploy de produção com `docker compose up`. Produção roda em Kubernetes, Swarm, ECS ou similar — orquestradores que entregam HA, rolling deploy, schedulling, etc. O `docker-compose.yml` aqui é um **espelho local** do que vai pra produção: mesma topologia de rede, mesmas imagens versionadas, mesmas portas expostas. Quando você roda `make prod-like`, está validando "esse stack se parece com o de prod o suficiente pra reproduzir bugs e testar integração" — não está produzindo um deploy real.

### `docker-compose.yml` — simulação local do ambiente de produção

O `docker-compose.yml` descreve **como o stack se parece em produção**: imagens versionadas (puxadas do registry, não buildadas), portas só do que é público, comandos finais, redes. Nada de `build:`, nada de bind mount com código fonte, nada de credenciais default.

> **Regra dura:** **`image:` mora no `docker-compose.yml`; `build:` mora SÓ no `docker-compose.override.yml.example`.** Essa separação não é estilo, é coerência com o ciclo de vida real:
>
> - Em prod, ninguém builda no servidor — o orquestrador puxa a imagem do registry. Então o `docker-compose.yml` (que espelha a topologia de prod) **não** declara `build:`.
> - Em dev, você precisa compilar o código da sua branch a cada mudança. O `build:` (com `target: dev`) vive no override, junto com os bind mounts e ports de debug.
> - Ao rodar `docker compose build` (que mescla os dois arquivos automaticamente), o compose usa o `image:` do principal como tag de destino e o `build:` do override como receita. Resultado: a tag fica apontando pra imagem buildada no target `dev`.
> - Ao rodar `docker compose -f docker-compose.yml up`, o override é ignorado e a imagem já existente (cacheada localmente ou puxada do registry) é usada como está. Mesma topologia de prod, sem build local.
>
> Isso elimina a ambiguidade "essa tag é dev ou prod?" do dia a dia: ela é o que o último `build`/`pull` colocou ali. Como dev e prod compartilham a tag, o stage `dev` precisa ser **autocontido** (ver §3): se a imagem dev for usada acidentalmente em prod-compose, ela ainda roda contra o snapshot interno em vez de quebrar.

Serve para dois usos:

1. **Localmente, com `make prod-like`**, para reproduzir o comportamento que vai rodar no servidor (backend sem porta exposta, tags pinadas, etc.).
2. **Como referência única de topologia** pro time DevOps que vai traduzir esse compose pra manifests de Kubernetes/Swarm/Helm chart. Quem deploya tem um único arquivo pra olhar e entender o que sobe, em que ordem, com quais networks.

```yaml
services:
  frontend:
    image: ${DOCKER_REGISTRY:-localhost}/exemplo/frontend:${PROJECT_TAG:-latest}
    env_file: .env
    environment:
      NEXT_PUBLIC_API_URL: http://bff:3000    # DNS da catraca: nada de IP, nada de localhost
    ports:
      - "${FRONTEND_PORT:-3001}:3000"
    networks:
      - catraca

  bff:
    image: ${DOCKER_REGISTRY:-localhost}/exemplo/bff:${PROJECT_TAG:-latest}
    env_file: .env
    environment:
      BACKEND_URL: http://backend:8080        # DNS interno
    ports:
      - "${BFF_PORT:-3000}:3000"
    networks:
      - internal
      - catraca

  backend:
    image: ${DOCKER_REGISTRY:-localhost}/exemplo/backend:${PROJECT_TAG:-latest}
    env_file: .env
    environment:
      DATABASE_URL: mongodb://database:27017
    # SEM `ports:` — backend só é alcançado de dentro da catraca/internal
    networks:
      - internal
      - catraca

  database:
    image: mongo:7
    volumes:
      - database-data:/data/db
    networks:
      - internal

networks:
  internal:
  catraca:
    external: true
    name: catraca

volumes:
  database-data:
```

Características que se repetem em todos os projetos:

- **Imagem parametrizada** por `${DOCKER_REGISTRY:-localhost}` e `${PROJECT_TAG:-latest}`. O mesmo arquivo serve para simular prod localmente (sem variáveis → cai no `localhost`) e para alimentar pipelines de CI/CD que puxam as imagens versionadas do registry (`DOCKER_REGISTRY=registry.empresa PROJECT_TAG=v1.2.3 docker compose pull`).
- **Portas e configs com defaults** via `${VAR:-default}`. Permite subir o stack sem nenhum `.env` mínimo.
- **Sem `build:`.** Espelha o cenário real: em prod (Kubernetes/Swarm) ninguém compila no servidor — só puxa imagens do registry. Localmente o `make prod-like` faz a mesma coisa.
- **Topologia conforme a seção 4:** frontend e bff com `ports:`, backend e database sem.

### `docker-compose.override.yml` — default de desenvolvimento

O Compose carrega automaticamente os dois arquivos quando você roda `docker compose up`, mesclando-os. O override é o **complemento de dev**: build local, hot reload, volumes montando código, ports de debug.

```yaml
services:
  frontend:
    build:
      context: ./frontend
      dockerfile: .docker/build/Dockerfile
      target: dev
    volumes:
      - ./frontend:/app
      - /app/node_modules
      - /app/.next
    command: npm run dev

  bff:
    build:
      context: ./bff
      dockerfile: .docker/build/Dockerfile
      target: dev
    volumes:
      - ./bff:/app
      - /app/node_modules      # ← volume anônimo, ver 9.6
    command: npm run start:dev

  backend:
    build:
      context: ./backend
      dockerfile: .docker/build/Dockerfile
      target: dev
    ports:
      - "${BACKEND_PORT:-8080}:8080"   # ← só em DEV: Postman, debugger, scripts
    volumes:
      - ./backend:/app
    command: air -c .air.toml

  database:
    # ports:                   # comentado: descomente se quiser conectar com Compass local
    #   - "${MONGO_PORT:-27017}:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER:-root}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASS:-root}
```

Em dev você consegue `curl http://localhost:8080/api/...` para bater direto no backend (útil pra debug e Postman). Em produção, isso simplesmente não existe. O tráfego sempre entra pelo frontend ou BFF.

### O detalhe que muita gente perde: o padrão `.example`

O arquivo **realmente versionado** não é o `docker-compose.override.yml`, e sim um `docker-compose.override.yml.example`. O override "de verdade" é uma **cópia local** desse template, criada no primeiro `make setup` e listada no `.gitignore`:

```
docker-compose.override.yml.example   ← versionado (template do time)
docker-compose.override.yml           ← ignorado (cópia local do dev)
```

Isso reproduz o mesmo princípio de `.env.sample` (versionado) vs `.env` (ignorado); o `Makefile` cuida das **duas** cópias no mesmo `make setup`. O sufixo `.example` segue convenção amplamente usada na comunidade ([NetBox](https://github.com/netbox-community/netbox-docker/blob/release/docker-compose.override.yml.example), [PyPI Warehouse](https://github.com/pypi/warehouse), entre outros), então quem chega de fora reconhece de imediato. Vantagens:

- **Onboarding com um comando.** `make setup` copia o default e o dev já tem um ambiente funcional sem editar nada.
- **Time atualiza o default sem pisar no pé de ninguém.** Se alguém adiciona um serviço novo (ex.: cache), basta um PR editando o `.yml.example`. Quem quiser puxar atualiza com `make sync-override` (ou apaga o local e roda `make setup` de novo).
- **Liberdade local sem `git stash` eterno.** Pode comentar `depends_on: database` porque você roda Mongo nativo, mudar `mem_limit`, expor portas extras, trocar `command`. O git nunca sabe, porque o arquivo está ignorado.
- **Histórico limpo.** Nenhum PR com "ajuste de override" poluindo o log; só mudanças de infra real, no `.yml.example`.

### Implementando com Makefile

Um `Makefile` cola todo o fluxo (criar network, copiar `.env.sample` → `.env`, copiar `.example` → override local, subir/descer stack, debug de IP por serviço, etc.). Para não duplicar o arquivo aqui, veja o template no repositório de exemplo: [`example/Makefile`](./example/Makefile).

Alvos principais que ele expõe:

| Alvo                | O que faz                                                            |
|---------------------|----------------------------------------------------------------------|
| `make setup`        | Cria network `catraca`, copia `.env.sample → .env` e `.yml.example → .yml` |
| `make up`           | `docker compose up -d` com override aplicado (modo dev)              |
| `make prod-like`    | `docker compose -f docker-compose.yml up -d` (ignora override)       |
| `make sync-override`| Atualiza override local a partir do `.example` (com backup)          |
| `make ip SVC=nome`  | Mostra o IP do serviço em cada network                               |
| `make ips`          | Lista IP de todos os serviços                                        |
| `make logs SVC=...` | Tail de logs por serviço                                             |
| `make sh SVC=...`   | Shell dentro do container                                            |
| `make rebuild SVC=...` | `docker compose build --no-cache <svc>`                           |
| `make network`/`network-rm` | Cria/remove a network externa idempotentemente               |
| `make clean`        | `down -v --remove-orphans` (preserva a network externa)              |
| `make reset-override` | Apaga override local pra recomeçar do default                      |

### Fluxo na prática

```bash
# Primeira vez no projeto:
git clone repo && cd repo
make setup                # copia .env.sample → .env  e  docker-compose.override.yml.example → docker-compose.override.yml
make up                   # sobe banco, bff e backend com hot reload

# Quer testar como produção (backend sem porta exposta):
make prod-like            # ignora o override, usa só o docker-compose.yml

# Time atualizou o default (novo serviço, nova porta):
git pull
make diff-override        # vê o que mudou
make sync-override        # adota o novo default (faz backup do seu antes)

# Quer começar do zero:
make reset-override && make setup
```

### Em resumo

- O `docker-compose.yml` é o **contrato imutável**: descreve a topologia que vai pra prod (no orquestrador real) e serve de espelho local. Não muda por capricho.
- O `docker-compose.override.yml.example` é o **template do time**: versionado, evolui via PR.
- O `docker-compose.override.yml` é o **playground do desenvolvedor**: gitignorado, copiado do default, modificado livremente para cada máquina.
- O `Makefile` cola tudo: `make setup` para começar, `make sync-override` para acompanhar mudanças do time, `make prod-like` para simular o ambiente de prod localmente.

### Por que isso é importante

1. **Onboarding instantâneo.** `git clone && make setup && make up` sobe um ambiente funcional, sem ler README.
2. **Simulação fiel do ambiente de prod.** `make prod-like` ignora o override e sobe o stack como ele se parece em produção (imagens pinadas, backend sem porta exposta, sem hot reload). Útil pra reproduzir bugs específicos do ambiente real sem precisar fazer deploy.
3. **Sem condicionais no Dockerfile.** Não existem `if NODE_ENV=development` espalhados; a diferença entre dev e prod é declarada na orquestração (`target`, `command`, `volumes`, `ports`), onde pertence.
4. **Liberdade sem conflito.** Cada dev pode comentar `depends_on: database` (porque roda Mongo nativo), expor ou esconder portas, mudar versões de imagem, sem nunca abrir PR para isso, e sem `git status` sujo.

---

## 7. `.dockerignore`

Pequeno mas crítico. O "build context" é tudo o que está dentro da pasta que você passa para `docker build .` (ou implícita pelo Compose). O Docker envia esse contexto inteiro para o daemon antes de começar — daí a importância de cortar o que não interessa.

Exemplos típicos:

| Tipo de projeto | Conteúdo do `.dockerignore`          |
|-----------------|--------------------------------------|
| Frontend/BFF Node | `.docker`, `node_modules`, `.next`, `dist`, `.env*` |
| Backend Go      | `.docker`, `build`, `tmp`, `.data`, `.env*` |
| Genérico        | `.git`, `.vscode`, `.idea`, `coverage`, `*.log` |

### Por que é tão importante

1. **Velocidade de build.** Sem `.dockerignore`, o daemon recebe `node_modules/` (centenas de MB), `.next/`, dumps, dados de volume. Build fica lento e estoura cache desnecessariamente.
2. **Cache estável.** Qualquer arquivo em mudança no contexto invalida camadas. Ignorar `node_modules`, `tmp`, `dist` garante que `COPY . .` só dispare quando código de verdade mudou.
3. **Segurança.** Sem ignorar, qualquer `.env`, credenciais ou backups locais viraria parte da imagem. Mesmo que não usados, ficam vazados em qualquer `docker save` ou registry leak.
4. **Coerência com `.docker/`.** Como toda a infraestrutura mora em `.docker/` (incluindo o próprio Dockerfile), ignorar `.docker` no build context evita um loop bobo: o Dockerfile que está sendo executado não precisa estar dentro do contexto que ele copia.
5. **Por que ignorar `.data/` e `.docker/data/`.** Esses diretórios são montados como bind para persistir banco/cache localmente; podem ter gigabytes. Jamais devem ir para o build context.

> Observação prática: `.dockerignore` segue regras parecidas com `.gitignore` mas é independente. Um arquivo pode estar comitado e mesmo assim ser ignorado pelo build (caso típico: `README.md`, `docs/`, `scripts/` de desenvolvimento).

---

## 8. `.gitignore`

Os `.gitignore` seguem dois princípios:

1. **Ignorar tudo que é gerado.** `dist/`, `build/`, `tmp/`, `node_modules/`, `.next/`, `coverage/`, `*.tsbuildinfo`, `next-env.d.ts`.
2. **Ignorar tudo que é local/sensível.** `.env*`, `.idea/`, `.vscode/*` (com exceções para configs compartilháveis do time), `.DS_Store`, `*.swp`, `docker-compose.override.yml`.

### Pontos específicos que viraram convenção

- **`.env*` totalmente ignorado**, com um `.env.sample` versionado servindo como documentação viva das variáveis.
- **Pastas de dados de Compose** (`.docker/data`, `.data/`) ficam fora: esses diretórios são criados em runtime pelos bind mounts.
- **`uploads/`** ignorado em backends que recebem arquivos em dev evita commit acidental.
- **`vendor/` e `go.work`** ignorados em projetos Go: preferimos `go.mod`/`go.sum` reproduzíveis ao invés de vendoring.
- **Configs de IDE seletivas.** O padrão `.vscode/*` + `!.vscode/settings.json` permite compartilhar settings do time (extensions sugeridas, debugger configs) sem comitar preferências pessoais (`launch.json` de cada um, etc.).

---

## 9. Outras boas práticas

### 9.1. Defaults com `${VAR:-fallback}`

Tudo que é configurável tem default razoável. Isso significa que `docker compose up` funciona "out of the box". Variáveis sobem o nível de fricção só quando há motivo (`MONGO_ROOT_PASSWORD` sem default é justificável; `APP_PORT` sem default não é).

### 9.2. `env_file: .env`

Em vez de listar 30 variáveis em cada serviço, o Compose carrega `.env` direto. Combinado com o `.env.sample`, mantém o setup curto e o segredo fora do repositório.

### 9.3. Volumes nomeados para dados que devem persistir entre `down/up`

Volumes nomeados (`database-data:/data/db`) são gerenciados pelo Docker e sobrevivem a `docker compose down`. Bind mounts (`./.docker/data/db:/data/db`) ficam para casos onde o dev quer inspecionar/exportar os dados via filesystem do host. Escolha um dos dois, não os dois ao mesmo tempo no mesmo serviço.

### 9.4. `profiles:` para serviços opcionais

Quando um serviço só faz sentido em alguns cenários (worker que processa fila, admin panel, ferramenta de seed), use **profiles** ao invés de deixá-lo subindo sempre:

```yaml
services:
  worker:
    image: exemplo/worker
    profiles: ["workers"]      # só sobe se você passar --profile workers

  seed:
    image: exemplo/seed
    profiles: ["tools"]        # idem
```

Comportamento:

- `docker compose up` → sobe só os serviços **sem** `profiles:`.
- `docker compose up --profile workers` → sobe os de cima + os com profile `workers`.
- `docker compose --profile workers --profile tools up` → sobe tudo.

Vantagens sobre o antigo truque de `deploy.replicas: 0`: é a forma oficial e idiomática no Compose v2+, funciona garantido em todas as versões modernas, e é declarativa. O time vê no compose quais profiles existem sem precisar adivinhar.

### 9.5. Ports comentadas em vez de removidas

Frequente em `docker-compose.override.yml.example`:

```yaml
database:
  # ports:
  #   - "${MONGO_PORT:-27017}:27017"
```

A intenção: por default, o banco não vaza porta para o host (evita conflito com Mongo nativo); mas se você precisar conectar via Compass, descomenta no seu override local. Documentação como código.

### 9.6. Hot reload sem rebuild — e o segredo do `node_modules` anônimo

Para Node (frontend, BFF), a fórmula que funciona é:

```yaml
volumes:
  - ./:/app                    # bind mount: código do host aparece dentro do container
  - /app/node_modules          # volume ANÔNIMO: "preserva" o node_modules do container
```

#### O problema que essa linha resolve

Sem o volume anônimo, o que acontece:

1. O Dockerfile no stage `deps` instala `node_modules` dentro do container (Linux/glibc-alpine).
2. O override monta `./:/app`, sobrescrevendo `/app` com o conteúdo do host.
3. Se o host tem `node_modules` (de um `npm install` rodado fora do Docker), ele **substitui** o `node_modules` que estava na imagem, e provavelmente quebra, porque foi compilado num macOS/Windows ou numa versão diferente do Node.
4. Se o host **não tem** `node_modules`, fica sem deps nenhuma: o `npm run dev` falha com `Cannot find module`.

Em qualquer dos casos, o app não sobe. O sintoma clássico é "funciona fora do Docker mas quebra com `docker compose up`", porque dependências nativas (`bcrypt`, `sharp`, `node-sass`, `argon2`, etc.) precisam ser compiladas para a arquitetura do container.

#### Como o volume anônimo conserta

O `- /app/node_modules` (sem o `./` na frente) cria um **volume anônimo gerenciado pelo Docker** e o monta em `/app/node_modules`. Como volumes têm prioridade sobre bind mounts em caminhos sobrepostos, o conteúdo de `node_modules` da imagem é preservado dentro do container, mesmo com o resto do `/app` vindo do host.

Resultado:
- Código do host → aparece em `/app` (hot reload funciona, edita no host, container vê na hora).
- `node_modules` da imagem → fica intocado em `/app/node_modules` (Linux/Alpine, compilado certo).
- `node_modules` do host → não atrapalha (nem precisa existir).

#### Quando preferir volume nomeado em vez de anônimo

Volume anônimo tem dois inconvenientes: (1) some no `docker compose down -v` junto com volumes "de verdade", então da próxima vez você espera todo o `npm ci` novamente; (2) é difícil de inspecionar (`docker volume ls` mostra um hash, não um nome legível). Para projetos onde a instalação demora bastante, vale trocar por **volume nomeado**:

```yaml
services:
  bff:
    volumes:
      - ./:/app
      - bff_node_modules:/app/node_modules

volumes:
  bff_node_modules:
```

Sobrevive a `down/up` sem `-v`, é inspecionável (`docker volume inspect projeto_bff_node_modules`) e dá pra limpar explicitamente quando precisar.

> Alternativa complementar (não substitui): `RUN --mount=type=cache,target=/root/.npm npm ci` no Dockerfile usa BuildKit para cachear o **download** de pacotes (o tarball que `npm` busca antes de extrair) entre builds. Acelera o build mas não resolve nada em runtime. Combine com o volume anônimo/nomeado, não troque um pelo outro.

#### Mesma técnica para outras pastas

```yaml
volumes:
  - ./:/app
  - /app/node_modules          # Node
  - /app/.next                 # Next.js: cache de build local da imagem
  - /app/dist                  # quando o container faz build incremental
  - /app/tmp                   # Go com Air
```

#### Em Go com Air

O equivalente em Go é mais simples: como não há `node_modules`, o bind mount `./:/app` já basta. Mas o Air precisa de `/app/tmp` para escrever os binários intermediários, então vale proteger esse diretório com volume anônimo também, senão o host enche de arquivos `tmp/main` cuspidos pelo container.

### 9.7. Compose com arquivo auxiliar e subindo serviço específico

Stacks de observabilidade (Grafana, Tempo, Prometheus), painéis admin, ferramentas de seed: tudo isso pode viver num `docker-compose.observability.yml` separado e ser ligado com `docker compose -f docker-compose.yml -f docker-compose.observability.yml up`. Vantagem: não obriga todo dev a subir Grafana+Tempo quando só está mexendo na API.

Por default, `docker compose up` sobe **todos** os serviços declarados (somando os arquivos passados com `-f` e o override automático). Quando você quer só uma parte:

```bash
docker compose up backend                       # só o backend (e suas dependências via depends_on)
docker compose up backend database              # backend + database, nada mais
docker compose up -d --no-deps bff              # só o bff, sem subir o backend declarado em depends_on
docker compose up --build --force-recreate bff  # rebuilda e recria só o bff
docker compose restart bff                      # reinicia sem rebuildar
```

> **Bug conhecido com `--no-deps` + `depends_on: condition: service_healthy`.** Em algumas versões do Compose v2 (issues [#9591](https://github.com/docker/compose/issues/9591), [#10759](https://github.com/docker/compose/issues/10759)) o `--no-deps` pode dar erro "no such service" ou recriar containers de dependências de forma inesperada quando o `depends_on` usa healthcheck. Em dev, prefira subir o stack inteiro normalmente e usar `--no-deps` só em scripts pontuais.

No `Makefile`, dá pra encurtar via `SVC=` (já existe nos alvos `logs`, `rebuild`, `sh`). Em projetos com 5-10 serviços, subir todos consome RAM/CPU à toa. Trabalhar "um pedaço por vez" deixa o loop de dev mais leve, especialmente em máquinas modestas ou quando você precisa rodar dois projetos da `catraca` ao mesmo tempo.

### 9.8. Evite `latest` — pin tudo em versão explícita

`latest` é um anti-padrão silencioso. Ele compila e parece funcionar, mas embute três problemas de uma vez:

1. **Não-determinismo.** A mesma `docker compose up` hoje e daqui a três meses pode puxar imagens diferentes (porque alguém republicou `node:latest`, `mongo:latest`, etc.). Builds que "funcionavam" começam a quebrar sem mudança de código.
2. **Difícil reverter.** Quando algo quebra em produção, você não sabe qual versão estava rodando. `docker image inspect` mostra o digest, mas você precisa correr atrás de qual tag aquele digest era. Rollback vira arqueologia.
3. **Cache enganoso.** O Docker considera `node:latest` como já baixado e não atualiza, mesmo que o registry tenha uma versão nova. Em alguns hosts você está rodando o que pegou em janeiro, em outros o que pegou em maio.

#### Onde isso aparece e como corrigir

**Imagens base no Dockerfile.** Sempre pin no mínimo a versão major+minor, e idealmente o patch:

```dockerfile
# ❌ Ruim
FROM node:latest
FROM golang:alpine
FROM mongo

# ✅ Bom
FROM node:22.11-alpine
FROM golang:1.25.5-alpine
FROM mongo:7.0.14

# 🏆 Melhor: pin por digest (imutável)
FROM node:22.11-alpine@sha256:abcd1234...
```

O pin por digest é o único 100% reprodutível: uma tag pode ser reescrita pelo mantenedor, um digest não. Para projetos críticos vale o overhead; para dev, `major.minor-alpine` já cobre 90% dos casos.

**Imagens dos seus serviços no compose.** O padrão `${PROJECT_TAG:-latest}` que aparece nos exemplos do `docker-compose.yml` é OK como **fallback para dev local** (quando você não setou nada, pega o último build), mas em produção **sempre** passe a tag explícita:

```bash
# ❌ Em produção
docker compose pull && docker compose up -d

# ✅ Em produção
PROJECT_TAG=v1.42.0 docker compose pull && PROJECT_TAG=v1.42.0 docker compose up -d
# ou via env do CI:
PROJECT_TAG=$(git rev-parse --short HEAD) docker compose up -d
```

Esquemas comuns para `PROJECT_TAG`:

- **Git SHA curto** (`a3f9c12`): simples, único, fácil de rastrear no log do CI.
- **SemVer** (`v1.42.0`): bom para releases; combine com `git tag`.
- **Data + SHA** (`2026.05.22-a3f9c12`): ordenável, raster do dia em que foi buildado.

Evite tags semânticas mutáveis (`stable`, `prod`, `release`) pelo mesmo motivo de `latest`: alguém pode reescrever o que `stable` aponta.

> Regra simples: se o nome da imagem em produção tem `latest`, considere isso um bug. Para dev local pode ficar, mas qualquer pipeline de CI/CD deve sempre passar um tag determinístico.

**Referências para defender em revisão de segurança:** o [CIS Docker Benchmark](https://www.aquasec.com/cloud-native-academy/docker-container/docker-cis-benchmark/) recomenda explicitamente "always tag images with a specific version", e o [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html) lista "Rule 8: Do not use the latest tag" entre as práticas de hardening.

### 9.9. Evite `container_name:` — destrava o `--scale`

Não fixe o nome do container no compose:

```yaml
# ❌ Ruim
services:
  backend:
    container_name: backend
```

Parece inofensivo (é até bonitinho no `docker ps`), mas quebra um recurso poderoso do Compose: **escalar o serviço** (visto em detalhe na seção 10). Como nomes de container precisam ser únicos no daemon, `docker compose up --scale backend=3` falha com `Conflict. The container name "/backend" is already in use`.

Sem o `container_name`, o Compose gera nomes automáticos no padrão `<projeto>-<serviço>-<n>` (e.g. `meuapp-backend-1`, `meuapp-backend-2`).

#### Quando `container_name` faria sentido?

Quase nunca. Os casos legítimos são raros: integração com ferramenta externa que precisa de hostname fixo (ex.: um `docker exec` num CI antigo, um script de monitoramento legado). Mesmo nesses casos, **prefira `hostname:`** (que afeta só o DNS interno do container, não o nome no daemon) ou aliases de network. `container_name` é a única opção que mata o `--scale`.

### 9.10. Healthchecks

`healthcheck:` ensina o Docker a saber se o container está realmente pronto para receber tráfego, não só rodando. É o que destrava `depends_on: condition: service_healthy`, que faz o `bff` esperar o `database` aceitar conexões antes de iniciar.

```yaml
services:
  database:
    image: mongo:7
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.runCommand({ ping: 1 })"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s     # tempo de graça antes de começar a contar falhas

  backend:
    depends_on:
      database:
        condition: service_healthy   # só sobe depois do healthcheck passar
```

Sem isso, `backend` sobe junto com `database` e dá uns 5 segundos de erro de conexão até o Mongo terminar de inicializar. Com healthcheck, o Compose espera o status virar `healthy` para iniciar o `backend`.

**Padrões úteis:**

| Serviço     | `test:` exemplo                                            |
|-------------|------------------------------------------------------------|
| HTTP API    | `["CMD", "curl", "-fsS", "http://localhost:8080/health"]` |
| Postgres    | `["CMD-SHELL", "pg_isready -U $$POSTGRES_USER"]`           |
| MongoDB     | `["CMD", "mongosh", "--quiet", "--eval", "db.runCommand({ ping: 1 })"]` |
| Redis       | `["CMD", "redis-cli", "ping"]`                             |

> `CMD-SHELL` interpreta a string num shell; `CMD` executa direto sem shell. Use `CMD-SHELL` quando precisar de variáveis de ambiente (`$$VAR` no compose) ou pipes.

### 9.11. `logging:` driver — evite encher o disco

Por default, o Docker usa o driver `json-file` sem rotação. Em produção, um app verboso pode encher o disco do host em dias. Limite explicitamente:

```yaml
services:
  bff:
    image: ...
    logging:
      driver: json-file
      options:
        max-size: "10m"      # cada arquivo de log até 10MB
        max-file: "3"        # mantém 3 arquivos (rotação)
```

Resultado: no máximo 30MB de log por container, com rotação. Em ambientes com agregação (Loki, ELK), troque para o driver correspondente (`loki`, `gelf`, `fluentd`) e o `json-file` vira só fallback local.

### 9.12. Limites de recurso

Por default, um container pode consumir toda a memória/CPU do host. Em dev isso raramente é problema; em produção (ou quando você roda muitos projetos da `catraca` em paralelo na sua máquina), vale limitar:

```yaml
services:
  backend:
    image: ...
    mem_limit: 512m          # mata o container se passar de 512MB
    cpus: 1.0                # no máximo 1 CPU
```

Em ambientes Swarm/Kubernetes a sintaxe equivalente é `deploy.resources.limits.memory` / `deploy.resources.limits.cpus`. Em Compose v2 não-Swarm, ambas funcionam, mas a forma curta acima é mais legível e mais portátil entre versões.

Útil principalmente para:
- Garantir que um leak de memória mate o container em vez do laptop inteiro.
- Reproduzir localmente os limites do prod (se em prod o backend tem 512MB, rodar com 512MB no dev expõe vazamentos cedo).
- Rodar várias stacks da `catraca` simultaneamente sem swap insano.

---

## 10. Escalando serviços com `--scale`

Quando os antipadrões da seção 9 estão fora do caminho (sem `container_name`, sem portas fixas obrigatórias), o Compose dá um superpoder de graça: rodar várias réplicas do mesmo serviço com um único comando.

### 10.1. Como funciona

```bash
docker compose up -d --scale backend=3
# cria:
#   projeto-backend-1
#   projeto-backend-2
#   projeto-backend-3
```

E o DNS interno **balanceia automaticamente**: outros containers chamando `http://backend:8080` recebem round-robin entre as três réplicas. Não precisa load balancer, não precisa mudar nenhuma config — desde que você tenha respeitado os requisitos das próximas seções.

### 10.2. Port ranges (porta fixa também quebra `--scale`)

Se o serviço expõe uma porta fixa pro host (`8080:8080`), o `--scale` falha pelo mesmo motivo do `container_name`: portas no host são únicas, e duas réplicas tentariam bindar na mesma. Para destravar, declare um **range** no lado do host:

```yaml
services:
  backend:
    ports:
      - "8080-8089:8080"     # host: range de 10 portas | container: porta fixa
```

Agora `docker compose up --scale backend=5` distribui as réplicas em `8080`, `8081`, `8082`, `8083`, `8084` automaticamente, cada uma escutando internamente em `8080`. Quem chega via DNS interno (`http://backend:8080`) continua usando a porta interna; quem chega de fora (`localhost:8081`) bate em uma réplica específica via host.

Variações úteis:

```yaml
ports:
  - "8080"                       # só porta interna — Docker escolhe uma porta efêmera no host pra cada réplica
  - "127.0.0.1:8080-8089:8080"   # range bindado só no loopback (não expõe na rede da máquina)
```

> **Regra prática:** toda porta exposta de serviço que pode ser escalado deve ter range no lado do host (ou ser omitida). Porta fixa só faz sentido em serviços singleton (BFF, gateway).

### 10.3. Debug ports

Debug ports também conflitam com `--scale` se forem fixos. Como elas só fazem sentido em dev, ficam no `docker-compose.override.yml.example`:

```yaml
services:
  bff:
    ports:
      - "8080-8089:8080"      # app
      - "9229-9238:9229"      # Node --inspect (10 slots pra escalar até 10 réplicas)
    command: node --inspect=0.0.0.0:9229 dist/main.js

  backend:
    ports:
      - "8090-8099:8080"      # app
      - "2345-2354:2345"      # Delve (Go)
```

Portas de debug por linguagem:

| Linguagem  | Porta padrão | Flag                                            |
|------------|--------------|-------------------------------------------------|
| Node.js    | `9229`       | `node --inspect=0.0.0.0:9229`                   |
| Go (Delve) | `2345`       | `dlv --listen=:2345 --headless --api-version=2` |
| Java JDWP  | `5005`       | `-agentlib:jdwp=...,address=*:5005`             |
| Python (debugpy) | `5678`  | `python -m debugpy --listen 0.0.0.0:5678`       |

Sem o range, debugar uma de várias réplicas no VS Code/IntelliJ vira loteria: você não sabe em qual instância o breakpoint vai cair. Com range, cada réplica fica num slot previsível e dá pra configurar múltiplas "launch configurations" apontando pra `localhost:9229`, `localhost:9230`, etc.

### 10.4. DNS round-robin e a pegadinha do keep-alive

Round-robin acontece em cada **resolução DNS nova**, não a cada request. Clientes HTTP modernos (`http.Agent` do Node, `http.Client` default do Go, conexões persistentes de drivers de banco) cacheiam o IP resolvido e reusam a conexão TCP, então uma instância pode receber 100% do tráfego mesmo havendo 3 réplicas.

Para teste de carga realista:

- **Opção 1:** desabilitar keep-alive no cliente (`new http.Agent({ keepAlive: false })` no Node; `Transport.DisableKeepAlives = true` no Go).
- **Opção 2:** colocar um proxy L7 (Traefik, nginx, HAProxy) no meio que faça o balanceamento por request, não por conexão.
- **Opção 3:** rodar o cliente de carga (k6, wrk) com conexões curtas (`--connections 100 --duration 30s --keepalive=false`).

Sem nenhuma dessas, seu teste de carga "com 5 réplicas" pode estar martelando uma única instância.

### 10.5. Imperativo (`--scale`) vs declarativo (`deploy.replicas`)

Duas formas de subir múltiplas réplicas em Compose v2:

**Imperativo — `--scale` na linha de comando:**

```bash
docker compose up -d --scale backend=3
```

Bom para experimento ad-hoc, teste de carga local, debug rápido. O número não fica versionado em lugar nenhum, então da próxima vez você precisa lembrar de passar `--scale` de novo.

**Declarativo — `deploy.replicas:` no compose:**

```yaml
services:
  backend:
    image: exemplo/backend:${PROJECT_TAG:-latest}
    deploy:
      replicas: 3            # sempre sobe 3 réplicas em `docker compose up`
      restart_policy:
        condition: on-failure
        max_attempts: 3
    ports:
      - "8080-8089:8080"
```

Aqui o número entra no git e qualquer `docker compose up` (sem `--scale`) sobe 3 réplicas. Bom para serviços onde a quantidade é parte do contrato (workers, schedulers de fila, backend stateless).

> **Nota histórica.** `deploy:` originalmente era exclusivo do modo Swarm. No Compose v2 moderno, `deploy.replicas` e `deploy.restart_policy` **são honrados pelo `docker compose up`** comum, não só pelo `docker stack deploy`. Outras chaves de `deploy:` (`mode: global`, `placement:`, `update_config:`) continuam só fazendo sentido em Swarm/Kubernetes.

Combinando os dois: você pode declarar `replicas: 3` como padrão e sobrescrever com `--scale backend=10` quando quiser fazer load test ad-hoc.

### 10.6. Casos de uso

- **Teste de carga local.** `docker compose up --scale backend=10` simula concorrência sem subir Kubernetes/Swarm. Combine com `wrk`, `vegeta` ou `k6` apontando pro BFF e meça throughput real com várias instâncias do backend (lembre da pegadinha do keep-alive, seção 10.4).
- **Debug de race condition.** Bugs que só aparecem com múltiplas instâncias (cache mal compartilhado, lock distribuído quebrado, idempotência falha) ficam reproduzíveis localmente.
- **Validação de stateless.** Se sua app não roda em `--scale > 1`, ela tem estado escondido em memória. Melhor descobrir agora do que em produção.
- **Workers e jobs.** Para serviços que processam fila, `--scale worker=5` (ou `deploy.replicas: 5`) é a forma trivial de paralelizar.

---

## 11. Resumo das regras

| Regra | Por quê |
|------|---------|
| `.docker/build/Dockerfile` único, multi-stage | Um arquivo serve dev + prod, com cache reutilizado entre stages |
| `docker-compose.yml` = produção (sem `build:`, com `ports:` só do que é público) | Réplica fiel do que sobe no servidor; backend fica invisível |
| `docker-compose.override.yml.example` versionado + `.override.yml` local ignorado | Editável por desenvolvedor sem disputar merge; `make setup` clona o default |
| BFF como único ponto público; backend sem `ports:` em prod, expostas só no override | Reduz superfície de ataque; em dev você ainda tem acesso direto pra debug |
| Duas redes: `internal` por projeto + `catraca` external | Banco isolado; apps se enxergam entre repos via DNS do Docker |
| Serviços se chamam por **nome via DNS interno** (`http://backend:8080`), nunca por `localhost` | Configuração estável entre dev/prod; sem IP hard-coded; `localhost` é loopback do container |
| `host.docker.internal` é dica situacional, **não** padrão de compose | Adicionar `extra_hosts` em todo serviço polui YAML e sugere dependência que não existe |
| `make network` idempotente como pré-requisito de `setup`/`up` | Garante a network externa existir antes do compose, sem erro de "network not found" |
| Volumes anônimos para `node_modules`/`.next`/`tmp` no override | Hot reload sem `npm install` do host quebrar a imagem |
| `.dockerignore` corta `node_modules`, `.docker`, `.next`, dados | Build mais rápido, cache estável, sem vazar segredo |
| `.gitignore` ignora artefatos + segredos + `docker-compose.override.yml` | Repo limpo; nada gerado entra; segredo nunca vaza |
| `${VAR:-default}` em tudo configurável | `up` funciona out-of-the-box; segredos exigem `.env` explícito |
| Imagem final non-root, `scratch`/`distroless`/`standalone` | Menor superfície de ataque, menor footprint |
| Sem `latest`: tags pinadas (`node:22.11-alpine`, `PROJECT_TAG=<sha>`) em prod | Build determinístico, rollback rastreável, sem surpresa silenciosa de atualização |
| Sem `container_name:` — deixa o Compose gerar nomes únicos | Destrava `docker compose up --scale backend=N` para teste de carga e múltiplas réplicas |
| Port ranges (`8080-8089:8080`) em serviços escaláveis | Cada réplica recebe uma porta única no host; porta fixa só em singleton |
| `profiles:` para serviços opcionais | Substituto idiomático e correto de `deploy.replicas: 0` |
| `healthcheck:` + `depends_on: condition: service_healthy` | Backend só sobe depois do banco aceitar conexões |
| `logging:` com `max-size`/`max-file` | Não enche o disco em produção |
| `mem_limit:` e `cpus:` em serviços de longa duração | Vazamento mata o container, não o host |

---

## 12. Checklist para um projeto novo

Quando criar um repositório seguindo esse padrão:

- [ ] Criar a estrutura `.docker/build/Dockerfile` multi-stage com pelo menos `deps → dev → builder → runner`.
- [ ] Escrever `docker-compose.yml` com imagens parametrizadas, sem `build:`, com `ports:` só do que é público em produção.
- [ ] Escrever `docker-compose.override.yml.example` com `build:`, `target: dev`, bind mounts de código, volumes anônimos para dependências, e ports de debug do backend.
- [ ] Declarar as networks `internal` (do projeto) e `catraca` (`external: true, name: catraca`) no compose.
- [ ] Adicionar `docker-compose.override.yml` e `*.bak.*` ao `.gitignore`.
- [ ] Copiar o `Makefile` deste diretório para a raiz do projeto.
- [ ] Criar `.env.sample` com todas as variáveis usadas.
- [ ] Criar `.dockerignore` cortando `node_modules`/`.docker`/`.next`/`build`/`.data`.
- [ ] Adicionar `healthcheck:` no `database` e `depends_on: condition: service_healthy` nos serviços que dependem dele.
- [ ] Adicionar `logging:` com `max-size`/`max-file` em todos os serviços que vão pra prod.
- [ ] Marcar serviços opcionais (workers, seeds, painéis admin) com `profiles:`.
- [ ] Validar com `make setup && make up` que o stack sobe limpo num clone novo.
- [ ] Validar com `make prod-like` que a versão de produção também sobe (sem porta do backend exposta).
- [ ] Se for escalável, validar com `docker compose up --scale backend=3` (sem `container_name:`, com port range).
