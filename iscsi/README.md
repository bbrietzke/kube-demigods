# iSCSI Storage — Day-Two LUN Operations

Nov 21, 2026 · @Brian Brietzke

## Overview

Day two on this target is three jobs: adding and removing LUNs with `iscsi-lun-create` and `iscsi-lun-remove`, keeping an eye on the USB RAID10 array, and keeping the target config backed up. This assumes *iSCSI Storage — Target Build (One-Time Setup)* is complete; the scripts' source is in that document.

| Task | Command (as root on 192.168.5.9) |
| --- | --- |
| Create a LUN | `iscsi-lun-create db03 64G` |
| Remove a LUN | `iscsi-lun-remove db03` |
| List LUNs | `targetcli ls /iscsi/iqn.2026-11.app.faultycloud:storage/tpg1/luns` |
| Free space | `vgs vg_iscsi` |
| Array health | `cat /proc/mdstat` |
| Who is logged in | `targetcli sessions` |

## Access model

Every LUN is available on all five Kubernetes nodes: hercules, achilles, perseus, helen and aenes. This is deliberate, so a pod can be rescheduled to any node and still reach its volume.

All LUNs are mapped to all five initiators so that Kubernetes can attach a volume from whichever node a pod lands on. A LUN carrying a normal filesystem (ext4, xfs) must only be mounted by one node at a time. Use `ReadWriteOnce` PVs for that, and never point two pods on different nodes at the same LUN.

How the target keeps it that way:

- The target runs with `auto_add_mapped_luns=true`, so `iscsi-lun-create` maps each new LUN to all five ACLs in one step. There is no per-node option, by design.
- An ACL added later, for a sixth node or a renamed one, receives every existing LUN automatically.
- `iscsi-lun-remove` unmaps a LUN from all five ACLs at once.
- To check, `targetcli ls /iscsi/iqn.2026-11.app.faultycloud:storage/tpg1/acls` should show the same set of mapped LUNs under each of the five initiators.

## How iscsi-lun-create works

`iscsi-lun-create NAME SIZE` turns a short name and a size into a LUN every node can attach, and prints the Kubernetes `PersistentVolume` for it. The name becomes the LV (`/dev/vg_iscsi/NAME`), the backstore and the PV name (`iscsi-NAME`). Sizes use LVM units: `512M`, `64G`, `1T`.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NAME` (arg 1) | `db00` | Lowercase letters, digits, `_`, `-`; up to 32 characters |
| `SIZE` (arg 2) | `64G` | Size passed to `lvcreate` |
| `FSTYPE` | `ext4` | Only written into the printed PV |
| `VG`, `IQN`, `TPG`, `PORTAL` | this target's values | Change only if the build changes |

What it does, in order:

1. **Checks** it runs as root, the name is valid, the target is loaded, and neither an LV nor a backstore with that name exists. Any failure here stops it before anything is created.
2. **Creates the LV** in `vg_iscsi`, wiping old signatures. This fails cleanly if the volume group lacks space.
3. **Creates a block backstore** on the LV.
4. **Picks the lowest free LUN number** and maps the backstore there. Because the target has `auto_add_mapped_luns=true`, the LUN is mapped to all five initiator ACLs in the same step.
5. **Saves the target config**, so the LUN survives a reboot.
6. **Prints** a summary line and a PV with the portal, IQN, LUN number, exact size in bytes, `ReadWriteOnce` and `Retain`.

If any step after the LV is created fails, the script removes the backstore and the LV again, so nothing half-made is left. Numbers are reused: after `db01` on LUN 1 is removed, the next LUN created takes 1.

To use the output, save the PV part to a file and `kubectl apply -f` it, then bind it with a PVC that names it in `volumeName` and has `storageClassName: ""`. The first pod to mount it formats it as `FSTYPE`.

## How iscsi-lun-remove works

`iscsi-lun-remove NAME` destroys the LUN and its data. There is no undo, and no snapshot is taken.

Before running it:

- [ ] Delete the pod, PVC and PV that use it (`kubectl delete pvc ...`, `kubectl delete pv iscsi-NAME`).
- [ ] Confirm no node still has a session to it: the script lists initiators with active sessions.
- [ ] Take any copy of the data you want to keep.

What it does, in order:

1. **Finds** the LUN number, the backstore and the LV for `NAME`. It carries on if only some of them exist, so it also cleans up a half-made LUN. If none exist it stops.
2. **Shows** what it is about to remove and which initiators are logged in. A session listed here is to the target as a whole, not necessarily to this LUN.
3. **Asks you to type the name.** `--yes` as the second argument skips this, for scripted use.
4. **Unmaps the LUN**, which removes it from all five ACLs at once.
5. **Deletes the backstore** and **saves the target config.**
6. **Removes the LV** and prints the volume group's free space.

`lvremove` refuses if something still holds the LV open; the LUN is already unmapped by then. Find the holder with `lsof /dev/vg_iscsi/NAME` or `dmsetup info`, then run `lvremove vg_iscsi/NAME` by hand. A node that still had the LUN attached sees I/O errors on that disk; drop the stale disk there with `echo 1 > /sys/block/sdX/device/delete`, or reboot the node.

The other LUN numbers do not change when one is removed, so existing PVs keep working.

## Grow a LUN

LUNs can grow online; they cannot shrink. Grow the LV on the target, rescan on the node, then grow the filesystem where it is mounted.

```bash
# target
lvextend -L +32G vg_iscsi/db03

# node that has it mounted (find it: kubectl get pod -o wide)
iscsiadm -m session --rescan
lsblk                                  # the disk shows the new size
resize2fs /dev/disk/by-path/ip-192.168.5.9:3260-iscsi-iqn.2026-11.app.faultycloud:storage-lun-N
# xfs instead: xfs_growfs <mountpoint>
```

The in-tree Kubernetes iSCSI volume does not expand on its own. After growing, edit the PV's `spec.capacity.storage` so it reflects the new size; the PVC's reported size will not change.

## Add, remove or rename an initiator

The ACL list is the access list: a node not on it cannot log in. Changes take effect at the node's next login.

```bash
T=/iscsi/iqn.2026-11.app.faultycloud:storage/tpg1

# add a node (every existing LUN is mapped to it automatically)
targetcli $T/acls create iqn.2026-11.home.demigods:odysseus

# remove a node (log it out first)
targetcli $T/acls delete iqn.2026-11.home.demigods:helen

targetcli saveconfig
```

To rename, for example `aenes` to `aeneas`: create the new ACL, change `/etc/iscsi/initiatorname.iscsi` on the node, `systemctl restart iscsid`, log the node in again, then delete the old ACL. Update the `INITIATORS` list in the build document's target setup script too, so a rebuild matches. A new node must also be inside `192.168.5.0/26`, or the firewall blocks it.

## Drive failures and USB drop-outs

Thumb drives fail and drop off the bus far more often than disks, so expect this. The array survives losing one drive, and two drives only if they are in different mirror pairs (drive 1 or 2, plus drive 3 or 4). Losing both drives of one pair loses every LUN.

Spot it: `cat /proc/mdstat` shows `[UU_U]` instead of `[UUUU]`, `mdadm --detail /dev/md/iscsi` lists a device as faulty or removed, and `dmesg -T | grep -i usb` shows resets or disconnects.

**A drive dropped and came back** (same by-id name present again):

```bash
mdadm /dev/md/iscsi --re-add /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_<serial>-0:0
```

The write-intent bitmap limits the resync to what changed, usually minutes. If `--re-add` is refused, use `--add`, which does a full rebuild of that drive.

**A drive is dead** — swap in a new drive of at least the same size:

```bash
mdadm /dev/md/iscsi --fail /dev/disk/by-id/<old> --remove /dev/disk/by-id/<old>  # if still listed
wipefs -a /dev/disk/by-id/<new>
mdadm /dev/md/iscsi --add /dev/disk/by-id/<new>
watch cat /proc/mdstat
```

A full rebuild of one 512 GB thumb drive takes hours, and LUN I/O is slow throughout. `mdadm.conf` identifies the array by UUID, so it needs no change. Record the new drive's by-id path in the build document.

## Back up and restore the target config

RAID10 protects against a dead drive, not against a deleted LUN or a lost host. Three small files rebuild the whole layout; the data needs its own copy.

| What | Where | Restore with |
| --- | --- | --- |
| Target config (LUNs, ACLs, portal) | `/etc/target/saveconfig.json` (Ubuntu: `/etc/rtslib-fb-target/saveconfig.json`); older copies in the `backup/` folder beside it | `targetcli restoreconfig <file> clear_existing=true` |
| LVM layout | `/etc/lvm/backup/vg_iscsi` | `vgcfgrestore -f <file> vg_iscsi` |
| Array identity | `/etc/mdadm/mdadm.conf` (AlmaLinux: `/etc/mdadm.conf`) | copy back, `mdadm --assemble --scan` |

Copy all three off the host after any LUN change, for example `scp` to another machine or into git.

To copy a LUN's data, take a short-lived snapshot so the copy is consistent, then stream it elsewhere. The snapshot needs free space in `vg_iscsi` for the writes made while it exists:

```bash
lvcreate -s -L 8G -n db03-snap vg_iscsi/db03
dd if=/dev/vg_iscsi/db03-snap bs=4M status=progress | gzip | ssh backup-host 'cat > db03.img.gz'
lvremove -y vg_iscsi/db03-snap
```

For a database, a dump from inside the database is a cleaner backup than a block image.

## Routine checks

**After every reboot of the target**

```bash
systemctl status iscsi-storage-wait.service target.service   # Ubuntu: rtslib-fb-targetctl
cat /proc/mdstat                                              # [UUUU]
targetcli ls /backstores/block                                # every LUN [activated]
targetcli sessions                                            # nodes logging back in
```

Nodes reconnect on their own. Pods may see a pause of a minute or two while the target is down; longer than the node's `node.session.timeo.replacement_timeout` (120 s by default) and their filesystems go read-only, which needs a pod restart.

**Weekly**

- `cat /proc/mdstat` and `mdadm --detail /dev/md/iscsi`: four active devices, no faulty.
- `vgs vg_iscsi`: keep some space free for snapshots and growth.
- `dmesg -T | grep -iE 'usb.*(reset|disconnect)'`: frequent resets point at a failing drive, cable or hub.

**Monthly**, a RAID scrub reads every block and repairs silent mismatches (Ubuntu and AlmaLinux schedule one already; this runs it by hand):

```bash
MD=$(basename "$(readlink -f /dev/md/iscsi)")
echo check > /sys/block/$MD/md/sync_action
cat /sys/block/$MD/md/mismatch_cnt      # after it finishes; 0 is good
```
