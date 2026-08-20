SHELL := /bin/bash
.DEFAULT_GOAL := help

SCRIPTS := ./scripts

.PHONY: help all prereqs infra core apps verify status logs uninstall clean

help: ## Show this help
	@echo "Kubeflow on Kubernetes - Helm-first hybrid deployment"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;34m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Typical first run:  make all"

all: prereqs infra core apps verify ## Run every phase end to end

prereqs: ## Phase 0 - CLI tools, kubeconfig, untaint control-plane, sysctl
	@bash $(SCRIPTS)/00-prereqs.sh

infra: ## Phase 1 - Helm: StorageClass, cert-manager, Istio
	@bash $(SCRIPTS)/01-helm-infra.sh

core: ## Phase 2 - kustomize: dex, oauth2-proxy, Pipelines, Dashboard, Notebooks, Katib
	@bash $(SCRIPTS)/02-kubeflow-core.sh

apps: ## Phase 3 - Helm: KServe, Trainer, Spark Operator
	@bash $(SCRIPTS)/03-helm-apps.sh

verify: ## Phase 4 - health checks and access details
	@bash $(SCRIPTS)/99-verify.sh

status: ## Quick cluster overview
	@kubectl get pods -A -o wide | grep -vE '\s(Running|Completed)\s' || echo "all pods healthy"
	@echo
	@helm list -A
	@echo
	@kubectl get pvc -A

logs: ## Tail the Central Dashboard logs
	@kubectl -n kubeflow logs -l app=centraldashboard --tail=100 -f

uninstall: ## Remove Kubeflow (keeps the cluster and CLI tools) - ARGS="--yes --revert-nodes"
	@bash $(SCRIPTS)/98-uninstall.sh $(ARGS)

clean: ## Delete the local manifest/chart cache only
	@rm -rf .cache
	@echo "cache removed"
