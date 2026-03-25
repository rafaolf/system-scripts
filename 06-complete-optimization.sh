#!/bin/bash
# =============================================================================
# Complete System Optimization — ASUS ROG Zephyrus G14 (GA402RJ)
#
# Fixes remaining issues found in full system audit:
#   1. Resolve PPD vs udev power rule conflict
#   2. Fix NVMe read-ahead (0 → 128 KB)
#   3. Install and configure lm-sensors
#   4. Clean up dead IPv6 privacy config
#   5. Fix rog-profile helper to use powerprofilesctl
#
# Usage: sudo bash 06-complete-optimization.sh
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
echo " Complete System Optimization — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="${SCRIPT_DIR}/optimization-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f /etc/udev/rules.d/99-rog-power-profile.rules ] && cp /etc/udev/rules.d/99-rog-power-profile.rules "$BACKUP_DIR/"
[ -f /etc/udev/rules.d/99-cpu-epp-power.rules ] && cp /etc/udev/rules.d/99-cpu-epp-power.rules "$BACKUP_DIR/"
[ -f /etc/udev/rules.d/60-nvme-scheduler.rules ] && cp /etc/udev/rules.d/60-nvme-scheduler.rules "$BACKUP_DIR/"
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. FIX POWER MANAGEMENT CONFLICT (PPD vs udev rules)
# =============================================================================
echo ""
echo "=== 1. Fixing Power Management Conflict ==="

# Problem: Custom udev rules directly write to sysfs for thermal policy and
# CPU EPP, but power-profiles-daemon (PPD) also manages these same knobs.
# They race against each other on AC/battery events.
#
# Fix: Rewrite the thermal udev rule to use powerprofilesctl (PPD's CLI),
# so PPD stays in sync. Remove the CPU EPP rule entirely since PPD manages
# EPP internally when switching profiles.

cat > /etc/udev/rules.d/99-rog-power-profile.rules <<'EOF'
# Auto-switch power profile based on power source via power-profiles-daemon
# AC plugged in → performance (higher clocks, fans spin up)
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/powerprofilesctl set performance"
# Battery → balanced (moderate clocks, quieter fans)
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/powerprofilesctl set balanced"
EOF

log "Rewrote thermal udev rule to use powerprofilesctl (no more PPD conflict)"

# Remove the CPU EPP rule — PPD handles EPP internally when switching profiles
rm -f /etc/udev/rules.d/99-cpu-epp-power.rules
log "Removed CPU EPP udev rule (PPD handles EPP via profile switching)"

# The set-cpu-epp helper script is no longer needed for udev, but keep it as
# a manual tool — it's harmless and useful for debugging
log "Kept /usr/local/bin/set-cpu-epp as a manual tool"

# =============================================================================
# 2. FIX NVMe READ-AHEAD (0 → 128 KB)
# =============================================================================
echo ""
echo "=== 2. Fixing NVMe Read-Ahead ==="

# Problem: read_ahead_kb=0 disables block-level prefetch entirely.
# While ZFS does its own prefetching at the ZFS layer, the block device
# read-ahead still helps with sequential I/O at the block layer (scrubs,
# large file reads, resilver). 128 KB is a good compromise.

cat > /etc/udev/rules.d/60-nvme-scheduler.rules <<'EOF'
# NVMe: no I/O scheduler (ZFS has its own), modest read-ahead for sequential I/O
# Match only whole-disk devices, not partitions
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="128"
EOF

# Apply immediately
echo 128 > /sys/block/nvme0n1/queue/read_ahead_kb 2>/dev/null && \
    log "NVMe read_ahead_kb: 0 → 128 (helps scrubs + sequential I/O)" || \
    warn "Could not apply read-ahead live"

# =============================================================================
# 3. INSTALL AND CONFIGURE LM-SENSORS
# =============================================================================
echo ""
echo "=== 3. Setting Up Thermal Monitoring ==="

if command -v sensors &>/dev/null; then
    log "lm-sensors already installed"
else
    apt-get install -y lm-sensors 2>/dev/null && \
        log "Installed lm-sensors" || \
        warn "Failed to install lm-sensors"
fi

# Auto-detect sensor modules (non-interactive)
if command -v sensors-detect &>/dev/null; then
    yes "" | sensors-detect --auto >/dev/null 2>&1 && \
        log "Sensor modules auto-detected" || \
        warn "sensors-detect had issues (run 'sudo sensors-detect' manually)"
fi

# Verify sensors are working
if command -v sensors &>/dev/null; then
    SENSOR_COUNT=$(sensors 2>/dev/null | grep -c "°C" || true)
    if [ "$SENSOR_COUNT" -gt 0 ]; then
        log "Sensors working: $SENSOR_COUNT temperature readings detected"
    else
        warn "No temperature sensors found — run 'sudo sensors-detect' manually after reboot"
    fi
fi

# =============================================================================
# 4. CLEAN UP DEAD IPv6 PRIVACY CONFIG
# =============================================================================
echo ""
echo "=== 4. Cleaning Up Dead Configs ==="

# IPv6 is fully disabled in 99-disable-ipv6.conf, so the IPv6 privacy
# extensions config in 10-ipv6-privacy.conf is dead code
if [ -f /etc/sysctl.d/99-disable-ipv6.conf ] && [ -f /etc/sysctl.d/10-ipv6-privacy.conf ]; then
    rm -f /etc/sysctl.d/10-ipv6-privacy.conf
    log "Removed dead IPv6 privacy config (IPv6 is fully disabled)"
fi

# Clean up commented-out GRUB lines for clarity
GRUB_FILE="/etc/default/grub"
if grep -q '^# GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
    sed -i '/^# GRUB_CMDLINE_LINUX_DEFAULT=/d' "$GRUB_FILE"
    log "Cleaned up commented-out GRUB_CMDLINE_LINUX_DEFAULT lines"
fi

# =============================================================================
# 5. UPDATE ROG-PROFILE HELPER TO USE PPD
# =============================================================================
echo ""
echo "=== 5. Updating rog-profile Helper ==="

# Rewrite to use powerprofilesctl so it stays in sync with PPD
cat > /usr/local/bin/rog-profile <<'SCRIPT'
#!/bin/bash
# ROG power profile switcher (uses power-profiles-daemon)
# Usage: rog-profile [balanced|performance|quiet|status]

case "${1:-}" in
    performance|turbo|1)
        powerprofilesctl set performance
        echo "Set: Performance (PPD + ASUS turbo)"
        ;;
    quiet|silent|power-saver|2)
        powerprofilesctl set power-saver
        echo "Set: Quiet / Power Saver"
        ;;
    balanced|0|"")
        powerprofilesctl set balanced
        echo "Set: Balanced (default)"
        ;;
    status)
        echo "PPD profile: $(powerprofilesctl get)"
        if [ -f /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy ]; then
            POLICY=$(cat /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy)
            case "$POLICY" in
                0) echo "ASUS thermal: Balanced" ;;
                1) echo "ASUS thermal: Performance" ;;
                2) echo "ASUS thermal: Quiet" ;;
            esac
        fi
        sensors 2>/dev/null | grep -E "Tctl|edge|junction" || true
        ;;
    *)
        echo "Usage: rog-profile [balanced|performance|quiet|status]"
        exit 1
        ;;
esac
SCRIPT

chmod +x /usr/local/bin/rog-profile
log "Updated rog-profile to use powerprofilesctl (PPD-aware)"

# =============================================================================
# 6. RELOAD UDEV RULES
# =============================================================================
echo ""
echo "=== 6. Reloading Rules ==="

udevadm control --reload-rules 2>/dev/null && log "udev rules reloaded" || true

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Optimization Complete"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Changes applied:"
echo "   [1] Power management: udev rules now use powerprofilesctl (no more PPD conflict)"
echo "   [2] NVMe read-ahead: 0 → 128 KB (helps scrubs + sequential reads)"
echo "   [3] lm-sensors: installed and configured for thermal monitoring"
echo "   [4] Cleanup: removed dead IPv6 privacy config + stale GRUB comments"
echo "   [5] rog-profile helper: now PPD-aware"
echo ""
echo " Verify with:"
echo "   powerprofilesctl get                        # current power profile"
echo "   rog-profile status                          # profile + temps"
echo "   sensors                                     # thermal readings"
echo "   cat /sys/block/nvme0n1/queue/read_ahead_kb  # should be 128"
echo ""
echo " Note: Sleep/suspend targets are masked (intentional for dGPU stability)."
echo "   If you want to re-enable suspend after confirming stability:"
echo "     sudo systemctl unmask sleep.target suspend.target"
echo ""
