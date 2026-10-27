# Makefile Raiz — Repositório learn-cilium (v2.7.0)
# Delega para poc-k8s-fabric/Makefile mantendo conveniência na raiz do projeto.

.PHONY: all lint test pdf latex help p008-e38 p008-e39 p008-e40 p008-e41 p008-s001 p008-s002 p008-all

all: lint test

lint:
	@$(MAKE) -C poc-k8s-fabric lint

test:
	@$(MAKE) -C poc-k8s-fabric test

pdf:
	@$(MAKE) -C poc-k8s-fabric pdf

latex:
	@$(MAKE) -C poc-k8s-fabric $@

p008-e38 p008-e39 p008-e40 p008-e41 p008-s001 p008-s002 p008-all:
	@$(MAKE) -C poc-k8s-fabric $@

help:
	@echo "Alvos disponíveis:"
	@echo "  make lint      - Valida sintaxe Bash (bash -n), ausência de chaves privadas e Go vet nas fixtures"
	@echo "  make test      - Executa validação --dry-run de todos os scripts P005, P006, P007 e P008 + go test"
	@echo "  make pdf       - Compila a apostila ABNT (output/pdf/cilium-lab-student-guide.pdf; requer pandoc e tectonic)"
	@echo "  make latex     - Gera a edição ABNT em LaTeX (poc-k8s-fabric/docs/latex/lab-guide-student.tex)"
	@echo "  make p008-s001 - Executa Onda 1 do Plano P008 (E38 + E39)"
	@echo "  make p008-s002 - Executa Onda 2 do Plano P008 (E40 + E41)"
	@echo "  make p008-all  - Executa todas as ondas do Plano P008 (E38 a E41)"
