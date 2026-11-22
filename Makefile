include common.mk

# Install order. Teardown runs in reverse.
#   metallb              - LoadBalancer IPs (traefik's Service needs one)
#   external-snapshotter - VolumeSnapshot CRDs + controller (rook's CSI snapshots use them)
#   rook                 - Ceph cluster, ssd-pool and the rook-ceph StorageClass
#   iscsi                - iSCSI CSI node driver + static iSCSI PersistentVolumes (no Helm chart)
#   traefik              - Gateway API CRDs + Traefik ingress / gateway
#   certificateManager   - cert-manager + letsencrypt-dns01 ClusterIssuer (needs the Gateway API CRDs)
#   postgresql           - CloudNativePG operator (cluster00 is `make -C postgresql demigods`)
#   harbor               - container registry; manual (`make -C harbor helm`), needs cluster00 + traefik postCertManager
#
# Per-component targets: make -C <component> help

.PHONY: install helm uninstall uninstall-helm

install: ## Install every component with kustomize, then apply the demigods config
	$(MAKE) -C metallb install demigods
	$(MAKE) -C external-snapshotter install demigods
	$(MAKE) -C rook install demigods
	$(MAKE) -C iscsi install demigods
	$(MAKE) -C traefik install
	$(MAKE) -C certificateManager install demigods
	$(MAKE) -C postgresql install

helm: ## Install every component with Helm where a chart exists (kustomize otherwise)
	$(MAKE) -C metallb helm demigods
	$(MAKE) -C external-snapshotter install demigods
	$(MAKE) -C rook helm demigods
	$(MAKE) -C iscsi install demigods
	$(MAKE) -C traefik helm
	$(MAKE) -C certificateManager helm demigods
	$(MAKE) -C postgresql helm

uninstall: ## Tear down everything installed by `make install`
	-$(MAKE) -C harbor uninstall-helm
	-$(MAKE) -C postgresql uninstall
	-$(MAKE) -C certificateManager uninstall
	-$(MAKE) -C traefik uninstall
	-$(MAKE) -C iscsi uninstall
	-$(MAKE) -C rook uninstall
	-$(MAKE) -C external-snapshotter uninstall
	-$(MAKE) -C metallb uninstall

uninstall-helm: ## Tear down everything installed by `make helm`
	-$(MAKE) -C harbor uninstall-helm
	-$(MAKE) -C postgresql uninstall-helm
	-$(MAKE) -C certificateManager uninstall-helm
	-$(MAKE) -C traefik uninstall-helm
	-$(MAKE) -C iscsi uninstall
	-$(MAKE) -C rook uninstall-helm
	-$(MAKE) -C external-snapshotter uninstall
	-$(MAKE) -C metallb uninstall-helm
