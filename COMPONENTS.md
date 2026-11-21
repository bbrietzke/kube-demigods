# Cluster Components
Each component directory follows the same layout:

```
<component>/
  Makefile                 # run `make -C <component>` to list its targets
  base/                    # resources specific to this cluster (pools, storage classes, …)
  overlays/prerequisites/  # upstream CRDs and common resources, pinned by tag
  overlays/install/        # upstream operator or controller
  overlays/demigods/       # base/ plus cluster patches
  helm/                    # values files for the Helm route
```

Standard targets (only where the component supports them):

| Target | Purpose |
|---|---|
| `prerequisites` | CRDs and anything the install needs first |
| `install` | Kustomize install (runs `prerequisites` first) |
| `helm` | Helm install, an alternative to `install` |
| `demigods` | Apply this cluster's config from `base/` (works after either route) |
| `uninstall` / `uninstall-helm` | Tear down the matching route, in reverse order |

| Component | Version | prerequisites | install | helm | demigods | Extra |
|---|---|---|---|---|---|---|
| metallb | v0.16.2 (FRR-K8s) | strictARP | ✅ | ✅ | address pool + adverts | |
| external-snapshotter | v8.7.0 | snapshot CRDs | ✅ | no upstream chart | `VolumeSnapshotClass` for rook RBD | |
| rook | v1.21.2 | CRDs, common, csi-operator | ✅ | ✅ (operator + cluster charts) | `ssd-pool` + `rook-ceph` | `toolbox` |
| iscsi | master @ `ce838d0` (image pinned by digest) | `CSIDriver` | node DaemonSet | no upstream chart | static iSCSI PVs | |
| traefik | chart 42.4.1 | Gateway API v1.7.0 CRDs | ✅ (kustomize inflates the chart) | ✅ | — | `postCertManager` |
| certificateManager | v1.21.3 | Gateway API CRDs (from traefik) | ✅ (upstream manifest, patched) | ✅ | Cloudflare token Secret + `letsencrypt-dns01` ClusterIssuer | |
| postgresql | CloudNativePG v1.30.2 (chart 0.29.2) | — | ✅ (upstream manifest) | ✅ | `db` namespace + `cluster00` (3 instances on `rook-ceph`) + daily snapshot backup | `snapshot`, `snapshots` (see `postgresql/README.md`) |

## Order
Running `make install` (kustomize) or `make helm` at the repo root installs everything in dependency order:

1. **metallb**: LoadBalancer IPs, which the traefik Service needs.
2. **external-snapshotter**: snapshot CRDs and controller.
3. **rook**: the Ceph cluster on the NVMe drives of the four workers.
4. **iscsi**: the iSCSI CSI node driver and the static iSCSI PersistentVolumes. Every node needs `open-iscsi` installed (`iscsiadm` and a running `iscsid`), because the driver runs the host's `iscsiadm`. Each node also needs a unique initiator name first (see [iSCSI initiator names](#iscsi-initiator-names)).
5. **traefik**: ingress and Gateway.
6. **certificateManager**: cert-manager and the `letsencrypt-dns01` DNS-01 issuer. Before running it, `cp certificateManager/base/cloudflare.env.example certificateManager/base/cloudflare.env` and fill in the Cloudflare API token. The file is git-ignored, and kustomize generates the Secret from it. Then run `make -C traefik postCertManager` to switch the Gateway to HTTPS (Helm route only).
7. **postgresql**: the CloudNativePG operator. `cluster00` is a separate step, `make -C postgresql demigods`, which waits up to `PG_TIMEOUT` (default 15m) for the cluster to be Ready.

Every `prerequisites`, `install` and `helm` target blocks until what it created is ready, so targets can be chained (`make -C rook install demigods`). Ready means CRDs are Established and all Deployments, DaemonSets and StatefulSets have rolled out (see `hack/wait-ready.sh`). Some components add their own check:

- **metallb**: waits until its webhooks accept the demigods config.
- **rook**: waits for the CephCluster to reach `Ready` (up to `CEPH_TIMEOUT`, default 30m) and for the RBD CSI driver to be registered. `demigods` waits for `ssd-pool` to be Ready.
- **traefik**: waits for the Gateway to be `Programmed`.
- **certificateManager**: waits until its webhook accepts the issuer config. `demigods` waits for the ClusterIssuer to be Ready (registered with Let's Encrypt).

Other timeouts default to `WAIT_TIMEOUT=300s`; override with, for example, `make install WAIT_TIMEOUT=10m`.

`make uninstall` or `make uninstall-helm` tears everything down in reverse. Uninstalling removes CRDs, which deletes every object of those kinds. Rook does not wipe the OSD drives.

Requires `kubectl`, `kustomize` (5.x) and `helm` (4.x), with the `demigods` context selected.
