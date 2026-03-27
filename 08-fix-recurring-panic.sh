#!/bin/bash
# =============================================================================
# Recurring Kernel Panic Fix — ASUS ROG Zephyrus G14 (GA402RJ)
#
# Root causes identified from post-mortem analysis (2026-03-26):
#
#   1. preempt=full exposes race conditions in amdgpu + ZFS on kernel 6.17
#      → Change to preempt=voluntary (still low-latency, much safer)
#   2. ZFS ARC max 8GB leaves only ~3.9GB free on a 24GB system under load
#      → Reduce ARC max to 6GB, giving ~2GB more headroom
#   3. vm.min_free_kbytes=128MB is too tight under combined ZFS + GPU pressure
#      → Increase to 256MB to avoid direct reclaim stalls that trigger panics
#   4. Journald Compress=no + 100MB cap discards crash evidence too quickly
#      → Enable compression, raise cap, so next crash leaves a usable trace
#   5. ZFS userland (2.2.2) / kmod (2.3.4) version mismatch
#      → Upgrade userland to match kmod
#   6. amdgpu.gpu_recovery=1 only in modprobe.d — not active during early boot
#      → Add to GRUB cmdline for full coverage
#   7. Offer fallback to kernel 6.14 (already installed, much more stable)
#
# Usage: sudo bash 08-fix-recurring-panic.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root: sudo bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================="
echo " Recurring Kernel Panic Fix — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="${SCRIPT_DIR}/recurring-panic-fix-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/" 2>/dev/null
cp /etc/sysctl.d/90-zfs-tuning.conf "$BACKUP_DIR/" 2>/dev/null
cp /etc/modprobe.d/zfs.conf "$BACKUP_DIR/" 2>/dev/null
cp /etc/systemd/journald.conf "$BACKUP_DIR/" 2>/dev/null
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. GRUB: preempt=full → preempt=voluntary, add amdgpu.gpu_recovery=1
# =============================================================================
echo ""
echo "=== 1. Fixing GRUB Kernel Parameters ==="

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

echo "  Before: $CURRENT_CMDLINE"

NEW_CMDLINE="$CURRENT_CMDLINE"

# preempt=full → preempt=voluntary
# Full preemption exposes race conditions in amdgpu and ZFS on experimental kernels.
# Voluntary preemption is still low-latency for desktop use but much safer.
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/preempt=full/preempt=voluntary/')

# Add amdgpu.gpu_recovery=1 to GRUB cmdline (currently only in modprobe.d)
# This ensures GPU hang recovery is active even during early boot, before
# modprobe.d configs are loaded.
if ! echo "$NEW_CMDLINE" | grep -q "amdgpu.gpu_recovery="; then
    NEW_CMDLINE="$NEW_CMDLINE amdgpu.gpu_recovery=1"
fi

# Clean up multiple spaces
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/  */ /g' | sed 's/^ //;s/ $//')

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"

echo "  After:  $NEW_CMDLINE"
log "Changed preempt=full → preempt=voluntary (fixes race conditions in amdgpu+ZFS)"
log "Added amdgpu.gpu_recovery=1 to GRUB (GPU hang recovery from early boot)"

# =============================================================================
# 2. ZFS ARC: Reduce max from 8GB to 6GB
# =============================================================================
echo ""
echo "=== 2. Reducing ZFS ARC Max (8GB → 6GB) ==="

# With 24GB RAM, an 8GB ARC cap leaves too little headroom under heavy desktop
# workloads (browser, IDE, Docker, GPU). When free memory drops below
# min_free_kbytes, the kernel enters direct reclaim which fights with ZFS's
# own ARC eviction — this race can trigger panics on experimental kernels.
#
# 6GB ARC is still generous (default would be ~12GB / 50% of RAM) and gives
# ~2GB more breathing room.

ZFS_CONF="/etc/modprobe.d/zfs.conf"
ARC_6GB=6442450944  # 6 * 1024^3

if grep -q "zfs_arc_max=8589934592" "$ZFS_CONF"; then
    sed -i "s/zfs_arc_max=8589934592/zfs_arc_max=${ARC_6GB}/" "$ZFS_CONF"
    sed -i 's/# ARC max 8GB/# ARC max 6GB — reduced from 8GB to leave more headroom/' "$ZFS_CONF"
    log "ZFS ARC max: 8GB → 6GB"

    # Apply live
    if [ -f /sys/module/zfs/parameters/zfs_arc_max ]; then
        echo "$ARC_6GB" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null && \
            log "Applied ARC max=6GB to running system" || true
    fi
else
    warn "zfs_arc_max value unexpected in $ZFS_CONF — check manually"
fi

# =============================================================================
# 3. SYSCTL: Increase min_free_kbytes (128MB → 256MB)
# =============================================================================
echo ""
echo "=== 3. Increasing min_free_kbytes (128MB → 256MB) ==="

# 128MB min_free_kbytes was insufficient under combined ZFS + GPU + desktop
# memory pressure. 256MB ensures the kernel has enough free pages to avoid
# entering direct reclaim, which on experimental kernels can deadlock with
# ZFS's ARC eviction path.

SYSCTL_FILE="/etc/sysctl.d/90-zfs-tuning.conf"

if grep -q "vm.min_free_kbytes = 131072" "$SYSCTL_FILE"; then
    sed -i 's/vm.min_free_kbytes = 131072/vm.min_free_kbytes = 262144/' "$SYSCTL_FILE"
    sed -i 's/# Increase min free memory to 128MB.*/# Increase min free memory to 256MB — avoids direct reclaim stalls under ZFS+GPU pressure/' "$SYSCTL_FILE"
    sysctl -w vm.min_free_kbytes=262144 >/dev/null 2>&1
    log "min_free_kbytes: 128MB → 256MB"
else
    CURRENT_MIN=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
    if [ "$CURRENT_MIN" -lt 262144 ] 2>/dev/null; then
        sed -i "s/vm.min_free_kbytes = .*/vm.min_free_kbytes = 262144/" "$SYSCTL_FILE"
        sysctl -w vm.min_free_kbytes=262144 >/dev/null 2>&1
        log "min_free_kbytes updated to 256MB (was ${CURRENT_MIN}KB)"
    else
        log "min_free_kbytes already >= 256MB"
    fi
fi

# =============================================================================
# 4. JOURNALD: Enable compression + increase cap for crash evidence
# =============================================================================
echo ""
echo "=== 4. Fixing Journald Configuration ==="

# With Compress=no and 100MB cap, crash-related log bursts get discarded
# before they can be analyzed. Enable compression and raise the cap so the
# next crash leaves a usable trace.

JOURNALD_CONF="/etc/systemd/journald.conf"

# Enable compression (was explicitly disabled)
if grep -q "^Compress=no" "$JOURNALD_CONF"; then
    sed -i 's/^Compress=no/Compress=yes/' "$JOURNALD_CONF"
    log "Journald compression re-enabled"
fi

# Raise SystemMaxUse from 100MB to 250MB (compressed, so ~500MB equivalent)
if grep -q "^SystemMaxUse=100M" "$JOURNALD_CONF"; then
    sed -i 's/^SystemMaxUse=100M/SystemMaxUse=250M/' "$JOURNALD_CONF"
    log "Journald max size: 100MB → 250MB (compressed)"
fi

# Raise SystemMaxFileSize from 16MB to 32MB for better single-boot coverage
if grep -q "^SystemMaxFileSize=16M" "$JOURNALD_CONF"; then
    sed -i 's/^SystemMaxFileSize=16M/SystemMaxFileSize=32M/' "$JOURNALD_CONF"
    log "Journald max file size: 16MB → 32MB"
fi

# Restart journald to pick up changes
systemctl restart systemd-journald 2>/dev/null && \
    log "Journald restarted with new config" || \
    warn "Could not restart journald (will apply on next boot)"

# =============================================================================
# 5. ZFS USERLAND: Upgrade to match kernel module
# =============================================================================
echo ""
echo "=== 5. Checking ZFS Version Compatibility ==="

ZFS_KMOD_VER=$(cat /sys/module/zfs/version 2>/dev/null | cut -d- -f1)
ZFS_USER_VER=$(dpkg -l zfsutils-linux 2>/dev/null | awk '/^ii/{print $3}' | cut -d- -f1)

info "ZFS kernel module: $ZFS_KMOD_VER"
info "ZFS userland:      $ZFS_USER_VER"

if [ "$(echo "$ZFS_KMOD_VER" | cut -d. -f1-2)" != "$(echo "$ZFS_USER_VER" | cut -d. -f1-2)" ]; then
    warn "ZFS version mismatch detected (kmod ${ZFS_KMOD_VER} vs userland ${ZFS_USER_VER})"
    info "Attempting to upgrade ZFS userland to match kernel module..."

    # Try to install the matching userland package
    apt-get update -qq 2>/dev/null
    if apt-cache show "zfsutils-linux" 2>/dev/null | grep -q "Version.*2\.3"; then
        apt-get install -y zfsutils-linux 2>/dev/null && \
            log "ZFS userland upgraded — run 'zfs version' to verify" || \
            warn "Could not auto-upgrade ZFS userland — upgrade manually with: sudo apt install zfsutils-linux"
    else
        warn "No matching ZFS 2.3.x userland available in repos"
        warn "This version mismatch can cause panics during pool operations"
        warn "Consider: sudo apt install zfsutils-linux/noble-updates"
    fi
else
    log "ZFS versions are compatible"
fi

# =============================================================================
# 6. UPDATE GRUB + REBUILD INITRAMFS
# =============================================================================
echo ""
echo "=== 6. Updating GRUB + Rebuilding Initramfs ==="

update-grub 2>/dev/null && log "GRUB updated" || err "update-grub failed"
update-initramfs -u 2>/dev/null && log "Initramfs rebuilt" || warn "Initramfs rebuild failed"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Recurring Panic Fixes Applied"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Root causes addressed:"
echo "   [1] GRUB: preempt=full → preempt=voluntary (fixes amdgpu+ZFS race conditions)"
echo "   [2] GRUB: Added amdgpu.gpu_recovery=1 (GPU hang recovery from early boot)"
echo "   [3] ZFS ARC: 8GB → 6GB (frees ~2GB for kernel/desktop headroom)"
echo "   [4] sysctl: min_free_kbytes 128MB → 256MB (prevents direct reclaim stalls)"
echo "   [5] journald: compression on, cap raised (preserves crash evidence)"
echo "   [6] ZFS userland: checked/upgraded to match kernel module"
echo ""
echo -e " ${YELLOW}ACTION REQUIRED:${NC}"
echo "   1. Reboot to apply GRUB + initramfs changes:"
echo "        sudo reboot"
echo ""
echo "   2. After reboot, verify:"
echo "        cat /proc/cmdline                              # preempt=voluntary, gpu_recovery=1"
echo "        cat /proc/sys/vm/min_free_kbytes               # should be 262144"
echo "        cat /sys/module/zfs/parameters/zfs_arc_max     # should be 6442450944"
echo "        zfs version                                    # kmod and userland should match"
echo ""
echo -e " ${YELLOW}IF PANICS CONTINUE:${NC}"
echo "   The most reliable fix is to fall back to kernel 6.14 (already installed)."
echo "   Kernel 6.17 is bleeding-edge and has known amdgpu regressions."
echo ""
echo "   To boot into kernel 6.14:"
echo "     1. During boot, hold SHIFT to open GRUB menu"
echo "     2. Select 'Advanced options for Ubuntu'"
echo "     3. Select 'Ubuntu, with Linux 6.14.0-37-generic'"
echo ""
echo "   To make kernel 6.14 the default permanently:"
echo "     sudo sed -i 's/^GRUB_DEFAULT=0/GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux 6.14.0-37-generic\"/' /etc/default/grub"
echo "     sudo update-grub"
echo ""
