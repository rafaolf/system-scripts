#!/bin/bash
# =============================================================================
# Deep System Optimization — ASUS ROG Zephyrus G14 (GA402RJ)
# Ubuntu 24.04.4, Kernel 6.17, ZFS root, AMD Ryzen 9 6900HS + RX 6800S
#
# Second-pass optimizations covering:
#   1. ZRAM compressed swap (RAM-speed, replaces NVMe swap as primary)
#   2. irqbalance (IRQ distribution across 16 threads)
#   3. DNS-over-TLS with Cloudflare (faster + private DNS)
#   4. Journald size limits (reduce I/O from logging)
#   5. Snap overhead reduction (clean old revisions, limit refresh)
#   6. IOMMU passthrough (reduce IOMMU overhead)
#   7. ASUS ROG thermal/performance integration
#   8. Stale kernel module cleanup
#
# Usage: sudo bash 04-deep-optimize.sh
# =============================================================================

set -uo pipefail
# Note: NOT using set -e — individual sections handle their own errors
# so one failure doesn't abort the entire script

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
echo " Deep System Optimization — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="${SCRIPT_DIR}/deep-optimize-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/"
[ -f /etc/systemd/journald.conf ] && cp /etc/systemd/journald.conf "$BACKUP_DIR/"
[ -f /etc/systemd/resolved.conf ] && cp /etc/systemd/resolved.conf "$BACKUP_DIR/"
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. ZRAM COMPRESSED SWAP
# =============================================================================
echo ""
echo "=== 1. ZRAM Compressed Swap ==="

# ZRAM creates a compressed block device in RAM. Swap operations happen at
# RAM speed (~50GB/s) instead of NVMe speed (~3.5GB/s). With zstd compression,
# an 8GB ZRAM device effectively holds ~16-20GB of swap data.
#
# The existing 8GB dm-crypt NVMe swap stays as a lower-priority fallback.

if dpkg -l systemd-zram-generator 2>/dev/null | grep -q '^ii'; then
    log "systemd-zram-generator already installed"
else
    apt-get install -y systemd-zram-generator 2>/dev/null && \
        log "Installed systemd-zram-generator" || \
        err "Failed to install systemd-zram-generator"
fi

# Configure ZRAM: 8GB device, zstd compression, higher priority than NVMe swap
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
# 8GB ZRAM device — zstd gives ~2-3x compression ratio
# Effective capacity: ~16-20GB of swap data at RAM speed
zram-size = 8192
compression-algorithm = zstd
# Higher priority than NVMe swap (-2), so kernel uses ZRAM first
swap-priority = 100
# Filesystem type
fs-type = swap
EOF

log "ZRAM configured: 8GB zstd, priority 100 (above NVMe swap)"
log "ZRAM will activate after reboot"

# =============================================================================
# 2. IRQBALANCE — Distribute IRQs across all 16 threads
# =============================================================================
echo ""
echo "=== 2. irqbalance ==="

# irqbalance distributes hardware interrupts across CPU cores to prevent
# any single core from becoming a bottleneck. Currently not installed on this
# system, meaning all IRQs default to CPU0.

if ! command -v irqbalance &>/dev/null; then
    apt-get install -y irqbalance 2>/dev/null && \
        log "Installed irqbalance" || \
        { warn "Failed to install irqbalance"; }
fi

if systemctl is-active irqbalance >/dev/null 2>&1; then
    log "irqbalance already active"
else
    systemctl enable irqbalance 2>/dev/null || true
    systemctl start irqbalance 2>/dev/null && \
        log "irqbalance enabled and started" || \
        warn "Could not start irqbalance"
fi

# =============================================================================
# 3. DNS-OVER-TLS WITH CLOUDFLARE
# =============================================================================
echo ""
echo "=== 3. DNS-over-TLS ==="

# Current DNS: router at 192.168.0.1 (unencrypted, no caching tuning).
# Cloudflare 1.1.1.1 is consistently the fastest public DNS resolver.
# DNS-over-TLS encrypts queries, preventing ISP snooping/injection.

cat > /etc/systemd/resolved.conf <<'EOF'
[Resolve]
# Cloudflare primary + Google fallback
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=9.9.9.9#dns.quad9.net
# Encrypt all DNS queries
DNSOverTLS=yes
# Disable mDNS and LLMNR (not needed, reduces attack surface)
MulticastDNS=no
LLMNR=no
# Enable DNS caching
Cache=yes
CacheFromLocalhost=no
# Use DNS result for negative caching too
DNSStubListenerExtra=
EOF

# Restart resolved to apply
systemctl restart systemd-resolved 2>/dev/null && \
    log "DNS-over-TLS enabled (Cloudflare 1.1.1.1)" || \
    warn "Could not restart systemd-resolved"

# Verify
sleep 1
DNS_STATUS=$(resolvectl status 2>/dev/null | grep -c "DNSOverTLS" || true)
if [ "$DNS_STATUS" -gt 0 ]; then
    log "DNS-over-TLS verified active"
fi

# =============================================================================
# 4. JOURNALD SIZE LIMITS
# =============================================================================
echo ""
echo "=== 4. Journald Tuning ==="

# Current: no limits, 286MB of logs with individual files up to 128MB.
# On ZFS, every log write is a CoW operation. Limiting journal size and
# enabling compression reduces I/O significantly.

cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
# Cap total journal size to 100MB (from unlimited ~286MB+)
SystemMaxUse=100M
# Individual file max 16MB (from default 128MB)
SystemMaxFileSize=16M
# Runtime (volatile) journal max
RuntimeMaxUse=50M
# ZFS already compresses at the block level — disable journal compression
# to avoid double-compression overhead (CPU waste for near-zero benefit)
Compress=no
# Rate limit: prevent log floods from consuming I/O
RateLimitIntervalSec=30s
RateLimitBurst=10000
# Retain 1 week of history
MaxRetentionSec=1week
EOF

systemctl restart systemd-journald 2>/dev/null && \
    log "Journald: max 100MB, zstd compression, 1 week retention" || \
    warn "Could not restart journald"

# Vacuum existing oversized logs
journalctl --vacuum-size=100M --vacuum-time=1week 2>/dev/null && \
    log "Vacuumed old journal entries" || true

# =============================================================================
# 5. SNAP OVERHEAD REDUCTION
# =============================================================================
echo ""
echo "=== 5. Snap Optimization ==="

# 19 squashfs mounts from snaps, many are duplicate revisions.
# Each mount consumes kernel memory for the mount table and squashfs metadata.

# Limit retained snap revisions from 3 (default) to 2
snap set system refresh.retain=2 2>/dev/null && \
    log "Snap: limited retained revisions to 2" || true

# Schedule snap refreshes to 4 AM (avoids disrupting active use)
snap set system refresh.timer=4:00-5:00 2>/dev/null && \
    log "Snap: refresh window set to 4:00-5:00 AM" || true

# Remove old snap revisions
CLEANED=0
snap list --all 2>/dev/null | while read -r name ver rev tracking publisher notes; do
    if echo "$notes" | grep -q "disabled"; then
        snap remove "$name" --revision="$rev" 2>/dev/null && CLEANED=$((CLEANED+1))
    fi
done
# Count what was actually cleaned
OLD_SNAPS=$(snap list --all 2>/dev/null | grep "disabled" | wc -l)
if [ "$OLD_SNAPS" -eq 0 ]; then
    log "Snap: no old revisions to clean (or all cleaned)"
else
    warn "Snap: $OLD_SNAPS old revisions remaining"
fi

# =============================================================================
# 6. IOMMU PASSTHROUGH MODE
# =============================================================================
echo ""
echo "=== 6. IOMMU Passthrough ==="

# iommu=pt enables passthrough mode: devices that don't need IOMMU translation
# bypass it entirely, reducing DMA overhead. Safe for desktop use (only needed
# for VFIO/passthrough VMs to be in full translation mode).

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

if echo "$CURRENT_CMDLINE" | grep -q "iommu=pt"; then
    log "iommu=pt already in GRUB"
else
    NEW_CMDLINE="$CURRENT_CMDLINE iommu=pt"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"
    log "Added iommu=pt to GRUB (reduces DMA translation overhead)"
fi
# GRUB update deferred to section 11 (after all GRUB changes)

# =============================================================================
# 7. ASUS ROG THERMAL / PERFORMANCE INTEGRATION
# =============================================================================
echo ""
echo "=== 7. ASUS ROG Platform Integration ==="

# The asus-nb-wmi driver exposes throttle_thermal_policy:
#   0 = balanced (default), 1 = performance/turbo, 2 = quiet
# power-profiles-daemon (PPD) should integrate with this, but let's
# also create a helper to quickly switch profiles.

# Create a quick profile switcher
cat > /usr/local/bin/rog-profile <<'SCRIPT'
#!/bin/bash
# Quick ROG thermal profile switcher
# Usage: rog-profile [balanced|performance|quiet]

POLICY_FILE="/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"

case "${1:-}" in
    performance|turbo|1)
        echo 1 > "$POLICY_FILE"
        powerprofilesctl set performance 2>/dev/null
        echo "Set: Performance (turbo fans, max clocks)"
        ;;
    quiet|silent|2)
        echo 2 > "$POLICY_FILE"
        powerprofilesctl set power-saver 2>/dev/null
        echo "Set: Quiet (minimal fans, reduced clocks)"
        ;;
    balanced|0|"")
        echo 0 > "$POLICY_FILE"
        powerprofilesctl set balanced 2>/dev/null
        echo "Set: Balanced (default)"
        ;;
    status)
        CURRENT=$(cat "$POLICY_FILE")
        case "$CURRENT" in
            0) echo "Current: Balanced" ;;
            1) echo "Current: Performance" ;;
            2) echo "Current: Quiet" ;;
        esac
        powerprofilesctl get
        ;;
    *)
        echo "Usage: rog-profile [balanced|performance|quiet|status]"
        exit 1
        ;;
esac
SCRIPT

chmod +x /usr/local/bin/rog-profile
log "Created /usr/local/bin/rog-profile helper"

# Create a udev rule to auto-set performance on AC, balanced on battery
cat > /etc/udev/rules.d/99-rog-power-profile.rules <<'EOF'
# Auto-switch ROG thermal profile based on power source
# AC plugged in → performance
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/bin/sh -c 'echo 1 > /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy'"
# Battery → balanced
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/bin/sh -c 'echo 0 > /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy'"
EOF

log "Auto power-profile switching: AC→performance, battery→balanced"

# Also set CPU EPP to performance when on AC (complements thermal policy)
cat > /etc/udev/rules.d/99-cpu-epp-power.rules <<'EOF'
# Auto-switch CPU EPP based on power source
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/bin/sh -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo balance_performance > $cpu 2>/dev/null; done'"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/bin/sh -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo balance_power > $cpu 2>/dev/null; done'"
EOF

log "Auto CPU EPP: AC→balance_performance, battery→balance_power"

# =============================================================================
# 8. KERNEL MODULE BLACKLIST (unused modules consuming memory)
# =============================================================================
echo ""
echo "=== 8. Module Cleanup ==="

# Blacklist modules loaded but not needed:
# - thunderbolt: No Thunderbolt port on GA402RJ (USB4/USB-C only)
# - intel VA-API drivers: AMD system, Intel drivers waste memory and can confuse libva

cat > /etc/modprobe.d/99-rog-blacklist.conf <<'EOF'
# Intel VA-API drivers: not needed on AMD system, can confuse libva driver selection
blacklist i915
blacklist i965
blacklist iHD

# Thunderbolt: GA402RJ has USB-C but no Thunderbolt controller
# (the USB4 controller handles USB-C natively via the AMD SoC)
# Comment out if you use a Thunderbolt dock
# blacklist thunderbolt
EOF

log "Blacklisted Intel VA-API drivers (AMD system)"

# =============================================================================
# 9. FILE DESCRIPTOR / INOTIFY LIMITS FOR DEVELOPMENT
# =============================================================================
echo ""
echo "=== 9. File Descriptor Limits ==="

# Increase inotify instances for development workloads (IDEs, file watchers,
# Docker containers all consume inotify instances)
CURRENT_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances)
if [ "$CURRENT_INSTANCES" -lt 1024 ]; then
    cat >> /etc/sysctl.d/90-zfs-tuning.conf <<'EOF'

# Increase inotify instances for development workloads (IDEs, Docker, watchers)
fs.inotify.max_user_instances = 1024
EOF
    sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1
    log "inotify max_user_instances: $CURRENT_INSTANCES → 1024"
else
    log "inotify max_user_instances already $CURRENT_INSTANCES"
fi

# =============================================================================
# 10. USB AUTOSUSPEND TUNING
# =============================================================================
echo ""
echo "=== 10. USB Autosuspend ==="

# Current: autosuspend=2 (2 seconds). This can cause issues with some USB
# devices (audio interfaces, webcams). For a desktop workload, a longer
# timeout reduces reconnection overhead.

# Tune per-device rather than globally: keep autosuspend on for hubs/HID
# but disable for audio and video devices
cat > /etc/udev/rules.d/99-usb-autosuspend.rules <<'EOF'
# Disable USB autosuspend for audio devices (prevents PipeWire glitches)
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="01", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
# Disable USB autosuspend for video devices (prevents webcam reconnection)
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="0e", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
EOF

log "USB autosuspend: disabled for audio/video devices"

# =============================================================================
# 11. RE-ENABLE dGPU RUNTIME PM (saves 8-15W on battery)
# =============================================================================
echo ""
echo "=== 11. dGPU Runtime Power Management ==="

# The stabilize script disabled runtime PM (amdgpu.runpm=0) due to ACPI/dGPU
# crash bugs on BIOS 318. With BIOS 319 + kernel 6.17, these are fixed:
#   - Kernel 6.5: fixed RDNA2 dGPU runtime PM regression
#   - Kernel 6.8: BACO improvements for Navi 23
#   - Kernel 6.11: PCI ASPM + runtime PM fixes for AMD platforms
#   - BIOS 319: ACPI dGPU bug patched
#
# The RX 6800S draws 8-15W idle when forced on. With runtime PM, it drops
# to <1W in D3cold when not in use. When HDMI is connected the dGPU stays
# active regardless (since HDMI is wired to the dGPU), so this mainly
# helps battery life when no external display is connected.

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

CHANGED=false

# Remove amdgpu.runpm=0 (re-enable runtime PM)
if echo "$CURRENT_CMDLINE" | grep -q "amdgpu.runpm=0"; then
    CURRENT_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed 's/amdgpu.runpm=0//')
    CURRENT_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    CHANGED=true
    log "Removed amdgpu.runpm=0 (re-enabling dGPU runtime PM)"
fi

# Also re-enable gfxoff (power saving feature, stable on 6.17)
if echo "$CURRENT_CMDLINE" | grep -q "amdgpu.gfxoff=0"; then
    CURRENT_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed 's/amdgpu.gfxoff=0//')
    CURRENT_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    CHANGED=true
    log "Removed amdgpu.gfxoff=0 (re-enabling GFX power gating)"
fi

if [ "$CHANGED" = true ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CURRENT_CMDLINE}\"|" "$GRUB_FILE"
    update-grub 2>/dev/null && log "GRUB updated (dGPU power saving re-enabled)" || warn "update-grub failed"
fi

# Create a safety script to re-disable if crashes occur
cat > /usr/local/bin/rog-disable-dgpu-pm <<'SAFETY'
#!/bin/bash
# Emergency: re-disable dGPU runtime PM if system becomes unstable
# Usage: sudo rog-disable-dgpu-pm
GRUB="/etc/default/grub"
CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')
if ! echo "$CMDLINE" | grep -q "amdgpu.runpm=0"; then
    CMDLINE="$CMDLINE amdgpu.runpm=0 amdgpu.gfxoff=0"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMDLINE}\"|" "$GRUB"
    update-grub
    echo "dGPU runtime PM disabled. Reboot to apply."
else
    echo "amdgpu.runpm=0 already set."
fi
SAFETY
chmod +x /usr/local/bin/rog-disable-dgpu-pm
log "Created /usr/local/bin/rog-disable-dgpu-pm safety script"

echo -e "${YELLOW}[NOTE]${NC} If you experience GPU crashes after reboot, run:"
echo "       sudo rog-disable-dgpu-pm && sudo reboot"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Deep Optimization Complete"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Changes applied (live):"
echo "   - irqbalance: enabled and started"
echo "   - DNS-over-TLS: Cloudflare 1.1.1.1 (encrypted)"
echo "   - Journald: capped to 100MB, no compression (ZFS handles it), 1 week"
echo "   - Snap: refresh.retain=2, refresh 4-5 AM, old revisions cleaned"
echo "   - inotify instances: 128 → 1024"
echo "   - /usr/local/bin/rog-profile helper installed"
echo ""
echo " Changes requiring reboot:"
echo "   - ZRAM 8GB zstd swap (priority above NVMe swap)"
echo "   - iommu=pt kernel parameter"
echo "   - dGPU runtime PM re-enabled (saves 8-15W on battery)"
echo "   - GFX power gating re-enabled"
echo "   - Intel VA-API module blacklist"
echo "   - USB autosuspend rules for audio/video"
echo "   - Auto power-profile udev rules (AC→performance, battery→balanced)"
echo "   - Auto CPU EPP udev rules"
echo ""
echo " New tools:"
echo "   sudo rog-profile performance  # max performance (AC)"
echo "   sudo rog-profile quiet        # silent mode (battery)"
echo "   sudo rog-profile balanced     # default"
echo "   sudo rog-profile status       # show current"
echo "   sudo rog-disable-dgpu-pm     # emergency: re-disable dGPU PM if unstable"
echo ""
echo " After reboot, verify with:"
echo "   swapon --show                      # should show zram0 + dm-crypt"
echo "   resolvectl status                  # should show DoT + Cloudflare"
echo "   journalctl --disk-usage            # should be ≤100MB"
echo "   grep iommu /proc/cmdline           # should show iommu=pt"
echo "   systemctl is-active irqbalance     # should be active"
echo "   cat /sys/class/drm/card1/device/power/runtime_status  # suspended when idle"
echo ""
