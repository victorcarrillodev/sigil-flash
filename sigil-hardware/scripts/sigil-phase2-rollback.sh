#!/bin/bash
# sigil-phase2-rollback.sh — Reversible rollback from Phase 2 services
# (radio-fetcher + audio-manager + audio-player) back to radio-stream.
#
# Shares restoration logic with sigil-phase2-cutover.sh:
#   restore_service_from_snapshot() — handles all 4 active/enabled combos
#   restore_files_from_snapshot()   — cp -a restoration of state files
#
# Usage:
#   ./sigil-phase2-rollback.sh --dry-run   # preview without mutation (default)
#   ./sigil-phase2-rollback.sh --status    # show current service state
#   ./sigil-phase2-rollback.sh --apply     # execute rollback
#
# Safe to run more than once.
# Does NOT delete playlists, music, logs, archives, or state files.
# =============================================================================
set -euo pipefail

# Source shared restoration functions from cutover script.
# Guard at bottom of cutover prevents main() from auto-executing on source.
CUTOVER_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/sigil-phase2-cutover.sh"
if [ -f "$CUTOVER_SCRIPT" ]; then
    # shellcheck disable=SC1090  # Installed path is the runtime sibling of this script.
    source "$CUTOVER_SCRIPT"
else
    echo "ERROR: Cannot find ${CUTOVER_SCRIPT}" >&2
    exit 1
fi

# ── Paths ────────────────────────────────────────────────────────────────────
LEGACY_SERVICE="radio-stream.service"
NEW_SERVICES=("radio-fetcher.service" "audio-manager.service" "audio-player.service")

# ── Flags ────────────────────────────────────────────────────────────────────
MODE="dry-run"

# ── Helpers (non-shared, rollback-specific) ──────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }
error(){ log "ERROR: $*"; }

die() { error "$*"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Must run as root"
    fi
}

would() {
    if [ "$MODE" = "apply" ]; then
        "$@"
    else
        echo "         [DRY-RUN] Would: $*"
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────

do_status() {
    echo "=== Phase 2 Rollback Status ==="
    echo ""
    echo "--- Legacy ---"
    echo "  ${LEGACY_SERVICE}:"
    echo "    active:  $(systemctl is-active  "$LEGACY_SERVICE" 2>/dev/null || echo 'unknown')"
    echo "    enabled: $(systemctl is-enabled "$LEGACY_SERVICE" 2>/dev/null || echo 'unknown')"
    echo ""
    echo "--- Phase 2 (to be stopped) ---"
    for s in "${NEW_SERVICES[@]}"; do
        echo "  ${s}:"
        echo "    active:  $(systemctl is-active  "$s" 2>/dev/null || echo 'unknown')"
        echo "    enabled: $(systemctl is-enabled "$s" 2>/dev/null || echo 'unknown')"
    done
}

# ── Apply ─────────────────────────────────────────────────────────────────────

do_apply() {
    info "=== Phase 2 rollback: apply ==="

    # Find latest cutover snapshot
    local snapshot_dir
    snapshot_dir=$(python3 - "$BACKUP_DIR" <<'PY'
import glob
import os
import sys

snapshots = [path for path in glob.glob(os.path.join(sys.argv[1], "phase2-cutover-*")) if os.path.isdir(path)]
print(max(snapshots, key=os.path.getmtime) if snapshots else "")
PY
    )

    # 0. Restore config and state files from latest cutover backup using cp -a
    info "=== Step 0: Restore config/state from latest backup ==="
    if [ -n "$snapshot_dir" ] && [ -d "$snapshot_dir" ]; then
        if [ "$MODE" = "apply" ]; then
            restore_files_from_snapshot "$snapshot_dir" \
                "audio.conf" "cache_meta.json" "playlist.active.json" "audio_mode.json" || return 1
        else
            info "Would restore config/state from: ${snapshot_dir}"
        fi
    else
        info "No backup snapshot found — config/state files left unchanged"
    fi

    # 1. Restore every service recorded by the snapshot through the shared
    #    production path. This handles active/enabled independently and does
    #    not impose a special legacy-service state.
    info "=== Step 1: Restore all snapshotted service states ==="
    if [ -n "$snapshot_dir" ] && [ -f "${snapshot_dir}/service-snapshot.json" ]; then
        if [ "$MODE" = "apply" ]; then
            restore_all_services_from_snapshot "$snapshot_dir" || return 1
        else
            info "Would restore every service from snapshot: ${snapshot_dir}"
        fi
    else
        if [ "$MODE" = "apply" ]; then
            error "No service snapshot found; exact rollback is impossible"
            return 1
        fi
        info "No service snapshot found; apply would fail rather than invent service states"
    fi

    # 2. Verify every service against both recorded dimensions. An inactive or
    #    disabled legacy service is a successful result when that is the
    #    pre-cutover snapshot state.
    info "=== Step 2: Verify all restored service states ==="
    if [ "$MODE" = "apply" ] && [ -n "$snapshot_dir" ]; then
        verify_all_services_against_snapshot "$snapshot_dir" || return 1
    else
        info "Would verify active and enabled state for every snapshotted service"
    fi

    info "========================================"
    info "=== Phase 2 rollback complete ==="
    info "=== Cache, playlists, music, logs preserved ==="
    info "=== All snapshotted service states restored exactly ==="
    info "========================================"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) MODE="dry-run" ;;
            --status)  MODE="status" ;;
            --apply)   MODE="apply" ;;
            --help|-h)
                echo "Usage: $0 [--dry-run|--status|--apply]"
                echo ""
                echo "  --dry-run   Preview what would be done (default)"
                echo "  --status    Show current service state"
                echo "  --apply     Execute the rollback (must be root)"
                exit 0
                ;;
            *) die "Unknown argument: ${arg} (use --help)" ;;
        esac
    done

    case "$MODE" in
        status) do_status ;;
        dry-run)
            do_apply
            ;;
        apply)
            check_root
            do_apply
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
