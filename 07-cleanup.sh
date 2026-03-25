#!/bin/bash
# =============================================================================
# Storage Cleanup — ASUS ROG Zephyrus G14 (GA402RJ)
#
# Reclaims disk space from:
#   - Trash
#   - node_modules and PHP vendor dirs in ~/projects
#   - pnpm global store (unreferenced packages)
#   - Docker: old images, dangling layers, build cache
#   - Browser caches (Chrome, Firefox)
#   - Playwright browser binaries cache
#   - APT package cache
#   - Old installer .deb files in ~/Downloads/programs (keeps latest per app)
#   - System journal (trims to configured limit)
#   - Snap old revisions
#   - pip cache
#   - Homebrew download cache
#
# Run as: bash 07-cleanup.sh
# Frequency: monthly, or whenever disk is tight
#
# What is NOT touched:
#   - Docker named volumes (may contain dev databases — rm manually if desired)
#   - ~/.ssh, ~/.gnupg, credentials
#   - Project source files
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${CYAN}==> $1${NC}"; }

HOME_DIR="${HOME:-/home/rafaolf}"
PROJECTS_DIR="$HOME_DIR/projects"
PROGRAMS_DIR="$HOME_DIR/Downloads/programs"

freed_total=0

du_mb() {
    du -sm "$1" 2>/dev/null | awk '{print $1}' || echo 0
}

# =============================================================================
# 1. TRASH
# =============================================================================
section "Trash"
before=$(du_mb "$HOME_DIR/.local/share/Trash")
rm -rf "$HOME_DIR/.local/share/Trash"/*
after=$(du_mb "$HOME_DIR/.local/share/Trash")
freed=$(( before - after ))
freed_total=$(( freed_total + freed ))
log "Trash emptied (~${freed} MB freed)"

# =============================================================================
# 2. node_modules
# =============================================================================
section "node_modules"
total_nm=0
for nm in "$PROJECTS_DIR"/*/node_modules; do
    [ -d "$nm" ] || continue
    mb=$(du_mb "$nm")
    rm -rf "$nm"
    project=$(basename "$(dirname "$nm")")
    log "Removed $project/node_modules (~${mb} MB)"
    total_nm=$(( total_nm + mb ))
done
# Also catch nested monorepo node_modules
for nm in "$PROJECTS_DIR"/*/packages/*/node_modules "$PROJECTS_DIR"/*/apps/*/node_modules; do
    [ -d "$nm" ] || continue
    mb=$(du_mb "$nm")
    rm -rf "$nm"
    rel="${nm#$PROJECTS_DIR/}"
    log "Removed $rel (~${mb} MB)"
    total_nm=$(( total_nm + mb ))
done
freed_total=$(( freed_total + total_nm ))
[ "$total_nm" -eq 0 ] && log "No node_modules found"

# =============================================================================
# 3. PHP vendor dirs
# =============================================================================
section "PHP vendor dirs"
total_vendor=0
for v in "$PROJECTS_DIR"/*/vendor; do
    [ -d "$v" ] || continue
    # Only treat as Composer vendor if composer.json exists alongside
    proj_dir="$(dirname "$v")"
    if [ -f "$proj_dir/composer.json" ]; then
        mb=$(du_mb "$v")
        rm -rf "$v"
        project=$(basename "$proj_dir")
        log "Removed $project/vendor (~${mb} MB)"
        total_vendor=$(( total_vendor + mb ))
    fi
done
freed_total=$(( freed_total + total_vendor ))
[ "$total_vendor" -eq 0 ] && log "No Composer vendor dirs found"

# =============================================================================
# 4. pnpm store
# =============================================================================
section "pnpm store"
if command -v pnpm &>/dev/null; then
    before=$(du_mb "$HOME_DIR/.local/share/pnpm" 2>/dev/null || echo 0)
    pnpm store prune --force 2>&1 | grep -E "Removed|removed" | tail -3 || true
    after=$(du_mb "$HOME_DIR/.local/share/pnpm" 2>/dev/null || echo 0)
    freed=$(( before - after ))
    freed_total=$(( freed_total + freed ))
    log "pnpm store pruned (~${freed} MB freed)"
else
    warn "pnpm not found, skipping"
fi

# =============================================================================
# 5. Docker
# =============================================================================
section "Docker"
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then

    # Dangling images
    before=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "0")
    dangling=$(docker images -f "dangling=true" -q)
    if [ -n "$dangling" ]; then
        docker rmi $dangling &>/dev/null && log "Removed dangling images"
    else
        log "No dangling images"
    fi

    # Remove images for old ddev versions — keeps only the latest tag per image name
    old_ddev=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'ddev/' | \
        awk -F: '{print $1}' | sort | uniq -d 2>/dev/null || true)
    if [ -n "$old_ddev" ]; then
        # Group by repo and remove all but the most recently created tag
        docker images --format '{{.Repository}} {{.Tag}} {{.CreatedAt}}' | grep 'ddev/' | \
        sort -k1,1 -k3,3r | \
        awk '!seen[$1]++ { next } { print $1 ":" $2 }' | \
        xargs -r docker rmi 2>/dev/null && log "Removed old ddev image versions" || true
    fi

    # Build cache
    cache_freed=$(docker builder prune -f --format '{{.ReclaimableSpace}}' 2>/dev/null || \
                  docker builder prune -f 2>&1 | grep -oP '[\d.]+ [KMGT]B' | tail -1 || echo "0 B")
    log "Docker build cache pruned ($cache_freed reclaimed)"

    # Stopped containers
    stopped=$(docker ps -a -q --filter "status=exited" --filter "status=created")
    if [ -n "$stopped" ]; then
        docker rm $stopped &>/dev/null && log "Removed stopped containers"
    else
        log "No stopped containers"
    fi

    # Unused networks
    docker network prune -f &>/dev/null && log "Pruned unused Docker networks"

else
    warn "Docker not running or not installed, skipping"
fi

# =============================================================================
# 6. Browser caches
# =============================================================================
section "Browser caches"
for cache_dir in \
    "$HOME_DIR/.cache/google-chrome" \
    "$HOME_DIR/.cache/mozilla" \
    "$HOME_DIR/.cache/chromium"
do
    if [ -d "$cache_dir" ]; then
        mb=$(du_mb "$cache_dir")
        rm -rf "$cache_dir"
        freed_total=$(( freed_total + mb ))
        log "Cleared $(basename "$cache_dir") cache (~${mb} MB)"
    fi
done

# =============================================================================
# 7. Playwright browser cache
# =============================================================================
section "Playwright cache"
for cache_dir in \
    "$HOME_DIR/.cache/ms-playwright" \
    "$HOME_DIR/.cache/ms-playwright-go"
do
    if [ -d "$cache_dir" ]; then
        mb=$(du_mb "$cache_dir")
        rm -rf "$cache_dir"
        freed_total=$(( freed_total + mb ))
        log "Cleared $(basename "$cache_dir") (~${mb} MB)"
    fi
done

# =============================================================================
# 8. pip cache
# =============================================================================
section "pip cache"
if [ -d "$HOME_DIR/.cache/pip" ]; then
    mb=$(du_mb "$HOME_DIR/.cache/pip")
    if command -v pip &>/dev/null; then
        pip cache purge &>/dev/null
    else
        rm -rf "$HOME_DIR/.cache/pip"
    fi
    freed_total=$(( freed_total + mb ))
    log "pip cache cleared (~${mb} MB)"
fi

# =============================================================================
# 9. Homebrew cache
# =============================================================================
section "Homebrew cache"
if [ -d "$HOME_DIR/.cache/Homebrew" ]; then
    mb=$(du_mb "$HOME_DIR/.cache/Homebrew")
    rm -rf "$HOME_DIR/.cache/Homebrew"
    freed_total=$(( freed_total + mb ))
    log "Homebrew download cache cleared (~${mb} MB)"
fi

# =============================================================================
# 10. Old installer .deb files — keep only latest per app
# =============================================================================
section "Old installer duplicates in Downloads/programs"
if [ -d "$PROGRAMS_DIR" ]; then
    total_debs=0

    # For each known app prefix, sort versions and delete all but the newest
    for prefix in "code_" "cursor_" "discord-" "amdgpu-install_"; do
        files=()
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$PROGRAMS_DIR" -maxdepth 1 -name "${prefix}*.deb" -print0 | sort -zV)

        count=${#files[@]}
        if [ "$count" -gt 1 ]; then
            # Remove all but the last (newest version by sort -V)
            for (( i=0; i<count-1; i++ )); do
                mb=$(du_mb "${files[$i]}")
                rm -f "${files[$i]}"
                total_debs=$(( total_debs + mb ))
                log "Removed old installer: $(basename "${files[$i]}") (~${mb} MB)"
            done
        fi
    done

    # Remove duplicate Firefox extracted dirs (keep the one without "(2)")
    while IFS= read -r -d '' dup; do
        mb=$(du_mb "$dup")
        rm -rf "$dup"
        total_debs=$(( total_debs + mb ))
        log "Removed duplicate: $(basename "$dup") (~${mb} MB)"
    done < <(find "$PROGRAMS_DIR" -maxdepth 1 -name "* (2)*" -print0 2>/dev/null)

    # Remove .tar.xz if extracted dir exists
    while IFS= read -r -d '' tarball; do
        base="${tarball%.tar.xz}"
        if [ -d "$base" ]; then
            mb=$(du_mb "$tarball")
            rm -f "$tarball"
            total_debs=$(( total_debs + mb ))
            log "Removed redundant tarball: $(basename "$tarball") (~${mb} MB)"
        fi
    done < <(find "$PROGRAMS_DIR" -maxdepth 1 -name "*.tar.xz" -print0 2>/dev/null)

    freed_total=$(( freed_total + total_debs ))
    [ "$total_debs" -eq 0 ] && log "No old installer duplicates found"
fi

# =============================================================================
# 11. Stale temp dirs in ~/tmp
# =============================================================================
section "~/tmp"
if [ -d "$HOME_DIR/tmp" ]; then
    mb=$(du_mb "$HOME_DIR/tmp")
    rm -rf "$HOME_DIR/tmp"/*
    freed_total=$(( freed_total + mb ))
    log "~/tmp cleared (~${mb} MB)"
fi

# =============================================================================
# 12. System journal (requires sudo)
# =============================================================================
section "System journal"
if [ "$EUID" -eq 0 ]; then
    journalctl --vacuum-size=100M 2>&1 | tail -2
    log "Journal trimmed to 100 MB"
else
    warn "Skipping journal trim (needs sudo) — run: sudo journalctl --vacuum-size=100M"
fi

# =============================================================================
# 13. APT cache (requires sudo)
# =============================================================================
section "APT cache"
if [ "$EUID" -eq 0 ]; then
    before=$(du_mb /var/cache/apt/archives)
    apt-get clean -q
    after=$(du_mb /var/cache/apt/archives)
    freed=$(( before - after ))
    freed_total=$(( freed_total + freed ))
    log "APT cache cleaned (~${freed} MB freed)"
else
    warn "Skipping APT cache (needs sudo) — run: sudo apt-get clean"
fi

# =============================================================================
# 14. Snap old revisions (requires sudo)
# =============================================================================
section "Snap old revisions"
if command -v snap &>/dev/null && [ "$EUID" -eq 0 ]; then
    snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
        snap remove "$snapname" --revision="$revision" 2>/dev/null && \
            log "Removed snap $snapname rev $revision" || true
    done
else
    [ "$EUID" -ne 0 ] && warn "Skipping snap cleanup (needs sudo)"
    command -v snap &>/dev/null || warn "snap not installed, skipping"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================="
echo " Cleanup complete — $(date)"
echo " Estimated space freed: ~${freed_total} MB ($(( freed_total / 1024 )) GB)"
echo "============================================="
echo ""
echo "Not touched (remove manually if needed):"
echo "  - Docker named volumes: docker volume ls"
echo "  - Root-owned backup dirs: sudo rm -rf ~/optimize-backup-* ~/stabilize-backup-*"
