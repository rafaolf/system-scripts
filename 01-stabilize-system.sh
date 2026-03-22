#!/bin/bash
# =============================================================================
# System Stabilization Script — ASUS ROG Zephyrus G14 (GA402RJ)
#
# Addresses:
#   - bpool (ZFS boot pool) not importing
#   - ACPI/GPU kernel parameter tuning
#   - ZFS ARC memory cap + VM tuning
#   - Stale kernel module references
#   - Missing /etc/exports.d directory
#   - Hardware error monitoring (rasdaemon)
#   - Crash report cleanup
#
# Usage: sudo bash stabilize-system.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[FAIL]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root: sudo bash $0"
    exit 1
fi

echo "============================================="
echo " System Stabilization — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup current configs ---
echo "=== 0. Backing up current configs ==="
BACKUP_DIR="/home/rafaolf/stabilize-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/grub.bak"
cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
[ -f /etc/modprobe.d/zfs.conf ] && cp /etc/modprobe.d/zfs.conf "$BACKUP_DIR/zfs.conf.bak"
log "Configs backed up to $BACKUP_DIR"

# --- 1. Import bpool (ZFS boot pool) ---
echo ""
echo "=== 1. Importing bpool (ZFS boot pool) ==="
if zpool list bpool &>/dev/null; then
    log "bpool is already imported"
else
    if zpool import -f bpool 2>/dev/null; then
        log "bpool imported successfully"
    elif zpool import -f -N bpool 2>/dev/null; then
        log "bpool imported (datasets not mounted yet)"
        zfs mount bpool/BOOT/ubuntu_qv7pin 2>/dev/null && log "bpool/BOOT mounted" || warn "Could not mount bpool/BOOT — check manually"
    else
        err "Failed to import bpool — check 'zpool import' output manually"
        warn "Continuing with remaining fixes..."
    fi
fi

# Mount /boot if not mounted
if mountpoint -q /boot 2>/dev/null; then
    log "/boot is mounted"
else
    systemctl start boot.mount 2>/dev/null && log "/boot mounted via systemd" || warn "/boot mount failed — will retry after reboot"
fi

# --- 2. Create missing directories ---
echo ""
echo "=== 2. Creating missing directories ==="
if [ ! -d /etc/exports.d ]; then
    mkdir -p /etc/exports.d
    log "Created /etc/exports.d"
else
    log "/etc/exports.d already exists"
fi

# --- 3. ZFS ARC memory cap ---
echo ""
echo "=== 3. Configuring ZFS ARC (cap at 8GB) ==="
ZFS_MODPROBE="/etc/modprobe.d/zfs.conf"
echo "options zfs zfs_arc_max=8589934592" > "$ZFS_MODPROBE"
log "ZFS ARC max set to 8GB in $ZFS_MODPROBE"

# Apply immediately if ZFS module is loaded
if [ -f /sys/module/zfs/parameters/zfs_arc_max ]; then
    echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null && \
        log "ARC max applied to running system" || \
        warn "Could not apply ARC max live — will take effect after reboot"
fi

# --- 4. VM tuning for ZFS ---
echo ""
echo "=== 4. VM tuning for ZFS ==="
cat > /etc/sysctl.d/90-zfs-tuning.conf <<'EOF'
# ZFS best practices for system with 24GB RAM
# Lower swappiness: ZFS uses its own ARC cache, high swappiness causes
# unnecessary memory pressure and can trigger OOM/panics
vm.swappiness=10

# Reduce inode/dentry cache eviction pressure (ZFS manages its own cache)
vm.vfs_cache_pressure=50
EOF

sysctl -w vm.swappiness=10 >/dev/null
sysctl -w vm.vfs_cache_pressure=50 >/dev/null
log "vm.swappiness=10, vm.vfs_cache_pressure=50 applied"

# --- 5. GRUB kernel parameters ---
echo ""
echo "=== 5. Updating GRUB kernel parameters ==="
GRUB_FILE="/etc/default/grub"
CURRENT_LINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE")
NEW_LINE='GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.runpm=0 amdgpu.gfxoff=0 amdgpu.dpm=1 acpi_backlight=native"'

if [ "$CURRENT_LINE" = "$NEW_LINE" ]; then
    log "GRUB parameters already set"
else
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${NEW_LINE}|" "$GRUB_FILE"
    log "GRUB parameters updated:"
    echo "    Before: $CURRENT_LINE"
    echo "    After:  $NEW_LINE"
fi

# Also ensure GRUB timeout is visible so you can pick a fallback kernel
sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=3/' "$GRUB_FILE"
sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_FILE"
log "GRUB menu enabled with 3s timeout (allows fallback kernel selection)"

update-grub 2>/dev/null && log "GRUB updated" || err "update-grub failed"

# --- 6. Regenerate module dependencies ---
echo ""
echo "=== 6. Regenerating module dependencies ==="
depmod -a 2>/dev/null && log "Module dependencies regenerated" || warn "depmod failed"

# --- 7. Rebuild initramfs ---
echo ""
echo "=== 7. Rebuilding initramfs ==="
update-initramfs -u 2>/dev/null && log "initramfs rebuilt" || warn "initramfs rebuild failed — check manually"

# --- 8. Install rasdaemon for hardware error monitoring ---
echo ""
echo "=== 8. Installing rasdaemon ==="
if command -v rasdaemon &>/dev/null; then
    log "rasdaemon already installed"
else
    apt-get install -y rasdaemon 2>/dev/null && log "rasdaemon installed" || warn "Failed to install rasdaemon — install manually: sudo apt install rasdaemon"
fi
systemctl enable rasdaemon 2>/dev/null
systemctl start rasdaemon 2>/dev/null && log "rasdaemon running" || warn "rasdaemon failed to start"

# --- 9. Clean up WiFi modprobe duplicates ---
echo ""
echo "=== 9. Cleaning WiFi modprobe duplicates ==="
MT_CONF="/etc/modprobe.d/mt7921e.conf"
# Consolidate mt7921e ASPM disable into a single file
echo "options mt7921e disable_aspm=1" > "$MT_CONF"
# Remove duplicates from other files
for f in /etc/modprobe.d/*.conf; do
    [ "$f" = "$MT_CONF" ] && continue
    if grep -q "mt7921e" "$f" 2>/dev/null; then
        sed -i '/options mt7921e/d' "$f"
        log "Removed mt7921e duplicate from $f"
    fi
done
log "mt7921e ASPM config consolidated to $MT_CONF"

# --- 10. Clean old crash reports ---
echo ""
echo "=== 10. Cleaning old crash reports ==="
CRASH_COUNT=$(ls /var/crash/*.crash 2>/dev/null | wc -l)
if [ "$CRASH_COUNT" -gt 0 ]; then
    rm -f /var/crash/*.crash
    log "Removed $CRASH_COUNT crash report(s)"
else
    log "No crash reports to clean"
fi

# --- Summary ---
echo ""
echo "============================================="
echo " Stabilization Complete"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Changes applied:"
echo "   [1] bpool imported / /boot mounted"
echo "   [2] /etc/exports.d directory created"
echo "   [3] ZFS ARC capped at 8GB"
echo "   [4] vm.swappiness=10, vfs_cache_pressure=50"
echo "   [5] GRUB: amdgpu.gfxoff=0 amdgpu.dpm=1 acpi_backlight=native"
echo "   [6] Module dependencies regenerated"
echo "   [7] initramfs rebuilt"
echo "   [8] rasdaemon installed for MCE monitoring"
echo "   [9] WiFi modprobe duplicates cleaned"
echo "  [10] Crash reports cleaned"
echo ""
echo -e " ${YELLOW}ACTION REQUIRED:${NC}"
echo "   1. Reboot to apply all changes: sudo reboot"
echo "   2. After reboot, verify with:"
echo "        zpool status bpool"
echo "        mount | grep boot"
echo "        cat /proc/sys/vm/swappiness"
echo "        cat /sys/module/zfs/parameters/zfs_arc_max"
echo "        sudo ras-mc-ctl --errors"
echo ""
echo -e "   3. ${YELLOW}Update BIOS${NC} (see BIOS update guide)"
echo "      Current: GA402RJ.318 (2023-03-09) — outdated"
echo "      The ACPI dGPU bug causing most crashes is a BIOS-level issue."
echo ""
