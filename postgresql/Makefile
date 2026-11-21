include ../common.mk

NAMESPACE     := cnpg-system
CHART_REPO    := https://cloudnative-pg.github.io/charts
CHART_VERSION := 0.29.2
# CloudNativePG v1.30.2 (kustomize manifest in overlays/install, chart 0.29.2 for Helm).

DB_NAMESPACE  := db
CLUSTER       := cluster00
# initdb plus two replicas cloning over the network can take a while on the Pis.
PG_TIMEOUT    ?= 15m

# make snapshot: the Backup is named $(CLUSTER)-$(SNAPSHOT_LABEL)-<UTC timestamp>.
SNAPSHOT_LABEL ?= adhoc
# Seconds to wait for an ad-hoc snapshot backup to complete.
SNAPSHOT_WAIT  ?= 600

.PHONY: install helm demigods snapshot snapshots uninstall uninstall-helm

install: ## Install the CloudNativePG operator (cnpg-system) via kustomize; waits for it
	$(call kinstall,overlays/install)

helm: ## Install the CloudNativePG operator with Helm (helm/values.yaml); waits for it
	$(HELM) upgrade --install cnpg cloudnative-pg --repo $(CHART_REPO) --version $(CHART_VERSION) \
		-n $(NAMESPACE) --create-namespace -f helm/values.yaml --wait
	$(WAIT_READY) -n $(NAMESPACE)

# The namespace is created first so the server-side dry run (which waits for the operator's
# webhook to answer) can validate the namespaced Cluster.
demigods: ## Create the db namespace and the cluster00 Postgres cluster; waits until it is Ready
	$(KUBECTL) create namespace $(DB_NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(call wait_accepts,$(KUSTOMIZE) build overlays/demigods)
	$(call kapply,overlays/demigods)
	$(KUBECTL) -n $(DB_NAMESPACE) wait cluster/$(CLUSTER) --for=condition=Ready --timeout=$(PG_TIMEOUT)

# Creates a new Backup from overlays/snapshot under a unique name, then polls until CNPG reports
# completed (exit 0) or failed (exit 1). The standby it runs on rejoins about 30s later.
snapshot: ## Take an ad-hoc volume-snapshot backup of cluster00 now (SNAPSHOT_LABEL=pre-upgrade to tag it); waits for it
	@echo "$(SNAPSHOT_LABEL)" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,20}[a-z0-9])?$$' || { \
		echo "SNAPSHOT_LABEL must be 1-22 chars of a-z, 0-9 and '-' (got '$(SNAPSHOT_LABEL)')" >&2; exit 1; }
	@name=$(CLUSTER)-$(SNAPSHOT_LABEL)-$$(date -u +%Y%m%d%H%M%S); \
	$(KUSTOMIZE) build overlays/snapshot \
		| sed "s/^  name: $(CLUSTER)-snapshot-placeholder$$/  name: $$name/" \
		| $(KUBECTL) create -f - || exit 1; \
	echo "waiting up to $(SNAPSHOT_WAIT)s for backup/$$name ..."; \
	for i in $$(seq 1 $$(( $(SNAPSHOT_WAIT) / 5 ))); do \
		phase=$$($(KUBECTL) -n $(DB_NAMESPACE) get backup $$name -o jsonpath='{.status.phase}'); \
		case "$$phase" in \
		completed) $(KUBECTL) -n $(DB_NAMESPACE) get backup,volumesnapshot $$name; exit 0 ;; \
		failed) $(KUBECTL) -n $(DB_NAMESPACE) get backup $$name -o jsonpath='{.status.error}{"\n"}' >&2; exit 1 ;; \
		esac; \
		sleep 5; \
	done; \
	echo "timed out; check: kubectl -n $(DB_NAMESPACE) describe backup $$name" >&2; exit 1

snapshots: ## List cluster00's backups (scheduled and ad-hoc) and their VolumeSnapshots
	$(KUBECTL) -n $(DB_NAMESPACE) get backup -l cnpg.io/cluster=$(CLUSTER) --sort-by=.metadata.creationTimestamp
	$(KUBECTL) -n $(DB_NAMESPACE) get volumesnapshot -l cnpg.io/cluster=$(CLUSTER) --sort-by=.metadata.creationTimestamp

# Deleting the Cluster deletes its PVCs, and rook-ceph's Delete reclaim policy removes the
# RBD images with them: uninstall destroys the database data. Deleting the db namespace also
# deletes every Backup and VolumeSnapshot in it, so the backups go too.
#
# Install external-snapshotter before this operator. If the snapshot CRDs are added later,
# restart it (kubectl -n cnpg-system rollout restart deploy/cnpg-controller-manager) or
# method: volumeSnapshot backups are rejected.

uninstall: ## Remove cluster00, the db namespace and the kustomize operator install (deletes the CNPG CRDs)
	-$(call kdelete,overlays/demigods)
	-$(call kdelete,overlays/install)

uninstall-helm: ## Remove cluster00, the db namespace and the Helm release
	-$(call kdelete,overlays/demigods)
	-$(HELM) uninstall cnpg -n $(NAMESPACE) --wait
	-$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
