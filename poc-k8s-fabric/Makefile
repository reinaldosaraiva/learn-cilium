# Makefile — poc-k8s-fabric (v2.8.0)
# Alvos de validação estática (lint), dry-run de estudos (test), geração de PDF (pdf) e execução P008 (E38–E41).

SHELL := /usr/bin/env bash
REPO_ROOT := $(abspath ..)
PYTHON_PDF ?= $(shell if [ -x "$(REPO_ROOT)/.venv/bin/python3" ]; then echo "$(REPO_ROOT)/.venv/bin/python3"; else command -v python3; fi)

.PHONY: all lint test pdf latex help p008-e38 p008-e39 p008-e40 p008-e41 p008-s001 p008-s002 p008-all

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
	@echo "[lint ABNT] Verificando citações, referências e numeração do guia..."
	@"$(PYTHON_PDF)" -I tools/build_latex.py --check-only
	@"$(PYTHON_PDF)" -I tools/build_latex.py --check-only --source docs/student-guide-template.md
	@echo "[lint 3/4] Executando go vet na fixture ExternalAuth (studies/p003/fixtures/auth)..."
	@if command -v go >/dev/null 2>&1; then \
		(cd studies/p003/fixtures/auth && go vet ./...); \
		echo "  -> OK (go vet limpo)"; \
	else \
		echo "  -> SKIP (go não encontrado no PATH)"; \
	fi
	@echo "[lint 4/4] Verificando presença dos scripts de estudo P005/P006/P007/P008..."
	@test -f studies/p006/arm-a-datapath/e29-bgp-unnumbered-l2.sh
	@test -f studies/p006/arm-b-platform/e33-kubevirt-live-migration.sh
	@test -f studies/p007/arm-a-datapath/e34-bgp-gshut-zero-loss-drain.sh
	@test -f studies/p007/arm-b-platform/e35-spiffe-mtls-wireguard-zerotrust.sh
	@test -f studies/p007/arm-a-datapath/e36-local-redirect-policy-nodelocal.sh
	@test -f studies/p007/arm-b-platform/e37-multus-ipvlan-macvlan-kubevirt-dualhomed.sh
	@test -f studies/p008/arm-a-datapath/e38-host-firewall-xdp-prefilter.sh
	@test -f studies/p008/arm-b-platform/e39-cilium-envoy-l7-resilience.sh
	@test -f studies/p008/arm-a-datapath/e40-bgp-route-reflector-srv6-dualstack.sh
	@test -f studies/p008/arm-b-platform/e41-netkit-bigtcp-wireguard-matrix.sh
	@echo "  -> OK (scripts P005/P006/P007/P008 presentes)"

test:
	@echo "[test 1/3] Executando suíte unitária Go da fixture ExternalAuth..."
	@if command -v go >/dev/null 2>&1; then \
		(cd studies/p003/fixtures/auth && go test -v ./...) || exit 1; \
	fi
	@echo "[test 2/3] Executando --dry-run em todos os scripts de estudo P005, P006, P007 e P008..."
	@for s in studies/p005/*/*.sh studies/p006/*/*.sh studies/p007/*/*.sh studies/p008/*/*.sh; do \
		echo "  -> dry-run: $$s"; \
		bash "$$s" --dry-run >/dev/null || exit 1; \
	done
	@echo "  -> OK (todos os scripts P005/P006/P007/P008 passaram em --dry-run)"
	@echo "[test 3/3] Verificando se o LaTeX versionado está sincronizado com o Markdown..."
	@if command -v pandoc >/dev/null 2>&1; then \
		tmp=$$(mktemp -d); \
		"$(PYTHON_PDF)" -I tools/build_latex.py --no-pdf --tex "$$tmp/lab-guide-student.tex" >/dev/null || exit 1; \
		if ! diff -q "$$tmp/lab-guide-student.tex" docs/latex/lab-guide-student.tex >/dev/null; then \
			echo "ERRO: docs/latex/lab-guide-student.tex desatualizado; rode make pdf" >&2; rm -r "$$tmp"; exit 1; \
		fi; \
		rm -r "$$tmp"; \
		echo "  -> OK (LaTeX idêntico ao gerado a partir de docs/lab-guide-student.md)"; \
	else \
		echo "  -> SKIP (pandoc não encontrado no PATH)"; \
	fi

p008-e38:
	@bash studies/p008/arm-a-datapath/e38-host-firewall-xdp-prefilter.sh

p008-e39:
	@bash studies/p008/arm-b-platform/e39-cilium-envoy-l7-resilience.sh

p008-e40:
	@bash studies/p008/arm-a-datapath/e40-bgp-route-reflector-srv6-dualstack.sh

p008-e41:
	@bash studies/p008/arm-b-platform/e41-netkit-bigtcp-wireguard-matrix.sh

p008-s001: p008-e38 p008-e39

p008-s002: p008-e40 p008-e41

p008-all: p008-s001 p008-s002

pdf:
	@echo "[pdf] Compilando a apostila ABNT (abnTeX2) via pandoc + tectonic..."
	@(cd "$(REPO_ROOT)" && "$(PYTHON_PDF)" -I poc-k8s-fabric/tools/build_latex.py)
	@ls -lh "$(REPO_ROOT)/output/pdf/cilium-lab-student-guide.pdf"

latex:
	@echo "[latex] Gerando edição ABNT (abnTeX2) em docs/latex/lab-guide-student.tex..."
	@(cd "$(REPO_ROOT)" && "$(PYTHON_PDF)" -I poc-k8s-fabric/tools/build_latex.py --no-pdf)
