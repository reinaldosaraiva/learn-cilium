# Makefile Raiz — Repositório learn-cilium (v2.5.0)
# Delega para poc-k8s-fabric/Makefile mantendo conveniência na raiz do projeto.

.PHONY: all lint test pdf help

all: lint test

lint:
	@$(MAKE) -C poc-k8s-fabric lint

test:
	@$(MAKE) -C poc-k8s-fabric test

pdf:
	@$(MAKE) -C poc-k8s-fabric pdf

help:
	@echo "Alvos disponíveis:"
	@echo "  make lint  - Valida sintaxe Bash (bash -n), ausência de chaves privadas e Go vet nas fixtures"
	@echo "  make test  - Executa validação --dry-run de todos os scripts P005 e P006 + go test"
	@echo "  make pdf   - Compila a apostila PDF (output/pdf/cilium-lab-student-guide.pdf)"
