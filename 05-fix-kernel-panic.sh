#!/bin/bash
# =============================================================================
# Kernel Panic Fix Script — ASUS ROG Zephyrus G14 (GA402RJ)
#
# Fixes root causes identified from kernel-panic-prevboot.log:
#   1. Re-enable CPU mitigations (MCE errors need graceful handling)
#   2. Re-enable NMI watchdog (captures panic traces on lockup)
#   3. Restore dGPU runtime PM guard (ACPI bug still present on BIOS 319)
#   4. Fix ZFS txg_timeout (was doubled instead of reduced)
#   5. Fix broken NVMe udev rule (matched partitions, not device)
#   6. Fix broken CPU EPP udev rule (shell glob vs udev substitution)
#   7. Restore watermark_boost_factor (was 0, needs to be >0 for ZFS)
#   8. Enable AMD GPU hang recovery (gpu_recovery=1)
#   9. Install kdump-tools for post-panic vmcore capture
#  10. Rebuild initramfs + update GRUB
#
# Usage: sudo bash 05-fix-kernel-panic.sh
# =============================================================================

set -uo pipefail

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================="
echo " Kernel Panic Fix — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="${SCRIPT_DIR}/panic-fix-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/"
cp /etc/sysctl.d/90-zfs-tuning.conf "$BACKUP_DIR/"
cp /etc/modprobe.d/zfs.conf "$BACKUP_DIR/"
cp /etc/udev/rules.d/60-nvme-scheduler.rules "$BACKUP_DIR/"
cp /etc/udev/rules.d/99-cpu-epp-power.rules "$BACKUP_DIR/"
[ -f /etc/modprobe.d/amdgpu-fix.conf ] && cp /etc/modprobe.d/amdgpu-fix.conf "$BACKUP_DIR/"
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. GRUB: Remove mitigations=off, nowatchdog; add amdgpu.runpm=0
# =============================================================================
echo ""
echo "=== 1. Fixing GRUB Kernel Parameters ==="

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

echo "  Before: $CURRENT_CMDLINE"

# Remove dangerous parameters
NEW_CMDLINE="$CURRENT_CMDLINE"
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/mitigations=off//')
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/nowatchdog//')

# Add dGPU safety guards (ACPI bug still present on BIOS 319)
if ! echo "$NEW_CMDLINE" | grep -q "amdgpu.runpm="; then
    NEW_CMDLINE="$NEW_CMDLINE amdgpu.runpm=0"
fi
if ! echo "$NEW_CMDLINE" | grep -q "amdgpu.gfxoff="; then
    NEW_CMDLINE="$NEW_CMDLINE amdgpu.gfxoff=0"
fi

# Clean up multiple spaces
NEW_CMDLINE=$(echo "$NEW_CMDLINE" | sed 's/  */ /g' | sed 's/^ //;s/ $//')

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"

echo "  After:  $NEW_CMDLINE"
log "Removed mitigations=off and nowatchdog"
log "Added amdgpu.runpm=0 amdgpu.gfxoff=0 (dGPU ACPI bug still present on BIOS 319)"

# =============================================================================
# 2. SYSCTL: Re-enable NMI watchdog, fix watermark_boost_factor
# =============================================================================
echo ""
echo "=== 2. Fixing sysctl Parameters ==="

SYSCTL_FILE="/etc/sysctl.d/90-zfs-tuning.conf"

# Fix kernel.nmi_watchdog: 0 -> 1
if grep -q "kernel.nmi_watchdog = 0" "$SYSCTL_FILE"; then
    sed -i 's/kernel.nmi_watchdog = 0/kernel.nmi_watchdog = 1/' "$SYSCTL_FILE"
    # Update the comment too
    sed -i 's/# Disable NMI watchdog.*/# NMI watchdog enabled — required to capture panic traces on lockup/' "$SYSCTL_FILE"
    sysctl -w kernel.nmi_watchdog=1 >/dev/null 2>&1
    log "NMI watchdog re-enabled (kernel.nmi_watchdog=1)"
else
    warn "kernel.nmi_watchdog not found in $SYSCTL_FILE — checking value"
    CURRENT_NMI=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)
    if [ "$CURRENT_NMI" = "0" ]; then
        echo "" >> "$SYSCTL_FILE"
        echo "# NMI watchdog enabled — required to capture panic traces on lockup" >> "$SYSCTL_FILE"
        echo "kernel.nmi_watchdog = 1" >> "$SYSCTL_FILE"
        sysctl -w kernel.nmi_watchdog=1 >/dev/null 2>&1
        log "NMI watchdog re-enabled"
    else
        log "NMI watchdog already enabled ($CURRENT_NMI)"
    fi
fi

# Fix watermark_boost_factor: 0 -> 15000 (kernel default)
if grep -q "vm.watermark_boost_factor = 0" "$SYSCTL_FILE"; then
    sed -i 's/vm.watermark_boost_factor = 0/vm.watermark_boost_factor = 15000/' "$SYSCTL_FILE"
    # Update the comment
    sed -i 's/# Reduce watermark boost.*/# Watermark boost at kernel default — needed for ZFS memory pressure handling/' "$SYSCTL_FILE"
    sysctl -w vm.watermark_boost_factor=15000 >/dev/null 2>&1
    log "watermark_boost_factor restored to 15000 (kernel default)"
else
    log "watermark_boost_factor already non-zero"
fi

# =============================================================================
# 3. ZFS MODPROBE: Fix txg_timeout (10 -> 5)
# =============================================================================
echo ""
echo "=== 3. Fixing ZFS Module Parameters ==="

ZFS_CONF="/etc/modprobe.d/zfs.conf"

if grep -q "zfs_txg_timeout=10" "$ZFS_CONF"; then
    sed -i 's/zfs_txg_timeout=10/zfs_txg_timeout=5/' "$ZFS_CONF"
    sed -i 's/# Reduce TXG timeout for snappier sync writes (default 5s)/# TXG timeout at default 5s — safe for ZFS on experimental kernel/' "$ZFS_CONF"
    log "ZFS txg_timeout fixed: 10 -> 5 (was incorrectly doubled)"
    # Apply live if possible
    if [ -f /sys/module/zfs/parameters/zfs_txg_timeout ]; then
        echo 5 > /sys/module/zfs/parameters/zfs_txg_timeout 2>/dev/null && \
            log "Applied zfs_txg_timeout=5 to running system" || true
    fi
else
    log "zfs_txg_timeout already correct"
fi

# =============================================================================
# 4. FIX NVMe UDEV RULE (was matching partitions, not just the device)
# =============================================================================
echo ""
echo "=== 4. Fixing NVMe udev Rule ==="

cat > /etc/udev/rules.d/60-nvme-scheduler.rules <<'EOF'
# NVMe: no I/O scheduler (ZFS has its own), no read-ahead (ZFS prefetches)
# Match only the whole disk device (nvme0n1), not partitions (nvme0n1p*)
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="0"
EOF

log "NVMe udev rule fixed (now targets disk devices only, not partitions)"

# =============================================================================
# 5. FIX CPU EPP UDEV RULE (shell glob conflicts with udev substitution)
# =============================================================================
echo ""
echo "=== 5. Fixing CPU EPP udev Rule ==="

# Create a helper script that udev calls (avoids glob-in-udev-rule problem)
cat > /usr/local/bin/set-cpu-epp <<'SCRIPT'
#!/bin/bash
# Set CPU energy_performance_preference for all cores
# Usage: set-cpu-epp <mode>
# Modes: balance_performance, balance_power, performance, power
MODE="${1:-balance_performance}"
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo "$MODE" > "$cpu" 2>/dev/null
done
SCRIPT
chmod +x /usr/local/bin/set-cpu-epp

# Rewrite the udev rule to call the helper script instead of inline shell glob
cat > /etc/udev/rules.d/99-cpu-epp-power.rules <<'EOF'
# Auto-switch CPU EPP based on power source (via helper to avoid glob issues)
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/local/bin/set-cpu-epp balance_performance"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/local/bin/set-cpu-epp balance_power"
EOF

log "CPU EPP udev rule fixed (uses helper script, no more glob errors)"

# =============================================================================
# 6. AMDGPU: Enable GPU hang recovery
# =============================================================================
echo ""
echo "=== 6. Enabling AMD GPU Hang Recovery ==="

# gpu_recovery=1 makes the driver attempt to recover from a hung GPU workqueue
# instead of triggering a full system reset (watchdog-triggered reboot).
# Addresses: "amdgpu_device_delay_enable_gfx_off hogged CPU for >10000us"
AMDGPU_CONF="/etc/modprobe.d/amdgpu-fix.conf"
if ! grep -q "gpu_recovery=1" "$AMDGPU_CONF" 2>/dev/null; then
    cat > "$AMDGPU_CONF" <<'EOF'
# Enable AMD GPU hang recovery — prevents a hung GPU workqueue from
# causing a full system reset (watchdog-triggered reboot).
# Added by 05-fix-kernel-panic.sh
options amdgpu gpu_recovery=1
EOF
    log "Created $AMDGPU_CONF with gpu_recovery=1"
else
    log "amdgpu gpu_recovery=1 already set"
fi

# =============================================================================
# 7. CRASH DUMPS: Install kdump-tools for post-panic vmcore capture
# =============================================================================
echo ""
echo "=== 7. Setting Up Crash Dump Collection ==="

# kdump-tools captures a vmcore on kernel panic so crashes can be diagnosed
# post-mortem. The installer also drops a grub.d snippet with crashkernel=
# (picked up by update-grub below).
if ! command -v kdump-config &>/dev/null; then
    apt-get install -y kdump-tools 2>/dev/null && \
        log "Installed kdump-tools (crashkernel param auto-added to GRUB)" || \
        warn "Failed to install kdump-tools"
else
    log "kdump-tools already installed"
fi

if command -v kdump-config &>/dev/null; then
    systemctl enable kdump-tools 2>/dev/null && \
        log "kdump-tools service enabled" || \
        warn "Could not enable kdump-tools service"
fi

# =============================================================================
# 8. UPDATE GRUB + REBUILD INITRAMFS
# =============================================================================
echo ""
echo "=== 8. Updating GRUB + Rebuilding Initramfs ==="

update-grub 2>/dev/null && log "GRUB updated" || err "update-grub failed"
update-initramfs -u 2>/dev/null && log "Initramfs rebuilt" || warn "Initramfs rebuild failed"

# Reload udev rules
udevadm control --reload-rules 2>/dev/null && log "udev rules reloaded" || true

# =============================================================================
# 9. VERIFY MCE MONITORING IS ACTIVE
# =============================================================================
echo ""
echo "=== 9. Verifying MCE/RAS Monitoring ==="

if systemctl is-active rasdaemon >/dev/null 2>&1; then
    log "rasdaemon is active (monitoring hardware errors)"
else
    systemctl enable rasdaemon 2>/dev/null
    systemctl start rasdaemon 2>/dev/null && \
        log "rasdaemon started" || \
        warn "Could not start rasdaemon"
fi

# Check for recent MCE errors
MCE_COUNT=$(ras-mc-ctl --errors 2>/dev/null | grep -c "error" || true)
if [ "$MCE_COUNT" -gt 0 ]; then
    warn "rasdaemon has logged $MCE_COUNT hardware errors — monitor closely"
    echo "       Run 'sudo ras-mc-ctl --errors' for details"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Kernel Panic Fixes Applied"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Root causes addressed:"
echo "   [1] GRUB: Removed mitigations=off (MCE errors need mitigations)"
echo "   [2] GRUB: Removed nowatchdog (need panic trace capture)"
echo "   [3] GRUB: Restored amdgpu.runpm=0 amdgpu.gfxoff=0 (ACPI dGPU bug)"
echo "   [4] sysctl: NMI watchdog re-enabled (lockup detection)"
echo "   [5] sysctl: watermark_boost_factor restored to 15000"
echo "   [6] ZFS: txg_timeout fixed 10->5 (was incorrectly doubled)"
echo "   [7] udev: NVMe rule now targets disk, not partitions"
echo "   [8] udev: CPU EPP rule fixed (helper script, no glob issues)"
echo "   [9] modprobe: amdgpu gpu_recovery=1 (GPU hang recovery)"
echo "  [10] kdump-tools: vmcore capture on kernel panic"
echo "  [11] GRUB updated + initramfs rebuilt"
echo ""
echo -e " ${YELLOW}IMPORTANT: Your CPU is reporting L1 cache MCE errors.${NC}"
echo "   Previous boot: Uncorrected error with Poison (caused the panic)"
echo "   Current boot:  Corrected error (handled gracefully, for now)"
echo "   These are HARDWARE errors. If panics continue after this fix,"
echo "   the CPU or RAM may need replacement (warranty)."
echo ""
echo -e " ${YELLOW}ACTION REQUIRED:${NC}"
echo "   1. Reboot to apply: sudo reboot"
echo "   2. After reboot, verify with:"
echo "        cat /proc/cmdline                    # no mitigations=off; amdgpu.runpm=0 amdgpu.gfxoff=0 present"
echo "        cat /proc/sys/kernel/nmi_watchdog    # should be 1"
echo "        cat /sys/module/zfs/parameters/zfs_txg_timeout  # should be 5"
echo "        kdump-config show                    # should say 'ready to kdump'"
echo "        sudo ras-mc-ctl --errors             # monitor MCE count"
echo ""
echo "   3. Monitor for MCE errors over the next few days:"
echo "        journalctl -k | grep 'Hardware Error'"
echo ""
