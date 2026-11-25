#!/usr/bin/env bash
# =============================================================================
#  ferryman  -  Ferry VMware disks & appliances across to Proxmox VE
#  https://github.com/<your-username>/ferryman
#
#  Point it at any of:
#    appliance.ova            OVA archive (extracted, verified, parsed, imported)
#    appliance.ovf            Already-extracted OVF (disk files next to it)
#    machine.vmx              VMware VM config (all its disks + settings)
#    disk.vmdk [disk2.vmdk]   One or more VMDKs (attached in the order given;
#                             settings read from a .vmx in the same folder if
#                             there is one, otherwise sensible defaults)
#
#  It creates a VM, converts/imports every disk onto your chosen storage,
#  attaches them, sets the boot order and picks safe hardware defaults
#  (e.g. SATA + e1000 for Windows, which has no VirtIO drivers yet).
#
#  Run as root on a Proxmox VE node. Use --dry-run first to see the plan.
# =============================================================================
set -Eeuo pipefail
shopt -s nocasematch

# ----------------------------- defaults --------------------------------------
VMID=""
STORAGE="local-lvm"
NAME=""
MEMORY=""
CORES=""
BRIDGE="vmbr0"
VLAN=""
BUS=""            # scsi|sata|ide|virtio   (auto from OS if empty)
NIC_MODEL=""      # virtio|e1000|e1000e|vmxnet3|rtl8139 (auto if empty)
BIOS=""           # seabios|ovmf           (auto from source firmware)
OSTYPE=""         # l26|win11|win10|win8|win7|other... (auto)
CPU_TYPE="x86-64-v2-AES"
FORMAT=""         # qcow2|raw|vmdk         (auto from storage type)
VMX_FILE=""
WORKDIR="/var/tmp"
START=0
VERIFY=1
DRY_RUN=0
KEEP_ON_FAIL=0
ASSUME_YES=0

# ----------------------------- state -----------------------------------------
INPUTS=()
DISKS=()
DISK_COMP=()
DISK_SIZE=()
M_NAME="" M_MEMORY="" M_CPUS="" M_FIRMWARE="" M_OSHINT="" M_OSTYPE=""
WORK_TMP=""
VM_CREATED=0
SUCCESS=0
FILEBASED=0

# ----------------------------- output helpers --------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_W=$'\e[1m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_W="" C_0=""
fi
info() { echo "${C_B}[*]${C_0} $*"; }
ok()   { echo "${C_G}[+]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*" >&2; }
die()  { echo "${C_R}[x]${C_0} $*" >&2; exit 1; }
hr()   { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

run() {
  if (( DRY_RUN )); then
    printf '    %s(dry-run)%s' "$C_Y" "$C_0"; printf ' %q' "$@"; echo
  else
    printf '    %s>%s' "$C_B" "$C_0"; printf ' %q' "$@"; echo
    "$@"
  fi
}

usage() {
  cat <<EOF
${C_W}Usage:${C_0} $(basename "$0") [options] <file.ova | file.ovf | file.vmx | disk.vmdk [disk2.vmdk ...]>

${C_W}Target options:${C_0}
  -i, --vmid ID         VM ID to create (default: next free ID)
  -s, --storage NAME    Storage for the disks (default: $STORAGE)
  -n, --name NAME       VM name (default: taken from OVF/VMX or file name)
  -b, --bridge NAME     Network bridge (default: $BRIDGE)
      --vlan TAG        VLAN tag for the NIC

${C_W}Hardware overrides (auto-detected if omitted):${C_0}
  -m, --memory MB       RAM in MB
  -c, --cores N         vCPU cores
      --bus TYPE        Disk bus: scsi | sata | ide | virtio
      --nic MODEL       NIC model: virtio | e1000 | e1000e | vmxnet3
      --bios TYPE       seabios (legacy BIOS) | ovmf (UEFI)
      --ostype TYPE     l26 | win11 | win10 | win8 | win7 | other ...
      --cpu TYPE        CPU type (default: $CPU_TYPE; 'host' for max speed)
      --format FMT      qcow2 | raw | vmdk (file-based storage only)

${C_W}Behaviour:${C_0}
      --vmx FILE        Read VM settings from this .vmx (VMDK mode)
      --workdir DIR     Where OVAs are extracted (default: $WORKDIR)
      --no-verify       Skip OVA manifest (.mf) checksum verification
      --start           Start the VM after import
      --keep-on-fail    Don't delete the half-built VM if something fails
      --dry-run         Show what would happen, change nothing
  -y, --yes             Don't ask for confirmation
  -h, --help            This help

${C_W}Examples:${C_0}
  $(basename "$0") --dry-run /mnt/nfs/appliance.ova
  $(basename "$0") -s local-zfs -b vmbr1 /mnt/nfs/appliance.ova
  $(basename "$0") -n web01 -m 4096 -c 2 /mnt/usb/web01/web01.vmdk
  $(basename "$0") /mnt/usb/dc01/dc01.vmx
EOF
}

# ----------------------------- OVF / VMX parser (python3) --------------------
IFS= read -r -d '' PY_PARSER <<'PY' || true
import sys, re, os
import xml.etree.ElementTree as ET

mode, path = sys.argv[1], sys.argv[2]
out, disks = {}, []

def map_os(hint):
    h = (hint or "").lower()
    if re.search(r"(^|[^a-z])win", h):            # avoid matching 'darwin'
        if re.search(r"windows ?11|win11|2022|2025", h): return "win11"
        if re.search(r"windows ?9|windows ?10|win10|2016|2019", h): return "win10"
        if re.search(r"windows ?8|2012", h): return "win8"
        if re.search(r"windows ?7|2008", h): return "win7"
        return "win10"
    if "solaris" in h: return "solaris"
    if re.search(r"linux|ubuntu|debian|rhel|red ?hat|centos|sles|suse|fedora|"
                 r"rocky|alma|oracle|photon|coreos|mint|arch|amazon", h):
        return "l26"
    return ""

def ln(tag): return tag.rsplit("}", 1)[-1]
def a(el, name):
    for k, v in el.attrib.items():
        if ln(k) == name: return v
    return None

if mode == "ovf":
    root = ET.parse(path).getroot()
    files, disk_file = {}, {}
    for el in root.iter():
        t = ln(el.tag)
        if t == "File":
            files[a(el, "id")] = (a(el, "href"), a(el, "compression") or "")
        elif t == "Disk":
            disk_file[a(el, "diskId")] = a(el, "fileRef")
    systems = [e for e in root.iter() if ln(e.tag) == "VirtualSystem"]
    if len(systems) > 1:
        out["WARN"] = "OVF contains %d VMs; only the first is imported" % len(systems)
    vs = systems[0] if systems else root
    for c in vs:
        if ln(c.tag) == "Name" and c.text: out["NAME"] = c.text.strip()
    out.setdefault("NAME", a(vs, "id") or "")
    hints, order = [], []
    for el in vs.iter():
        t = ln(el.tag)
        if t == "OperatingSystemSection":
            hints.append(a(el, "osType") or "")
            for c in el:
                if ln(c.tag) == "Description" and c.text: hints.append(c.text)
        elif t in ("Item", "StorageItem"):
            f = {ln(c.tag): (c.text or "").strip() for c in el}
            rt = f.get("ResourceType")
            if rt == "4" and "MEMORY" not in out:
                q = float(f.get("VirtualQuantity") or 0)
                units = f.get("AllocationUnits", "").lower()
                m = re.search(r"2\s*\^\s*(\d+)", units)
                exp = int(m.group(1)) if m else (30 if "giga" in units else 20)
                out["MEMORY"] = str(int(q * 2**exp / 2**20))
            elif rt == "3" and "CPUS" not in out:
                out["CPUS"] = str(int(float(f.get("VirtualQuantity") or 1)))
            elif rt == "17":
                m = re.search(r"/(disk|file)/(.+)$", f.get("HostResource", ""))
                if m:
                    ref = disk_file.get(m.group(2)) if m.group(1) == "disk" else m.group(2)
                    if ref in files and ref not in order: order.append(ref)
        elif t == "Config" and a(el, "key") == "firmware":
            out["FIRMWARE"] = (a(el, "value") or "").lower()
    if not order:
        order = [r for r in disk_file.values() if r in files]
    base = os.path.dirname(os.path.abspath(path))
    for ref in order:
        href, comp = files[ref]
        disks.append((os.path.join(base, href), comp))
    out["OSHINT"] = " / ".join(h for h in hints if h)

elif mode == "vmx":
    kv = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            m = re.match(r'\s*([^#=]+?)\s*=\s*"(.*)"\s*$', line)
            if m: kv[m.group(1).strip().lower()] = m.group(2)
    out["NAME"] = kv.get("displayname", "")
    if kv.get("memsize"):  out["MEMORY"] = kv["memsize"]
    if kv.get("numvcpus"): out["CPUS"] = kv["numvcpus"]
    out["FIRMWARE"] = kv.get("firmware", "bios").lower()
    out["OSHINT"] = kv.get("guestos", "")
    base = os.path.dirname(os.path.abspath(path))
    buses = ("scsi", "sata", "nvme", "ide")
    found = []
    for k, v in kv.items():
        m = re.match(r"(scsi|sata|nvme|ide)(\d+):(\d+)\.filename$", k)
        if not m or not v.lower().endswith(".vmdk"): continue
        pre = "%s%s:%s" % m.groups()
        if kv.get(pre + ".present", "true").lower() == "false": continue
        if "cdrom" in kv.get(pre + ".devicetype", "").lower(): continue
        p = v if os.path.isabs(v) else os.path.join(base, v)
        if not os.path.exists(p):                 # e.g. /vmfs/volumes/... paths
            p = os.path.join(base, os.path.basename(v))
        found.append(((buses.index(m.group(1)), int(m.group(2)), int(m.group(3))), p))
    disks = [(p, "") for _, p in sorted(found)]

out["OSTYPE"] = map_os(out.get("OSHINT", ""))
for k, v in out.items():
    print("%s\t%s" % (k, " ".join(str(v).split())))
for p, c in disks:
    print("DISK\t%s\t%s" % (p, c))
PY

# parse_meta <ovf|vmx> <file> <collect_disks 0|1>
parse_meta() {
  local mode=$1 file=$2 collect=$3 meta k v c
  meta=$(python3 -c "$PY_PARSER" "$mode" "$file") || die "Could not parse $file"
  while IFS=$'\t' read -r k v c; do
    case $k in
      NAME)     M_NAME=$v ;;
      MEMORY)   M_MEMORY=$v ;;
      CPUS)     M_CPUS=$v ;;
      FIRMWARE) M_FIRMWARE=$v ;;
      OSHINT)   M_OSHINT=$v ;;
      OSTYPE)   M_OSTYPE=$v ;;
      WARN)     warn "$v" ;;
      DISK)     if (( collect )); then DISKS+=("$v"); DISK_COMP+=("$c"); fi ;;
    esac
  done <<< "$meta"
}

# ----------------------------- helpers ---------------------------------------
cleanup() {
  local rc=$?
  if [[ -n $WORK_TMP && -d $WORK_TMP ]]; then
    rm -rf -- "$WORK_TMP"
  fi
  if (( rc != 0 && VM_CREATED && !SUCCESS && !DRY_RUN )); then
    if (( KEEP_ON_FAIL )); then
      warn "Import failed. Partial VM $VMID left in place (--keep-on-fail)."
    else
      warn "Import failed - removing partially created VM $VMID ..."
      qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || \
        warn "Could not remove VM $VMID automatically; run: qm destroy $VMID"
    fi
  fi
}
trap cleanup EXIT
trap 'die "Interrupted"' INT TERM
trap 'echo "${C_R}[x]${C_0} Command failed (line $LINENO): $BASH_COMMAND" >&2' ERR

prepare_workdir() {
  [[ -n $WORK_TMP ]] && return
  mkdir -p "$WORKDIR"
  WORK_TMP=$(mktemp -d "$WORKDIR/pve-import.XXXXXX")
}

sanitize_name() {
  local n
  n=$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '-' | sed -E 's/-+/-/g; s/^[-.]+//; s/[-.]+$//')
  n=${n:0:63}
  printf '%s' "${n:-imported-vm}"
}

# Turn a -flat.vmdk / -s001.vmdk extent into its descriptor if present
resolve_vmdk() {
  local f=$1 dir base
  dir=$(dirname "$f"); base=$(basename "$f")
  if [[ $base =~ ^(.+)-flat\.vmdk$ && -f "$dir/${BASH_REMATCH[1]}.vmdk" ]]; then
    warn "$base is a data extent; using descriptor ${BASH_REMATCH[1]}.vmdk instead" >&2
    f="$dir/${BASH_REMATCH[1]}.vmdk"
  elif [[ $base =~ ^(.+)-s[0-9]{3}\.vmdk$ && -f "$dir/${BASH_REMATCH[1]}.vmdk" ]]; then
    warn "$base is a split extent; using descriptor ${BASH_REMATCH[1]}.vmdk instead" >&2
    f="$dir/${BASH_REMATCH[1]}.vmdk"
  fi
  readlink -f "$f"
}

verify_manifest() {
  local mf=$1 dir line algo file want got re='^(SHA1|SHA256|SHA512)\((.+)\)= *([0-9a-fA-F]+)'
  dir=$(dirname "$mf")
  info "Verifying checksums from $(basename "$mf") (can take a while on big disks) ..."
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    algo=${BASH_REMATCH[1],,}; file=${BASH_REMATCH[2]}; want=${BASH_REMATCH[3],,}
    [[ -f "$dir/$file" ]] || die "Manifest lists $file but it is not in the OVA"
    got=$("${algo}sum" "$dir/$file" | awk '{print $1}')
    [[ $got == "$want" ]] || die "Checksum mismatch for $file - the OVA may be corrupt (use --no-verify to skip)"
    ok "  $file OK"
  done < "$mf"
}

# ----------------------------- argument parsing ------------------------------
while (( $# )); do
  case $1 in
    -i|--vmid)     VMID=${2:?"$1 needs a value"}; shift 2 ;;
    -s|--storage)  STORAGE=${2:?"$1 needs a value"}; shift 2 ;;
    -n|--name)     NAME=${2:?"$1 needs a value"}; shift 2 ;;
    -m|--memory)   MEMORY=${2:?"$1 needs a value"}; shift 2 ;;
    -c|--cores)    CORES=${2:?"$1 needs a value"}; shift 2 ;;
    -b|--bridge)   BRIDGE=${2:?"$1 needs a value"}; shift 2 ;;
    --vlan)        VLAN=${2:?"$1 needs a value"}; shift 2 ;;
    --bus)         BUS=${2,,}; shift 2 ;;
    --nic)         NIC_MODEL=${2,,}; shift 2 ;;
    --bios)        BIOS=${2,,}; shift 2 ;;
    --ostype)      OSTYPE=${2:?"$1 needs a value"}; shift 2 ;;
    --cpu)         CPU_TYPE=${2:?"$1 needs a value"}; shift 2 ;;
    --format)      FORMAT=${2,,}; shift 2 ;;
    --vmx)         VMX_FILE=${2:?"$1 needs a value"}; shift 2 ;;
    --workdir)     WORKDIR=${2:?"$1 needs a value"}; shift 2 ;;
    --start)       START=1; shift ;;
    --no-verify)   VERIFY=0; shift ;;
    --keep-on-fail) KEEP_ON_FAIL=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; INPUTS+=("$@"); break ;;
    -*)            die "Unknown option: $1 (see --help)" ;;
    *)             INPUTS+=("$1"); shift ;;
  esac
done

(( ${#INPUTS[@]} )) || { usage; exit 1; }

[[ -z $BUS       || $BUS  =~ ^(scsi|sata|ide|virtio)$ ]]   || die "--bus must be scsi, sata, ide or virtio"
[[ -z $BIOS      || $BIOS =~ ^(seabios|ovmf)$ ]]           || die "--bios must be seabios or ovmf"
[[ -z $FORMAT    || $FORMAT =~ ^(qcow2|raw|vmdk)$ ]]       || die "--format must be qcow2, raw or vmdk"
[[ -z $MEMORY    || $MEMORY =~ ^[0-9]+$ ]]                 || die "--memory must be a number (MB)"
[[ -z $CORES     || $CORES  =~ ^[0-9]+$ ]]                 || die "--cores must be a number"
[[ -z $VLAN      || $VLAN   =~ ^[0-9]+$ ]]                 || die "--vlan must be a number"

# ----------------------------- pre-flight ------------------------------------
[[ $EUID -eq 0 ]] || die "Run this as root on the Proxmox node"
for cmd in qm pvesm pvesh qemu-img python3 tar numfmt; do
  command -v "$cmd" >/dev/null || die "Required command '$cmd' not found (is this a Proxmox VE node?)"
done
for f in "${INPUTS[@]}"; do [[ -f $f ]] || die "File not found: $f"; done

IMPORT_CMD=(qm disk import)
qm help disk import >/dev/null 2>&1 || IMPORT_CMD=(qm importdisk)   # older PVE

FIRST=${INPUTS[0]}
case $FIRST in
  *.ova|*.ovf) (( ${#INPUTS[@]} == 1 )) || die "Give one OVA/OVF at a time"; MODE=appliance ;;
  *.vmx)       (( ${#INPUTS[@]} == 1 )) || die "Give one VMX at a time";     MODE=vmx ;;
  *.vmdk)      MODE=vmdk
               for f in "${INPUTS[@]}"; do
                 [[ $f == *.vmdk ]] || die "Can't mix VMDKs with other file types ($f)"
               done ;;
  *)           die "Unsupported file type: $FIRST (expected .ova, .ovf, .vmx or .vmdk)" ;;
esac

# ----------------------------- gather source info ----------------------------
case $MODE in
  appliance)
    if [[ $FIRST == *.ova ]]; then
      prepare_workdir
      need=$(stat -c %s "$FIRST")
      avail=$(df -PB1 "$WORK_TMP" | awk 'NR==2{print $4}')
      (( avail > need + 1073741824 )) || \
        die "Not enough space in $WORKDIR to extract the OVA ($(hr "$need") needed, $(hr "$avail") free). Use --workdir."
      info "Extracting $(basename "$FIRST") ($(hr "$need")) to $WORK_TMP ..."
      tar -xf "$FIRST" -C "$WORK_TMP" --no-same-owner || die "Failed to extract OVA (is it a valid tar archive?)"
      OVF=$(find "$WORK_TMP" -maxdepth 2 -type f -iname '*.ovf' | head -n1)
    else
      OVF=$(readlink -f "$FIRST")
    fi
    [[ -n ${OVF:-} ]] || die "No .ovf descriptor found inside the OVA"
    if (( VERIFY )); then
      MF=$(find "$(dirname "$OVF")" -maxdepth 1 -type f -iname '*.mf' | head -n1)
      if [[ -n $MF ]]; then verify_manifest "$MF"; else info "No manifest (.mf) found - skipping checksum verification"; fi
    fi
    info "Reading $(basename "$OVF") ..."
    parse_meta ovf "$OVF" 1
    ;;
  vmx)
    info "Reading $(basename "$FIRST") ..."
    parse_meta vmx "$(readlink -f "$FIRST")" 1
    ;;
  vmdk)
    for f in "${INPUTS[@]}"; do
      r=$(resolve_vmdk "$f")
      [[ " ${DISKS[*]-} " == *" $r "* ]] || { DISKS+=("$r"); DISK_COMP+=(""); }
    done
    if [[ -z $VMX_FILE ]]; then
      mapfile -t vmxs < <(find "$(dirname "${DISKS[0]}")" -maxdepth 1 -type f -iname '*.vmx')
      if (( ${#vmxs[@]} == 1 )); then
        VMX_FILE=${vmxs[0]}
      elif (( ${#vmxs[@]} > 1 )); then
        warn "Several .vmx files next to the disk; pass --vmx to pick one. Using defaults."
      fi
    fi
    if [[ -n $VMX_FILE ]]; then
      [[ -f $VMX_FILE ]] || die "VMX file not found: $VMX_FILE"
      info "Reading VM settings from $(basename "$VMX_FILE")"
      parse_meta vmx "$VMX_FILE" 0
    else
      info "No .vmx found - using default hardware settings (override with -m/-c/--bios/--ostype)"
    fi
    ;;
esac

(( ${#DISKS[@]} )) || die "No disks found to import"

# ----------------------------- decide settings -------------------------------
NAME=$(sanitize_name "${NAME:-${M_NAME:-$(basename "${FIRST%.*}")}}")
MEMORY=${MEMORY:-${M_MEMORY:-2048}}
CORES=${CORES:-${M_CPUS:-2}}
OSTYPE=${OSTYPE:-${M_OSTYPE:-other}}
if [[ -z $BIOS ]]; then
  [[ ${M_FIRMWARE:-} == efi ]] && BIOS=ovmf || BIOS=seabios
fi
# Linux has VirtIO drivers built in; Windows/unknown guests get emulated
# hardware that works without extra drivers.
if [[ -z $BUS ]]; then
  [[ $OSTYPE == l26 ]] && BUS=scsi || BUS=sata
fi
if [[ -z $NIC_MODEL ]]; then
  [[ $OSTYPE == l26 ]] && NIC_MODEL=virtio || NIC_MODEL=e1000
fi

case $BUS in
  ide) MAXD=4; DOPTS="" ;;
  sata) MAXD=6; DOPTS=",discard=on" ;;
  scsi) MAXD=31; DOPTS=",iothread=1,discard=on" ;;
  virtio) MAXD=16; DOPTS=",iothread=1,discard=on" ;;
esac
(( ${#DISKS[@]} <= MAXD )) || die "$BUS supports at most $MAXD disks; this VM has ${#DISKS[@]} (try --bus scsi)"

# Storage checks
STYPE=$(pvesm status --storage "$STORAGE" 2>/dev/null | awk 'NR==2{print $2}') || true
IMG_STORES=$(pvesm status --content images 2>/dev/null | awk 'NR>1{print $1}') || true
[[ -n $STYPE ]] || die "Storage '$STORAGE' not found. Storages that accept VM disks: $(echo $IMG_STORES)"
grep -qx -- "$STORAGE" <<< "$IMG_STORES" || die "Storage '$STORAGE' is not enabled for 'Disk image' content"
case $STYPE in dir|nfs|cifs|glusterfs|cephfs|btrfs) FILEBASED=1 ;; esac
if (( FILEBASED )); then
  FORMAT=${FORMAT:-qcow2}
else
  [[ -z $FORMAT || $FORMAT == raw ]] || warn "Storage type '$STYPE' only supports raw; ignoring --format $FORMAT"
  FORMAT=raw
fi

# VMID
if [[ -z $VMID ]]; then
  VMID=$(pvesh get /cluster/nextid)
else
  [[ $VMID =~ ^[0-9]+$ ]] || die "--vmid must be a number"
  pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || die "VMID $VMID is already in use"
fi

[[ -d /sys/class/net/$BRIDGE ]] || warn "Bridge '$BRIDGE' doesn't exist on this node - the VM will have no working network until fixed"

# Check every disk is readable by qemu-img
for i in "${!DISKS[@]}"; do
  d=${DISKS[$i]}
  [[ -f $d ]] || die "Disk file missing: $d"
  if [[ -z ${DISK_COMP[$i]} ]]; then
    vs=$(qemu-img info -U "$d" 2>/dev/null | awk -F': ' '/^virtual size/{print $2; exit}') || true
    [[ -n $vs ]] || die "qemu-img can't read $(basename "$d"). For descriptor VMDKs make sure the matching -flat / -sNNN / snapshot files are in the same folder."
    DISK_SIZE[$i]=$vs
  else
    DISK_SIZE[$i]="(${DISK_COMP[$i]} compressed)"
  fi
done

# ----------------------------- summary ---------------------------------------
NET="${NIC_MODEL},bridge=${BRIDGE}${VLAN:+,tag=$VLAN}"
echo
echo "${C_W}================ Import plan ================${C_0}"
printf '  %-12s %s\n' "Source:" "$FIRST ($MODE)"
[[ -n $M_OSHINT ]] && printf '  %-12s %s\n' "Guest OS:" "$M_OSHINT"
printf '  %-12s %s\n' "VMID:" "$VMID" "Name:" "$NAME" "Memory:" "${MEMORY} MB" \
  "Cores:" "$CORES" "CPU type:" "$CPU_TYPE" "OS type:" "$OSTYPE" \
  "Firmware:" "$BIOS$([[ $BIOS == ovmf ]] && echo ' (UEFI, q35, secure boot off)')" \
  "Network:" "$NET" "Storage:" "$STORAGE ($STYPE, $FORMAT)" "Disk bus:" "$BUS"
for i in "${!DISKS[@]}"; do
  printf '  %-12s %s -> %s%d  [%s]\n' "Disk $((i+1)):" "$(basename "${DISKS[$i]}")" "$BUS" "$i" "${DISK_SIZE[$i]}"
done
echo "${C_W}=============================================${C_0}"
echo

if (( ! ASSUME_YES && ! DRY_RUN )); then
  read -r -p "Proceed with import? [y/N] " ans
  [[ $ans =~ ^y(es)?$ ]] || die "Aborted by user"
fi

# ----------------------------- create VM -------------------------------------
info "Creating VM $VMID ..."
CREATE=(qm create "$VMID" --name "$NAME" --memory "$MEMORY" --cores "$CORES" --sockets 1
        --cpu "$CPU_TYPE" --ostype "$OSTYPE" --bios "$BIOS" --scsihw virtio-scsi-single
        --net0 "$NET")
if [[ $BIOS == ovmf ]]; then
  EFI="${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
  (( FILEBASED )) && EFI+=",format=$FORMAT"
  CREATE+=(--machine q35 --efidisk0 "$EFI")
fi
run "${CREATE[@]}"
VM_CREATED=1

# ----------------------------- import disks ----------------------------------
for i in "${!DISKS[@]}"; do
  src=${DISKS[$i]}
  if [[ -n ${DISK_COMP[$i]} ]]; then
    [[ ${DISK_COMP[$i]} == gzip ]] || die "Unsupported disk compression '${DISK_COMP[$i]}' for $(basename "$src")"
    prepare_workdir
    info "Decompressing $(basename "$src") ..."
    if (( ! DRY_RUN )); then
      gunzip -c "$src" > "$WORK_TMP/disk$i.vmdk"
    fi
    src="$WORK_TMP/disk$i.vmdk"
  fi

  info "Importing disk $((i+1))/${#DISKS[@]}: $(basename "${DISKS[$i]}") -> $STORAGE"
  IMP=("${IMPORT_CMD[@]}" "$VMID" "$src" "$STORAGE")
  (( FILEBASED )) && IMP+=(--format "$FORMAT")
  run "${IMP[@]}"

  if (( DRY_RUN )); then
    VOL="${STORAGE}:vm-${VMID}-disk-$i"
  else
    VOL=$(qm config "$VMID" | awk '/^unused[0-9]+:/{sub(/^unused[0-9]+: */,""); print; exit}')
    [[ -n $VOL ]] || die "Imported disk not found in VM config"
    [[ ${DISK_COMP[$i]} ]] && rm -f -- "$src"
  fi
  run qm set "$VMID" "--${BUS}${i}" "${VOL}${DOPTS}"
done

run qm set "$VMID" --boot "order=${BUS}0"
SUCCESS=1
ok "VM $VMID ($NAME) imported successfully."

if (( START )); then
  info "Starting VM $VMID ..."
  run qm start "$VMID"
fi

# ----------------------------- next steps ------------------------------------
echo
echo "${C_W}Next steps:${C_0}"
echo "  - Open the console: Proxmox web UI -> VM $VMID -> Console"
echo "  - Uninstall VMware Tools inside the guest, then install qemu-guest-agent"
echo "    and enable it with: qm set $VMID --agent enabled=1"
if [[ $OSTYPE == win* ]]; then
  echo "  - Windows: install the VirtIO drivers (virtio-win ISO). Then you can switch"
  echo "    to faster hardware: --nic virtio and disks on scsi (virtio-scsi-single)."
fi
if [[ $OSTYPE == other ]]; then
  echo "  - Guest OS was unknown, so safe SATA + e1000 hardware was used."
  echo "    For Linux guests you can re-run with --ostype l26 for VirtIO."
fi
echo "  - Network adapters change, so the guest may need its IP config redone"
echo "    (Linux interface names like ens160 usually become ens18)."
if [[ $BIOS == seabios && $MODE == vmdk && -z $VMX_FILE ]]; then
  echo "  - If it doesn't boot, the source may have been UEFI: qm set $VMID --bios ovmf"
  echo "    (plus an EFI disk: qm set $VMID --efidisk0 ${STORAGE}:1,efitype=4m,pre-enrolled-keys=0)"
fi
