# PostgreSQL — Snapshot Backups

`cluster00` (namespace `db`) is a three-instance CloudNativePG cluster on the `rook-ceph` StorageClass. It is backed up with **CSI volume snapshots** of an instance's 64Gi data volume, taken through `rook-ceph-snapclass`. There is no WAL archive or object store.

| Task | Command (from `postgresql/`) |
| --- | --- |
| Take a snapshot now | `make snapshot` |
| Take a tagged snapshot | `make snapshot SNAPSHOT_LABEL=pre-upgrade` |
| List backups and snapshots | `make snapshots` |
| Delete one backup and its snapshot | `kubectl -n db delete backup <name>` |
| Pause the daily schedule | `kubectl -n db patch scheduledbackup cluster00-daily --type merge -p '{"spec":{"suspend":true}}'` |
| Restore | See [Restoring](#restoring) |

## How a snapshot backup works

Every backup is **cold**: CNPG fences one standby (stops Postgres on it), snapshots that instance's PVC, then unfences it. A cold snapshot is consistent by itself, so it needs no WAL archive. This is the approach CNPG recommends when there is no archive.

- The **primary keeps serving** throughout. Backups target `prefer-standby` and only fall back to the primary if no standby is healthy. A backup on the primary makes the cluster read-only for its duration.
- A backup takes about **30 seconds**. The fenced standby catches up and is Ready again about 30 seconds later, so `kubectl -n db get cluster` briefly shows `READY 2` of 3.
- Ceph snapshots are copy-on-write. A new snapshot costs almost nothing, and grows only as the data on the volume changes.

The settings live in `overlays/demigods/kustomization.yaml` as a patch on the Cluster:

```yaml
spec:
  backup:
    target: prefer-standby
    volumeSnapshot:
      className: rook-ceph-snapclass
      online: false                 # cold
      snapshotOwnerReference: backup
```

`snapshotOwnerReference: backup` ties each VolumeSnapshot to its CNPG `Backup` object. **Deleting the Backup deletes the snapshot**, and the class's `deletionPolicy: Delete` then removes the Ceph snapshot as well. Backups themselves have no owner, so they survive deleting the `cluster00` Cluster.

## Scheduled backups

`overlays/demigods/backup.yaml` defines the ScheduledBackup `cluster00-daily`. It runs at **03:00 UTC every day** and is named `cluster00-daily-<timestamp>`. CNPG cron has six fields with seconds first: `"0 0 3 * * *"`. It is applied with the rest of the cluster by `make demigods`, and it took a first backup immediately.

## Ad-hoc snapshots

Take one before anything risky, such as a schema migration, an upgrade or a bulk delete:

```sh
make snapshot SNAPSHOT_LABEL=pre-upgrade
```

This builds `overlays/snapshot`, a single CNPG `Backup` with `method: volumeSnapshot`, and creates it as `cluster00-<SNAPSHOT_LABEL>-<UTC timestamp>`. It then waits until CNPG reports the backup `completed`, exiting 0, or `failed`, exiting 1. `SNAPSHOT_LABEL` defaults to `adhoc`. The wait limit is `SNAPSHOT_WAIT`, default 600 seconds.

Kustomize cannot build an object without a fixed name, so the overlay uses a placeholder name, `cluster00-snapshot-placeholder`, which the Makefile replaces on every run. Do not `kubectl apply` the overlay by hand: you would create the placeholder-named backup once, and re-applying it does nothing.

The same thing without make:

```sh
kubectl create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cluster00-manual-$(date -u +%Y%m%d%H%M%S)
  namespace: db
  labels: {cnpg.io/cluster: cluster00}
spec:
  cluster: {name: cluster00}
  method: volumeSnapshot
EOF
```

Ad-hoc backups carry the label `demigods/backup-type=adhoc`, so they can be listed separately with `kubectl -n db get backup -l demigods/backup-type=adhoc`.

## Retention

**Nothing deletes old backups automatically.** CNPG's `retentionPolicy` only applies to object-store backups. Prune by deleting old `Backup` objects, which removes each one's snapshot as well:

```sh
make snapshots                                      # oldest first
kubectl -n db delete backup cluster00-daily-20261121231754
```

## Restoring

A snapshot restores into a **new** Cluster that bootstraps from it. Restoring always lands exactly at the moment of a backup. Point-in-time recovery between backups needs a WAL archive, which this setup does not have.

### Side by side (recommended first step)

This leaves `cluster00` untouched, so you can inspect the data or copy pieces back:

```sh
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster00-restore
  namespace: db
spec:
  instances: 1
  storage: {size: 64Gi, storageClass: rook-ceph}    # at least the snapshot's RESTORESIZE
  bootstrap:
    recovery:
      volumeSnapshots:
        storage:
          name: cluster00-daily-20261121231754      # the VolumeSnapshot name (same as the Backup)
          kind: VolumeSnapshot
          apiGroup: snapshot.storage.k8s.io
EOF
kubectl -n db wait cluster/cluster00-restore --for=condition=Ready --timeout=15m
kubectl -n db exec -it cluster00-restore-1 -c postgres -- psql -U postgres -d app
```

Delete it with `kubectl -n db delete cluster cluster00-restore` when you're done. The source snapshot is not affected. This procedure has been tested: a row written just before a backup was present in the restored cluster.

### Replacing cluster00

To roll `cluster00` itself back to a snapshot:

1. Take a snapshot of the current state first (`make snapshot SNAPSHOT_LABEL=before-restore`), in case you need it.
2. Stop the apps that write to it.
3. `kubectl -n db delete cluster cluster00`. This deletes its pods, PVCs, data and Secrets. The Backups, their VolumeSnapshots and the `cluster00-daily` ScheduledBackup stay.
4. Temporarily add the `bootstrap` block to `base/cluster00.yaml`, directly under `instances: 3`, then run `make demigods`:
   ```yaml
     bootstrap:
       recovery:
         volumeSnapshots:
           storage:
             name: <VolumeSnapshot name from `make snapshots`>
             kind: VolumeSnapshot
             apiGroup: snapshot.storage.k8s.io
   ```
5. Once it is Ready, remove the `bootstrap` block from `base/cluster00.yaml` and run `make demigods` again. The API server accepts the change without restarting anything. CNPG fills in an `initdb` default in the live spec, but that field is only read when a cluster is created.
6. Restart the apps. **The `app` password changes**: CNPG generates a new `cluster00-app` Secret and resets the role's password to match it, so apps must pick up the new Secret.

This procedure was tested on 2026-11-21 with marker rows on either side of a snapshot. The restored cluster had the row written before the snapshot and not the one written after. It took about 2 minutes to reach `3/3` Ready, with both replicas streaming and the restored data on each.

`make uninstall` is **not** a restore path. It deletes the `db` namespace, and with it every Backup and VolumeSnapshot.

## Limits and gotchas

- **Same failure domain.** The snapshots live in the same Ceph cluster as the database. They protect against mistakes and bad writes, not against losing Ceph. Off-cluster copies need an object store and the Barman Cloud plugin.
- **No point-in-time recovery.** You can only restore to the moment a backup was taken.
- **Install order.** The CNPG operator must start after the snapshot CRDs exist (install `external-snapshotter` first). If it started first, `method: volumeSnapshot` is rejected with "missing VolumeSnapshot CRD" until you run `kubectl -n cnpg-system rollout restart deploy/cnpg-controller-manager`.
- **A cold backup is rejected while any instance is already fenced.**
- If a backup sits in `started`, check `kubectl -n db describe backup <name>` and the snapshot-controller logs (`kubectl -n kube-system logs deploy/snapshot-controller`). CNPG gives up on a snapshot after 10 minutes by default.
