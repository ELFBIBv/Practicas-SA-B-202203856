# Atajos de P9. Uso desde la raíz del repositorio: make -C P9 <objetivo>
SHELL := bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help

TF_DIR  := terraform
TF_STACKS := 00-persistent 01-cluster 02-platform
RAW_LOG := evidencia/bootstrap/raw

.PHONY: help bootstrap backend plan verify verify-lock destroy-cluster audit fmt-check validate dr-restore-test dr-node-test dr-rebuild-test

help: ## Lista los objetivos disponibles.
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

bootstrap: ## Reconstrucción completa (punto de entrada único). Log crudo en evidencia/bootstrap/raw/.
	@mkdir -p $(RAW_LOG)
	./scripts/bootstrap.sh all 2>&1 | tee "$(RAW_LOG)/bootstrap-$$(date -u +%Y%m%dT%H%M%SZ).log"

backend: ## Asegura el backend remoto del estado y ejecuta terraform init.
	./scripts/bootstrap.sh backend

plan: ## backend + terraform plan de cada etapa (no aplica cambios).
	./scripts/bootstrap.sh plan

verify: ## Solo verificaciones finales contra el clúster existente.
	./scripts/bootstrap.sh verify

destroy-cluster: ## IRREVERSIBLE. Destruye solo 01-cluster. Uso: make destroy-cluster CONFIRM=aks-sa-p9
	./scripts/destroy-cluster.sh --confirm "$(CONFIRM)"

dr-restore-test: ## Prueba de restauración de datos verificada (2.3/2.6). Log en evidencia/restauracion/.
	./scripts/dr-data-restore-test.sh

dr-node-test: ## Prueba de pérdida de nodo con sondeo continuo (2.5). Uso: make dr-node-test [NODE=<nodo>]
	./scripts/dr-node-drain-test.sh $(NODE)

dr-rebuild-test: ## IRREVERSIBLE. Destrucción + reconstrucción cronometrada. Uso: make dr-rebuild-test CONFIRM=aks-sa-p9
	./scripts/dr-rebuild-test.sh --confirm "$(CONFIRM)"

verify-lock: ## Prueba que el backend bloquea el estado (blob lease).
	./scripts/verify-tfstate-lock.sh

audit: ## Falla si hay estado, planes, tfvars o credenciales en el índice de git.
	./scripts/audit-repo.sh

fmt-check: ## terraform fmt -check sobre todo P9/terraform.
	terraform -chdir=$(TF_DIR) fmt -check -recursive -diff

validate: ## terraform validate de cada etapa sin tocar el backend remoto.
	for stack in $(TF_STACKS); do \
	  terraform -chdir=$(TF_DIR)/$$stack init -backend=false -input=false >/dev/null; \
	  terraform -chdir=$(TF_DIR)/$$stack validate; \
	done
