# system-scripts

System optimization scripts for the **ASUS ROG Zephyrus G14 (GA402RJ)**.

| | |
|---|---|
| **OS** | Ubuntu 24.04.4 LTS |
| **Kernel** | 6.17 |
| **Root filesystem** | ZFS (with encrypted swap) |
| **CPU** | AMD Ryzen 9 6900HS (Zen 3+, 8C/16T) |
| **GPU (iGPU)** | AMD Rembrandt (RDNA 2 integrated) |
| **GPU (dGPU)** | AMD Radeon RX 6800S (Navi 23, RDNA 2) |
| **RAM** | 24 GB |
| **Storage** | NVMe SSD |
| **WiFi** | MediaTek MT7921e |

## Why

This laptop shipped with good hardware but Ubuntu's defaults leave a lot of performance on the table — especially on a ZFS root with an AMD hybrid GPU setup. Out of the box, the system suffered from:

- **ZFS boot pool (`bpool`) failing to import** on some boots, leaving `/boot` unmounted.
- **ZFS ARC eating all available memory** (no cap), starving desktop apps and triggering OOM kills.
- **dGPU (RX 6800S) drawing 8–15 W at idle** because runtime power management was disabled as a workaround for ACPI bugs in BIOS 318.
- **TCP using CUBIC** instead of BBR, with tiny 208 KB socket buffers — bad for WiFi throughput.
- **No kernel preemption tuning** — the default `voluntary` preemption model causes noticeable UI stutter under CPU load.
- **Tracker file indexer** burning CPU scanning the filesystem in the background.
- **19 squashfs mounts from snap** duplicate revisions, wasting kernel memory.
- **Unencrypted DNS** going through the ISP's resolver.
- **No ZRAM** — swap was only on an encrypted NVMe partition, orders of magnitude slower than compressed RAM.
- **Unused services** (cloud-init, ModemManager, thermald, apport, udev-settle) adding 15+ seconds to boot.
- **No hardware video decode** in Firefox snap — CPU decoding video instead of using VA-API.
- **WiFi power save** enabled by default, causing latency spikes.
- **No IRQ balancing** — all hardware interrupts pinned to CPU 0.

These scripts fix all of that in four incremental stages, each idempotent and safe to re-run.

## Scripts

### `01-stabilize-system.sh` — Stabilization

Gets the system into a reliable baseline state. Run this first.

| Change | What it does | Why |
|---|---|---|
| bpool import | Force-imports the ZFS boot pool and mounts `/boot` | Boot pool sometimes fails to auto-import, leaving the system unable to install kernel updates |
| `/etc/exports.d` | Creates the missing directory | `nfs-kernel-server` logs errors without it |
| ZFS ARC cap | Caps ARC at 8 GB (`zfs_arc_max=8589934592`) | Without a cap, ARC grows to consume all free RAM, causing memory pressure and OOM kills on a 24 GB system |
| VM tuning | `swappiness=10`, `vfs_cache_pressure=50` | ZFS has its own caching (ARC), so the kernel's page cache and swap behavior need to back off |
| GRUB kernel params | `amdgpu.runpm=0 amdgpu.gfxoff=0 amdgpu.dpm=1 acpi_backlight=native` | Disables dGPU runtime PM and GFX power gating to work around ACPI crashes on BIOS 318; enables native backlight control |
| GRUB menu | 3-second timeout, visible menu | Allows selecting a fallback kernel if a bad update lands |
| Module deps | `depmod -a` | Cleans up stale module references from removed kernels |
| initramfs | `update-initramfs -u` | Picks up the modprobe and crypttab changes |
| rasdaemon | Installs and enables hardware error monitoring | Logs MCE (Machine Check Exception) events so hardware errors are traceable instead of silent |
| WiFi modprobe | Consolidates `mt7921e disable_aspm=1` into one file | Duplicate modprobe entries across files cause warnings |
| Crash reports | Clears `/var/crash/*.crash` | Stale crash reports waste disk and trigger apport popups |

### `02-optimize-system.sh` — Performance

Tunes networking, memory, I/O, and services for a desktop workload.

| Change | What it does | Why |
|---|---|---|
| TCP BBR | Switches congestion control from CUBIC to BBR with `fq` qdisc | BBR delivers better throughput and lower latency, especially on WiFi and lossy networks |
| TCP buffers | `rmem_max`/`wmem_max` raised to 16 MB | Default 208 KB buffers bottleneck large downloads and streaming |
| TCP Fast Open | Enabled for client + server | Reduces latency on repeated connections by sending data in the SYN packet |
| MTU probing | `tcp_mtu_probing=1` | Auto-discovers optimal MTU, helps with VPNs and WiFi |
| VM deep tuning | `compaction_proactiveness=0`, `watermark_boost_factor=0`, `page-cluster=0`, `min_free_kbytes=128MB`, `nmi_watchdog=0` | Stops the kernel from fighting ZFS's cache management; reduces unnecessary background work; avoids direct reclaim stalls |
| Dirty pages | `dirty_ratio=10`, `dirty_background_ratio=5` | ZFS does its own write batching via TXG — hand off dirty pages quickly instead of accumulating large bursts |
| Kernel preemption | `preempt=full nowatchdog` | Full preemption eliminates UI stutter under CPU load; `nowatchdog` saves a perf counter |
| `/tmp` on tmpfs | 4 GB tmpfs | Keeps temp files in RAM instead of hitting ZFS/NVMe — reduces CoW write amplification |
| Swap TRIM | Adds `discard` to encrypted swap in crypttab | Passes TRIM through to the NVMe, maintaining SSD performance |
| ZFS datasets | `atime=off` on rpool, `compression=zstd` on USERDATA | Eliminates unnecessary metadata writes; zstd gives better compression than lz4 with negligible CPU on Zen 3+ |
| ZFS module | `zfs_txg_timeout=10`, `zfs_prefetch_disable=0` | Lets ZFS batch writes longer for efficiency; keeps prefetch enabled for sequential reads |
| NVMe read-ahead | `read_ahead_kb=0` via udev rule | ZFS does its own prefetch — kernel read-ahead is redundant and wastes DRAM |
| Mutter | `rt-scheduler` + VRR experimental features | Gives the compositor real-time priority via rtkit, reducing frame drops under load; enables variable refresh rate |
| Disabled services | cloud-init (×4), ModemManager, NetworkManager-wait-online, thermald, apport, systemd-udev-settle | None of these are needed on a physical laptop already managed by power-profiles-daemon; saves ~15 seconds of boot time |
| Docker cleanup | Prunes stale bridge networks | Orphaned Docker networks accumulate iptables rules and consume kernel memory |
| Config cleanup | Consolidates duplicate WiFi/modprobe/sysctl files | Multiple conflicting config files cause unpredictable behavior |

### `03-enhance-system.sh` — Enhancement

Final round of desktop UX and multimedia improvements.

| Change | What it does | Why |
|---|---|---|
| Tracker | Masks `tracker-miner-fs-3` and clears the index | Tracker causes periodic CPU spikes scanning the filesystem; GNOME Files browsing still works fine without it |
| DING extension | Disables Desktop Icons NG | DING spawns a separate process for desktop icons — one of the heavier GNOME extensions, and desktop icons aren't useful on a tiling/workflow setup |
| `mitigations=off` | Disables Spectre/Meltdown/SRSO kernel mitigations | ~5–15% CPU performance boost; acceptable trade-off on a single-user personal machine where all running software is trusted |
| PipeWire | `quantum=512` (10.7 ms latency), WirePlumber ALSA headroom tuning | Default 21.3 ms latency is noticeably sluggish for desktop audio, notifications, and video playback |
| Firefox VA-API | Sets `MOZ_DISABLE_RDD_SANDBOX=1`, `MOZ_ENABLE_WAYLAND=1`, and `user.js` prefs | Firefox snap doesn't enable hardware video decode by default — without this, the CPU decodes all video, wasting power and causing thermal throttling |
| Backup consolidation | Moves backup dirs from `~` into `system-scripts/` | Keeps the home directory clean |

### `04-deep-optimize.sh` — Deep Optimization

Second-pass tuning: swap, IRQs, DNS, IOMMU, and hardware-specific platform integration.

| Change | What it does | Why |
|---|---|---|
| ZRAM | 8 GB zstd-compressed swap at priority 100 | Swap at RAM speed (~50 GB/s) instead of NVMe speed (~3.5 GB/s); zstd gives ~2–3× compression ratio, so 8 GB ZRAM holds ~16–20 GB of data; NVMe swap stays as lower-priority fallback |
| irqbalance | Distributes hardware interrupts across all 16 threads | Without it, all IRQs go to CPU 0, which becomes a bottleneck under I/O-heavy workloads |
| DNS-over-TLS | Cloudflare 1.1.1.1 primary, Google 8.8.8.8 fallback, Quad9 9.9.9.9 emergency | Encrypts DNS queries (prevents ISP snooping/injection); Cloudflare is consistently the fastest public resolver |
| Journald | 100 MB cap, 16 MB max file, 1-week retention, no compression | On ZFS, every log write is a CoW operation; ZFS already compresses at block level so journal compression wastes CPU; the default unlimited journal had grown to 286 MB |
| Snap cleanup | `refresh.retain=2`, refresh window 4–5 AM, old revisions removed | Reduces squashfs mount count; prevents snap refreshes from disrupting active use |
| `iommu=pt` | IOMMU passthrough mode | Devices that don't need IOMMU translation bypass it entirely, reducing DMA overhead |
| ROG thermal profiles | Auto AC→performance / battery→balanced via udev + `rog-profile` CLI helper | Automatically uses full performance when plugged in and conserves battery when unplugged; the helper script lets you manually override |
| CPU EPP | Auto AC→`balance_performance` / battery→`balance_power` via udev | Complements the thermal profile switching with CPU energy/performance preference tuning |
| dGPU runtime PM | Re-enables `amdgpu.runpm` and `amdgpu.gfxoff` (removes the overrides from script 01) | With BIOS 319 + kernel 6.17, the ACPI bugs are fixed; the RX 6800S drops from 8–15 W idle to <1 W in D3cold |
| Module blacklist | Blacklists Intel VA-API drivers (`i915`, `i965`, `iHD`) | Not needed on an all-AMD system; loaded Intel drivers waste memory and can confuse libva driver selection |
| inotify limits | `max_user_instances=1024` | IDEs, Docker, and file watchers all consume inotify instances; the default 128 is too low for development workloads |
| USB autosuspend | Disables autosuspend for USB audio and video devices | Prevents PipeWire glitches and webcam reconnection issues caused by aggressive 2-second autosuspend |
| Safety script | `/usr/local/bin/rog-disable-dgpu-pm` | One-command rollback if dGPU runtime PM causes instability |

## Usage

Each script must be run as root. They are designed to be run in order, but each is idempotent — safe to re-run at any time.

```bash
sudo bash 01-stabilize-system.sh
sudo bash 02-optimize-system.sh
sudo bash 03-enhance-system.sh
sudo bash 04-deep-optimize.sh
sudo reboot
```

Each script creates a timestamped backup of every config file it modifies before making changes.

## Post-reboot verification

```bash
# Script 01
zpool status bpool
mount | grep boot
cat /sys/module/zfs/parameters/zfs_arc_max        # 8589934592

# Script 02
cat /proc/sys/net/ipv4/tcp_congestion_control      # bbr
df /tmp                                             # tmpfs
cat /sys/kernel/debug/sched/preempt                 # full
cat /sys/block/nvme0n1/queue/read_ahead_kb          # 0
systemd-analyze blame | head -10

# Script 03
grep mitigations /proc/cmdline                      # mitigations=off
pw-metadata -n settings 0 | grep quantum            # 512
systemctl --user status tracker-miner-fs-3          # masked

# Script 04
swapon --show                                       # zram0 + dm-crypt
resolvectl status                                   # DoT + Cloudflare
journalctl --disk-usage                             # ≤100 MB
grep iommu /proc/cmdline                            # iommu=pt
cat /sys/class/drm/card1/device/power/runtime_status # suspended (when idle)
sudo rog-profile status
```

## Installed tools

| Command | Description |
|---|---|
| `sudo rog-profile balanced\|performance\|quiet\|status` | Switch ASUS thermal/fan profile |
| `sudo rog-disable-dgpu-pm` | Emergency rollback: re-disable dGPU runtime PM if system becomes unstable |
