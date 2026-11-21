include ../common.mk

NAMESPACE     := rook-ceph
CHART_REPO    := https://charts.rook.io/release
CHART_VERSION := v1.21.2
# Bringing up mons, mgr and OSDs on the Pis can take a while.
CEPH_TIMEOUT  ?= 30m

# Wait until the CephCluster is Ready, the RBD CSI driver is registered and every
# workload in the namespace (mons, mgr, OSDs, CSI plugins) has rolled out.
define wait_ceph
$(KUBECTL) -n $(NAMESPACE) wait cephcluster/rook-ceph --for=jsonpath='{.status.phase}'=Ready --timeout=$(CEPH_TIMEOUT)
$(KUBECTL) wait --for=create csidriver/rook-ceph.rbd.csi.ceph.com --timeout=$(WAIT_TIMEOUT)
$(WAIT_READY) -n $(NAMESPACE)
endef

.PHONY: prerequisites install helm demigods toolbox uninstall uninstall-helm

prerequisites: ## Install the Rook CRDs, common RBAC and the ceph-csi operator
	$(call kinstall,overlays/prerequisites)

install: prerequisites ## Install the Rook operator and the CephCluster via kustomize; waits for a Ready cluster
	$(call kinstall,overlays/install)
	$(wait_ceph)

helm: ## Install the Rook operator and the CephCluster with Helm; waits for a Ready cluster
	$(HELM) upgrade --install rook-ceph rook-ceph --repo $(CHART_REPO) --version $(CHART_VERSION) \
		-n $(NAMESPACE) --create-namespace -f helm/operator.yaml --wait
	$(HELM) upgrade --install rook-ceph-cluster rook-ceph-cluster --repo $(CHART_REPO) --version $(CHART_VERSION) \
		-n $(NAMESPACE) -f helm/cluster.yaml
	$(wait_ceph)

demigods: ## Apply the ssd-pool CephBlockPool and the rook-ceph-ssd StorageClass; waits for the pool
	$(call kapply,overlays/demigods)
	$(KUBECTL) -n $(NAMESPACE) wait cephblockpool/ssd-pool --for=jsonpath='{.status.phase}'=Ready --timeout=$(WAIT_TIMEOUT)

toolbox: ## Deploy the rook-ceph-tools pod
	$(call kinstall,overlays/toolbox)

# Teardown order matters: pools before the cluster, the cluster before the operator
# (or the CephCluster finalizer is never removed), and the CRDs last.
# Data on the OSD drives is NOT wiped; see Rook's cleanupPolicy docs for that.

uninstall: ## Remove toolbox, pools, CephCluster, operator and CRDs (kustomize route)
	-$(call kdelete,overlays/toolbox)
	-$(call kdelete,overlays/demigods)
	-$(KUBECTL) -n $(NAMESPACE) delete cephcluster rook-ceph --ignore-not-found --timeout=10m
	-$(call kdelete,overlays/install)
	-$(call kdelete,overlays/prerequisites)

uninstall-helm: ## Remove toolbox, pools and both Helm releases (Helm route)
	-$(call kdelete,overlays/toolbox)
	-$(call kdelete,overlays/demigods)
	-$(HELM) uninstall rook-ceph-cluster -n $(NAMESPACE) --wait
	-$(HELM) uninstall rook-ceph -n $(NAMESPACE) --wait
