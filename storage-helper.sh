#!/usr/bin/env bash
# ── libvirt-vm-and-backup-storage-setup-debian13-v10.sh ───────────────────────
# Debian 13/Trixie helper:
#   - Lists all drives and marks the OS/system drive.
#   - Lets you configure one extra drive for VM image storage.
#   - Lets you configure another extra drive for Timeshift backups + ISO files.
#   - Optionally wipes/formats selected extra drives as GPT + ext4.
#   - Unmounts selected extra drives if GNOME/Nautilus already mounted them.
#   - Mounts selected drives permanently via /etc/fstab.
#   - Creates libvirt storage pools for virt-manager:
#       nvme-vms  -> VM disk images
#       iso-files -> ISO directory on the backup drive
#
# Run as your normal desktop user, not with sudo:
#   bash libvirt-vm-and-backup-storage-setup-debian13.sh
#
# This script never formats anything without an explicit typed confirmation.
# ─────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
trap 'printf "\nERROR at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ── Config ────────────────────────────────────────────────────────────────────
VM_LABEL="vm-nvme"
VM_MOUNT="/mnt/vm-nvme"
VM_POOL_NAME="nvme-vms"
VM_POOL_DIR="$VM_MOUNT/libvirt/images"

BACKUP_LABEL="backup-iso"
BACKUP_MOUNT="/mnt/backup"
ISO_DIR="$BACKUP_MOUNT/iso"
ISO_POOL_NAME="iso-files"

FSTAB_OPTS_BASE="defaults,noatime,lazytime,nofail,x-systemd.device-timeout=10"
VM_GVFS_NAME="VM-NVMe"
BACKUP_GVFS_NAME="Backup"
TEMP_FSTAB=""

# Install missing virt/libvirt/filesystem dependencies automatically.
INSTALL_MISSING_PACKAGES=1

# Candidate filtering:
#   1 = hide removable/USB drives from the default candidate list.
#   0 = include them as candidates too.
EXCLUDE_REMOVABLE_OR_USB=1

# ── Output helpers ────────────────────────────────────────────────────────────
info()    { printf '\n\e[1;34m──\e[0m %s\n' "$*" >&2; }
success() { printf '\e[1;32m✓\e[0m %s\n' "$*" >&2; }
warn()    { printf '\e[1;33m!\e[0m %s\n' "$*" >&2; }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

read_prompt() {
    # Usage: read_prompt VAR
    # Returns non-zero on Ctrl+D/EOF so callers can treat it as cancellation
    # instead of letting set -e abort via the ERR trap.
    local __var="$1"

    if ! read -r "$__var"; then
        warn "EOF received; treating as cancellation"
        return 1
    fi

    return 0
}

fstab_opts_for_mount() {
    # Add x-gvfs-show so GNOME/Nautilus displays these permanent mounts in the
    # Devices section, and x-gvfs-name for friendly sidebar names.
    local mountpoint="$1"
    local name=""

    case "$mountpoint" in
        "$VM_MOUNT")
            name="$VM_GVFS_NAME"
            ;;
        "$BACKUP_MOUNT")
            name="$BACKUP_GVFS_NAME"
            ;;
    esac

    if [[ -n "$name" ]]; then
        printf '%s,x-gvfs-show,x-gvfs-name=%s\n' "$FSTAB_OPTS_BASE" "$name"
    else
        printf '%s\n' "$FSTAB_OPTS_BASE"
    fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    die "Run this as your normal user, not with sudo. The script uses sudo internally."
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    die "/etc/os-release missing."
fi

[[ "${ID:-}" == "debian" ]] || die "This script is intended for Debian."
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || warn "This was written for Debian 13/Trixie; detected: ${VERSION_CODENAME:-unknown}"

for cmd in sudo lsblk findmnt readlink awk sed grep sort head; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is missing."
done

if [[ ! -t 0 ]]; then
    die "Interactive terminal required because this script can format drives."
fi

# Ask for sudo once near the beginning.
sudo -v

# Keep sudo timestamp fresh while script runs.
while true; do
    sudo -n true 2>/dev/null || exit 0
    sleep 60
done &
SUDO_KEEPALIVE_PID=$!

cleanup_runtime() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi

    if [[ -n "${TEMP_FSTAB:-}" ]]; then
        sudo rm -f "$TEMP_FSTAB" 2>/dev/null || true
    fi
}

trap cleanup_runtime EXIT
trap 'cleanup_runtime; exit 130' INT
trap 'cleanup_runtime; exit 143' TERM
trap 'cleanup_runtime; exit 129' HUP

# ── Package / libvirt setup ───────────────────────────────────────────────────
ensure_packages() {
    local packages=(
        qemu-kvm
        libvirt-daemon-system
        libvirt-clients
        bridge-utils
        virtinst
        virt-manager
        qemu-system-x86
        cpu-checker
        gdisk
        e2fsprogs
        parted
        util-linux
        acl
    )

    if [[ "$INSTALL_MISSING_PACKAGES" != "1" ]]; then
        return 0
    fi

    info "Installing/checking required Debian packages"

    sudo env DEBIAN_FRONTEND=noninteractive apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

    success "Required packages installed/confirmed"

    if command -v kvm-ok >/dev/null 2>&1; then
        info "Checking KVM hardware virtualization"
        if sudo kvm-ok; then
            success "KVM acceleration is available"
        else
            warn "KVM acceleration check failed. Enable Intel VT-x/AMD-V in firmware/BIOS if needed."
        fi
    fi
}

ensure_libvirt_service() {
    info "Enabling libvirt service"

    if sudo systemctl enable --now libvirtd.service >/dev/null 2>&1; then
        success "libvirtd.service enabled and running"
    else
        warn "libvirtd.service not available or failed; trying modular libvirt sockets"

        local unit
        for unit in virtqemud.socket virtlogd.socket virtlockd.socket; do
            sudo systemctl enable --now "$unit" >/dev/null 2>&1 || true
        done

        success "Modular libvirt sockets checked"
    fi
}

ensure_user_groups() {
    local target_user="$USER"

    info "Adding $target_user to libvirt/kvm groups"

    if getent group libvirt >/dev/null 2>&1; then
        sudo usermod -aG libvirt "$target_user"
        success "User is/will be in group: libvirt"
    else
        warn "Group libvirt not found"
    fi

    if getent group kvm >/dev/null 2>&1; then
        sudo usermod -aG kvm "$target_user"
        success "User is/will be in group: kvm"
    else
        warn "Group kvm not found"
    fi

    warn "Group changes require log out/in or reboot before they fully apply."
}

# ── Drive discovery ───────────────────────────────────────────────────────────
get_parent_disk() {
    local dev="$1"
    local cur parent type pkname

    cur="$(readlink -f "$dev")"
    [[ -b "$cur" ]] || return 1

    # Preferred path: ask lsblk for the full ancestor chain and pick the
    # physical parent disk. This is more reliable than PKNAME alone on NVMe,
    # LUKS, LVM, and other mapped-device layouts.
    parent="$(lsblk -spnr -o NAME,TYPE "$cur" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')"
    if [[ -n "$parent" && -b "$parent" ]]; then
        readlink -f "$parent"
        return 0
    fi

    # Fallback: walk PKNAME manually. Keep this for older/quirky lsblk output.
    for _ in {1..20}; do
        type="$(lsblk -nro TYPE "$cur" 2>/dev/null | head -n1 || true)"

        if [[ "$type" == "disk" ]]; then
            printf '%s\n' "$cur"
            return 0
        fi

        pkname="$(lsblk -no PKNAME "$cur" 2>/dev/null | awk 'NF { print $1; exit }')"
        [[ -n "$pkname" ]] || break

        if [[ "$pkname" == /dev/* ]]; then
            cur="$pkname"
        else
            cur="/dev/$pkname"
        fi

        cur="$(readlink -f "$cur")"
    done

    return 1
}

get_root_disk() {
    local root_src root_dev

    root_src="$(findmnt -no SOURCE /)"
    # btrfs roots may appear as /dev/nvme0n1p2[/@]. Strip the subvolume suffix
    # before resolving the block device.
    root_src="${root_src%%\[*}"

    if [[ ! -b "$root_src" ]]; then
        die "Root filesystem source is not a plain block device: $(findmnt -no SOURCE /). This script currently supports normal block-device roots."
    fi

    root_dev="$(readlink -f "$root_src")"

    get_parent_disk "$root_dev"
}

lsblk_pair_value() {
    local line="$1"
    local key="$2"

    # lsblk -P prints KEY="value" pairs and safely preserves empty fields and
    # values containing spaces. Match only complete KEY= fields to avoid accidental
    # substring matches such as PKNAME when asking for NAME.
    sed -n \
        -e "s/.* ${key}=\"\([^\"]*\)\".*/\1/p" \
        -e "s/^${key}=\"\([^\"]*\)\".*/\1/p" \
        <<<"$line" | head -n1
}

print_drive_inventory() {
    local root_disk="$1"

    info "All detected drives"
    printf 'System/OS parent disk: %s\n\n' "$root_disk"

    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,RM,ROTA,TRAN,MODEL

    printf '\nClassification:\n'

    while IFS= read -r line; do
        local disk size rm rota tran model mark transport

        disk="$(lsblk_pair_value "$line" NAME)"
        size="$(lsblk_pair_value "$line" SIZE)"
        rm="$(lsblk_pair_value "$line" RM)"
        rota="$(lsblk_pair_value "$line" ROTA)"
        tran="$(lsblk_pair_value "$line" TRAN)"
        model="$(lsblk_pair_value "$line" MODEL)"

        mark="extra"
        transport="${tran:-unknown}"

        if [[ "$(readlink -f "$disk")" == "$(readlink -f "$root_disk")" ]]; then
            mark="SYSTEM/OS"
        elif [[ "$EXCLUDE_REMOVABLE_OR_USB" == "1" && ( "$rm" == "1" || "$transport" == "usb" ) ]]; then
            mark="extra/removable-or-usb"
        fi

        printf '  %-14s %-22s size=%-8s rm=%s rota=%s tran=%-8s model=%s\n' \
            "$disk" "$mark" "$size" "$rm" "$rota" "$transport" "${model:-}"
    done < <(lsblk -dnpPo NAME,SIZE,RM,ROTA,TRAN,MODEL)
}

collect_candidate_disks() {
    local root_disk="$1"
    local disk size rm rota tran model root_real disk_real

    root_real="$(readlink -f "$root_disk")"

    while IFS= read -r line; do
        disk="$(lsblk_pair_value "$line" NAME)"
        size="$(lsblk_pair_value "$line" SIZE)"
        rm="$(lsblk_pair_value "$line" RM)"
        rota="$(lsblk_pair_value "$line" ROTA)"
        tran="$(lsblk_pair_value "$line" TRAN)"
        model="$(lsblk_pair_value "$line" MODEL)"

        disk_real="$(readlink -f "$disk")"

        [[ "$disk_real" != "$root_real" ]] || continue

        if [[ "$EXCLUDE_REMOVABLE_OR_USB" == "1" ]]; then
            [[ "$rm" == "0" ]] || continue
            [[ "${tran:-}" != "usb" ]] || continue
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$disk" "$size" "$rm" "$rota" "${tran:-unknown}" "${model:-}"
    done < <(lsblk -dnpPo NAME,SIZE,RM,ROTA,TRAN,MODEL)
}

print_candidate_details() {
    local candidates=("$@")
    local i line disk size rm rota tran model

    info "Extra drive candidates"

    if ((${#candidates[@]} == 0)); then
        warn "No extra internal candidate drives found."
        return 1
    fi

    for i in "${!candidates[@]}"; do
        line="${candidates[$i]}"
        IFS=$'\t' read -r disk size rm rota tran model <<<"$line"

        printf '\n[%d] %s  size=%s  rm=%s  rota=%s  tran=%s  model=%s\n' \
            "$((i + 1))" "$disk" "$size" "$rm" "$rota" "$tran" "$model"

        lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$disk" | sed 's/^/    /'
    done

    return 0
}

is_used_disk() {
    local disk="$1"
    shift
    local used

    for used in "$@"; do
        [[ -n "$used" ]] || continue
        if [[ "$(readlink -f "$disk")" == "$(readlink -f "$used")" ]]; then
            return 0
        fi
    done

    return 1
}

select_candidate_disk() {
    local role="$1"
    shift
    local used_disks_csv="$1"
    shift
    local candidates=("$@")
    local used_disks=()
    local available=()
    local answer idx line disk size rm rota tran model
    local old_ifs="$IFS"

    IFS=',' read -r -a used_disks <<<"$used_disks_csv"
    IFS="$old_ifs"

    for line in "${candidates[@]}"; do
        IFS=$'\t' read -r disk size rm rota tran model <<<"$line"
        if ! is_used_disk "$disk" "${used_disks[@]}"; then
            available+=("$line")
        fi
    done

    if ((${#available[@]} == 0)); then
        warn "No remaining candidate drives for $role."
        return 1
    fi

    info "Select drive for: $role"

    local i
    for i in "${!available[@]}"; do
        line="${available[$i]}"
        IFS=$'\t' read -r disk size rm rota tran model <<<"$line"
        printf '\n[%d] %s  size=%s  rm=%s  rota=%s  tran=%s  model=%s\n' \
            "$((i + 1))" "$disk" "$size" "$rm" "$rota" "$tran" "$model" >&2
        lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$disk" | sed 's/^/    /' >&2
    done

    while true; do
        printf '\nSelect drive for %s, s to skip, or q to quit: ' "$role" >&2
        if ! read_prompt answer; then
            return 1
        fi

        [[ "$answer" =~ ^[Qq]$ ]] && return 2
        [[ "$answer" =~ ^[Ss]$ ]] && return 1

        if [[ "$answer" =~ ^[0-9]+$ ]]; then
            idx=$((answer - 1))

            if ((idx >= 0 && idx < ${#available[@]})); then
                line="${available[$idx]}"
                IFS=$'\t' read -r disk size rm rota tran model <<<"$line"
                printf '%s\n' "$disk"
                return 0
            fi
        fi

        warn "Invalid selection"
    done
}

# ── Filesystem / mount helpers ────────────────────────────────────────────────
list_mounts_under_disk() {
    local disk="$1"
    local dev

    # Print mountpoints belonging to the selected disk or any partition below it.
    # Mounted children are sorted later so nested mounts are unmounted first.
    while read -r dev; do
        findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true
    done < <(lsblk -rnpo NAME "$disk")
}

unmount_one_mountpoint() {
    local mountpoint="$1"
    local source=""
    local source_real=""

    source="$(findmnt -rn --mountpoint "$mountpoint" -o SOURCE 2>/dev/null | head -n1 || true)"

    if [[ -n "$source" ]]; then
        source_real="$(readlink -f "$source" 2>/dev/null || true)"
    fi

    # GNOME/Nautilus user mounts under /media/$USER are usually udisks mounts.
    # Try udisksctl first because it cleanly updates the desktop session state.
    if [[ -n "$source_real" && -b "$source_real" ]] && command -v udisksctl >/dev/null 2>&1; then
        if udisksctl unmount -b "$source_real" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Fallback for normal system mounts.
    if sudo umount "$mountpoint"; then
        return 0
    fi

    warn "Could not unmount $mountpoint. It may be busy."

    if command -v fuser >/dev/null 2>&1; then
        warn "Processes currently using $mountpoint:"
        sudo fuser -vm "$mountpoint" || true
    fi

    return 1
}

unmount_disk_tree() {
    local disk="$1"
    local mounts=()
    local m

    mapfile -t mounts < <(
        list_mounts_under_disk "$disk" |
            awk 'NF { n = gsub("/", "/"); print n "	" $0 }' |
            sort -rn |
            cut -f2-
    )

    if ((${#mounts[@]} == 0)); then
        return 0
    fi

    info "Unmounting existing mounts on $disk"

    for m in "${mounts[@]}"; do
        warn "Unmounting $m"

        if ! unmount_one_mountpoint "$m"; then
            die "Failed to unmount $m. Close Files/Nautilus windows, terminals, or apps using this drive and rerun the script."
        fi
    done
}

find_single_ext4_target_on_disk() {
    local disk="$1"
    local ext4_devs=()

    mapfile -t ext4_devs < <(
        lsblk -rnpo NAME,FSTYPE "$disk" |
            awk '$2 == "ext4" { print $1 }'
    )

    if ((${#ext4_devs[@]} == 1)); then
        printf '%s\n' "${ext4_devs[0]}"
        return 0
    fi

    return 1
}

device_has_label() {
    local device="$1"
    local expected_label="$2"
    local actual_label=""

    [[ -n "$device" && -b "$device" ]] || return 1

    # First try a direct low-level probe. This is the most reliable path
    # immediately after mkfs/e2label because it does not depend on blkid cache.
    actual_label="$(sudo blkid -p -s LABEL -o value "$device" 2>/dev/null || true)"

    if [[ "$actual_label" == "$expected_label" ]]; then
        return 0
    fi

    # Fallbacks for older/quirky blkid output paths.
    actual_label="$(sudo blkid -c /dev/null -s LABEL -o value "$device" 2>/dev/null || true)"

    if [[ "$actual_label" == "$expected_label" ]]; then
        return 0
    fi

    actual_label="$(lsblk -dnro LABEL "$device" 2>/dev/null || true)"

    [[ "$actual_label" == "$expected_label" ]]
}

label_devices() {
    local label="$1"
    local devices=()
    local dev=""
    local existing=""
    local found=0

    # Primary lookup: direct blkid scan with cache disabled.
    mapfile -t devices < <(sudo blkid -c /dev/null -t "LABEL=$label" -o device 2>/dev/null || true)

    # Fallback lookup: lsblk sometimes sees the freshly written label before
    # blkid's label search does on a just-created partition.
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue

        found=0
        for existing in "${devices[@]}"; do
            if [[ "$existing" == "$dev" ]]; then
                found=1
                break
            fi
        done

        if [[ "$found" == "0" ]]; then
            devices+=("$dev")
        fi
    done < <(lsblk -rnpo NAME,LABEL 2>/dev/null | awk -v wanted="$label" '$2 == wanted { print $1 }')

    if ((${#devices[@]})); then
        printf '%s\n' "${devices[@]}"
    fi
}

check_label_conflict() {
    local target_dev="$1"
    local label="$2"
    local existing=()
    local dev

    sudo blkid -p "$target_dev" >/dev/null 2>&1 || true
    mapfile -t existing < <(label_devices "$label")

    for dev in "${existing[@]}"; do
        if [[ "$(readlink -f "$dev")" != "$(readlink -f "$target_dev")" ]]; then
            die "Label '$label' already exists on $dev. Refusing to create duplicate filesystem labels."
        fi
    done
}

format_disk_for_role() {
    local disk="$1"
    local label="$2"
    local role="$3"
    local confirm partdev

    printf '\n\e[1;31mDESTRUCTIVE ACTION\e[0m\n' >&2
    printf 'This will wipe and reformat the selected drive for: %s\n' "$role" >&2
    printf '  %s\n\n' "$disk" >&2
    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$disk" >&2
    printf '\nThis creates a new GPT partition table and one ext4 partition labeled %s.\n' "$label" >&2
    printf 'All existing data on %s will be destroyed.\n\n' "$disk" >&2

    printf 'To continue, type exactly: FORMAT %s. Ctrl+D/EOF cancels.\n> ' "$disk" >&2
    if ! read_prompt confirm; then
        return 1
    fi

    if [[ "$confirm" != "FORMAT $disk" ]]; then
        warn "Format cancelled"
        return 1
    fi

    unmount_disk_tree "$disk"

    info "Wiping and formatting $disk"

    # Wipe signatures from existing partitions first, then the parent disk.
    # This prevents stale ext4/LVM/etc. signatures from surviving a new GPT.
    while IFS= read -r child; do
        [[ "$child" == "$disk" ]] && continue
        sudo wipefs -a "$child" >&2 || true
    done < <(lsblk -rnpo NAME "$disk" | tail -n +2)

    sudo wipefs -a "$disk" >&2

    if command -v sgdisk >/dev/null 2>&1; then
        sudo sgdisk --zap-all "$disk" >&2 || true
    fi

    sudo parted -s "$disk" mklabel gpt >&2
    sudo parted -s -a optimal "$disk" mkpart "$label" ext4 1MiB 100% >&2
    sudo partprobe "$disk" || true
    sudo udevadm settle || true

    partdev=""
    for _ in {1..10}; do
        partdev="$(lsblk -rnpo NAME,TYPE "$disk" | awk '$2 == "part" { print $1; exit }')"
        [[ -n "$partdev" ]] && break
        sleep 1
        sudo partprobe "$disk" || true
        sudo udevadm settle || true
    done
    [[ -n "$partdev" ]] || die "Could not detect new partition on $disk"

    sudo mkfs.ext4 -F -L "$label" "$partdev" >&2
    sudo udevadm settle || true
    sudo blkid -p "$partdev" >/dev/null 2>&1 || true

    success "Formatted $partdev as ext4 with label $label"
    printf '%s\n' "$partdev"
}

use_existing_ext4_for_role() {
    local disk="$1"
    local label="$2"
    local mountpoint="$3"
    local role="$4"
    local target_dev current_label confirm

    if ! target_dev="$(find_single_ext4_target_on_disk "$disk")"; then
        warn "Could not find exactly one ext4 filesystem on $disk"
        return 1
    fi

    printf '\nExisting ext4 filesystem detected for: %s\n' "$role" >&2
    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$target_dev" >&2

    current_label="$(sudo blkid -s LABEL -o value "$target_dev" 2>/dev/null || true)"

    printf '\nThis will NOT format the drive.\n' >&2
    printf 'It will only:\n' >&2
    printf '  - unmount current temporary/user mounts if needed\n' >&2
    printf '  - set filesystem label to %s\n' "$label" >&2
    printf '  - add /etc/fstab entry for %s\n\n' "$mountpoint" >&2

    if [[ -n "$current_label" && "$current_label" != "$label" ]]; then
        warn "Current label is '$current_label'. It will be changed to '$label'."
    fi

    printf 'Apply this to %s? [y/N] ' "$target_dev" >&2
    if ! read_prompt confirm; then
        return 1
    fi

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        warn "Existing filesystem setup cancelled"
        return 1
    }

    check_label_conflict "$target_dev" "$label"

    unmount_disk_tree "$disk"

    sudo e2label "$target_dev" "$label"
    success "Set label on $target_dev: $label"

    printf '%s\n' "$target_dev"
}

ensure_fstab_label_mount() {
    local label="$1"
    local mountpoint="$2"
    local fstype="${3:-ext4}"
    local opts="${4:-$FSTAB_OPTS_BASE}"
    local expected_device="${5:-}"
    local spec="LABEL=$label"
    local fstab="/etc/fstab"
    local backup
    local devices=()
    local device

    # Bypass blkid cache because this may run immediately after mkfs/e2label.
    # Use sudo because normal users often cannot read raw block devices when
    # the cache is bypassed. Retry briefly for udev/blkid visibility after mkfs.
    # If the selected target device is known and directly proves it has the
    # expected label, use it as a safe fallback even if blkid's LABEL search is
    # still empty for a moment.
    for _ in {1..15}; do
        mapfile -t devices < <(label_devices "$label")

        if ((${#devices[@]} > 0)); then
            break
        fi

        if [[ -n "$expected_device" ]] && device_has_label "$expected_device" "$label"; then
            devices=("$expected_device")
            break
        fi

        sudo udevadm settle || true
        sleep 1
    done

    if ((${#devices[@]} == 0)) && [[ -n "$expected_device" ]] && device_has_label "$expected_device" "$label"; then
        devices=("$expected_device")
    fi

    if ((${#devices[@]} != 1)); then
        die "Expected exactly one filesystem with $spec, found ${#devices[@]}"
    fi

    device="${devices[0]}"

    if [[ -n "$expected_device" && "$(readlink -f "$device")" != "$(readlink -f "$expected_device")" ]]; then
        die "$spec resolved to $device, but selected target is $expected_device. Refusing to mount the wrong filesystem."
    fi

    sudo mkdir -p "$mountpoint"

    backup="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$fstab" "$backup"
    success "Backed up /etc/fstab to $backup"

    # Remove old line for this mountpoint/label, then append a clean line.
    # Stage the replacement in /etc and atomically rename it into place.
    TEMP_FSTAB="$(sudo mktemp "/etc/.fstab.tmp.storage-setup.XXXXXX")"

    sudo awk -v spec="$spec" -v mp="$mountpoint" '
        $1 == spec { next }
        $2 == mp { next }
        { print }
    ' "$fstab" | sudo tee "$TEMP_FSTAB" >/dev/null

    printf '%s  %s  %s  %s  0  0\n' \
        "$spec" "$mountpoint" "$fstype" "$opts" |
        sudo tee -a "$TEMP_FSTAB" >/dev/null

    sudo chown root:root "$TEMP_FSTAB"
    sudo chmod 0644 "$TEMP_FSTAB"
    sudo mv -f "$TEMP_FSTAB" "$fstab"
    TEMP_FSTAB=""

    sudo systemctl daemon-reload

    if findmnt -rn --mountpoint "$mountpoint" >/dev/null 2>&1; then
        sudo umount "$mountpoint"
    fi

    sudo mount "$mountpoint"

    success "Mounted $device at $mountpoint"
}

# ── Libvirt / permissions ─────────────────────────────────────────────────────
get_qemu_user() {
    if getent passwd libvirt-qemu >/dev/null 2>&1; then
        printf '%s\n' "libvirt-qemu"
    elif getent passwd qemu >/dev/null 2>&1; then
        printf '%s\n' "qemu"
    else
        return 1
    fi
}

get_qemu_group() {
    if getent group kvm >/dev/null 2>&1; then
        printf '%s\n' "kvm"
    elif getent group libvirt-qemu >/dev/null 2>&1; then
        printf '%s\n' "libvirt-qemu"
    elif getent group qemu >/dev/null 2>&1; then
        printf '%s\n' "qemu"
    else
        return 1
    fi
}

configure_libvirt_dir_pool() {
    local pool_name="$1"
    local pool_dir="$2"
    local existing_path

    command -v virsh >/dev/null 2>&1 || die "virsh is missing. Install libvirt-clients."

    info "Configuring libvirt storage pool: $pool_name"

    if sudo virsh pool-info "$pool_name" >/dev/null 2>&1; then
        existing_path="$(sudo virsh pool-dumpxml "$pool_name" 2>/dev/null |
            sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -n1 || true)"

        if [[ -n "$existing_path" && "$existing_path" != "$pool_dir" ]]; then
            die "Libvirt pool '$pool_name' already exists with different path: $existing_path"
        fi

        sudo virsh pool-start "$pool_name" >/dev/null 2>&1 || true
        sudo virsh pool-autostart "$pool_name" >/dev/null 2>&1 || true
        success "Libvirt storage pool already exists and is enabled: $pool_name"
    else
        sudo virsh pool-define-as "$pool_name" dir --target "$pool_dir"
        sudo virsh pool-build "$pool_name" || true
        sudo virsh pool-start "$pool_name"
        sudo virsh pool-autostart "$pool_name"
        success "Libvirt storage pool configured: $pool_name -> $pool_dir"
    fi
}

configure_vm_storage_permissions_and_pool() {
    local qemu_user qemu_group pool_root

    qemu_user="$(get_qemu_user)" || die "No QEMU runtime user found. Is libvirt-daemon-system installed?"
    qemu_group="$(get_qemu_group)" || die "No QEMU runtime group found. Is kvm/libvirt installed?"
    pool_root="$(dirname "$VM_POOL_DIR")"

    info "Preparing VM image storage directory"

    sudo install -d -o "$qemu_user" -g "$qemu_group" -m 2770 "$pool_root"
    sudo install -d -o "$qemu_user" -g "$qemu_group" -m 2770 "$VM_POOL_DIR"

    sudo chown -R "$qemu_user:$qemu_group" "$pool_root"
    sudo find "$pool_root" -type d -exec chmod 2770 {} +
    sudo find "$pool_root" -type f -exec chmod 0660 {} +

    success "VM storage permissions set: $VM_POOL_DIR"

    configure_libvirt_dir_pool "$VM_POOL_NAME" "$VM_POOL_DIR"
}

configure_backup_iso_permissions_and_pool() {
    local qemu_user qemu_group

    qemu_user="$(get_qemu_user)" || die "No QEMU runtime user found. Is libvirt-daemon-system installed?"
    qemu_group="$(get_qemu_group)" || die "No QEMU runtime group found. Is kvm/libvirt installed?"

    info "Preparing backup/ISO drive directories"

    # Keep the backup mount itself root-owned for Timeshift/root backup use.
    sudo chown root:root "$BACKUP_MOUNT"
    sudo chmod 0755 "$BACKUP_MOUNT"

    # Dedicated ISO directory: writable by the desktop user and readable by QEMU.
    sudo install -d -o "$USER" -g "$qemu_group" -m 2775 "$ISO_DIR"

    if command -v setfacl >/dev/null 2>&1; then
        sudo setfacl -m "u:${qemu_user}:rX,g:${qemu_group}:rwX" "$ISO_DIR"
        sudo setfacl -d -m "u:${qemu_user}:rX,g:${qemu_group}:rwX" "$ISO_DIR"
        success "ISO ACLs set for $qemu_user and group $qemu_group"
    else
        warn "setfacl not found; using plain Unix permissions only"
    fi

    # Do not create a Timeshift directory here. Timeshift should create and
    # manage its own backup directory structure on the selected drive.

    success "Backup/ISO directories prepared"

    configure_libvirt_dir_pool "$ISO_POOL_NAME" "$ISO_DIR"
}

# ── Role configuration ────────────────────────────────────────────────────────
configure_drive_role() {
    local role="$1"
    local label="$2"
    local mountpoint="$3"
    local selected_disk="$4"
    local choice target_dev=""

    info "Selected $role drive: $selected_disk"

    printf '\nChoose what to do with %s for %s:\n' "$selected_disk" "$role"
    printf '  1) Use existing single ext4 filesystem without formatting\n'
    printf '  2) Wipe disk and format properly as GPT + ext4\n'
    printf '  q) Skip/cancel this role\n'
    printf '\nSelection: '
    if ! read_prompt choice; then
        warn "$role setup skipped"
        return 1
    fi

    case "$choice" in
        1)
            target_dev="$(use_existing_ext4_for_role "$selected_disk" "$label" "$mountpoint" "$role")" || return 1
            ;;
        2)
            target_dev="$(format_disk_for_role "$selected_disk" "$label" "$role")" || return 1
            ;;
        q|Q)
            warn "$role setup skipped"
            return 1
            ;;
        *)
            warn "Invalid choice; $role setup skipped"
            return 1
            ;;
    esac

    [[ -n "$target_dev" ]] || die "No target filesystem selected for $role"

    check_label_conflict "$target_dev" "$label"
    ensure_fstab_label_mount "$label" "$mountpoint" ext4 "$(fstab_opts_for_mount "$mountpoint")" "$target_dev"

    return 0
}

verify_setup() {
    info "Verification"

    printf '\nMounts:\n'
    findmnt "$VM_MOUNT" 2>/dev/null || true
    findmnt "$BACKUP_MOUNT" 2>/dev/null || true

    printf '\nLibvirt pools:\n'
    sudo virsh pool-list --all || true

    printf '\nVM pool info:\n'
    sudo virsh pool-info "$VM_POOL_NAME" 2>/dev/null || true

    printf '\nISO pool info:\n'
    sudo virsh pool-info "$ISO_POOL_NAME" 2>/dev/null || true

    printf '\nDirectories:\n'
    ls -ld "$VM_POOL_DIR" 2>/dev/null || true
    ls -ld "$ISO_DIR" 2>/dev/null || true
}

# ── Main flow ─────────────────────────────────────────────────────────────────
main() {
    local root_disk
    local candidates=()
    local vm_disk=""
    local backup_disk=""
    local select_rc
    local used_csv=""
    local vm_done=0
    local backup_done=0

    ensure_packages
    ensure_libvirt_service
    ensure_user_groups

    if ! root_disk="$(get_root_disk)"; then
        local root_src=""
        root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
        warn "Root source reported by findmnt: ${root_src:-unknown}"

        root_src="${root_src%%\[*}"
        if [[ -n "$root_src" && -b "$root_src" ]]; then
            warn "Root block-device hierarchy seen by lsblk:"
            lsblk -spno NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS "$root_src" >&2 || true
        fi

        die "Could not detect the OS/root disk."
    fi

    print_drive_inventory "$root_disk"

    mapfile -t candidates < <(collect_candidate_disks "$root_disk")

    if ! print_candidate_details "${candidates[@]}"; then
        exit 0
    fi

    printf '\nThis script will never offer the OS/system disk for formatting.\n'
    printf 'For each selected extra drive, formatting requires typing an exact confirmation.\n'
    printf 'If a selected extra drive is already mounted by GNOME/Nautilus under /media, it will be unmounted before relabeling, formatting, or remounting via /etc/fstab.\n'

    set +e
    vm_disk="$(select_candidate_disk "VM image storage" "$used_csv" "${candidates[@]}")"
    select_rc=$?
    set -e

    if [[ $select_rc -eq 2 ]]; then
        warn "Quit requested"
        exit 0
    elif [[ $select_rc -eq 0 && -n "$vm_disk" ]]; then
        if configure_drive_role "VM image storage" "$VM_LABEL" "$VM_MOUNT" "$vm_disk"; then
            configure_vm_storage_permissions_and_pool
            vm_done=1
            used_csv="$vm_disk"
        fi
    else
        warn "VM image storage setup skipped"
    fi

    set +e
    backup_disk="$(select_candidate_disk "Timeshift backups + ISO files" "$used_csv" "${candidates[@]}")"
    select_rc=$?
    set -e

    if [[ $select_rc -eq 2 ]]; then
        warn "Quit requested"
        exit 0
    elif [[ $select_rc -eq 0 && -n "$backup_disk" ]]; then
        if configure_drive_role "Timeshift backups + ISO files" "$BACKUP_LABEL" "$BACKUP_MOUNT" "$backup_disk"; then
            configure_backup_iso_permissions_and_pool
            backup_done=1
        fi
    else
        warn "Backup/ISO drive setup skipped"
    fi

    verify_setup

    printf '\n'
    printf '  ────────────────────────────────────────\n'
    printf '  Storage setup complete\n'
    printf '  ────────────────────────────────────────\n'

    if [[ "$vm_done" == "1" ]]; then
        printf '  VM mount          : %s\n' "$VM_MOUNT"
        printf '  VM libvirt pool   : %s\n' "$VM_POOL_NAME"
        printf '  VM image path     : %s\n' "$VM_POOL_DIR"
    else
        printf '  VM storage        : skipped\n'
    fi

    if [[ "$backup_done" == "1" ]]; then
        printf '  Backup mount      : %s\n' "$BACKUP_MOUNT"
        printf '  ISO directory     : %s\n' "$ISO_DIR"
        printf '  ISO libvirt pool  : %s\n' "$ISO_POOL_NAME"
    else
        printf '  Backup/ISO drive  : skipped\n'
    fi

    printf '\n'
    printf '  In virt-manager:\n'
    printf '    Connect to qemu:///system, then open Edit → Connection Details → Storage.\n'
    printf '    Use %s for VM disks.\n' "$VM_POOL_NAME"
    printf '    Use %s for installation ISO files.\n' "$ISO_POOL_NAME"
    printf '\n'
    printf '  In Timeshift:\n'
    printf '    Select the backup drive/partition labeled %s.\n' "$BACKUP_LABEL"
    printf '\n'
    printf '  In Files/Nautilus:\n'
    printf '    %s and %s should appear in the Devices section after remount/re-login.\n' "$BACKUP_MOUNT" "$VM_MOUNT"
    printf '\n'
    printf '  Important:\n'
    printf '    Log out/in or reboot so libvirt/kvm group membership applies.\n'
    printf '    If a VM later fails with disk permission denied, check AppArmor: sudo dmesg | grep -i DENIED or /var/log/audit/audit.log\n'
    printf '    Custom libvirt paths can also be allowed in /etc/apparmor.d/local/abstractions/libvirt-qemu.\n'
    printf '  ────────────────────────────────────────\n'
}

main "$@"
