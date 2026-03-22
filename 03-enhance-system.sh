#!/bin/bash
# =============================================================================
# System Enhancement Script — ASUS ROG Zephyrus G14 (GA402RJ)
# Ubuntu 24.04.4, Kernel 6.17, ZFS root, AMD Ryzen 9 6900HS + RX 6800S
#
# Covers the final round of optimizations:
#   1. Disable Tracker file indexer (reduces CPU spikes)
#   2. Disable DING desktop icons extension (reduces GNOME overhead)
#   3. CPU mitigations=off (max performance, security trade-off)
#   4. PipeWire low-latency audio tuning
#   5. Firefox snap hardware video acceleration
#   6. Move backups into system-scripts/
#
# Usage: sudo bash enhance-system.sh
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================="
echo " System Enhancement — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="${SCRIPT_DIR}/enhance-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/"
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. DISABLE TRACKER FILE INDEXER
# =============================================================================
echo ""
echo "=== 1. Disable Tracker File Indexer ==="

# Tracker causes periodic CPU spikes scanning the filesystem.
# Disabling it removes GNOME Files search-as-you-type, but file browsing
# and manual search still work fine.

# Disable for the current user (rafaolf)
sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
    systemctl --user mask tracker-miner-fs-3.service 2>/dev/null && \
    log "Masked tracker-miner-fs-3 (user service)" || \
    warn "Could not mask tracker-miner-fs-3"

sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
    systemctl --user stop tracker-miner-fs-3.service 2>/dev/null && \
    log "Stopped tracker-miner-fs-3" || true

# Also mask the control service and writeback
for svc in tracker-miner-fs-control-3 tracker-writeback-3; do
    sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
        systemctl --user mask "${svc}.service" 2>/dev/null && \
        log "Masked ${svc}" || true
    sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
        systemctl --user stop "${svc}.service" 2>/dev/null || true
done

# Clear existing index to free disk space
sudo -u rafaolf tracker3 reset -s -r 2>/dev/null && \
    log "Tracker index cleared" || \
    warn "Could not clear tracker index (may already be empty)"

# =============================================================================
# 2. DISABLE DING (DESKTOP ICONS NG) EXTENSION
# =============================================================================
echo ""
echo "=== 2. Disable DING Extension ==="

# DING spawns a separate process to render desktop icons and is one of the
# heavier GNOME extensions. Disabling it reduces memory usage and compositor load.

sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
    gnome-extensions disable ding@rastersoft.com 2>/dev/null && \
    log "Disabled DING (Desktop Icons NG)" || \
    warn "Could not disable DING"

# =============================================================================
# 3. CPU MITIGATIONS=OFF — Maximum Performance
# =============================================================================
echo ""
echo "=== 3. CPU Mitigations ==="

echo -e "${YELLOW}[NOTE]${NC} mitigations=off disables Spectre/Meltdown/SRSO protections."
echo "       This gives ~5-15% CPU performance boost but reduces security."
echo "       Safe on a personal machine where you trust all running software."

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

if echo "$CURRENT_CMDLINE" | grep -q "mitigations="; then
    log "Mitigations already configured in GRUB"
else
    NEW_CMDLINE="$CURRENT_CMDLINE mitigations=off"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"
    log "Added mitigations=off to GRUB"
fi

update-grub 2>/dev/null && log "GRUB updated" || warn "update-grub failed"

# =============================================================================
# 4. PIPEWIRE LOW-LATENCY AUDIO
# =============================================================================
echo ""
echo "=== 4. PipeWire Audio Tuning ==="

# Default quantum=1024 at 48kHz = 21.3ms latency.
# quantum=512 = 10.7ms — noticeably snappier for desktop audio/video,
# notifications, browser media. Still very safe for USB audio devices.

PIPEWIRE_CONF_DIR="/home/rafaolf/.config/pipewire/pipewire.conf.d"
mkdir -p "$PIPEWIRE_CONF_DIR"
chown -R rafaolf:rafaolf /home/rafaolf/.config/pipewire

cat > "${PIPEWIRE_CONF_DIR}/10-low-latency.conf" <<'EOF'
# Lower audio latency: 512 samples at 48kHz = 10.7ms (default 1024 = 21.3ms)
# Also allow 44.1kHz for lossless audio sources
context.properties = {
    default.clock.quantum         = 512
    default.clock.min-quantum     = 64
    default.clock.max-quantum     = 1024
    default.clock.allowed-rates   = [ 44100 48000 96000 ]
}
EOF

chown rafaolf:rafaolf "${PIPEWIRE_CONF_DIR}/10-low-latency.conf"
log "PipeWire quantum=512 (10.7ms latency, effective after reboot or pw restart)"

# Also tune WirePlumber for faster node switching
WP_CONF_DIR="/home/rafaolf/.config/wireplumber/wireplumber.conf.d"
mkdir -p "$WP_CONF_DIR"
chown -R rafaolf:rafaolf /home/rafaolf/.config/wireplumber

cat > "${WP_CONF_DIR}/10-alsa-tweaks.conf" <<'EOF'
# Reduce ALSA headroom for lower latency
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.*" }
    ]
    actions = {
      update-props = {
        api.alsa.headroom      = 512
        api.alsa.period-size   = 512
        session.suspend-timeout-seconds = 0
      }
    }
  }
  {
    matches = [
      { node.name = "~alsa_input.*" }
    ]
    actions = {
      update-props = {
        api.alsa.headroom      = 512
        api.alsa.period-size   = 512
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF

chown rafaolf:rafaolf "${WP_CONF_DIR}/10-alsa-tweaks.conf"
log "WirePlumber ALSA headroom tuned"

# =============================================================================
# 5. FIREFOX SNAP — Hardware Video Acceleration
# =============================================================================
echo ""
echo "=== 5. Firefox Snap VA-API ==="

# Firefox snap needs explicit environment variables for hardware video decode.
# LIBVA_DRIVER_NAME=radeonsi is already in /etc/environment.
# Firefox also needs MOZ_DISABLE_RDD_SANDBOX=1 for VA-API in its sandbox.

# Create the snap environment override
FIREFOX_SNAP_ENV="/etc/environment.d/90-firefox-vaapi.conf"
cat > "$FIREFOX_SNAP_ENV" <<'EOF'
# Firefox hardware video acceleration (VA-API)
MOZ_DISABLE_RDD_SANDBOX=1
MOZ_ENABLE_WAYLAND=1
EOF
log "Firefox VA-API environment set ($FIREFOX_SNAP_ENV)"

# If Firefox snap profile exists, also set user.js preferences
FIREFOX_PROFILES=$(find /home/rafaolf/snap/firefox -maxdepth 5 -name 'prefs.js' -printf '%h\n' 2>/dev/null)
if [ -n "$FIREFOX_PROFILES" ]; then
    for profile_dir in $FIREFOX_PROFILES; do
        cat > "${profile_dir}/user.js" <<'FFEOF'
// Hardware video acceleration
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.ffvpx.enabled", false);
user_pref("media.rdd-vpx.enabled", false);
user_pref("media.av1.enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("widget.dmabuf.force-enabled", true);
FFEOF
        chown rafaolf:rafaolf "${profile_dir}/user.js"
        log "Firefox user.js set in $profile_dir"
    done
else
    # No Firefox profile yet — create the override for when they first launch
    warn "No Firefox snap profile found (will apply on first launch via env vars)"
fi

# =============================================================================
# 6. CONSOLIDATE BACKUPS INTO system-scripts/
# =============================================================================
echo ""
echo "=== 6. Consolidating Backups ==="

for bak in /home/rafaolf/stabilize-backup-* /home/rafaolf/optimize-backup-*; do
    if [ -d "$bak" ]; then
        mv "$bak" "${SCRIPT_DIR}/" 2>/dev/null && \
            log "Moved $(basename $bak) → system-scripts/" || \
            warn "Could not move $(basename $bak)"
    fi
done

# Fix ownership of backup dirs (created by sudo)
chown -R rafaolf:rafaolf "${SCRIPT_DIR}" 2>/dev/null
log "Fixed ownership of system-scripts/"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Enhancement Complete"
echo "============================================="
echo ""
echo " Backup location: $BACKUP_DIR"
echo ""
echo " Changes applied (live):"
echo "   - Tracker file indexer: masked + index cleared"
echo "   - DING extension: disabled"
echo ""
echo " Changes requiring reboot/re-login:"
echo "   - mitigations=off (kernel parameter)"
echo "   - PipeWire quantum=512 (10.7ms audio latency)"
echo "   - Firefox snap VA-API environment vars"
echo ""
echo " All scripts are now in: ${SCRIPT_DIR}/"
echo ""
echo " After reboot, verify with:"
echo "   grep 'mitigations' /proc/cmdline"
echo "   pw-metadata -n settings 0 | grep quantum"
echo "   systemctl --user status tracker-miner-fs-3  # should be masked"
echo "   gnome-extensions list --enabled              # DING should be gone"
echo ""
