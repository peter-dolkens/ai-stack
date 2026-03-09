#!/usr/bin/env bash
# 1-configure-drives.sh — Interactive drive → mount assignment for the AI stack
#
# Scans available drives, checks SMART status, suggests assignments based on
# speed/size, prompts for confirmation, then generates a machine-specific
# 2-mount-<hostname>.sh script.
#
# Run as regular user — uses sudo for smartctl and blkid.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
ok()     { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info()   { echo -e "  ${CYAN}→${RESET}  $*"; }

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root.${RESET}" >&2; exit 1
fi

HOSTNAME=$(hostname -s)
OUT_SCRIPT="$(dirname "$0")/2-mount-${HOSTNAME}.sh"
TMPFS_SIZE="4G"

echo -e "${BOLD}AI Stack Drive Assignment${RESET}"
echo    "────────────────────────────────────────"

# ── Target mounts ─────────────────────────────────────────────────────────────
# Format: "mountpoint|description|priority"
# priority: speed = prefer fast drives (NVMe>SSD>HDD), size = prefer large drives
TARGETS=(
    "/ai/models|Model storage (ollama, whisper, piper, frigate)|size"
    "/ai/vector-db|Vector DB / experiments|speed"
    "/ai/frigate/disk1|Frigate recordings|size"
    "/ai/frigate/disk2|Frigate clips|size"
)
# /ai/frigate/cache is always tmpfs — handled separately at the end.

# ── Identify system disks (to exclude) ───────────────────────────────────────
header "Scanning block devices"

SYS_DISKS=()
# Find disks backing critical system mounts (/, /boot, /boot/efi)
for mount_path in / /boot /boot/efi; do
    dev=$(findmnt -n -o SOURCE "$mount_path" 2>/dev/null | sed 's/\[.*\]//' || true)
    [[ -z "$dev" ]] && continue
    disk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 || true)
    [[ -n "$disk" ]] && SYS_DISKS+=("$disk")
done
# Deduplicate
readarray -t SYS_DISKS < <(printf '%s\n' "${SYS_DISKS[@]}" | sort -u)
info "System disk(s): ${SYS_DISKS[*]:-none detected}"

# ── Collect candidate drives ──────────────────────────────────────────────────
declare -a DISKS=()
declare -A DISK_SIZE_GB DISK_TYPE DISK_MODEL DISK_SMART DISK_SMART_DETAIL
declare -A DISK_PART DISK_UUID DISK_FSTYPE DISK_MOUNTPOINT DISK_SPEED_SCORE

while read -r name size_bytes rota tran model_rest; do
    # Skip non-data device types
    [[ "$name" =~ ^(loop|sr|fd|zram) ]] && continue
    [[ -z "$size_bytes" || "$size_bytes" == "0" ]] && continue

    # Skip system disks
    is_sys=false
    for s in "${SYS_DISKS[@]:-}"; do [[ "$name" == "$s" ]] && is_sys=true && break; done
    $is_sys && continue

    # Skip tiny devices (< 10 GB)
    size_gb=$(( size_bytes / 1073741824 ))
    [[ $size_gb -lt 10 ]] && continue

    DISKS+=("$name")
    DISK_SIZE_GB["$name"]=$size_gb
    DISK_MODEL["$name"]="${model_rest:-unknown}"

    # Drive type and speed score
    if [[ "${tran:-}" == "nvme" ]]; then
        DISK_TYPE["$name"]="NVMe"; DISK_SPEED_SCORE["$name"]=300
    elif [[ "${rota:-1}" == "0" ]]; then
        DISK_TYPE["$name"]="SSD";  DISK_SPEED_SCORE["$name"]=200
    else
        DISK_TYPE["$name"]="HDD";  DISK_SPEED_SCORE["$name"]=100
    fi

    # First partition (if any)
    part=$(lsblk -lno NAME,TYPE "/dev/$name" 2>/dev/null | awk '$2=="part"{print $1; exit}' || true)
    DISK_PART["$name"]="${part:-}"

    if [[ -n "$part" ]]; then
        uuid=$(sudo blkid -s UUID -o value "/dev/$part" 2>/dev/null || true)
        fstype=$(sudo blkid -s TYPE -o value "/dev/$part" 2>/dev/null || true)
        mnt=$(lsblk -no MOUNTPOINT "/dev/$part" 2>/dev/null | head -1 || true)
        DISK_UUID["$name"]="${uuid:-}"
        DISK_FSTYPE["$name"]="${fstype:-}"
        DISK_MOUNTPOINT["$name"]="${mnt:-}"
    else
        DISK_UUID["$name"]=""
        DISK_FSTYPE["$name"]=""
        DISK_MOUNTPOINT["$name"]=""
    fi

    # SMART health check
    smart_out=$(sudo smartctl -H "/dev/$name" 2>/dev/null || true)
    crc_count=$(sudo smartctl -A "/dev/$name" 2>/dev/null | awk '/CRC_Error_Count/{print $10}' || true)
    if echo "$smart_out" | grep -q "PASSED"; then
        if [[ -n "$crc_count" && "$crc_count" -gt 0 ]] 2>/dev/null; then
            DISK_SMART["$name"]="WARN"
            DISK_SMART_DETAIL["$name"]="PASSED but ${crc_count} CRC errors (check SATA cable)"
        else
            DISK_SMART["$name"]="PASSED"
            DISK_SMART_DETAIL["$name"]=""
        fi
    elif echo "$smart_out" | grep -q "FAILED"; then
        DISK_SMART["$name"]="FAILED"
        DISK_SMART_DETAIL["$name"]="SMART self-assessment FAILED"
    else
        DISK_SMART["$name"]="UNKNOWN"
        DISK_SMART_DETAIL["$name"]="could not read SMART data"
    fi

done < <(lsblk -d -b -o NAME,SIZE,ROTA,TRAN,MODEL --noheadings 2>/dev/null)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo -e "\n${RED}No candidate drives found after excluding system disk(s).${RESET}"
    exit 1
fi

# ── Drive table ───────────────────────────────────────────────────────────────
echo
printf "  %-6s  %-5s  %7s  %-8s  %-12s  %-28s\n" \
    "DISK" "TYPE" "SIZE" "SMART" "MOUNTED AT" "MODEL"
printf "  %-6s  %-5s  %7s  %-8s  %-12s  %-28s\n" \
    "──────" "─────" "───────" "──────" "────────────" "────────────────────────────"

for disk in "${DISKS[@]}"; do
    smart="${DISK_SMART[$disk]}"
    case "$smart" in
        PASSED)  smart_fmt="${GREEN}PASSED ${RESET}" ;;
        WARN)    smart_fmt="${YELLOW}WARN   ${RESET}" ;;
        FAILED)  smart_fmt="${RED}FAILED ${RESET}" ;;
        *)       smart_fmt="${DIM}UNKNOWN${RESET}" ;;
    esac
    mnt="${DISK_MOUNTPOINT[$disk]:-(none)}"
    note=""
    [[ -z "${DISK_PART[$disk]}" ]] && note=" ${YELLOW}(no partition)${RESET}"
    [[ -z "${DISK_UUID[$disk]:-}" && -n "${DISK_PART[$disk]:-}" ]] && note=" ${YELLOW}(not formatted)${RESET}"
    mnt_trunc="${mnt:0:14}"
    printf "  %-6s  %-5s  %5dGB  " "$disk" "${DISK_TYPE[$disk]}" "${DISK_SIZE_GB[$disk]}"
    echo -e "${smart_fmt}  $(printf '%-14s' "$mnt_trunc")  ${DISK_MODEL[$disk]:0:28}${note}"
    [[ -n "${DISK_SMART_DETAIL[$disk]:-}" ]] && echo -e "         ${YELLOW}⚠ ${DISK_SMART_DETAIL[$disk]}${RESET}"
done

# ── Auto-assign: sort by speed, then size ─────────────────────────────────────
header "Suggested assignments"

# Build sorted arrays
readarray -t BY_SPEED < <(
    for d in "${DISKS[@]}"; do
        [[ "${DISK_SMART[$d]}" == "FAILED" ]] && continue
        echo "${DISK_SPEED_SCORE[$d]} ${DISK_SIZE_GB[$d]} $d"
    done | sort -k1,1rn -k2,2rn | awk '{print $3}'
)

readarray -t BY_SIZE < <(
    for d in "${DISKS[@]}"; do
        [[ "${DISK_SMART[$d]}" == "FAILED" ]] && continue
        echo "${DISK_SIZE_GB[$d]} ${DISK_SPEED_SCORE[$d]} $d"
    done | sort -k1,1rn -k2,2rn | awk '{print $3}'
)

declare -A SUGGESTION
declare -a ASSIGNED=()

pick_disk() {
    local -n arr=$1
    for d in "${arr[@]}"; do
        local used=false
        for a in "${ASSIGNED[@]:-}"; do [[ "$a" == "$d" ]] && used=true && break; done
        $used && continue
        echo "$d"; return
    done
    echo ""
}

# Speed-priority mounts first, then size-priority
for pass in speed size; do
    for target in "${TARGETS[@]}"; do
        IFS='|' read -r mnt desc priority <<< "$target"
        [[ "$priority" != "$pass" ]] && continue
        [[ -v "SUGGESTION[$mnt]" ]] && continue
        if [[ "$priority" == "speed" ]]; then
            disk=$(pick_disk BY_SPEED)
        else
            disk=$(pick_disk BY_SIZE)
        fi
        SUGGESTION["$mnt"]="$disk"
        [[ -n "$disk" ]] && ASSIGNED+=("$disk")
    done
done

# ── Interactive confirmation ───────────────────────────────────────────────────
declare -A FINAL

for target in "${TARGETS[@]}"; do
    IFS='|' read -r mnt desc priority <<< "$target"
    suggested="${SUGGESTION[$mnt]:-}"

    echo
    echo -e "  ${BOLD}${mnt}${RESET}  ${DIM}— ${desc}${RESET}"

    if [[ -n "$suggested" ]]; then
        part="${DISK_PART[$suggested]:-$suggested}"
        echo -e "    Suggested: ${GREEN}${suggested}${RESET} (${DISK_TYPE[$suggested]}, ${DISK_SIZE_GB[$suggested]}GB, SMART: ${DISK_SMART[$suggested]}, /dev/${part})"
    else
        echo -e "    ${YELLOW}No drive available — would share with root disk${RESET}"
    fi

    echo
    local_idx=1
    declare -a MENU_DISKS=()
    for disk in "${DISKS[@]}"; do
        part="${DISK_PART[$disk]:-—}"
        smart="${DISK_SMART[$disk]}"
        flag=""
        [[ "$smart" == "FAILED" ]] && flag="${RED}[FAILED SMART]${RESET} "
        [[ "$smart" == "WARN"   ]] && flag="${YELLOW}[CRC errors]${RESET} "
        [[ -z "${DISK_UUID[$disk]:-}" && -n "${DISK_PART[$disk]:-}" ]] && flag+="${YELLOW}[needs format]${RESET} "
        [[ -z "${DISK_PART[$disk]:-}" ]] && flag+="${YELLOW}[needs partition]${RESET} "
        echo -e "      ${local_idx}) /dev/${disk} (/dev/${part}) — ${DISK_TYPE[$disk]}, ${DISK_SIZE_GB[$disk]}GB ${flag}"
        MENU_DISKS+=("$disk")
        local_idx=$((local_idx + 1))
    done
    echo    "      s) Skip — mount stays on root disk"
    [[ -n "$suggested" ]] && prompt="Enter/s/1-$((local_idx-1))" || prompt="s/1-$((local_idx-1))"

    while true; do
        read -r -p "    Choice [${prompt}]: " choice
        choice="${choice,,}"
        if [[ -z "$choice" && -n "$suggested" ]]; then
            FINAL["$mnt"]="$suggested"; break
        elif [[ "$choice" == "s" ]]; then
            FINAL["$mnt"]="skip"; break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < local_idx )); then
            FINAL["$mnt"]="${MENU_DISKS[$((choice-1))]}"; break
        else
            echo "    Please enter a valid option."
        fi
    done
    unset MENU_DISKS
done

# ── Validation warnings ────────────────────────────────────────────────────────
echo
header "Final plan"
echo
HAS_ISSUES=false
for target in "${TARGETS[@]}"; do
    IFS='|' read -r mnt desc priority <<< "$target"
    disk="${FINAL[$mnt]:-skip}"
    if [[ "$disk" == "skip" ]]; then
        printf "  %-26s  %s\n" "$mnt" "(skipped — on root disk)"
    else
        part="${DISK_PART[$disk]:-}"
        uuid="${DISK_UUID[$disk]:-}"
        fstype="${DISK_FSTYPE[$disk]:-}"
        issues=""
        [[ -z "$part" ]]              && issues+=" [needs partitioning]" && HAS_ISSUES=true
        [[ -n "$part" && -z "$uuid" ]] && issues+=" [needs formatting]"  && HAS_ISSUES=true
        [[ "${DISK_SMART[$disk]}" == "WARN"   ]] && issues+=" [CRC errors — check cable]"
        [[ "${DISK_SMART[$disk]}" == "FAILED" ]] && issues+=" [SMART FAILED]" && HAS_ISSUES=true
        printf "  %-26s  /dev/%-6s  %-5s  %5dGB  %s%s\n" \
            "$mnt" "${part:-$disk}" "${DISK_TYPE[$disk]}" "${DISK_SIZE_GB[$disk]}" "${fstype:-?}" "${issues}"
    fi
done
printf "  %-26s  %s\n" "/ai/frigate/cache" "tmpfs  ${TMPFS_SIZE} RAM"

if $HAS_ISSUES; then
    echo
    warn "Some drives need partitioning or formatting before use."
    warn "Partition with: sudo parted /dev/sdX mklabel gpt mkpart primary 0% 100%"
    warn "Format with:    sudo mkfs.ext4 /dev/sdX1"
fi

# ── Generate output script ─────────────────────────────────────────────────────
echo
read -r -p "Generate ${OUT_SCRIPT}? [Y/n]: " confirm
[[ "${confirm,,}" == "n" ]] && echo "Aborted." && exit 0

{
cat << HEADER
#!/usr/bin/env bash
# $(basename "$OUT_SCRIPT") — fstab setup for ${HOSTNAME}
# Generated by 1-configure-drives.sh on $(date '+%Y-%m-%d')
#
# Drive assignments:
HEADER

for target in "${TARGETS[@]}"; do
    IFS='|' read -r mnt desc priority <<< "$target"
    disk="${FINAL[$mnt]:-skip}"
    if [[ "$disk" == "skip" ]]; then
        echo "#   ${mnt}: skipped (on root disk)"
    else
        part="${DISK_PART[$disk]:-$disk}"
        echo "#   ${mnt}: /dev/${disk} (/dev/${part}) — ${DISK_TYPE[$disk]}, ${DISK_SIZE_GB[$disk]}GB"
    fi
done

cat << 'BODY'
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

WARNINGS=0; ERRORS=0; CHANGES=0
changed() { CHANGES=$((CHANGES+1)); info "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}Do not run as root.${RESET}" >&2; exit 1
fi
BODY

echo "echo -e \"\${BOLD}Drive Mount Setup — ${HOSTNAME}\${RESET}\""
echo "echo    '────────────────────────────────────────'"

echo
echo "declare -A FSTAB_ENTRIES=("

for target in "${TARGETS[@]}"; do
    IFS='|' read -r mnt desc priority <<< "$target"
    disk="${FINAL[$mnt]:-skip}"
    [[ "$disk" == "skip" ]] && continue
    part="${DISK_PART[$disk]:-}"
    uuid="${DISK_UUID[$disk]:-}"
    fstype="${DISK_FSTYPE[$disk]:-ext4}"
    if [[ -z "$uuid" ]]; then
        echo "    # WARNING: /dev/${part:-$disk} has no UUID — format it first, then update this entry"
        echo "    # [\"${mnt}\"]=\"UUID=<uuid-here>  ${mnt}  ${fstype}  defaults,nofail  0  2\""
    else
        printf '    ["%s"]="UUID=%s  %s  %s  defaults,nofail  0  2"\n' \
            "$mnt" "$uuid" "$mnt" "$fstype"
    fi
done

# Always include tmpfs
printf '    ["%s"]="%s"\n' \
    "/ai/frigate/cache" "tmpfs  /ai/frigate/cache  tmpfs  size=${TMPFS_SIZE},mode=0755,noatime  0  0"

echo ")"

cat << 'FOOTER'

header "fstab entries"
for mnt in "${!FSTAB_ENTRIES[@]}"; do
    entry="${FSTAB_ENTRIES[$mnt]}"
    if grep -qE "\s${mnt}\s" /etc/fstab 2>/dev/null; then
        ok "$mnt already in fstab"
    else
        echo "$entry" | sudo tee -a /etc/fstab > /dev/null
        changed "Added fstab entry for $mnt"
    fi
done

header "Mount point directories"
for mnt in "${!FSTAB_ENTRIES[@]}"; do
    if [[ -d "$mnt" ]]; then ok "$mnt"
    else sudo mkdir -p "$mnt"; changed "Created $mnt"
    fi
done

header "Mounts"
for mnt in "${!FSTAB_ENTRIES[@]}"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        ok "$mnt already mounted"
    elif sudo mount "$mnt" 2>/dev/null; then
        changed "Mounted $mnt"
    else
        fail "Failed to mount $mnt — check UUID and device"
    fi
done

echo
echo "────────────────────────────────────────"
[[ $ERRORS   -gt 0 ]] && echo -e "${RED}${BOLD}  $ERRORS error(s).${RESET}"
[[ $WARNINGS -gt 0 ]] && echo -e "${YELLOW}${BOLD}  $WARNINGS warning(s).${RESET}"
[[ $CHANGES  -gt 0 ]] && echo -e "${GREEN}${BOLD}  $CHANGES change(s) applied.${RESET}"
[[ $ERRORS -eq 0 && $WARNINGS -eq 0 && $CHANGES -eq 0 ]] && \
    echo -e "${GREEN}${BOLD}  All checks passed — nothing to do.${RESET}"
[[ $ERRORS -eq 0 ]]
FOOTER

} > "$OUT_SCRIPT"

chmod +x "$OUT_SCRIPT"
echo -e "\n${GREEN}${BOLD}Generated: ${OUT_SCRIPT}${RESET}"
echo
read -r -p "Run ${OUT_SCRIPT} now? [Y/n]: " run_now
if [[ "${run_now,,}" != "n" ]]; then
    bash "$OUT_SCRIPT"
else
    echo -e "Run manually: ${BOLD}${OUT_SCRIPT}${RESET}"
fi
