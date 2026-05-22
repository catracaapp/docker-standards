# =============================================================================
# Makefile padrão para projetos com Docker Compose + override local.
# Copie para a raiz do seu projeto como `Makefile` e ajuste apenas as
# variáveis em "Convenções" se algum nome divergir.
# Documentação: docs/README_PT-BR.md (ou equivalente no seu repo)
# =============================================================================

# ===== Convenções =====
COMPOSE              := docker compose
OVERRIDE_DEFAULT     := docker-compose.override.yml.example
OVERRIDE_LOCAL       := docker-compose.override.yml
ENV_SAMPLE           := .env.sample
ENV_LOCAL            := .env
EXTERNAL_NETWORK     := catraca

.DEFAULT_GOAL := help

# ===== Bootstrap =====
.PHONY: setup
setup: network $(ENV_LOCAL) $(OVERRIDE_LOCAL) ## Prepara o projeto para rodar localmente
	@echo "✓ Ambiente pronto. Rode: make up"

$(ENV_LOCAL):
	@cp $(ENV_SAMPLE) $(ENV_LOCAL)
	@echo "→ Criado $(ENV_LOCAL) a partir de $(ENV_SAMPLE). Ajuste se precisar."

$(OVERRIDE_LOCAL):
	@cp $(OVERRIDE_DEFAULT) $(OVERRIDE_LOCAL)
	@echo "→ Criado $(OVERRIDE_LOCAL) a partir de $(OVERRIDE_DEFAULT). Edite à vontade — está no .gitignore."

.PHONY: sync-override
sync-override: ## Sobrescreve o override local com o default (CUIDADO: perde customizações)
	@if [ -f $(OVERRIDE_LOCAL) ]; then \
		cp $(OVERRIDE_LOCAL) $(OVERRIDE_LOCAL).bak.$$(date +%s); \
		echo "→ Backup salvo em $(OVERRIDE_LOCAL).bak.<timestamp>"; \
	fi
	@cp $(OVERRIDE_DEFAULT) $(OVERRIDE_LOCAL)
	@echo "✓ $(OVERRIDE_LOCAL) atualizado a partir de $(OVERRIDE_DEFAULT)"

.PHONY: diff-override
diff-override: ## Mostra o que mudou entre seu override e o default do time
	@diff -u $(OVERRIDE_DEFAULT) $(OVERRIDE_LOCAL) || true

# ===== Rede compartilhada =====
.PHONY: network
network: ## Cria a network externa `catraca` se ainda não existir (idempotente)
	@if docker network inspect $(EXTERNAL_NETWORK) >/dev/null 2>&1; then \
		echo "✓ Network '$(EXTERNAL_NETWORK)' já existe"; \
	else \
		echo "→ Criando network '$(EXTERNAL_NETWORK)'..."; \
		docker network create --driver bridge $(EXTERNAL_NETWORK); \
		echo "✓ Network '$(EXTERNAL_NETWORK)' criada"; \
	fi

.PHONY: network-rm
network-rm: ## Remove a network externa (só funciona se nenhum container estiver conectado)
	@docker network rm $(EXTERNAL_NETWORK) 2>/dev/null && \
		echo "✓ Network '$(EXTERNAL_NETWORK)' removida" || \
		echo "⚠ Não foi possível remover (não existe ou há containers conectados)"

# ===== Operação diária =====
.PHONY: up
up: network $(OVERRIDE_LOCAL) ## Sobe o stack de dev (garante network + compose + override local)
	$(COMPOSE) up -d

.PHONY: down
down: ## Derruba o stack
	$(COMPOSE) down

.PHONY: logs
logs: ## Acompanha os logs (use SVC=nome para filtrar)
	$(COMPOSE) logs -f $(SVC)

.PHONY: rebuild
rebuild: ## Rebuilda a imagem do serviço (use SVC=nome)
	$(COMPOSE) build --no-cache $(SVC)

.PHONY: sh
sh: ## Abre shell no serviço (use SVC=nome)
	$(COMPOSE) exec $(SVC) sh

# ===== Debug de rede =====
.PHONY: ip
ip: ## Mostra o IP do serviço em cada network (use SVC=nome). Ex: make ip SVC=backend
	@if [ -z "$(SVC)" ]; then \
		echo "Uso: make ip SVC=<nome-do-serviço>"; \
		echo "Ex:  make ip SVC=backend"; \
		exit 1; \
	fi
	@CID=$$($(COMPOSE) ps -q $(SVC) 2>/dev/null); \
	if [ -z "$$CID" ]; then \
		echo "⚠ Serviço '$(SVC)' não está rodando neste compose"; \
		exit 1; \
	fi; \
	echo "Serviço: $(SVC)  (container $${CID:0:12})"; \
	docker inspect $$CID --format '{{range $$net, $$cfg := .NetworkSettings.Networks}}  {{$$net}}: {{$$cfg.IPAddress}}{{println}}{{end}}'

.PHONY: ips
ips: ## Lista o IP de TODOS os serviços do compose em cada network
	@for svc in $$($(COMPOSE) ps --services); do \
		CID=$$($(COMPOSE) ps -q $$svc 2>/dev/null); \
		if [ -n "$$CID" ]; then \
			echo "── $$svc ──"; \
			docker inspect $$CID --format '{{range $$net, $$cfg := .NetworkSettings.Networks}}  {{$$net}}: {{$$cfg.IPAddress}}{{println}}{{end}}'; \
		fi; \
	done

# ===== Produção-like local =====
.PHONY: prod-like
prod-like: network ## Sobe ignorando o override — simula localmente o ambiente de prod
	$(COMPOSE) -f docker-compose.yml up -d

# ===== Limpeza =====
.PHONY: clean
clean: ## Para tudo e remove volumes anônimos (preserva a network externa)
	$(COMPOSE) down -v --remove-orphans

.PHONY: reset-override
reset-override: ## Apaga seu override local (volta ao default na próxima `make setup`)
	@rm -f $(OVERRIDE_LOCAL)
	@echo "✓ $(OVERRIDE_LOCAL) removido. Rode 'make setup' para recriar."

# ===== Help =====
.PHONY: help
help: ## Lista os comandos disponíveis
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
