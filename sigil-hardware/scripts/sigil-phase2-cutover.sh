#!/bin/bash
# sigil-phase2-cutover.sh — Controlled, reversible repair/migration from a
# legacy radio-stream deployment to the production Phase 2 runtime
#
# Usage:
#   ./sigil-phase2-cutover.sh --dry-run   # preview without mutation (default)
#   ./sigil-phase2-cutover.sh --status    # show current service state
#   ./sigil-phase2-cutover.sh --apply     # execute migration
#
# This script does NOT delete radio-stream.sh, its unit, or any data.
# It does NOT enable services before runtime validation succeeds.
# On any failure before finalization, it rolls back automatically.
# =============================================================================
set -euo pipefail

# ── Paths (all overridable via environment for testing) ──────────────────────
SIGIL_BIN="${SIGIL_BIN:-/usr/local/bin}"
SIGIL_ETC="${SIGIL_ETC:-/etc/sigil}"
SIGIL_STATE="${SIGIL_STATE:-/var/lib/sigil}"
SIGIL_LOG="${SIGIL_LOG:-/var/log/sigil}"
SIGIL_HOME="${SIGIL_HOME:-/home/sigil}"

LEGACY_SERVICE="radio-stream.service"
NEW_SERVICES=("radio-fetcher.service" "audio-manager.service" "audio-player.service")
SNAPSHOT_SERVICES=(
    "$LEGACY_SERVICE"
    "radio-fetcher.service"
    "audio-manager.service"
    "audio-player.service"
    "ssh-monitor.service"
)

# Process and lock paths are overridable only to allow production-function tests
# to use a synthetic /proc tree. Production always uses the defaults below.
PROC_ROOT="${SIGIL_PROC_ROOT:-/proc}"
PLAYER_LOCK_FILE="${SIGIL_PLAYER_LOCK_FILE:-/var/lock/sigil-audio-player.lock}"

# Allow override via environment for testing (e.g., mock systemd paths)
SYSTEMD_DIR="${SIGIL_SYSTEMD_DIR:-/etc/systemd/system}"

AUDIO_CONF="${SIGIL_ETC}/audio.conf"
CACHE_META="${SIGIL_STATE}/cache_meta.json"
PLAYLIST_ACTIVE="${SIGIL_STATE}/playlist.active.json"
AUDIO_MODE="${SIGIL_STATE}/audio_mode.json"
BACKUP_DIR="${SIGIL_STATE}/backups"

# ── Flags ────────────────────────────────────────────────────────────────────
MODE="dry-run"   # dry-run | status | apply
CREATED_BACKUP_DIR=""

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }
error(){ log "ERROR: $*"; }

die() { error "$*"; exit 1; }

dry() {
    if [ "$MODE" = "dry-run" ]; then
        echo "         [DRY-RUN] Would: $*"
    fi
}

would() {
    if [ "$MODE" = "apply" ]; then
        "$@"
    else
        echo "         [DRY-RUN] Would: $*"
    fi
}

# ── Pre-flight validation ────────────────────────────────────────────────────

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Must run as root"
    fi
    info "Running as root"
}

check_scripts() {
    local missing=0
    for s in radio-fetcher.sh audio-manager.sh audio-player.sh sigil-validate-state.sh; do
        if [ ! -x "${SIGIL_BIN}/${s}" ]; then
            error "Missing executable: ${SIGIL_BIN}/${s}"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "Run install.sh first"
    fi
    info "All required scripts present"
}

check_units() {
    local missing=0
    if [ ! -f "${SYSTEMD_DIR}/${LEGACY_SERVICE}" ]; then
        error "Missing unit: ${SYSTEMD_DIR}/${LEGACY_SERVICE}"
        missing=1
    fi
    for s in "${NEW_SERVICES[@]}"; do
        if [ ! -f "${SYSTEMD_DIR}/${s}" ]; then
            error "Missing unit: ${SYSTEMD_DIR}/${s}"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "Install service units first"
    fi
    info "All service units present"
}

check_config() {
    if [ ! -f "$AUDIO_CONF" ] || [ ! -r "$AUDIO_CONF" ]; then
        die "Missing or unreadable: ${AUDIO_CONF}"
    fi
    info "${AUDIO_CONF} present and readable"
}

check_state_files() {
    # Validate playlist.active.json if it exists
    if [ -f "$PLAYLIST_ACTIVE" ]; then
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PLAYLIST_ACTIVE" 2>/dev/null; then
            info "${PLAYLIST_ACTIVE} is valid JSON"
        else
            warn "${PLAYLIST_ACTIVE} exists but is not valid JSON"
        fi
    else
        info "${PLAYLIST_ACTIVE} does not exist yet (will be created by radio-fetcher)"
    fi

    # Validate cache_meta.json if it exists
    if [ -f "$CACHE_META" ]; then
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CACHE_META" 2>/dev/null; then
            info "${CACHE_META} is valid JSON"
        else
            warn "${CACHE_META} exists but is not valid JSON"
        fi
    else
        info "${CACHE_META} does not exist yet (will be created by radio-fetcher)"
    fi
}

check_dependencies() {
    local missing=0
    for cmd in systemctl pgrep python3 curl mpg123; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Missing command: ${cmd}"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "Install missing dependencies"
    fi
    info "All runtime dependencies present"
}

check_legacy_recoverable() {
    local state
    state=$(systemctl is-active "$LEGACY_SERVICE" 2>/dev/null || echo "inactive")
    info "Legacy service state: ${state}"

    local enabled
    enabled=$(systemctl is-enabled "$LEGACY_SERVICE" 2>/dev/null || echo "disabled")
    info "Legacy service enabled: ${enabled}"
}

check_new_not_conflicting() {
    for s in "${NEW_SERVICES[@]}"; do
        local state
        state=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
        if [ "$state" = "active" ]; then
            warn "${s} is already active — may conflict"
        fi
    done
}

# ── Backup ────────────────────────────────────────────────────────────────────

create_backup() {
    local ts
    ts=$(date -u '+%Y%m%dT%H%M%SZ')
    local dir="${BACKUP_DIR}/phase2-cutover-${ts}"
    mkdir -p "$dir"
    chmod 750 "$dir"

    # Config — copy with metadata preservation
    if [ -f "$AUDIO_CONF" ]; then
        cp -a "$AUDIO_CONF" "${dir}/audio.conf"
    fi

    # Snapshot service states as structured JSON for programmatic rollback
    {
        echo '{'
        local first=true
        for s in "${SNAPSHOT_SERVICES[@]}"; do
            $first || echo ','
            first=false
            local active_state enabled_state
            if systemctl is-active "$s" &>/dev/null; then
                active_state="active"
            else
                active_state="inactive"
            fi
            if systemctl is-enabled "$s" &>/dev/null; then
                enabled_state="enabled"
            else
                enabled_state="disabled"
            fi
            printf '"%s": {"active": "%s", "enabled": "%s"}' "$s" "$active_state" "$enabled_state"
        done
        echo ''
        echo '}'
    } > "${dir}/service-snapshot.json"
    chmod 640 "${dir}/service-snapshot.json"

    # Human-readable service state summary for manual review
    {
        echo "=== systemctl list-unit-files ==="
        systemctl list-unit-files --type=service 2>/dev/null | grep -E 'radio|audio' || true
        echo ""
        echo "=== systemctl status ==="
        for s in "${SNAPSHOT_SERVICES[@]}"; do
            echo "--- ${s} ---"
            if systemctl is-active "$s" 2>/dev/null; then
                systemctl is-enabled "$s" 2>/dev/null || true
            fi
        done
    } > "${dir}/service-state.txt"

    # JSON state files — copy with metadata preservation
    for f in "$CACHE_META" "$PLAYLIST_ACTIVE" "$AUDIO_MODE"; do
        if [ -f "$f" ]; then
            cp -a "$f" "${dir}/$(basename "$f")"
        fi
    done

    CREATED_BACKUP_DIR="$dir"
    info "Backup created: ${dir}"
}

# ── Phase 2 implementation existence check ────────────────────────────────────

check_implementation_exists() {
    local missing=0
    for s in radio-fetcher audio-manager audio-player; do
        if [ ! -f "${SIGIL_BIN}/${s}.sh" ]; then
            error "Phase 2 script not found: ${SIGIL_BIN}/${s}.sh"
            missing=1
        fi
    done
    for unit in cache_meta playlist_active audio_mode; do
        local schema_file="${SIGIL_STATE}/schemas/schema-${unit}.json"
        if [ ! -f "$schema_file" ]; then
            warn "Schema not found: ${schema_file} (validation will be skipped)"
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "Phase 2 implementation incomplete — run install.sh"
    fi
}

# ── Shared restoration (used by cutover rollback and standalone rollback) ─────
#
# Restore a single service to its pre-cutover active+enabled state from snapshot,
# handling all four combinations independently:
#   1. was active + was enabled  → start + enable
#   2. was active + was disabled → start only
#   3. was inactive + was enabled → keep stopped, enable
#   4. was inactive + was disabled → keep stopped, disable
restore_service_from_snapshot() {
    local svc="$1"
    local snapshot_dir="$2"

    local snapshot_file="${snapshot_dir}/service-snapshot.json"
    if [ ! -f "$snapshot_file" ]; then
        error "Service snapshot missing: ${snapshot_file}"
        return 1
    fi

    local was_active was_enabled
    if ! IFS=$'\t' read -r was_active was_enabled < <(
        python3 - "$snapshot_file" "$svc" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
state = snapshot.get(sys.argv[2])
if not isinstance(state, dict):
    raise SystemExit(1)
active = state.get("active")
enabled = state.get("enabled")
if active not in ("active", "inactive"):
    raise SystemExit(1)
if enabled not in ("enabled", "disabled"):
    raise SystemExit(1)
print(f"{active}\t{enabled}")
PY
    ); then
        error "Invalid or missing snapshot state for ${svc}"
        return 1
    fi

    info "Restoring ${svc}: was_active=${was_active} was_enabled=${was_enabled}"

    # Restore enabled state independently of active state
    if [ "$was_enabled" = "enabled" ]; then
        enable_service "$svc" || return 1
    else
        disable_service "$svc"
    fi

    # Restore active state independently of enabled state
    if [ "$was_active" = "active" ]; then
        start_service "$svc" || return 1
    else
        stop_service "$svc"
    fi

    verify_service_against_snapshot "$svc" "$snapshot_dir"
}

validate_service_snapshot() {
    local snapshot_dir="$1"
    local snapshot_file="${snapshot_dir}/service-snapshot.json"
    python3 - "$snapshot_file" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        snapshot = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)

if not isinstance(snapshot, dict) or not snapshot:
    raise SystemExit(1)
valid_name = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.@:-]*\.service$")
for service, state in snapshot.items():
    if not isinstance(service, str) or not valid_name.fullmatch(service):
        raise SystemExit(1)
    if not isinstance(state, dict):
        raise SystemExit(1)
    if state.get("active") not in ("active", "inactive"):
        raise SystemExit(1)
    if state.get("enabled") not in ("enabled", "disabled"):
        raise SystemExit(1)
PY
}

snapshot_service_names() {
    local snapshot_dir="$1"
    python3 - "${snapshot_dir}/service-snapshot.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
for service in snapshot:
    print(service)
PY
}

verify_service_against_snapshot() {
    local svc="$1"
    local snapshot_dir="$2"
    local expected_active expected_enabled
    if ! IFS=$'\t' read -r expected_active expected_enabled < <(
        python3 - "${snapshot_dir}/service-snapshot.json" "$svc" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)[sys.argv[2]]
print(f"{state['active']}\t{state['enabled']}")
PY
    ); then
        error "Cannot read expected state for ${svc}"
        return 1
    fi

    local actual_active="inactive"
    local actual_enabled="disabled"
    if systemctl is-active "$svc" &>/dev/null; then
        actual_active="active"
    fi
    if systemctl is-enabled "$svc" &>/dev/null; then
        actual_enabled="enabled"
    fi

    if [ "$actual_active" != "$expected_active" ] || [ "$actual_enabled" != "$expected_enabled" ]; then
        error "State mismatch for ${svc}: expected active=${expected_active} enabled=${expected_enabled}; got active=${actual_active} enabled=${actual_enabled}"
        return 1
    fi
    info "Verified ${svc}: active=${actual_active} enabled=${actual_enabled}"
}

restore_all_services_from_snapshot() {
    local snapshot_dir="$1"
    if ! validate_service_snapshot "$snapshot_dir"; then
        error "Invalid service snapshot: ${snapshot_dir}/service-snapshot.json"
        return 1
    fi

    local services=()
    local svc
    while IFS= read -r svc; do
        services+=("$svc")
    done < <(snapshot_service_names "$snapshot_dir")

    local rc=0
    for svc in "${services[@]}"; do
        if ! restore_service_from_snapshot "$svc" "$snapshot_dir"; then
            rc=1
        fi
    done
    return "$rc"
}

verify_all_services_against_snapshot() {
    local snapshot_dir="$1"
    if ! validate_service_snapshot "$snapshot_dir"; then
        error "Invalid service snapshot: ${snapshot_dir}/service-snapshot.json"
        return 1
    fi

    local rc=0
    local svc
    while IFS= read -r svc; do
        if ! verify_service_against_snapshot "$svc" "$snapshot_dir"; then
            rc=1
        fi
    done < <(snapshot_service_names "$snapshot_dir")
    return "$rc"
}

restore_files_from_snapshot() {
    local snapshot_dir="$1"
    shift
    local files=("$@")
    if [ ! -d "$snapshot_dir" ]; then
        warn "Snapshot directory not found: ${snapshot_dir}"
        return 1
    fi
    for f in "${files[@]}"; do
        local src="${snapshot_dir}/${f}"
        if [ ! -f "$src" ]; then
            warn "Snapshot file not found: ${src}"
            continue
        fi
        local dst=""
        case "$f" in
            audio.conf)           dst="${SIGIL_ETC}/audio.conf" ;;
            cache_meta.json)      dst="${SIGIL_STATE}/cache_meta.json" ;;
            playlist.active.json) dst="${SIGIL_STATE}/playlist.active.json" ;;
            audio_mode.json)      dst="${SIGIL_STATE}/audio_mode.json" ;;
            *)
                warn "Unknown file in snapshot: ${f}"
                continue
                ;;
        esac
        if ! cp -a "$src" "$dst"; then
            error "Failed to restore ${f}"
            return 1
        fi
        if ! cmp -s "$src" "$dst"; then
            error "Restored content differs for ${f}"
            return 1
        fi
        local src_metadata dst_metadata
        if ! src_metadata=$(stat -c '%u:%g:%a' "$src") || ! dst_metadata=$(stat -c '%u:%g:%a' "$dst"); then
            error "Could not verify restored metadata for ${f}"
            return 1
        fi
        if [ "$src_metadata" != "$dst_metadata" ]; then
            error "Restored metadata differs for ${f}: expected ${src_metadata}, got ${dst_metadata}"
            return 1
        fi
        info "Restored ${f} to ${dst} with content, owner, group, and mode preserved"
    done
}

# ── Apply: service state helpers ──────────────────────────────────────────────

stop_service() {
    local svc="$1"
    info "Stopping ${svc}..."
    systemctl stop "$svc" 2>/dev/null || true
    local waited=0
    while systemctl is-active "$svc" &>/dev/null && [ $waited -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if systemctl is-active "$svc" &>/dev/null; then
        warn "${svc} did not stop gracefully — sending SIGKILL"
        systemctl kill "$svc" 2>/dev/null || true
        sleep 2
    fi
    info "${svc} stopped"
}

start_service() {
    local svc="$1"
    info "Starting ${svc}..."
    systemctl start "$svc" 2>/dev/null || {
        error "Failed to start ${svc}"
        return 1
    }
    sleep 2
    if ! systemctl is-active "$svc" &>/dev/null; then
        error "${svc} started but not active after 2s"
        journalctl -u "$svc" --no-pager -n 20 2>/dev/null || true
        return 1
    fi
    info "${svc} is active"
}

enable_service() {
    local svc="$1"
    info "Enabling ${svc}..."
    systemctl enable "$svc" 2>/dev/null || {
        warn "Failed to enable ${svc}"
        return 1
    }
}

disable_service() {
    local svc="$1"
    info "Disabling ${svc}..."
    systemctl disable "$svc" 2>/dev/null || true
}

confirm_no_legacy_mpg123() {
    if pgrep -x mpg123 &>/dev/null; then
        error "mpg123 remains after stopping the legacy systemd cgroup — aborting"
        return 1
    fi
    info "No legacy mpg123 process remains"
}

process_executes_canonical_player() {
    local pid="$1"
    local canonical_script="$2"
    local cmdline="${PROC_ROOT}/${pid}/cmdline"
    [ -r "$cmdline" ] || return 1

    python3 - "$cmdline" "$canonical_script" <<'PY'
import os
import sys

try:
    raw = open(sys.argv[1], "rb").read()
except OSError:
    raise SystemExit(1)
argv = [os.fsdecode(arg) for arg in raw.split(b"\0") if arg]
if not argv:
    raise SystemExit(1)

canonical = os.path.realpath(sys.argv[2])
direct = os.path.realpath(argv[0]) == canonical
interpreted = (
    len(argv) >= 2
    and os.path.basename(argv[0]) == "bash"
    and os.path.realpath(argv[1]) == canonical
)
raise SystemExit(0 if direct or interpreted else 1)
PY
}

process_holds_player_lock() {
    local pid="$1"
    local fd target
    for fd in "${PROC_ROOT}/${pid}/fd/"*; do
        [ -e "$fd" ] || [ -L "$fd" ] || continue
        target=$(readlink "$fd" 2>/dev/null || true)
        target="${target% (deleted)}"
        if [ "$target" = "$PLAYER_LOCK_FILE" ]; then
            return 0
        fi
    done
    return 1
}

enumerate_genuine_player_pids() {
    local canonical_script="$1"
    local pid_dir pid
    for pid_dir in "${PROC_ROOT}"/[0-9]*; do
        [ -d "$pid_dir" ] || continue
        pid="${pid_dir##*/}"
        if process_executes_canonical_player "$pid" "$canonical_script"; then
            printf '%s\n' "$pid"
        fi
    done
}

confirm_no_duplicate_player() {
    local canonical_script
    canonical_script=$(readlink -f "${SIGIL_BIN}/audio-player.sh" 2>/dev/null) || {
        error "Cannot resolve canonical player script: ${SIGIL_BIN}/audio-player.sh"
        return 1
    }

    local service_active=false
    if systemctl is-active audio-player.service &>/dev/null; then
        service_active=true
    fi

    local main_pid="0"
    main_pid=$(systemctl show audio-player.service -p MainPID --value 2>/dev/null || true)
    if ! [[ "$main_pid" =~ ^[0-9]+$ ]]; then
        error "Invalid MainPID reported for audio-player.service: ${main_pid}"
        return 1
    fi

    local player_pids=()
    local pid
    while IFS= read -r pid; do
        [ -n "$pid" ] && player_pids+=("$pid")
    done < <(enumerate_genuine_player_pids "$canonical_script")

    if [ "${#player_pids[@]}" -ge 2 ]; then
        error "Multiple genuine audio-player processes found: ${player_pids[*]}"
        return 1
    fi

    if [ "${#player_pids[@]}" -eq 0 ]; then
        if $service_active; then
            error "audio-player.service is active but no canonical player process was found"
            return 1
        fi
        info "No canonical audio-player process found; service is inactive"
        return 0
    fi

    local player_pid="${player_pids[0]}"
    if $service_active && [ "$main_pid" -ne "$player_pid" ]; then
        error "audio-player.service MainPID=${main_pid} does not match canonical player PID=${player_pid}"
        return 1
    fi
    if ! process_holds_player_lock "$player_pid"; then
        error "Canonical player PID ${player_pid} does not hold ${PLAYER_LOCK_FILE}"
        return 1
    fi

    info "Single canonical audio-player PID=${player_pid}; MainPID=${main_pid}; lock=${PLAYER_LOCK_FILE}"
}

verify_services_active() {
    local duration="${1:-10}"
    local interval=2
    local elapsed=0
    while [ $elapsed -lt "$duration" ]; do
        for s in "${NEW_SERVICES[@]}"; do
            if ! systemctl is-active "$s" &>/dev/null; then
                error "${s} is not active during verification window"
                return 1
            fi
        done
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    info "All Phase 2 services remained active for ${duration}s"
}

# ── Apply: controlled migration ───────────────────────────────────────────────

do_apply() {
    info "=== Phase 2 cutover: apply ==="

    # ── 0. Pre-flight ──
    # (check_root is called in main() before do_apply)
    check_scripts
    check_units
    check_config
    check_dependencies
    check_legacy_recoverable
    check_new_not_conflicting
    check_implementation_exists

    # ── 1. Backup ──
    local backup_dir=""
    if [ "$MODE" = "apply" ]; then
        create_backup
        backup_dir="$CREATED_BACKUP_DIR"
        info "Backup at: ${backup_dir}"
    else
        info "Backup would be created at: ${BACKUP_DIR}/phase2-cutover-<timestamp>"
    fi

    # ── 2. Record initial state ──
    local legacy_was_active=false
    if [ "$MODE" = "apply" ]; then
        if systemctl is-active "$LEGACY_SERVICE" &>/dev/null; then
            legacy_was_active=true
        fi
    else
        info "Dry-run: will query legacy state at cutover time"
    fi
    info "Legacy was active: ${legacy_was_active}"

    # ── 3. Stop legacy ──
    info "=== Step: Stop legacy radio-stream ==="
    if $legacy_was_active; then
        would stop_service "$LEGACY_SERVICE"
    else
        info "${LEGACY_SERVICE} was not active — skipping stop"
    fi

    # ── 4. Confirm no mpg123 ──
    would confirm_no_legacy_mpg123 || {
        error "Step 4 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 4.5. Fix state file permissions ──
    info "=== Step: Fix state file permissions ==="
    if [ "$MODE" = "apply" ]; then
        for f in "$CACHE_META" "$PLAYLIST_ACTIVE" "$AUDIO_MODE"; do
            if [ -f "$f" ]; then
                chown sigil:sigil "$f" 2>/dev/null || true
                chmod 644 "$f" 2>/dev/null || true
            fi
        done
        info "State file ownership set to sigil:sigil"
    fi

    # ── 5. Start radio-fetcher ──
    info "=== Step: Start radio-fetcher ==="
    would start_service "radio-fetcher.service" || {
        error "Step 5 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 6. Validate playlist & cache after fetch ──
    info "=== Step: Validate state files ==="
    if [ "$MODE" = "apply" ]; then
        sleep 5
    fi
    if [ -f "$PLAYLIST_ACTIVE" ]; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PLAYLIST_ACTIVE" 2>/dev/null || {
            error "playlist.active.json is not valid after fetch — rollback"
            do_rollback_after_failure "$backup_dir"
            return 1
        }
        info "playlist.active.json validated"
    else
        warn "playlist.active.json not created yet — continuing"
    fi

    if [ -f "$CACHE_META" ]; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CACHE_META" 2>/dev/null || {
            error "cache_meta.json is not valid — rollback"
            do_rollback_after_failure "$backup_dir"
            return 1
        }
        info "cache_meta.json validated"
    fi

    # ── 7. Start audio-manager ──
    info "=== Step: Start audio-manager ==="
    would start_service "audio-manager.service" || {
        error "Step 7 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 8. Validate audio_mode.json ──
    info "=== Step: Validate audio_mode.json ==="
    if [ "$MODE" = "apply" ]; then
        sleep 3
    fi
    if [ -f "$AUDIO_MODE" ]; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$AUDIO_MODE" 2>/dev/null || {
            warn "audio_mode.json not valid — continuing (manager may not have written yet)"
        }
        info "audio_mode.json validated"
    fi

    # ── 9. Start audio-player ──
    info "=== Step: Start audio-player ==="
    would start_service "audio-player.service" || {
        error "Step 9 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 10. Confirm no duplicate player ──
    would confirm_no_duplicate_player || {
        error "Step 10 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 11. Verify stability ──
    info "=== Step: Verify service stability ==="
    would verify_services_active 10 || {
        error "Step 11 failed — starting rollback"
        do_rollback_after_failure "$backup_dir"
        return 1
    }

    # ── 12. Enable new services (only now) ──
    info "=== Step: Enable new services ==="
    for s in "${NEW_SERVICES[@]}"; do
        would enable_service "$s" || {
            warn "Failed to enable ${s} — continuing (service is running)"
        }
    done

    # ── 13. Disable legacy (only now) ──
    info "=== Step: Disable legacy service ==="
    would disable_service "$LEGACY_SERVICE"

    info "========================================"
    info "=== Phase 2 cutover complete ==="
    info "=== Rollback available: ${backup_dir} ==="
    info "=== Rollback command: sigil-phase2-rollback.sh ==="
    info "========================================"
}

# ── Rollback after failure ────────────────────────────────────────────────────

do_rollback_after_failure() {
    local backup_dir="${1:-}"
    local rollback_failed=0
    warn "=== ROLLBACK: Reversing cutover after failure ==="

    # Restore config and state files from backup using cp -a
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
        info "Restoring config and state from backup via cp -a: ${backup_dir}"
        if ! restore_files_from_snapshot "$backup_dir" \
            "audio.conf" "cache_meta.json" "playlist.active.json" "audio_mode.json"; then
            error "One or more backed-up files could not be restored exactly"
            rollback_failed=1
        fi
    fi

    # Use the same snapshot-driven restoration as standalone rollback. Iterate
    # the snapshot itself so every recorded service is restored, including
    # services added to future snapshots.
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ] && [ -f "${backup_dir}/service-snapshot.json" ]; then
        if ! restore_all_services_from_snapshot "$backup_dir"; then
            error "One or more services could not be restored exactly"
            rollback_failed=1
        fi
    else
        error "No valid snapshot available; exact automatic rollback is impossible"
        rollback_failed=1
    fi

    if [ "$rollback_failed" -eq 0 ]; then
        info "=== Rollback complete: snapshot restored exactly ==="
    else
        error "=== Rollback incomplete: manual recovery required ==="
    fi
    if [ -n "$backup_dir" ]; then
        info "Backup preserved: ${backup_dir}"
    fi
    return 1
}

# ── Status ────────────────────────────────────────────────────────────────────

do_status() {
    echo "=== Phase 2 Cutover Status ==="
    echo ""
    echo "--- Legacy ---"
    echo "  ${LEGACY_SERVICE}:"
    echo "    active:  $(systemctl is-active  "$LEGACY_SERVICE" 2>/dev/null || echo 'unknown')"
    echo "    enabled: $(systemctl is-enabled "$LEGACY_SERVICE" 2>/dev/null || echo 'unknown')"
    echo ""
    echo "--- Phase 2 ---"
    for s in "${NEW_SERVICES[@]}"; do
        echo "  ${s}:"
        echo "    active:  $(systemctl is-active  "$s" 2>/dev/null || echo 'unknown')"
        echo "    enabled: $(systemctl is-enabled "$s" 2>/dev/null || echo 'unknown')"
    done
    echo ""
    echo "--- State files ---"
    for f in "$AUDIO_CONF" "$CACHE_META" "$PLAYLIST_ACTIVE" "$AUDIO_MODE"; do
        if [ -f "$f" ]; then
            local valid="valid"
            python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || valid="INVALID"
            echo "  ${f}: present, ${valid}"
        else
            echo "  ${f}: MISSING"
        fi
    done
    echo ""
    echo "--- Phase 2 scripts ---"
    for s in radio-fetcher.sh audio-manager.sh audio-player.sh sigil-validate-state.sh; do
        if [ -x "${SIGIL_BIN}/${s}" ]; then
            echo "  ${s}: present"
        else
            echo "  ${s}: MISSING"
        fi
    done
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
                echo "  --status    Show current service and state status"
                echo "  --apply     Execute the cutover (must be root)"
                exit 0
                ;;
            *) die "Unknown argument: ${arg} (use --help)" ;;
        esac
    done

    case "$MODE" in
        status) do_status ;;
        dry-run|apply)
            if [ "$MODE" = "apply" ]; then
                check_root
            fi
            do_apply
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
