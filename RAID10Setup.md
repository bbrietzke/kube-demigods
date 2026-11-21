# General
This is to setup an iSCSI based network attached storage target in a lab/learning environment. 

The iSCSI initiators will be a series of hosts that are in a kubernetes cluster.

The idea is to have a series of thumb drives that act as LVM volumes that serve iSCSI LUNs.

The volume group itself should be RAID10.  

Ideally, there should be one document that describes the target setup, including building the volumes groups, setting any systemd junk, creation of scripts for LUN creation/deletion and any testing/troubleshooting from the initiator side.  All of these task should be executed once for this document and this target.

The second document should detail how the LUN creation and deletion scripts work and what to expect to handle on day two.

## IQN
The IQN should be `iqn.2026-11.app.faultycloud:storage`.

## Drives
I have four, 512Gb USB thumb drives, listed below:

```
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03005120053125194358-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050032052925214808-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050408052925214429-0:0
  /dev/disk/by-id/usb-USB_SanDisk_3.2Gen1_03050723052925214046-0:0
```

## Initiators
There will be five initiators, listed below:

```
  InitiatorName=iqn.2026-11.home.demigods:hercules
  InitiatorName=iqn.2026-11.home.demigods:achilles
  InitiatorName=iqn.2026-11.home.demigods:perseus
  InitiatorName=iqn.2026-11.home.demigods:helen
  InitiatorName=iqn.2026-11.home.demigods:aenes
```

## Security
The iSCSI target resides on `192.168.5.9` and should have a singular firewall restriction to only allow iSCSI initiators form `192.168.5.0/26`.

The target should only allow initiators from the list above.