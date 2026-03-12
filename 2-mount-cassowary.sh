#!/usr/bin/env bash
# 2-mount-cassowary.sh — fstab setup for cassowary (Ryzen 5800X / RTX 3090)
#
# Drives:
#   sda (860 EVO 1TB) → /ai/frigate/disk1   Frigate recordings
#   sdc (860 EVO 1TB) → /ai/frigate/disk2   Frigate clips
#   sde (860 EVO 1TB) → /ai/models          Model storage (ollama, whisper, piper, frigate)
#   sdb (850 EVO 500GB) → /ai/vector-db     Vector DB / experiments
#   tmpfs (4GB RAM)   → /ai/frigate/cache   Frigate segment cache
#
# Run as regular user — uses sudo for privileged steps.
# Safe to re-run; only adds missing fstab entries and mounts unmounted paths.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; WARNINGS=$((WARNINGS+1)); }
info()   { echo -e "  ${CYAN}→${RESET}  $*"; }
fail()   { echo -e "  ${RED}✗${RESET}  $*"; ERRORS=$((ERRORS+1)); }
header() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

WARNINGS=0
ERRORS=0
CHANGES=0
changed() { CHANGES=$((CHANGES+1)); info "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root. Run as your regular user.${RESET}" >&2
    exit 1
fi

echo -e "${BOLD}Drive Mount Setup — cassowary${RESET}"
echo    "────────────────────────────────────────"

# ── btrfs subvolumes on nvme1 ─────────────────────────────────────────────────
# Format: mountpoint → "subvol=@name uid:gid"
# Subvolumes are created on nvme1 if missing, then mounted and chowned.
NVME1_UUID="0365efd4-03e8-4a09-a513-a203cb762246"

declare -A BTRFS_SUBVOLS=(
    ["/ai/prometheus/data"]="@prometheus 65534:65534"
    ["/ai/grafana/data"]="@grafana 472:472"
)

header "btrfs subvolumes (nvme1)"

# Temporarily mount the nvme1 root to create missing subvolumes
BTRFS_TMP=$(mktemp -d)
sudo mount -t btrfs -o subvolid=5 "UUID=${NVME1_UUID}" "$BTRFS_TMP" 2>/dev/null

for mnt in "${!BTRFS_SUBVOLS[@]}"; do
    read -r subvol _owner <<< "${BTRFS_SUBVOLS[$mnt]}"
    if [[ -d "${BTRFS_TMP}/${subvol}" ]]; then
        ok "subvolume ${subvol} exists"
    else
        sudo btrfs subvolume create "${BTRFS_TMP}/${subvol}" > /dev/null
        changed "Created btrfs subvolume ${subvol}"
    fi
done

sudo umount "$BTRFS_TMP"
rmdir "$BTRFS_TMP"

# fstab entries for btrfs subvolumes
for mnt in "${!BTRFS_SUBVOLS[@]}"; do
    read -r subvol _owner <<< "${BTRFS_SUBVOLS[$mnt]}"
    entry="UUID=${NVME1_UUID}  ${mnt}  btrfs  subvol=${subvol},defaults,nofail,noatime  0  0"
    if grep -qE "\s${mnt}\s" /etc/fstab 2>/dev/null; then
        ok "${mnt} already in fstab"
    else
        echo "$entry" | sudo tee -a /etc/fstab > /dev/null
        changed "Added fstab entry for ${mnt}"
    fi
done

# Mount point directories, mount, and ownership
for mnt in "${!BTRFS_SUBVOLS[@]}"; do
    read -r _subvol owner <<< "${BTRFS_SUBVOLS[$mnt]}"
    [[ -d "$mnt" ]] || { sudo mkdir -p "$mnt"; changed "Created $mnt"; }
    if mountpoint -q "$mnt" 2>/dev/null; then
        ok "$mnt already mounted"
    else
        if sudo mount "$mnt" 2>/dev/null; then
            changed "Mounted $mnt"
        else
            fail "Failed to mount $mnt"
        fi
    fi
    # Fix ownership on the mounted subvolume root
    current_owner=$(stat -c '%u:%g' "$mnt")
    if [[ "$current_owner" != "$owner" ]]; then
        sudo chown "$owner" "$mnt"
        changed "Set ownership ${owner} on $mnt"
    fi
done

# ── fstab entries ─────────────────────────────────────────────────────────────
# Format: UUID  mountpoint  fstype  options  dump  pass
declare -A FSTAB_ENTRIES=(
    ["/ai/frigate/disk1"]="UUID=7f8d15c8-f30b-4e0a-89e5-8d9a5736b8f5  /ai/frigate/disk1  ext4  defaults,nofail  0  2"
    ["/ai/frigate/disk2"]="UUID=4c8fd2b0-c327-4d2b-9697-00322090320d  /ai/frigate/disk2  ext4  defaults,nofail  0  2"
    ["/ai/models"]="UUID=e781a8b4-b811-471c-aaa4-73c975099844  /ai/models         ext4  defaults,nofail  0  2"
    ["/ai/vector-db"]="UUID=590482e5-77db-4cb3-bbcb-907d5c6ae5de  /ai/vector-db      ext4  defaults,nofail  0  2"
    ["/ai/frigate/cache"]="tmpfs  /ai/frigate/cache  tmpfs  size=4G,mode=0755,noatime  0  0"
)

header "fstab entries"

for mnt in "${!FSTAB_ENTRIES[@]}"; do
    entry="${FSTAB_ENTRIES[$mnt]}"
    # Match on mount point — grep for the path as a field
    if grep -qE "\s${mnt}\s" /etc/fstab 2>/dev/null; then
        ok "$mnt already in fstab"
    else
        echo "$entry" | sudo tee -a /etc/fstab > /dev/null
        changed "Added fstab entry for $mnt"
    fi
done

# ── Mount point directories ───────────────────────────────────────────────────
header "Mount point directories"

for mnt in "${!FSTAB_ENTRIES[@]}"; do
    if [[ -d "$mnt" ]]; then
        ok "$mnt"
    else
        sudo mkdir -p "$mnt"
        changed "Created $mnt"
    fi
done

# ── Mount all ─────────────────────────────────────────────────────────────────
header "Mounts"

for mnt in "${!FSTAB_ENTRIES[@]}"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        ok "$mnt already mounted"
    else
        if sudo mount "$mnt" 2>/dev/null; then
            changed "Mounted $mnt"
        else
            fail "Failed to mount $mnt — check UUID and device"
        fi
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}${BOLD}  $ERRORS error(s) — manual action required.${RESET}"
fi
if [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}  $WARNINGS warning(s).${RESET}"
fi
if [[ $CHANGES -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}  $CHANGES change(s) applied.${RESET}"
fi
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 && $CHANGES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All checks passed — nothing to do.${RESET}"
fi

[[ $ERRORS -eq 0 ]]
