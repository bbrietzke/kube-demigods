# iSCSI Storage — Target Build (One-Time Setup)

Nov 21, 2026 · @Brian Brietzke

## Order of operations and packages

Run this document once, top to bottom, as root on the target host `192.168.5.9`. When it is done, the target serves LUNs from a RAID10 volume group to the five Kubernetes nodes only, and the `iscsi-lun-create` and `iscsi-lun-remove` scripts are installed. How those scripts behave and what to look after afterwards is in *iSCSI Storage — Day-Two LUN Operations*.

1. Install packages (below).
2. Build the RAID10 array and `vg_iscsi`.
3. Persist the array.
4. Set up the target.
5. Apply the firewall rule.
6. Install the systemd boot ordering.
7. Install the LUN scripts.
8. Test and troubleshoot from an initiator.

Packages:

```bash
# Ubuntu / Debian
apt install -y mdadm lvm2 targetcli-fb python3-rtslib-fb
# AlmaLinux / RHEL
dnf install -y mdadm lvm2 targetcli
```

On Ubuntu the service that restores `/etc/rtslib-fb-target/saveconfig.json` at boot is `rtslib-fb-targetctl.service`; on AlmaLinux it is `target.service` with `/etc/target/saveconfig.json`. This document says `target.service`; substitute the Ubuntu name where needed.

## Build the RAID10 array and volume group

The four drives become one mdadm RAID10 array, `/dev/md/iscsi`, and that array is the only physical volume in `vg_iscsi`. The volume group is therefore RAID10 as a whole, and every LUN carved from it is a plain linear LV that inherits the protection. LVM's own `--type raid10` cannot do this: it applies per LV, not per volume group. Usable space is about 950 GiB.

This destroys everything on the four drives.

1. Confirm the drives, and unmount anything that was auto-mounted.

```bash
DRIVES=(
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03005120053125194358-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050032052925214808-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050408052925214429-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050723052925214046-0:0
)
for d in "${DRIVES[@]}"; do printf '%s -> %s\n' "$d" "$(readlink -f "$d")"; done
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS
```

2. Wipe old partition tables and filesystem signatures.

```bash
for d in "${DRIVES[@]}"; do
  for p in "$d"-part*; do
    [[ -e $p ]] || continue
    umount -q "$p" 2>/dev/null
    wipefs -a "$p"
  done
  wipefs -a "$d"
done
partprobe 2>/dev/null; udevadm settle
```

3. Create the array. With the near-2 layout, drives 1+2 mirror each other and drives 3+4 mirror each other. If the drives sit on two USB controllers or hubs, order the list so each pair spans both.

```bash
mdadm --create /dev/md/iscsi --name=iscsi \
  --level=10 --layout=n2 --raid-devices=4 \
  --metadata=1.2 --bitmap=internal \
  "${DRIVES[@]}"
```

The internal write-intent bitmap matters on USB: when a drive drops off the bus and is re-added, only the changed regions resync. The initial resync takes hours on thumb drives. The array is usable during it; watch it with `watch cat /proc/mdstat`.

4. Create the physical volume and volume group.

```bash
pvcreate /dev/md/iscsi
vgcreate vg_iscsi /dev/md/iscsi
```

5. Verify.

```bash
mdadm --detail /dev/md/iscsi     # State: clean (or resyncing), 4 active devices
pvs /dev/md/iscsi
vgs vg_iscsi                     # VFree about 950g
```

## Persist the mdadm array

Record the array in `mdadm.conf` so it always assembles as `/dev/md/iscsi` rather than `/dev/md127`, and set an address for failure mail if the host can send it.

```bash
# Ubuntu / Debian
mdadm --detail --scan /dev/md/iscsi | tee -a /etc/mdadm/mdadm.conf
update-initramfs -u

# AlmaLinux / RHEL
mdadm --detail --scan /dev/md/iscsi | tee -a /etc/mdadm.conf
dracut -f
```

Check the file contains exactly one `ARRAY ... name=...:iscsi` line; remove duplicates if the step was run twice. Enable the monitor so a dropped thumb drive gets noticed: `systemctl enable --now mdmonitor` (AlmaLinux) or confirm `mdadm --monitor` is running (Ubuntu runs it by default).

If a USB drive drops off the bus and comes back, re-add it with `mdadm /dev/md/iscsi --re-add /dev/disk/by-id/<drive>`. The internal bitmap keeps that resync short.

## Target setup script

`setup-target.sh` creates the target, binds it to `192.168.5.9:3260` only, turns off demo mode so unlisted initiators are refused, and creates an ACL for each of the five initiators. It is safe to re-run: existing pieces are skipped. With `auto_add_mapped_luns=true`, every LUN created later is mapped to every ACL here, and an ACL added later receives every existing LUN.

```bash
#!/usr/bin/env bash
# setup-target.sh - one-time LIO target setup for iqn.2026-11.app.faultycloud:storage
set -euo pipefail

# ---- parameters ----------------------------------------------------------
IQN="iqn.2026-11.app.faultycloud:storage"
PORTAL_IP="192.168.5.9"
PORT=3260
SERVICE="target.service"          # Ubuntu: rtslib-fb-targetctl.service
INITIATORS=(
  iqn.2026-11.home.demigods:hercules
  iqn.2026-11.home.demigods:achilles
  iqn.2026-11.home.demigods:perseus
  iqn.2026-11.home.demigods:helen
  iqn.2026-11.home.demigods:aenes
)
# --------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
systemctl enable --now "$SERVICE"

CFS="/sys/kernel/config/target/iscsi/${IQN}/tpgt_1"
TPG="/iscsi/${IQN}/tpg1"

# Map new LUNs to all ACLs; don't create a 0.0.0.0 portal on new targets
targetcli set global auto_add_mapped_luns=true
targetcli set global auto_add_default_portal=false 2>/dev/null || true

# Target + TPG
[[ -d $CFS ]] || targetcli /iscsi create "$IQN"

# Portal: only 192.168.5.9:3260
for ip in 0.0.0.0 ::0; do targetcli "${TPG}/portals" delete "$ip" "$PORT" &>/dev/null || true; done
[[ -d "${CFS}/np/${PORTAL_IP}:${PORT}" ]] || targetcli "${TPG}/portals" create "$PORTAL_IP" "$PORT"

# Explicit ACLs only: no demo mode, no auto-generated ACLs, no CHAP
targetcli "$TPG" set attribute generate_node_acls=0 cache_dynamic_acls=0 \
  demo_mode_write_protect=1 authentication=0

# One ACL per initiator
for i in "${INITIATORS[@]}"; do
  [[ -d "${CFS}/acls/${i}" ]] || targetcli "${TPG}/acls" create "$i"
done

targetcli saveconfig
targetcli ls "/iscsi/${IQN}"
```

Expected result: one portal (`192.168.5.9:3260`), five ACLs, zero LUNs until `iscsi-lun-create` runs.

The ACL list is identity by name only: any host on the /26 that sets its initiator name to one of these IQNs gets in. If that matters, add CHAP per ACL (`targetcli /iscsi/<iqn>/tpg1/acls/<initiator> set auth userid=... password=...` plus `authentication=1`) and the matching `node.session.auth.*` settings on each node.

## Firewall

One rule: TCP 3260 to `192.168.5.9`, from `192.168.5.0/26` only (hosts `.0`–`.63`). Use whichever firewall the host runs. If the firewall is being enabled for the first time, allow SSH first so you don't lock yourself out.

```bash
# ufw (Ubuntu)
ufw allow proto tcp from 192.168.5.0/26 to 192.168.5.9 port 3260 comment 'iSCSI initiators'
ufw status numbered        # confirm no broader 3260 rule exists

# firewalld (AlmaLinux)
firewall-cmd --permanent --remove-service=iscsi-target 2>/dev/null || true
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.5.0/26" destination address="192.168.5.9" port port="3260" protocol="tcp" accept'
firewall-cmd --reload
firewall-cmd --list-all
```

Test from a node: `nc -zv 192.168.5.9 3260` should connect. From any host outside the /26 it should time out.

## systemd boot ordering

USB drives can enumerate after the target service starts, and the portal binds to a specific address. Without ordering, the target restores its config before `/dev/vg_iscsi/*` exists or before `192.168.5.9` is up, and the LUNs come back missing. The fix is a small wait service that the target depends on.

Paste this block as root. It writes the wait script, its unit, and a drop-in for the target service, then reloads systemd.

```bash
SERVICE="rtslib-fb-targetctl.service"        # Ubuntu: rtslib-fb-targetctl.service

cat > /usr/local/sbin/iscsi-storage-wait.sh <<'EOF'
#!/usr/bin/env bash
# Wait for the USB RAID10 array and vg_iscsi before the iSCSI target starts.
MD=/dev/md/iscsi
VG=vg_iscsi
TIMEOUT="${TIMEOUT:-120}"
for ((i = 0; i < TIMEOUT; i++)); do
  [[ -b $MD ]] || mdadm --assemble --scan >/dev/null 2>&1 || true
  if [[ -b $MD ]] && vgchange -ay "$VG" >/dev/null 2>&1; then
    echo "$MD and $VG ready after ${i}s"
    exit 0
  fi
  sleep 1
done
echo "timed out after ${TIMEOUT}s waiting for $MD / $VG" >&2
exit 1
EOF
chmod 0755 /usr/local/sbin/iscsi-storage-wait.sh

cat > /etc/systemd/system/iscsi-storage-wait.service <<'EOF'
[Unit]
Description=Wait for USB RAID10 array and vg_iscsi
After=local-fs.target
DefaultDependencies=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/iscsi-storage-wait.sh
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "/etc/systemd/system/${SERVICE}.d"
cat > "/etc/systemd/system/${SERVICE}.d/10-iscsi-storage.conf" <<'EOF'
[Unit]
Requires=iscsi-storage-wait.service
After=iscsi-storage-wait.service network-online.target
Wants=network-online.target
EOF

systemctl daemon-reload
systemctl enable iscsi-storage-wait.service "$SERVICE"
```

Verify after a reboot:

```bash
systemctl status iscsi-storage-wait.service "$SERVICE"
journalctl -b -u iscsi-storage-wait.service
targetcli ls /backstores/block     # every LUN listed and [activated]
```

On shutdown the order reverses: the target stops before the array is released. A degraded array (one drive missing) still starts after mdadm's last-resort timeout, so the wait can take around 30 seconds longer in that case.

## Install the LUN scripts

Paste both blocks as root. They install `iscsi-lun-create` and `iscsi-lun-remove` into `/usr/local/sbin`. Each script has a parameter block at the top; the name and size can also be passed as arguments. What they do step by step, and how to use them day to day, is in the Day-Two document.

**iscsi-lun-create** — `iscsi-lun-create NAME SIZE`, for example `iscsi-lun-create db03 64G`:

```bash
cat > /usr/local/sbin/iscsi-lun-create <<'SCRIPT'
#!/usr/bin/env bash
# iscsi-lun-create - create an LV in vg_iscsi and export it as an iSCSI LUN
# Usage: iscsi-lun-create [NAME] [SIZE]      e.g. iscsi-lun-create db03 64G
set -euo pipefail

# ---- parameters: edit here or pass as arguments --------------------------
NAME="${1:-db00}"     # shortcut name, used for the LV and the backstore
SIZE="${2:-64G}"      # lvcreate size: 512M, 64G, 1T ...
FSTYPE="ext4"         # only used in the printed Kubernetes PV
VG="vg_iscsi"
IQN="iqn.2026-11.app.faultycloud:storage"
TPG=1
PORTAL="192.168.5.9:3260"
# --------------------------------------------------------------------------

DEV="/dev/${VG}/${NAME}"
CFS="/sys/kernel/config/target/iscsi/${IQN}/tpgt_${TPG}"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]]                         || die "run as root"
[[ $NAME =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "invalid name '$NAME' (a-z 0-9 _ -, max 32)"
[[ -d $CFS ]]                             || die "target $IQN tpg${TPG} not loaded; start the target service"
lvs "${VG}/${NAME}" &>/dev/null          && die "LV $DEV already exists"
compgen -G "/sys/kernel/config/target/core/iblock_*/${NAME}" >/dev/null \
                                          && die "backstore '$NAME' already exists"

CREATED=0
rollback() {
  local rc=$?
  if (( rc != 0 && CREATED )); then
    echo "Rolling back $NAME ..." >&2
    targetcli /backstores/block delete "$NAME" &>/dev/null || true
    targetcli saveconfig &>/dev/null || true
    lvremove -y "${VG}/${NAME}" &>/dev/null || true
  fi
}
trap rollback EXIT

# 1. Logical volume
lvcreate --yes --wipesignatures y --name "$NAME" --size "$SIZE" "$VG"
CREATED=1

# 2. Block backstore
targetcli /backstores/block create name="$NAME" dev="$DEV"

# 3. LUN on the next free number (auto-mapped to every ACL)
LUN=0
while [[ -e "${CFS}/lun/lun_${LUN}" ]]; do LUN=$((LUN + 1)); done
targetcli "/iscsi/${IQN}/tpg${TPG}/luns" create "/backstores/block/${NAME}" lun="$LUN"

# 4. Persist
targetcli saveconfig
CREATED=0

BYTES=$(lvs --noheadings --nosuffix --units b -o lv_size "${VG}/${NAME}" | tr -d ' ')

cat <<EOF

LUN ready: name=${NAME} size=${SIZE} lun=${LUN} dev=${DEV}

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: iscsi-${NAME}
spec:
  capacity:
    storage: "${BYTES}"
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: iscsi-static
  volumeMode: Filesystem
  csi:
    driver: iscsi.csi.k8s.io
    volumeHandle: faultycloud-storage-${NAME}
    fsType: ${FSTYPE}
    volumeAttributes:
      targetPortal: "${PORTAL}"
      portals: "[]"
      iqn: "${IQN}"
      lun: "${LUN}"
      iscsiInterface: "default"
      discovery: "true"
      discoveryCHAPAuth: "false"
      sessionCHAPAuth: "false"
EOF
SCRIPT
chmod 0750 /usr/local/sbin/iscsi-lun-create
```

**iscsi-lun-remove** — `iscsi-lun-remove NAME [--yes]`:

```bash
cat > /usr/local/sbin/iscsi-lun-remove <<'SCRIPT'
#!/usr/bin/env bash
# iscsi-lun-remove - unmap and destroy an iSCSI LUN and its LV in vg_iscsi
# Usage: iscsi-lun-remove NAME [--yes]
set -euo pipefail

# ---- parameters: edit here or pass as arguments --------------------------
NAME="${1:-}"         # shortcut name used when the LUN was created
CONFIRM="${2:-}"      # --yes skips the confirmation prompt
VG="vg_iscsi"
IQN="iqn.2026-11.app.faultycloud:storage"
TPG=1
# --------------------------------------------------------------------------

CFS="/sys/kernel/config/target/iscsi/${IQN}/tpgt_${TPG}"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -n $NAME ]]    || die "usage: $0 NAME [--yes]"
[[ -d $CFS ]]     || die "target $IQN tpg${TPG} not loaded; start the target service"

# Find the LUN number whose backstore is NAME
LUN=""
for d in "${CFS}"/lun/lun_*; do
  [[ -d $d ]] || continue
  for l in "$d"/*; do
    [[ -L $l ]] || continue
    [[ "$(basename "$(readlink -f "$l")")" == "$NAME" ]] && LUN="${d##*/lun_}"
  done
done
HAS_BS=0; compgen -G "/sys/kernel/config/target/core/iblock_*/${NAME}" >/dev/null && HAS_BS=1
HAS_LV=0; lvs "${VG}/${NAME}" &>/dev/null && HAS_LV=1

(( HAS_BS || HAS_LV )) || [[ -n $LUN ]] || die "nothing named '$NAME' found"

echo "About to remove: name=${NAME} lun=${LUN:-none} backstore=${HAS_BS} lv=${HAS_LV}"
echo "Initiators with an active session (they will lose this LUN):"
for a in "${CFS}"/acls/*/; do
  [[ -d $a ]] || continue
  grep -q "No active iSCSI Session" "${a}info" 2>/dev/null || echo "  $(basename "$a")"
done

if [[ $CONFIRM != "--yes" ]]; then
  read -rp "Type '${NAME}' to destroy it and all its data: " ans
  [[ $ans == "$NAME" ]] || die "aborted"
fi

# 1. Unmap the LUN (also removes the mapped LUNs under every ACL)
[[ -n $LUN ]] && targetcli "/iscsi/${IQN}/tpg${TPG}/luns" delete lun="$LUN"

# 2. Delete the backstore
(( HAS_BS )) && targetcli /backstores/block delete "$NAME"

# 3. Persist
targetcli saveconfig

# 4. Destroy the logical volume
(( HAS_LV )) && lvremove -y "${VG}/${NAME}"

echo "Removed ${NAME}."
vgs "$VG"
SCRIPT
chmod 0750 /usr/local/sbin/iscsi-lun-remove
```

## Test and troubleshoot from the initiator

The build is done when one node can log in, see a scratch LUN, write to it, and log out cleanly. Do this before any Kubernetes PV points at the target.

**Prerequisites on every node**

1. `/etc/iscsi/initiatorname.iscsi` matches its ACL exactly, character for character. Note `aenes`: if that host is actually named `aeneas`, fix whichever side is wrong now.
2. `open-iscsi` (Ubuntu) or `iscsi-initiator-utils` (AlmaLinux) is installed and `iscsid` is enabled. Talos nodes need the `siderolabs/iscsi-tools` system extension instead.
3. `nc -zv 192.168.5.9 3260` connects.

**End-to-end test** (target commands on `192.168.5.9`, node commands on one node, for example hercules):

```bash
# target: scratch LUN
iscsi-lun-create scratch 1G

# node: discover, log in, find the disk
iscsiadm -m discovery -t sendtargets -p 192.168.5.9:3260
iscsiadm -m node -T iqn.2026-11.app.faultycloud:storage -p 192.168.5.9:3260 --login
lsblk -S -o NAME,VENDOR,MODEL,SIZE,TRAN | grep -i lio     # LIO-ORG, 1G, iscsi
DEV=/dev/disk/by-path/ip-192.168.5.9:3260-iscsi-iqn.2026-11.app.faultycloud:storage-lun-0

# node: write and read back (use the LUN number create printed)
mkfs.ext4 -q "$DEV" && mount "$DEV" /mnt && echo ok > /mnt/t && cat /mnt/t && umount /mnt

# node: log out and forget the record so it doesn't fight kubelet
iscsiadm -m node -T iqn.2026-11.app.faultycloud:storage -p 192.168.5.9:3260 --logout
iscsiadm -m node -T iqn.2026-11.app.faultycloud:storage -p 192.168.5.9:3260 -o delete

# target: clean up
iscsi-lun-remove scratch --yes
```

Repeat just the discovery and login on the other four nodes to prove each ACL.

**Troubleshooting**

| Symptom on the node | Likely cause | Check |
| --- | --- | --- |
| Discovery times out | Firewall, or portal not on 192.168.5.9 | `nc -zv 192.168.5.9 3260`; on target `ss -ltn sport = :3260`, firewall rule list |
| Connection refused | Target service not running | `systemctl status target.service` (Ubuntu: `rtslib-fb-targetctl`) |
| Login fails with authorization failure | Initiator name does not match an ACL | `cat /etc/iscsi/initiatorname.iscsi`; on target `targetcli ls /iscsi/iqn.2026-11.app.faultycloud:storage/tpg1/acls`; restart `iscsid` after changing the name |
| Login works but no disk appears | LUN not mapped to this ACL | ACL in `targetcli ls` shows no mapped LUN; re-run `iscsiadm -m session --rescan` |
| LUNs missing after target reboot | Target restored before the array or VG was ready | `journalctl -b -u iscsi-storage-wait.service`; `vgs vg_iscsi`; `systemctl restart target.service` |
| I/O errors or very slow writes | Array degraded or resyncing, a USB drive dropped | On target `cat /proc/mdstat`, `dmesg -T \| grep -i usb` |
| Kubernetes pod stuck in ContainerCreating | LUN already logged in elsewhere, or stale manual session | `kubectl describe pod`; on nodes `iscsiadm -m session` |

Target-side logs for all of the above: `dmesg -T | grep -iE 'iscsi|target'`.
