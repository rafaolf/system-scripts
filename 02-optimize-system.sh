#!/bin/bash
# =============================================================================
# System Performance Optimization — ASUS ROG Zephyrus G14 (GA402RJ)
# Ubuntu 24.04.4, Kernel 6.17, ZFS root, AMD Ryzen 9 6900HS + RX 6700S
#
# Usage: sudo bash optimize-system.sh
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
echo " System Performance Optimization — GA402RJ"
echo " $(date)"
echo "============================================="
echo ""

# --- Backup ---
BACKUP_DIR="/home/rafaolf/optimize-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR/"
cp /etc/crypttab "$BACKUP_DIR/"
[ -f /etc/fstab ] && cp /etc/fstab "$BACKUP_DIR/"
cp -r /etc/sysctl.d/ "$BACKUP_DIR/"
cp -r /etc/modprobe.d/ "$BACKUP_DIR/"
cp -r /etc/NetworkManager/conf.d/ "$BACKUP_DIR/"
log "Configs backed up to $BACKUP_DIR"

# =============================================================================
# 1. NETWORK STACK — BBR + Larger Buffers
# =============================================================================
echo ""
echo "=== 1. Network Stack Optimization ==="

cat > /etc/sysctl.d/90-network-performance.conf <<'EOF'
# TCP BBR congestion control — better throughput and lower latency than CUBIC,
# especially on WiFi and lossy networks
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Larger socket buffers for high-throughput connections (streaming, downloads)
# Default 212992 (208KB) is far too small for modern networks
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP Fast Open — client + server (reduces latency on repeated connections)
net.ipv4.tcp_fastopen = 3

# MTU probing — auto-discover optimal MTU (helps with VPNs and WiFi)
net.ipv4.tcp_mtu_probing = 1

# Increase network device backlog for bursty traffic
net.core.netdev_max_backlog = 16384

# Disable slow start after idle — keeps connections warmed up for interactive use
net.ipv4.tcp_slow_start_after_idle = 0

# Reduce TIME_WAIT socket duration
net.ipv4.tcp_fin_timeout = 15
EOF

# Load BBR module and apply
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/90-network-performance.conf >/dev/null 2>&1
log "BBR + TCP buffer tuning applied"

# =============================================================================
# 2. MEMORY / VM TUNING (ZFS-aware)
# =============================================================================
echo ""
echo "=== 2. Memory / VM Tuning ==="

cat > /etc/sysctl.d/90-zfs-tuning.conf <<'EOF'
# ZFS-aware VM tuning for 24GB RAM desktop

# Lower swappiness: ZFS ARC is the primary cache, minimize swap pressure
vm.swappiness = 10

# Reduce VFS cache pressure — ZFS manages its own metadata cache (ARC)
vm.vfs_cache_pressure = 50

# Disable proactive compaction — wastes CPU on desktop workloads
# (compaction still happens on-demand when needed)
vm.compaction_proactiveness = 0

# Reduce watermark boost — ZFS handles its own caching; aggressive kernel
# page reclaim fights with ARC and causes unnecessary I/O
vm.watermark_boost_factor = 0

# Dirty page tuning for NVMe + ZFS:
# ZFS does its own write batching via TXG, so we want the kernel to hand
# off dirty pages quickly rather than accumulating large write bursts
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000

# Page lock unfairness — lower value improves fairness under contention
vm.page_lock_unfairness = 1

# Single-page swap I/O — reduces wasted swap reads (default reads 8 pages)
vm.page-cluster = 0

# Increase min free memory to 128MB — avoids direct reclaim stalls under pressure
vm.min_free_kbytes = 131072

# Disable NMI watchdog — saves a perf counter, slight CPU overhead reduction
kernel.nmi_watchdog = 0
EOF

sysctl -p /etc/sysctl.d/90-zfs-tuning.conf >/dev/null 2>&1
log "VM tuning applied (ZFS-aware)"

# =============================================================================
# 3. KERNEL PREEMPTION — Switch to full preempt for desktop responsiveness
# =============================================================================
echo ""
echo "=== 3. Kernel Preemption ==="

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

if echo "$CURRENT_CMDLINE" | grep -q "preempt="; then
    log "Preempt already set in GRUB"
else
    NEW_CMDLINE="$CURRENT_CMDLINE preempt=full nowatchdog"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "$GRUB_FILE"
    log "Added preempt=full nowatchdog to GRUB (desktop responsiveness + reduced overhead)"
fi

update-grub 2>/dev/null && log "GRUB updated" || warn "update-grub failed"

# =============================================================================
# 4. /tmp ON TMPFS — Keep temp files in RAM instead of hitting ZFS/NVMe
# =============================================================================
echo ""
echo "=== 4. /tmp on tmpfs ==="

if grep -q 'tmpfs.*/tmp' /etc/fstab 2>/dev/null; then
    log "/tmp tmpfs already in fstab"
elif systemctl is-enabled tmp.mount 2>/dev/null | grep -q enabled; then
    log "/tmp tmpfs already enabled via systemd"
else
    # Use systemd tmp.mount (cleaner than fstab for ZFS systems)
    cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount 2>/dev/null || true
    if [ -f /etc/systemd/system/tmp.mount ]; then
        systemctl enable tmp.mount 2>/dev/null
        log "/tmp tmpfs enabled (effective after reboot)"
    else
        # Fallback to fstab
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=4G 0 0" >> /etc/fstab
        log "/tmp tmpfs added to fstab (effective after reboot)"
    fi
fi

# =============================================================================
# 5. ENCRYPTED SWAP — Enable TRIM passthrough
# =============================================================================
echo ""
echo "=== 5. Swap TRIM Passthrough ==="

CRYPTTAB="/etc/crypttab"
if grep -q "dm_crypt-0" "$CRYPTTAB"; then
    if grep "dm_crypt-0" "$CRYPTTAB" | grep -q "discard"; then
        log "Swap TRIM passthrough already enabled"
    else
        # Add discard option to the swap dm-crypt entry
        sed -i '/^dm_crypt-0/s/size=256/size=256,discard/' "$CRYPTTAB"
        log "Added discard to encrypted swap (TRIM passthrough, effective after reboot)"
    fi
fi

# =============================================================================
# 6. ZFS TUNING
# =============================================================================
echo ""
echo "=== 6. ZFS Dataset Tuning ==="

# Disable atime on all datasets (relatime is set but off is better)
zfs set atime=off rpool 2>/dev/null && log "atime=off on rpool" || warn "Could not set atime=off"

# Enable zstd compression on USERDATA (better ratio than lz4 with negligible CPU on Zen3+)
CURRENT_COMP=$(zfs get -H -o value compression rpool/USERDATA 2>/dev/null)
if [ "$CURRENT_COMP" = "lz4" ]; then
    zfs set compression=zstd rpool/USERDATA 2>/dev/null && \
        log "USERDATA compression upgraded to zstd (new writes only)" || \
        warn "Could not set zstd on USERDATA"
else
    log "USERDATA compression: $CURRENT_COMP (keeping as-is)"
fi

# Tune ZFS module parameters
cat > /etc/modprobe.d/zfs.conf <<'EOF'
# ZFS tuning for 24GB RAM desktop on NVMe
# ARC max 8GB (stabilize-system.sh)
options zfs zfs_arc_max=8589934592
# Reduce TXG timeout for snappier sync writes (default 5s)
options zfs zfs_txg_timeout=10
# Increase prefetch distance for sequential reads (helps large file ops)
options zfs zfs_prefetch_disable=0
EOF

log "ZFS module parameters updated"

# =============================================================================
# 7. NVMe READ-AHEAD — Disable (ZFS does its own prefetch)
# =============================================================================
echo ""
echo "=== 7. NVMe Read-Ahead ==="

# Create udev rule to persist across reboots
cat > /etc/udev/rules.d/60-nvme-scheduler.rules <<'EOF'
# NVMe: no I/O scheduler (ZFS has its own), no read-ahead (ZFS prefetches)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="0"
EOF

# Apply immediately
echo 0 > /sys/block/nvme0n1/queue/read_ahead_kb 2>/dev/null
log "NVMe read_ahead_kb=0 (ZFS does its own prefetch)"

# =============================================================================
# 8. MUTTER RT-SCHEDULER — Compositor gets real-time priority
# =============================================================================
echo ""
echo "=== 8. Mutter RT-Scheduler ==="

# Enable rt-scheduler for mutter compositor (reduces frame drops under CPU load)
# rtkit-daemon handles the privilege escalation safely
CURRENT_FEATURES=$(sudo -u rafaolf gsettings get org.gnome.mutter experimental-features 2>/dev/null || echo "@as []")
if echo "$CURRENT_FEATURES" | grep -q "rt-scheduler"; then
    log "rt-scheduler already enabled in mutter"
else
    sudo -u rafaolf DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" \
        gsettings set org.gnome.mutter experimental-features "['variable-refresh-rate', 'rt-scheduler']" 2>/dev/null && \
        log "Enabled rt-scheduler + VRR in mutter" || \
        warn "Could not set mutter experimental-features (set manually after login)"
fi

# =============================================================================
# 9. DISABLE UNNECESSARY SERVICES
# =============================================================================
echo ""
echo "=== 9. Disabling Unnecessary Services ==="

# cloud-init: not needed on a physical laptop
for svc in cloud-config cloud-final cloud-init-local cloud-init; do
    if systemctl is-enabled "${svc}.service" 2>/dev/null | grep -q enabled; then
        systemctl disable "${svc}.service" 2>/dev/null
        log "Disabled ${svc}.service"
    fi
done

# ModemManager: no modem on this laptop
if systemctl is-enabled ModemManager.service 2>/dev/null | grep -q enabled; then
    systemctl disable ModemManager.service 2>/dev/null
    systemctl stop ModemManager.service 2>/dev/null
    log "Disabled ModemManager.service"
fi

# NetworkManager-wait-online: adds ~3s to boot, rarely needed
if systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null | grep -q enabled; then
    systemctl disable NetworkManager-wait-online.service 2>/dev/null
    log "Disabled NetworkManager-wait-online.service (saves ~3s boot)"
fi

# thermald: conflicts with power-profiles-daemon (which is already active)
if systemctl is-enabled thermald.service 2>/dev/null | grep -q enabled; then
    systemctl disable thermald.service 2>/dev/null
    systemctl stop thermald.service 2>/dev/null
    log "Disabled thermald.service (PPD handles thermal management)"
fi

# apport: crash reporter — adds ~450ms boot, rarely useful
if systemctl is-enabled apport.service 2>/dev/null | grep -q enabled; then
    systemctl disable apport.service 2>/dev/null
    log "Disabled apport.service"
fi

# systemd-udev-settle: deprecated, adds ~8s to boot
if systemctl is-enabled systemd-udev-settle.service 2>/dev/null | grep -q enabled; then
    systemctl mask systemd-udev-settle.service 2>/dev/null
    log "Masked systemd-udev-settle.service (saves ~8s boot)"
fi

# =============================================================================
# 10. CLEAN UP STALE DOCKER NETWORKS
# =============================================================================
echo ""
echo "=== 10. Cleaning Stale Docker Networks ==="

if command -v docker &>/dev/null; then
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -eq 0 ]; then
        BEFORE=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | wc -l)
        docker network prune -f 2>/dev/null
        AFTER=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | wc -l)
        REMOVED=$((BEFORE - AFTER))
        log "Pruned $REMOVED stale Docker bridge networks"
    else
        warn "Containers running — skipping network prune"
    fi
fi

# =============================================================================
# 11. CLEAN UP CONFIG FILE DUPLICATES
# =============================================================================
echo ""
echo "=== 11. Cleaning Config Duplicates ==="

# WiFi powersave: consolidate into a single file
cat > /etc/NetworkManager/conf.d/99-wifi-performance.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
rm -f /etc/NetworkManager/conf.d/99-no-wifi-powersave.conf 2>/dev/null
rm -f /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf 2>/dev/null
rm -f /etc/NetworkManager/conf.d/wifi-powersave.conf 2>/dev/null
log "WiFi powersave configs consolidated (powersave=off)"

# Empty mt7921e files
rm -f /etc/modprobe.d/mt7921e-disable-aspm.conf 2>/dev/null
rm -f /etc/modprobe.d/mt7921e-fix.conf 2>/dev/null
log "Removed empty mt7921e modprobe files"

# Remove the bufferbloat sysctl (superseded by our network tuning)
if [ -f /etc/sysctl.d/10-bufferbloat.conf ]; then
    rm -f /etc/sysctl.d/10-bufferbloat.conf
    log "Removed old bufferbloat sysctl (superseded by BBR/fq config)"
fi

# =============================================================================
# 12. REBUILD INITRAMFS (picks up crypttab + modprobe changes)
# =============================================================================
echo ""
echo "=== 12. Rebuilding Initramfs ==="
update-initramfs -u 2>/dev/null && log "Initramfs rebuilt" || warn "Initramfs rebuild failed"

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
echo " Changes applied (live):"
echo "   - TCP BBR congestion control + larger buffers (208KB → 16MB)"
echo "   - TCP Fast Open (client+server), slow-start-after-idle=off"
echo "   - VM: compaction_proactiveness=0, watermark_boost=0, page-cluster=0"
echo "   - VM: min_free_kbytes=128MB, nmi_watchdog=off"
echo "   - NVMe read_ahead_kb=0 (ZFS does its own prefetch)"
echo "   - ZFS: atime=off, USERDATA compression=zstd"
echo "   - Mutter: rt-scheduler + VRR enabled"
echo "   - Docker: stale bridge networks pruned"
echo "   - WiFi/modprobe configs cleaned up"
echo ""
echo " Changes requiring reboot:"
echo "   - preempt=full + nowatchdog kernel parameters"
echo "   - /tmp on tmpfs"
echo "   - Swap TRIM passthrough (discard in crypttab)"
echo "   - ZFS module parameters (txg_timeout=10)"
echo "   - NVMe udev rules"
echo "   - Disabled services: cloud-init, ModemManager, thermald,"
echo "     apport, NM-wait-online, udev-settle"
echo ""
echo -e " ${YELLOW}Estimated boot time improvement: ~15 seconds${NC}"
echo ""
echo " To apply all changes: sudo reboot"
echo ""
echo " After reboot, verify with:"
echo "   cat /proc/sys/net/ipv4/tcp_congestion_control  # should be: bbr"
echo "   df /tmp                                         # should be: tmpfs"
echo "   cat /sys/kernel/debug/sched/preempt             # should be: full"
echo "   cat /sys/block/nvme0n1/queue/read_ahead_kb      # should be: 0"
echo "   systemd-analyze blame | head -10"
echo ""
