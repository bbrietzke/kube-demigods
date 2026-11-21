include ../common.mk

# There is no Helm chart for csi-driver-iscsi, so this component is kustomize-only.
# Nodes need open-iscsi (iscsiadm + iscsid) installed; the plugin uses the host's iscsiadm.

.PHONY: prerequisites install demigods uninstall

prerequisites: ## Register the iscsi.csi.k8s.io CSIDriver
	$(call kapply,overlays/prerequisites)
	$(KUBECTL) wait --for=create csidriver/iscsi.csi.k8s.io --timeout=$(WAIT_TIMEOUT)

install: prerequisites ## Install the csi-iscsi-node DaemonSet (kube-system); waits for it on every node
	$(call kinstall,overlays/install)

demigods: ## Apply the iscsi-static StorageClass and any static iSCSI PVs listed in base/
	@if [ -z "$$($(KUSTOMIZE) build overlays/demigods)" ]; then \
		echo "overlays/demigods renders nothing; nothing to apply."; \
	else \
		$(KUSTOMIZE) build overlays/demigods | $(KUBECTL) apply --server-side --force-conflicts -f -; \
	fi

# Deleting a PV only removes the Kubernetes object; the LUN and its data on the target are untouched.
uninstall: ## Remove the PVs, the node DaemonSet and the CSIDriver
	-$(call kdelete,overlays/demigods)
	-$(call kdelete,overlays/install)
	-$(call kdelete,overlays/prerequisites)
