include ../common.mk

NAMESPACE     := metallb-system
CHART_REPO    := https://metallb.github.io/metallb
CHART_VERSION := 0.16.2

.PHONY: prerequisites install helm demigods uninstall uninstall-helm

prerequisites: ## Enable strictARP in kube-proxy (required for L2 mode with IPVS)
	$(KUBECTL) get configmap kube-proxy -n kube-system -o yaml | \
	sed -e "s/strictARP: false/strictARP: true/" | \
	$(KUBECTL) apply -f - -n kube-system

install: prerequisites ## Install MetalLB (FRR-K8s mode) via kustomize; waits until its webhooks accept config
	$(call kinstall,overlays/install)
	$(call wait_accepts,$(KUSTOMIZE) build overlays/demigods)

helm: prerequisites ## Install MetalLB (FRR-K8s mode) with Helm; waits until its webhooks accept config
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) label namespace $(NAMESPACE) --overwrite \
		pod-security.kubernetes.io/enforce=privileged \
		pod-security.kubernetes.io/audit=privileged \
		pod-security.kubernetes.io/warn=privileged
	$(HELM) upgrade --install metallb metallb --repo $(CHART_REPO) --version $(CHART_VERSION) \
		-n $(NAMESPACE) -f helm/values.yaml --wait
	$(WAIT_READY) -n $(NAMESPACE)
	$(call wait_accepts,$(KUSTOMIZE) build overlays/demigods)

demigods: ## Apply the demigods address pool and advertisements
	$(call wait_accepts,$(KUSTOMIZE) build overlays/demigods)
	$(call kapply,overlays/demigods)

uninstall: ## Remove the demigods config and the kustomize install
	-$(call kdelete,overlays/demigods)
	-$(call kdelete,overlays/install)

uninstall-helm: ## Remove the demigods config and the Helm release
	-$(call kdelete,overlays/demigods)
	-$(HELM) uninstall metallb -n $(NAMESPACE) --wait
	-$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
