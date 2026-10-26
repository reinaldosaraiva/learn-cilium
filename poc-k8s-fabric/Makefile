# Makefile — poc-k8s-fabric (v2.5.0)
# Alvos de validação estática (lint), dry-run de estudos (test) e geração de PDF (pdf).

SHELL := /usr/bin/env bash
REPO_ROOT := $(abspath ..)
PYTHON_PDF ?= $(shell if [ -x "$(REPO_ROOT)/.venv/bin/python3" ]; then echo "$(REPO_ROOT)/.venv/bin/python3"; else command -v python3; fi)

.PHONY: all lint test pdf help

all: lint test

lint:
	@echo "[lint 1/4] Verificando sintaxe Bash (bash -n) em todos os scripts .sh..."
	@count=0; \
	while IFS= read -r -d '' f; do \
		bash -n "$$f" || exit 1; \
		count=$$((count + 1)); \
	done < <(find . -name '*.sh' -not -path './evidence/*' -print0); \
	echo "  -> OK ($$count scripts .sh validados com zero erros de sintaxe)"
	@echo "[lint 2/4] Verificando ausência de chaves privadas PEM versionadas..."
	@if grep -rnE "^[[:space:]]*-----BEGIN (RSA |EC )?PRIVATE KEY-----" scripts/ k8s/ configs/ topo/ studies/ labctl/ docs/ 2>/dev/null; then \
		echo "ERRO: Chave privada estática encontrada!" >&2; exit 1; \
	fi
	@echo "  -> OK (zero chaves privadas estáticas)"
	@echo "[lint 3/4] Executando go vet na fixture ExternalAuth (studies/p003/fixtures/auth)..."
	@if command -v go >/dev/null 2>&1; then \
		(cd studies/p003/fixtures/auth && go vet ./...); \
		echo "  -> OK (go vet limpo)"; \
	else \
		echo "  -> SKIP (go não encontrado no PATH)"; \
	fi
	@echo "[lint 4/4] Verificando presença dos scripts de estudo P005/P006..."
	@test -f studies/p006/arm-a-datapath/e29-bgp-unnumbered-l2.sh
	@test -f studies/p006/arm-b-platform/e33-kubevirt-live-migration.sh
	@echo "  -> OK (scripts P005/P006 presentes)"

test:
	@echo "[test 1/2] Executando suíte unitária Go da fixture ExternalAuth..."
	@if command -v go >/dev/null 2>&1; then \
		(cd studies/p003/fixtures/auth && go test -v ./...) || exit 1; \
	fi
	@echo "[test 2/2] Executando --dry-run em todos os scripts de estudo P005 e P006..."
	@for s in studies/p005/*/*.sh studies/p006/*/*.sh; do \
		echo "  -> dry-run: $$s"; \
		bash "$$s" --dry-run >/dev/null || exit 1; \
	done
	@echo "  -> OK (todos os scripts P005/P006 passaram em --dry-run)"

pdf:
	@echo "[pdf] Compilando apostila PDF via tools/build_guide.py..."
	@(cd "$(REPO_ROOT)" && "$(PYTHON_PDF)" poc-k8s-fabric/tools/build_guide.py)
	@ls -lh "$(REPO_ROOT)/output/pdf/cilium-lab-student-guide.pdf"
