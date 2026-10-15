#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

SWAP_FILE="/swapfile"
LOCK_FILE="/run/setup-swap.lock"

# Minimum RAM we want to keep available when doing swapoff.
RAM_SAFETY_MB=256

# Extra disk-space safety margin.
DISK_SAFETY_MB=256

# ============================================================
# Logging / error handling
# ============================================================

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [[ -n "${TEMP_FILE:-}" && -e "${TEMP_FILE:-}" ]] &&
        rm -f -- "$TEMP_FILE" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# Usage
# ============================================================

usage() {
    cat <<EOF

Usage:
    sudo $0 <size>

Examples:
    sudo $0 4G
    sudo $0 8G
    sudo $0 4096M
    sudo $0 1024M

The argument represents the DESIRED final swap size.

Examples:
    4G  -> create/resize swap to 4G
    8G  -> create/resize swap to 8G
    2G  -> shrink swap to 2G

EOF
    exit 2
}

# ============================================================
# Argument validation
# ============================================================

[[ $# -eq 1 ]] || usage

REQUESTED_SIZE="$1"

if [[ ! "$REQUESTED_SIZE" =~ ^[1-9][0-9]*([MG])$ ]]; then
    die "Invalid size '$REQUESTED_SIZE'. Use formats such as 512M, 4G or 8G."
fi

# ============================================================
# Root check
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    die "Run this script with sudo/root."
fi

# ============================================================
# Required commands
# ============================================================

REQUIRED_COMMANDS=(
    awk
    df
    free
    grep
    mkswap
    swapon
    swapoff
    stat
    rm
    chmod
    mktemp
    flock
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command '$cmd' not found."
done

# ============================================================
# Single-instance lock
# ============================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    die "Another swap resize operation is already running."
fi

# ============================================================
# Convert requested size to MiB / bytes
# ============================================================

NUMBER="${REQUESTED_SIZE%[MG]}"
UNIT="${REQUESTED_SIZE: -1}"

if [[ "$UNIT" == "G" ]]; then
    REQUESTED_MB=$((NUMBER * 1024))
else
    REQUESTED_MB=$NUMBER
fi

REQUESTED_BYTES=$((REQUESTED_MB * 1024 * 1024))

# ============================================================
# Basic sanity check
# ============================================================

if (( REQUESTED_MB < 1 )); then
    die "Requested swap size must be at least 1M."
fi

# ============================================================
# Detect existing swapfile
# ============================================================

FILE_EXISTS=0
CURRENT_FILE_BYTES=0
CURRENT_FILE_MB=0

if [[ -e "$SWAP_FILE" ]]; then

    if [[ ! -f "$SWAP_FILE" ]]; then
        die "$SWAP_FILE exists but is not a regular file."
    fi

    FILE_EXISTS=1

    CURRENT_FILE_BYTES=$(stat -c '%s' "$SWAP_FILE")
    CURRENT_FILE_MB=$((CURRENT_FILE_BYTES / 1024 / 1024))
fi

# ============================================================
# Detect active swap
# ============================================================

SWAP_ACTIVE=0
ACTIVE_SWAP_BYTES=0
USED_SWAP_BYTES=0

while read -r NAME TYPE SIZE USED PRIO; do

    [[ "$NAME" == "$SWAP_FILE" ]] || continue

    SWAP_ACTIVE=1
    ACTIVE_SWAP_BYTES="${SIZE:-0}"
    USED_SWAP_BYTES="${USED:-0}"

done < <(
    swapon \
        --show=NAME,TYPE,SIZE,USED,PRIO \
        --bytes \
        --noheadings 2>/dev/null || true
)

# ============================================================
# Consistency checks
# ============================================================

if (( SWAP_ACTIVE == 1 && FILE_EXISTS == 0 )); then
    die "$SWAP_FILE is reported as active swap, but the file does not exist. Refusing to modify swap."
fi

# ============================================================
# Display current state
# ============================================================

echo
echo "=========================================="
echo "          Swap Configuration"
echo "=========================================="
echo "Swap file:       $SWAP_FILE"
echo "Current file:    ${CURRENT_FILE_MB} MiB"
echo "Active:          $([[ $SWAP_ACTIVE -eq 1 ]] && echo yes || echo no)"
echo "Used swap:       $((USED_SWAP_BYTES / 1024 / 1024)) MiB"
echo "Requested:       ${REQUESTED_MB} MiB"
echo "=========================================="
echo

# ============================================================
# Already correct
# ============================================================

if (( FILE_EXISTS == 1 &&
      SWAP_ACTIVE == 1 &&
      CURRENT_FILE_BYTES == REQUESTED_BYTES )); then

    log "Swap is already configured at $REQUESTED_SIZE."

    echo
    swapon --show
    echo
    free -h

    exit 0
fi

# ============================================================
# Determine filesystem containing swapfile
# ============================================================

if [[ -e "$SWAP_FILE" ]]; then
    DF_TARGET="$SWAP_FILE"
else
    DF_TARGET="/"
fi

AVAILABLE_KB=$(df -Pk -- "$DF_TARGET" |
    awk 'NR==2 {print $4}')

if [[ ! "$AVAILABLE_KB" =~ ^[0-9]+$ ]]; then
    die "Unable to determine available disk space."
fi

AVAILABLE_MB=$((AVAILABLE_KB / 1024))

# ============================================================
# Determine whether we need resize/create
# ============================================================

NEED_RECREATE=1

# ============================================================
# For an existing active swapfile, we need swapoff.
# Before doing that, ensure enough available RAM.
# ============================================================

if (( SWAP_ACTIVE == 1 )); then

    USED_SWAP_MB=$((USED_SWAP_BYTES / 1024 / 1024))

    if (( USED_SWAP_MB > 0 )); then

        AVAILABLE_RAM_KB=$(free -k |
            awk '/^Mem:/ {print $7}')

        if [[ ! "$AVAILABLE_RAM_KB" =~ ^[0-9]+$ ]]; then
            die "Unable to determine available RAM."
        fi

        AVAILABLE_RAM_MB=$((AVAILABLE_RAM_KB / 1024))

        REQUIRED_RAM_MB=$((USED_SWAP_MB + RAM_SAFETY_MB))

        log "Available RAM: ${AVAILABLE_RAM_MB} MiB"
        log "Swap currently used: ${USED_SWAP_MB} MiB"
        log "RAM required for swapoff safety check: ${REQUIRED_RAM_MB} MiB"

        if (( AVAILABLE_RAM_MB < REQUIRED_RAM_MB )); then

            die "Not enough available RAM to safely disable swap.

Available RAM:       ${AVAILABLE_RAM_MB} MiB
Used swap:           ${USED_SWAP_MB} MiB
Required safety RAM: ${REQUIRED_RAM_MB} MiB

The swapfile has NOT been modified."
        fi
    fi
fi

# ============================================================
# Disk-space logic
#
# Important:
#
# If an old swapfile exists, we can remove it before creating
# the new one.
#
# Therefore we calculate the final available space rather
# than requiring old + new swap simultaneously.
# ============================================================

OLD_FILE_MB=0

if (( FILE_EXISTS == 1 )); then
    OLD_FILE_MB=$CURRENT_FILE_MB
fi

# After removing the old swapfile:
FINAL_AVAILABLE_MB=$((AVAILABLE_MB + OLD_FILE_MB))

REQUIRED_DISK_MB=$((REQUESTED_MB + DISK_SAFETY_MB))

log "Current free disk: ${AVAILABLE_MB} MiB"
log "Recoverable old swap space: ${OLD_FILE_MB} MiB"
log "Estimated final free disk: ${FINAL_AVAILABLE_MB} MiB"
log "Required: ${REQUIRED_DISK_MB} MiB"

if (( FINAL_AVAILABLE_MB < REQUIRED_DISK_MB )); then

    die "Insufficient disk space.

Requested swap:       ${REQUESTED_MB} MiB
Disk safety margin:   ${DISK_SAFETY_MB} MiB
Required:             ${REQUIRED_DISK_MB} MiB
Available after old swap removal:
                      ${FINAL_AVAILABLE_MB} MiB

The existing swapfile has NOT been modified."
fi

# ============================================================
# Prepare rollback
# ============================================================

BACKUP_FILE=""

if (( FILE_EXISTS == 1 )); then
    BACKUP_FILE="${SWAP_FILE}.backup.$$"

    log "Creating temporary backup reference..."

    # Hard-link where possible.
    # This does not duplicate the disk contents.
    if ! ln "$SWAP_FILE" "$BACKUP_FILE" 2>/dev/null; then
        BACKUP_FILE=""
    fi
fi

# ============================================================
# Disable active swap
# ============================================================

if (( SWAP_ACTIVE == 1 )); then

    log "Disabling current swap..."

    if ! swapoff "$SWAP_FILE"; then
        [[ -n "$BACKUP_FILE" ]] && rm -f -- "$BACKUP_FILE" || true

        die "swapoff failed.

The existing swapfile has NOT been deleted."
    fi

    SWAP_ACTIVE=0
fi

# ============================================================
# Remove old swapfile
# ============================================================

if (( FILE_EXISTS == 1 )); then

    log "Removing old swapfile..."

    if ! rm -f -- "$SWAP_FILE"; then

        # Restore via hard link if available.
        if [[ -n "$BACKUP_FILE" && -e "$BACKUP_FILE" ]]; then
            mv "$BACKUP_FILE" "$SWAP_FILE" || true
            chmod 600 "$SWAP_FILE" || true
            swapon "$SWAP_FILE" || true
        fi

        die "Failed to remove old swapfile."
    fi
fi

# ============================================================
# Create new swapfile
# ============================================================

log "Creating new swapfile: $REQUESTED_SIZE"

CREATE_FAILED=0

if command -v fallocate >/dev/null 2>&1; then

    if ! fallocate -l "$REQUESTED_BYTES" "$SWAP_FILE"; then
        CREATE_FAILED=1
    fi

else

    log "fallocate unavailable; using dd."

    if ! dd \
        if=/dev/zero \
        of="$SWAP_FILE" \
        bs=1M \
        count="$REQUESTED_MB" \
        status=progress \
        conv=fsync; then

        CREATE_FAILED=1
    fi

fi

# ============================================================
# Creation failure
# ============================================================

if (( CREATE_FAILED == 1 )); then

    rm -f -- "$SWAP_FILE" || true

    # Restore old swapfile if possible.
    if [[ -n "$BACKUP_FILE" && -e "$BACKUP_FILE" ]]; then

        log "Attempting to restore previous swapfile..."

        mv "$BACKUP_FILE" "$SWAP_FILE" || true
        chmod 600 "$SWAP_FILE" || true

        if swapon "$SWAP_FILE" 2>/dev/null; then
            log "Previous swapfile restored."
        else
            warn "Previous swapfile was restored but could not be activated."
        fi
    fi

    die "Failed to create the new swapfile."
fi

# ============================================================
# Secure permissions
# ============================================================

chmod 600 "$SWAP_FILE"

# ============================================================
# Format as swap
# ============================================================

log "Formatting swapfile..."

if ! mkswap "$SWAP_FILE" >/dev/null; then

    rm -f -- "$SWAP_FILE"

    if [[ -n "$BACKUP_FILE" && -e "$BACKUP_FILE" ]]; then
        mv "$BACKUP_FILE" "$SWAP_FILE" || true
        chmod 600 "$SWAP_FILE" || true
        swapon "$SWAP_FILE" || true
    fi

    die "mkswap failed."
fi

# ============================================================
# Activate new swap
# ============================================================

log "Activating new swap..."

if ! swapon "$SWAP_FILE"; then

    rm -f -- "$SWAP_FILE"

    if [[ -n "$BACKUP_FILE" && -e "$BACKUP_FILE" ]]; then
        mv "$BACKUP_FILE" "$SWAP_FILE" || true
        chmod 600 "$SWAP_FILE" || true
        swapon "$SWAP_FILE" || true
    fi

    die "swapon failed."
fi

# ============================================================
# Remove backup
# ============================================================

if [[ -n "$BACKUP_FILE" && -e "$BACKUP_FILE" ]]; then
    rm -f -- "$BACKUP_FILE"
fi

# ============================================================
# Update /etc/fstab safely
# ============================================================

if [[ ! -f /etc/fstab ]]; then
    die "/etc/fstab does not exist."
fi

TEMP_FILE=$(mktemp /etc/fstab.swap.XXXXXX)

# Preserve all existing entries except old /swapfile entries.
awk -v sf="$SWAP_FILE" '
    $0 ~ "^[[:space:]]*" sf "([[:space:]]|$)" {
        next
    }
    {
        print
    }
' /etc/fstab > "$TEMP_FILE"

printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> "$TEMP_FILE"

# Preserve original permissions.
chmod --reference=/etc/fstab "$TEMP_FILE" 2>/dev/null || true

# Replace fstab atomically.
mv "$TEMP_FILE" /etc/fstab

TEMP_FILE=""

# ============================================================
# Final verification
# ============================================================

if ! swapon --show=NAME --noheadings |
    grep -Fxq "$SWAP_FILE"; then

    die "Final verification failed: swapfile is not active."
fi

FINAL_SIZE_BYTES=$(stat -c '%s' "$SWAP_FILE")
FINAL_SIZE_MB=$((FINAL_SIZE_BYTES / 1024 / 1024))

if (( FINAL_SIZE_BYTES != REQUESTED_BYTES )); then
    die "Final swap size mismatch.

Expected: ${REQUESTED_MB} MiB
Actual:   ${FINAL_SIZE_MB} MiB"
fi

echo
echo "=========================================="
echo "       SWAP CONFIGURATION SUCCESS"
echo "=========================================="
echo
echo "Swap file:"
echo "  $SWAP_FILE"
echo
echo "Configured size:"
echo "  $FINAL_SIZE_MB MiB"
echo
echo "Active swap:"
swapon --show
echo
echo "Memory:"
free -h
echo
echo "fstab:"
grep -F "$SWAP_FILE" /etc/fstab
echo
echo "=========================================="
