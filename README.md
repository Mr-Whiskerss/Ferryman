# ⛴️ Ferryman

**Ferry your VMware VMs across to Proxmox VE: one command, no manual fiddling.**

Point Ferryman at an `.ova`, `.ovf`, `.vmx` or `.vmdk` and it works out the rest. It creates the VM, converts and imports every disk, picks hardware the guest can actually boot on, and sets the boot order. If anything goes wrong, it removes the half-built VM.

```bash
./ferryman.sh /mnt/nfs/my-appliance.ova
```

---

## Features

- **Takes whatever you have:** OVA archives, extracted OVF packages, whole VMware VM folders (`.vmx`), or loose VMDK disks
- **Reads the source config:** Name, RAM, vCPUs, guest OS, BIOS/UEFI firmware and disk order come from the OVF or VMX
- **Boot-safe hardware defaults:**
  - Linux gets VirtIO SCSI and a VirtIO NIC (fast)
  - Windows and unknown guests get SATA and e1000 (boots without extra drivers, so no `INACCESSIBLE_BOOT_DEVICE` blue screen)
- **UEFI aware:** Adds an EFI disk and the q35 machine type when the source VM was UEFI
- **Storage aware:** Uses qcow2 on file storage (dir/NFS/CIFS/CephFS) and raw on block storage (LVM-thin/ZFS/Ceph RBD)
- **Integrity checks:** Verifies OVA manifest (`.mf`) checksums before importing
- **Handles VMware disk quirks:**
  - If you point it at a `-flat.vmdk` or `-s001.vmdk` extent, it uses the matching descriptor
  - gzip-compressed OVF disks are decompressed automatically
  - Snapshot chains are flattened on import
- **Plans before it acts:** `--dry-run` shows exactly what would run, and the real run asks for confirmation first
- **Cleans up after itself:** Temporary files are always removed, and a failed import removes the partial VM

## Requirements

- A Proxmox VE node (7.x or newer), run as `root`
- `python3` (installed on Proxmox VE by default)
- Enough free space in `/var/tmp`, or a `--workdir`, to extract OVAs

## Installation

```bash
wget https://raw.githubusercontent.com/<your-username>/ferryman/main/ferryman.sh
chmod +x ferryman.sh
```

Optionally put it on your `PATH`:

```bash
mv ferryman.sh /usr/local/bin/ferryman
```

## Quick start

```bash
# 1. See what it would do (changes nothing)
./ferryman.sh --dry-run /mnt/nfs/appliance.ova

# 2. Do it for real
./ferryman.sh /mnt/nfs/appliance.ova
```

Example plan output:

```
================ Import plan ================
  Source:      /mnt/nfs/appliance.ova (appliance)
  Guest OS:    ubuntu64Guest / Ubuntu Linux (64-bit)
  VMID:        105
  Name:        my-appliance
  Memory:      4096 MB
  Cores:       2
  OS type:     l26
  Firmware:    seabios
  Network:     virtio,bridge=vmbr0
  Storage:     local-lvm (lvmthin, raw)
  Disk bus:    scsi
  Disk 1:      my-appliance-disk1.vmdk -> scsi0  [40 GiB (42949672960 bytes)]
=============================================
```

## 📖 Usage

```
ferryman.sh [options] <file.ova | file.ovf | file.vmx | disk.vmdk [disk2.vmdk ...]>
```

### Examples

```bash
# OVA onto ZFS, on a different bridge and VLAN, and start it afterwards
./ferryman.sh -s local-zfs -b vmbr1 --vlan 20 --start appliance.ova

# A whole VMware VM folder copied off a datastore
./ferryman.sh /mnt/usb/dc01/dc01.vmx

# Loose VMDKs with a custom name and specs (attached in the order given)
./ferryman.sh -n web01 -m 4096 -c 2 web01.vmdk web01_1.vmdk

# Big OVA, but /var/tmp is small
./ferryman.sh --workdir /mnt/scratch huge-appliance.ova

# Unattended, with a specific VMID
./ferryman.sh -y -i 9001 template.ova
```

### Options

| Option | Description | Default |
|---|---|---|
| `-i, --vmid ID` | VM ID to create | next free ID |
| `-s, --storage NAME` | Target storage for disks | `local-lvm` |
| `-n, --name NAME` | VM name | from OVF/VMX, else file name |
| `-b, --bridge NAME` | Network bridge | `vmbr0` |
| `--vlan TAG` | VLAN tag for the NIC | none |
| `-m, --memory MB` | RAM in MB | from source, else `2048` |
| `-c, --cores N` | vCPU cores | from source, else `2` |
| `--bus TYPE` | Disk bus: `scsi` `sata` `ide` `virtio` | auto |
| `--nic MODEL` | NIC: `virtio` `e1000` `e1000e` `vmxnet3` | auto |
| `--bios TYPE` | `seabios` (BIOS) or `ovmf` (UEFI) | from source |
| `--ostype TYPE` | `l26` `win11` `win10` `win8` `win7` `other` ... | from source |
| `--cpu TYPE` | CPU type (`host` for max performance) | `x86-64-v2-AES` |
| `--format FMT` | `qcow2` `raw` `vmdk` (file storage only) | auto |
| `--vmx FILE` | Read settings from this VMX (VMDK mode) | auto-detected |
| `--workdir DIR` | Where OVAs get extracted | `/var/tmp` |
| `--no-verify` | Skip OVA manifest checksum verification | |
| `--start` | Start the VM after import | |
| `--keep-on-fail` | Keep the partial VM if import fails | |
| `--dry-run` | Show the plan and commands; change nothing | |
| `-y, --yes` | Skip the confirmation prompt | |
| `-h, --help` | Show help | |

## How it decides

| Detected guest | Disk bus | NIC | Why |
|---|---|---|---|
| Linux | VirtIO SCSI (single, iothread) | VirtIO | Drivers are built into the kernel, so you get the best performance |
| Windows | SATA | e1000 | Works without VirtIO drivers |
| Unknown | SATA | e1000 | The safest choice to get it booting |

| Source firmware | Proxmox setup |
|---|---|
| BIOS | SeaBIOS, i440fx |
| EFI | OVMF + EFI disk, q35, Secure Boot keys **not** enrolled |

## After importing

1. **Uninstall VMware Tools** inside the guest.
2. **Install the QEMU guest agent**, then run `qm set <vmid> --agent enabled=1`.
3. **On Windows**, install the [VirtIO drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers). Once they're in, switch the disks to SCSI and the NIC to VirtIO for much better performance.
4. **Fix networking.** The NIC is new hardware, so the guest may need its IP set again. On Linux, `ens160` usually becomes `ens18`.

## Troubleshooting

**"qemu-img can't read disk.vmdk"**
You probably only have the small descriptor file. Copy the matching `-flat.vmdk`, `-s00X.vmdk` or snapshot `-00000X.vmdk` files into the same folder.

**The VM won't boot or can't find a boot device**
The source was probably UEFI but was detected as BIOS, which is common with loose VMDKs that have no `.vmx`. Fix it with:

```bash
qm set <vmid> --bios ovmf --machine q35 --efidisk0 <storage>:1,efitype=4m,pre-enrolled-keys=0
```

**Windows blue screen with `INACCESSIBLE_BOOT_DEVICE`**
The disk is on a bus Windows has no driver for. Re-run with `--bus sata`.

**Not enough space to extract the OVA**
Use `--workdir /path/with/space`.

**"Storage is not enabled for Disk image content"**
Pick another storage with `-s`, or enable *Disk image* content on it under Datacenter → Storage.

## Limitations

- Only the first VM in a multi-VM OVF is imported.
- Disk controller and NIC layout are chosen by the rules above, not copied from VMware.
- No direct pull from ESXi/vCenter; export to OVA/VMDK first. Recent Proxmox VE versions also have a built-in ESXi import wizard for that case.
- Test it on something non-critical first.

## Contributing

Issues and PRs are welcome. If an OVA from a particular vendor doesn't import cleanly, open an issue and include the `.ovf` file (with any sensitive information removed).

