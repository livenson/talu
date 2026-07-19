# Talu — developer entrypoints.
#
# Local development runs against a REMOTE lab (the Rocky 10 sandbox). The cluster lives
# on the lab host; you drive it from your laptop over an SSH tunnel.
#
#   make lab-push     rsync repo to the lab + run host bootstrap (Stage 0)
#   make up           create the Talos-in-Docker cluster ON the lab
#   make lab-tunnel   open the persistent SSH tunnel + fetch kubeconfig
#   make lab-sync     push the working-tree overlay to the lab (inner loop)
#   make lab-status   read reconcile/health back, rendered locally
#   make try          one-shot: push + up + tunnel + sync
#   make down         destroy the lab cluster;  make lab-down  closes the tunnel
#
# Config lives in env.sh (gitignored, site-specific). Copy env.sh.example -> env.sh and edit,
# or override any LAB_* var in your shell. Falls back to env.sh.example (generic defaults).

SHELL := /usr/bin/env bash
LABENV := set -a && source ./$$([ -f env.sh ] && echo env.sh || echo env.sh.example) && set +a
SSH     = ssh -S "$$LAB_SSH_SOCKET" "$$LAB_SSH"
# Prefer standalone kustomize; fall back to the one built into kubectl.
KUSTOMIZE := $(shell command -v kustomize >/dev/null 2>&1 && echo kustomize || echo 'kubectl kustomize')

.DEFAULT_GOAL := help
.PHONY: help try up down trust lab-push lab-tunnel lab-down lab-sync lab-oci lab-status lab-logs lab-shell kbuild

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## ---- install (Ansible) ---------------------------------------------------

install: ## full no-KVM lab install via Ansible (idempotent); TAGS=storage to slice
	@cd ansible && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),)

## ---- lab lifecycle -------------------------------------------------------

lab-push: ## rsync repo to the lab and run host bootstrap (Stage 0)
	@$(LABENV); \
	  rsync -az --delete --exclude '.git' --exclude '.lab' ./ "$$LAB_SSH:$$LAB_REMOTE_DIR/"; \
	  $(SSH) "cd $$LAB_REMOTE_DIR && sudo -E bash bootstrap/rocky/bootstrap.sh"

up: ## create the Talos-in-Docker cluster on the lab
	@$(LABENV); \
	  $(SSH) "cd $$LAB_REMOTE_DIR && LAB_CLUSTER=$$LAB_CLUSTER bash dev/lab/remote-up.sh"

down: ## destroy the lab cluster (and loop devices); keeps Docker/daemon.json
	@$(LABENV); \
	  $(SSH) "cd $$LAB_REMOTE_DIR && bash bootstrap/rocky/teardown.sh" || true

## ---- remote dev loop -----------------------------------------------------

lab-tunnel: ## open the persistent SSH tunnel + fetch kubeconfig
	@$(LABENV); bash dev/lab/tunnel.sh up

lab-down: ## close the SSH tunnel
	@$(LABENV); bash dev/lab/tunnel.sh down

lab-sync: ## push the working-tree overlay to the lab (kubectl apply --server-side)
	@$(LABENV); bash dev/lab/sync.sh apply

lab-oci: ## push the working tree as an OCI artifact to the lab zot (reconcile-semantics)
	@$(LABENV); bash dev/lab/sync.sh oci

lab-status: ## read lab reconcile/health back, rendered locally
	@$(LABENV); bash dev/lab/status.sh

lab-logs: ## stream logs for a workload:  make lab-logs C='-n kubevirt deploy/virt-operator'
	@$(LABENV); KUBECONFIG="$$LAB_KUBECONFIG" kubectl logs -f $(C)

lab-shell: ## ssh into the lab host
	@$(LABENV); $(SSH)

## ---- stage 1: CNI ---------------------------------------------------------

cilium: ## bootstrap Cilium as CNI on the lab (helm, layered base+env values)
	@$(LABENV); bash dev/lab/cilium-install.sh

mtu-test: ## Stage 1 exit gate: large-payload pod-to-pod test under the host MTU
	@$(LABENV); bash dev/lab/mtu-test.sh

## ---- convenience ---------------------------------------------------------

try: lab-push up lab-tunnel lab-sync ## one-shot: bring the lab up and sync from scratch
	@echo "try: lab is up and synced. 'make lab-status' to watch it reconcile."

trust: ## import the cluster's dev CA into the local trust store (TLS without warnings)
	@echo "TODO (Stage 6): fetch cert-manager dev CA over the tunnel and add to the OS/browser trust store."

kbuild: ## verify the overlays build (structure-integrity / customization-boundary check)
	@for e in environments/*/; do echo "== $(KUSTOMIZE) $$e =="; $(KUSTOMIZE) "$$e" >/dev/null && echo OK; done
