# Local checks, the same as CI's validate.yml (run before pushing). Not used by CI.
#   make validate      everything below
#   make kustomize     render both environments
#   make kubeconform   rendered manifests against Kubernetes schemas
#   make terraform     fmt -check + validate (no init, no plan, no state access)
#   make shellcheck    every script
#   make secrets       gitleaks over the working tree
.PHONY: validate kustomize kubeconform terraform shellcheck secrets
TMP := $(shell mktemp -d)

validate: kustomize kubeconform terraform shellcheck secrets

kustomize:
	kubectl kustomize envs/local/apps > $(TMP)/local.yaml
	kubectl kustomize envs/oracle/apps > $(TMP)/oracle.yaml
	@echo "kustomize: both environments render"

kubeconform: kustomize
	kubeconform -strict -ignore-missing-schemas -summary $(TMP)/local.yaml $(TMP)/oracle.yaml

terraform:
	cd terraform/oracle && terraform fmt -check -recursive && terraform validate   # needs a prior terraform init (your normal one)

shellcheck:
	shellcheck -S error scripts/*.sh envs/oracle/*.sh

secrets:
	gitleaks dir . --no-banner --redact
