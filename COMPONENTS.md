# Cluster Components
Each component directory follows the same layout:

```
<component>/
  Makefile                 # run `make -C <component>` to list its targets
  base/                    # resources specific to this cluster (pools, storage classes, …)
  overlays/prerequisites/  # upstream CRDs and common resources, pinned by tag
  overlays/install/        # upstream operator or controller
  overlays/demigods/       # base/ plus cluster patches
  overlays/<extra>/        # backs an extra target (rook: toolbox; postgresql: snapshot, b2backup, plugin-barman-cloud)
  helm/                    # values files for the Helm route
  README.md                # day-two operations, where a component has them
```

Standard targets (only where the component supports them):

| Target | Purpose |
|---|---|
| `prerequisites` | CRDs and anything the install needs first |
| `install` | Kustomize install (runs `prerequisites` first) |
| `helm` | Helm install, an alternative to `install` |
| `demigods` | Apply this cluster's config from `base/` (works after either route) |
| `uninstall` / `uninstall-helm` | Tear down the matching route, in reverse order |

**Pick one route per component and stay on it.** Kustomize-installed objects carry `app.kubernetes.io/managed-by: kustomize`, and Helm refuses to adopt them ("invalid ownership metadata"). To switch a component from one route to the other, run its matching `uninstall` target first. On the live cluster, Traefik runs from the Helm route because `postCertManager` needs it. Every other component runs from the kustomize route.

| Component | Version | prerequisites | install | helm | demigods | Extra |
|---|---|---|---|---|---|---|
| metallb | v0.16.2 (FRR-K8s) | strictARP | ✅ | ✅ | `primary-pool` (192.168.5.60–62) + L2/BGP adverts | |
| external-snapshotter | v8.7.0 | snapshot CRDs | snapshot-controller (kube-system) | no upstream chart | default `rook-ceph-snapclass` VolumeSnapshotClass | |
| rook | v1.21.2 | CRDs, common, csi-operator | ✅ (upstream examples, patched) | ✅ (operator + cluster charts) | `ssd-pool` + default `rook-ceph` StorageClass | `toolbox` |
| iscsi | master @ `ce838d0` (image pinned by digest) | `CSIDriver` | node DaemonSet | no upstream chart | `iscsi-static` StorageClass + any static PVs in `base/` | see `iscsi/README.md`, `iscsi/SERVER-SETUP.md` |
| traefik | chart 42.4.1 | Gateway API v1.7.0 CRDs | ✅ (kustomize inflates the chart) | ✅ | — | `postCertManager` (Helm route only) |
| certificateManager | v1.21.3 | Gateway API CRDs (from traefik) | ✅ (upstream manifest, patched) | ✅ | Cloudflare token Secret + `letsencrypt-dns01` ClusterIssuer | |
| postgresql | CloudNativePG v1.30.2 (chart 0.29.2) + Barman Cloud plugin v0.16.0 | — | ✅ (upstream manifests) | ✅ (plugin via kustomize) | `db` namespace + `cluster00` (3 instances on `rook-ceph`) + daily snapshot backup + WAL archive and weekly base backup to Backblaze B2 (key in git-ignored `postgresql/base/backblaze.env`) | `snapshot`, `b2backup`, `snapshots` (see `postgresql/README.md`) |
| harbor | chart 1.19.4 running Harbor v2.16.0 images (first arm64 release) | `harbor` namespace, password Secrets, `harbor` DatabaseRole + Database (cluster00) | — | ✅ (Helm only) | — | `password` (see `harbor/README.md`) |

## Storage

| Class | Kind | Backed by | Use for |
|---|---|---|---|
| `rook-ceph` (**default**) | StorageClass, dynamic | Ceph RBD, `ssd-pool`: 3 replicas across the four workers' NVMe drives (`nvme` device class), ~590 GiB usable | Everything, unless it won't fit |
| `iscsi-static` | StorageClass, static only | LUNs on the RAID10 array on hercules (`192.168.5.9`), ~950 GiB | Large volumes that won't fit in Ceph |
| `rook-ceph-snapclass` (**default**) | VolumeSnapshotClass, `deletionPolicy: Delete` | Ceph RBD snapshots (copy-on-write) | Snapshots of `rook-ceph` volumes, CNPG backups |

- **`rook-ceph`** uses `reclaimPolicy: Delete`. Deleting a PVC deletes its data. Ceph classes NVMe OSDs as `nvme`, not `ssd`, so `ssd-pool` uses `deviceClass: nvme`. The pool keeps its historical name.
- **`iscsi-static`** has no provisioner. csi-driver-iscsi is alpha and has no CreateVolume, so each volume needs a LUN plus a hand-written PV. On hercules, `iscsi-lun-create <name> <size>` creates the LUN and prints a ready PV. Save that PV in `iscsi/base/`, list it in `iscsi/base/kustomization.yaml`, and run `make -C iscsi demigods`. The class uses `WaitForFirstConsumer`, so a PVC stays `Pending` until a pod using it is scheduled. Pin a PVC to its PV with `volumeName`. Every node needs `open-iscsi` (`iscsiadm`, running `iscsid`) and a unique initiator name, `iqn.2026-11.home.demigods:<hostname>`, that matches the target's ACLs. The target IQN is `iqn.2026-11.app.faultycloud:storage`.

## Order
Running `make install` (kustomize) or `make helm` at the repo root installs everything in dependency order:

1. **metallb**: LoadBalancer IPs. Without its `demigods` address pool, every LoadBalancer Service, including traefik's, stays `<pending>`.
2. **external-snapshotter**: snapshot CRDs and controller. It must come before rook and postgresql (see [Install-order dependencies](#install-order-dependencies)).
3. **rook**: the Ceph cluster on the NVMe drives of the four workers. hercules has no data drive and gets no OSD.
4. **iscsi**: the iSCSI CSI node driver and the `iscsi-static` StorageClass. It runs on the four workers only, because hercules is tainted `control-plane:NoSchedule`.
5. **traefik**: Gateway API CRDs, Traefik and the `traefik-gateway` Gateway (HTTP only at this point).
6. **certificateManager**: cert-manager and the `letsencrypt-dns01` DNS-01 issuer. Before running it, `cp certificateManager/base/cloudflare.env.example certificateManager/base/cloudflare.env` and fill in the Cloudflare API token. The file is git-ignored, and kustomize generates the Secret from it.
7. **postgresql**: the CloudNativePG operator and the Barman Cloud plugin. The plugin uses cert-manager for its TLS, so it comes after certificateManager.

The root targets stop there. Three more steps are manual, in this order:

- `make -C traefik postCertManager` switches the Gateway to HTTPS for `faultycloud.app`, using the `faultycloud-app-tls` certificate from `letsencrypt-dns01`. It needs the Helm route (`make -C traefik helm` or `make helm`) and certificateManager's `demigods` step.
- `make -C postgresql demigods` creates `cluster00`, its backup schedules and the Backblaze B2 ObjectStore. First `cp postgresql/base/backblaze.env.example postgresql/base/backblaze.env` and fill in the B2 key. The file is git-ignored, and the target refuses to run without it. It waits up to `PG_TIMEOUT` (default 15m) for the cluster to be Ready, then for WAL archiving to B2, and takes the first B2 base backup if none exists.
- `make -C harbor helm` installs Harbor at `https://harbor.faultycloud.app`, after `cluster00` and `traefik postCertManager`. It generates its own git-ignored passwords and creates a `harbor` DatabaseRole and Database for cluster00 without modifying cluster00 or the postgresql component (see `harbor/README.md`). The name must resolve to `192.168.5.60` on the LAN, including on the nodes, for pushes and pulls.

After `postCertManager`, `traefik-gateway` has four listeners: `web` and `websecure` for `faultycloud.app`, plus `web-wildcard` and `websecure-wildcard` for `*.faultycloud.app`. A wildcard listener doesn't match the bare domain, hence the pairs. Both HTTPS listeners share the `faultycloud-app-tls` certificate, which covers both names. An HTTPRoute can attach only from a namespace labeled `demigods/traefik-gateway=allowed`:

```sh
kubectl label namespace <ns> demigods/traefik-gateway=allowed
```

```yaml
# HTTPRoute in that namespace
spec:
  parentRefs: [{name: traefik-gateway, namespace: traefik}]
  hostnames: ["app.faultycloud.app"]
```

A route from an unlabeled namespace, including `traefik` itself, is rejected with `Accepted=False (NotAllowedByListeners)`. Every plain-HTTP request is redirected to HTTPS with a `301`, keeping the host, path and query. Traefik does this on the `web` entrypoint before any route matches, so apps never serve over HTTP and their HTTPRoutes need no redirect filter. These settings are only in `traefik/helm/postCertManager.yaml`. The pre-certificate `helm/install.yaml` route still has a single apex HTTP listener.

Every `prerequisites`, `install` and `helm` target blocks until what it created is ready, so targets can be chained (`make -C rook install demigods`). Ready means CRDs are Established and all Deployments, DaemonSets and StatefulSets have rolled out (see `hack/wait-ready.sh`). Some components add their own check:

- **metallb**: waits until its webhooks accept the demigods config.
- **rook**: waits for the CephCluster to reach `Ready` (up to `CEPH_TIMEOUT`, default 30m; a first install takes about 11 minutes) and for the RBD CSI driver to be registered. `demigods` waits for `ssd-pool` to be Ready.
- **iscsi**: `prerequisites` waits for the `CSIDriver` to exist. `install` waits for the node DaemonSet on every worker.
- **traefik**: waits for the Gateway to be `Programmed`.
- **certificateManager**: waits until its webhook accepts the issuer config. `demigods` waits for the ClusterIssuer to be Ready (registered with Let's Encrypt).
- **postgresql**: `install` / `helm` also wait for the Barman Cloud plugin. `demigods` waits until the webhook accepts `cluster00`, for the cluster to be Ready, and until every instance has the barman-cloud sidecar and `ContinuousArchiving` is `True`. `snapshot` and `b2backup` wait for the Backup to complete, up to `SNAPSHOT_WAIT` seconds (default 600).
- **harbor**: `prerequisites` waits until the `harbor` DatabaseRole is applied with no error, then for the `harbor` Database. `helm` waits for every workload and for the HTTPRoute to be Accepted.

Other timeouts default to `WAIT_TIMEOUT=300s`; override with, for example, `make install WAIT_TIMEOUT=10m`.

## Install-order dependencies
Some controllers only detect CRDs when they start. If the CRDs are installed after the controller, it keeps running without them until it is restarted:

| Installed late | Affected | Symptom | Fix |
|---|---|---|---|
| external-snapshotter (snapshot CRDs) | rook's RBD and CephFS CSI controllers | `csi-snapshotter` sidecar logs `failed to list *v1.VolumeSnapshotContent` | `kubectl -n rook-ceph rollout restart deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin deploy/rook-ceph.cephfs.csi.ceph.com-ctrlplugin` |
| external-snapshotter (snapshot CRDs) | CloudNativePG operator | `method: volumeSnapshot` rejected: "missing VolumeSnapshot CRD" | `kubectl -n cnpg-system rollout restart deploy/cnpg-controller-manager` |
| certificateManager `demigods` (ClusterIssuer) | traefik `postCertManager` | Certificate stuck `Ready: False`, "ClusterIssuer not found" | Run certificateManager `demigods`. cert-manager retries on its own. |

The root `make install` / `make helm` order avoids all three.

## Local patches to upstream
These are deliberate deviations from the pinned upstream manifests. Keep them when bumping versions, and drop any that upstream fixes:

- **rook** (`overlays/install`):
  - `csi.cephfs: {}`. Upstream `cluster.yaml` v1.21.2 leaves it with only commented-out keys, which parses as `null` and fails CRD validation.
  - `deviceFilter: ^nvme0n1$` with `useAllDevices: false`.
  - The cephx cipher settings.
- **rook** (`base/`): `deviceClass: nvme` on `ssd-pool`.
- **certificateManager** (`overlays/install`): `--enable-gateway-api` and `--enable-certificate-owner-ref=true`, to match `helm/values.yaml`.
- **iscsi**: pinned to a master commit, with the plugin image pinned by digest, because upstream only publishes a moving `canary` tag.
- **postgresql**:
  - `shared_buffers: 256MB`. It must fit well inside the 2Gi memory limit.
  - Cold (`online: false`) volume-snapshot backups. They were chosen when there was no WAL archive, and they stay self-contained, so a snapshot restore never needs B2. With B2 archiving in place they could switch to hot (`online: true`), which avoids fencing a standby.
  - Barman Cloud sidecar env `AWS_REQUEST_CHECKSUM_CALCULATION` / `AWS_RESPONSE_CHECKSUM_VALIDATION` = `when_required`, the plugin's workaround for S3-compatible stores (B2).
  - The B2 ScheduledBackup has `immediate: false`. `make demigods` takes the first base backup once the sidecars are up.

- **harbor**:
  - All images overridden to `v2.16.0` on chart 1.19.4 (built for 2.15.4, amd64-only images). Switch to the first 2.16 chart and drop the overrides.
  - `maxOpenConns: 30` / `maxIdleConns: 5`, down from 900/100, so Harbor can't exhaust cluster00's 100 connections.

## Uninstalling
`make uninstall` or `make uninstall-helm` tears everything down in reverse. Uninstalling removes CRDs, which deletes every object of those kinds. Some components lose data when uninstalled:

- **harbor**: `uninstall-helm` removes the release only. The PVCs (image layers), the `harbor` namespace and its Secrets, and the `harbor` database and role in cluster00 are kept. The root `uninstall` targets remove Harbor before postgresql.
- **postgresql**: deletes `cluster00`, its volumes (`rook-ceph` is `Delete`) and the `db` namespace. That includes **every Backup and VolumeSnapshot**, so the snapshot backups go too. The Backblaze B2 bucket is not touched, so the off-cluster backups survive. With no cluster archiving there any more, nothing prunes them.
- **external-snapshotter**: deletes every VolumeSnapshot in the cluster.
- **traefik**: both uninstall targets remove the Gateway API CRDs, which deletes every Gateway and HTTPRoute in the cluster. certificateManager also depends on those CRDs.
- **rook**: Rook does not wipe the OSD drives. Re-using them needs a manual wipe (see Rook's cleanupPolicy docs).
- **iscsi**: deleting a PV only removes the Kubernetes object. The LUN and its data on the target are untouched.

Requires `kubectl` (1.37), `kustomize` (5.x) and `helm` (4.x), with the `demigods` context selected.
