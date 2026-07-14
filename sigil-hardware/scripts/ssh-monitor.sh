#!/bin/bash
# ssh-monitor.sh — Monitor SSH sessions, wipe cache on login, rebuild on logout
#
# Policy:
#   SSH 0→1: stop playback safely, wipe cache (no SECURITY_MAINTENANCE, no mask)
#   SSH 1→0: run radio-fetcher --once (no unmask, no maintenance mode)
#
# Runs as a systemd service (Type=simple).
#
# Usage:
#   ssh-monitor.sh              # normal mode (continuous loop)
#   ssh-monitor.sh --once       # single check, then exit
#   ssh-monitor.sh --status     # show current state and exit
#   ssh-monitor.sh --help       # show this message
# =============================================================================
set -euo pipefail

STATE_DIR="${SIGIL_STATE_DIR:-/var/lib/sigil}"
SSH_STATUS_FILE="${STATE_DIR}/ssh_status.json"
RUN_SIGIL_DIR="${SIGIL_RUN_DIR:-/run/sigil}"
CACHE_WIPE="${SIGIL_CACHE_WIPE:-/usr/local/bin/sigil-cache-wipe.sh}"
RADIO_FETCHER="${SIGIL_RADIO_FETCHER:-/usr/local/bin/radio-fetcher.sh}"
FETCH_WRAPPER="${SIGIL_FETCH_WRAPPER:-/usr/local/bin/sigil-logout-fetch-operation.sh}"
FETCH_OPERATION_FILE="${SIGIL_FETCH_OPERATION_FILE:-${RUN_SIGIL_DIR}/logout-fetch-operation.json}"
SSH_ACTIVE_MARKER="${RUN_SIGIL_DIR}/ssh-active"
LOGOUT_FETCH_MARKER="${RUN_SIGIL_DIR}/logout-fetch-active"
SERVICE_SNAPSHOT_FILE="${SIGIL_SERVICE_SNAPSHOT_FILE:-${RUN_SIGIL_DIR}/ssh-service-snapshot.json}"
MARKER_OWNER="${SIGIL_MARKER_OWNER:-root}"
MARKER_GROUP="${SIGIL_MARKER_GROUP:-sigil}"
PROC_ROOT="${SIGIL_PROC_ROOT:-/proc}"
SS_BIN="${SIGIL_SS_BIN:-ss}"
SSH_MONITOR_SCRIPT="${SIGIL_SSH_MONITOR_SCRIPT:-$(readlink -f "${BASH_SOURCE[0]}")}"
MANAGED_SERVICES=(
    "radio-fetcher.service"
    "audio-manager.service"
    "audio-player.service"
    "radio-stream.service"
)
LOGOUT_COORDINATION_TOKEN=""
LOGOUT_COORDINATION_OWNED=false
ACTIVE_FETCH_PID=""
RESTORE_FAILED_SERVICE=""
RECOVERED_FETCH_IN_PROGRESS=false
SNAPSHOT_FAILED_SERVICE=""
SNAPSHOT_FAILED_QUERY=""
LAST_FETCH_EXIT=""
LAST_FETCH_LAUNCH_PID=""

POLL_INTERVAL=5
ONCE=false
STATUS_ONLY=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ssh-monitor] $*" >&2
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--once] [--status]

Options:
  --once    Single check cycle, then exit
  --status  Show current SSH session state and exit
  --help    Show this message
EOF
    exit 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────

get_ssh_count() {
    local output=""

    # On the SSH server the local listening port is the source port in ss
    # output. Prefer the service name, then fall back to numeric port 22 for
    # systems whose service database does not define "ssh".
    if output=$("$SS_BIN" -H -n state established 'sport = :ssh' 2>/dev/null); then
        :
    elif output=$("$SS_BIN" -H -n state established 'sport = :22' 2>/dev/null); then
        :
    else
        log "ERROR" "Cannot query established inbound SSH sessions with ${SS_BIN}"
        return 1
    fi

    awk 'NF { count++ } END { print count + 0 }' <<< "$output"
}

read_ssh_status() {
    if [ ! -f "$SSH_STATUS_FILE" ]; then
        echo "0"
        return
    fi
    python3 -c "
import json, sys
try:
    with open('${SSH_STATUS_FILE}') as f:
        d = json.load(f)
    print(d.get('ssh_session_count', 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

read_ssh_recovery_state() {
    [ -f "$SSH_STATUS_FILE" ] || return 0
    python3 - "$SSH_STATUS_FILE" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
last_exit = document.get("last_exit")
if isinstance(last_exit, dict):
    state = last_exit.get("recovery_state")
    if isinstance(state, str):
        print(state)
PYEOF
}

write_ssh_status() {
    local count="$1"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local wipe_ok="${2:-}"
    local fetch_ok="${3:-}"
    local fetch_pid="${4:-}"
    local fetch_exit="${5:-}"
    local cache_valid="${6:-}"
    local restore_ok="${7:-}"
    local failed_service="${8:-}"
    local recovery_pending="${9:-}"
    local recovery_exit="${10:-}"
    local recovery_state="${11:-}"
    python3 - "$SSH_STATUS_FILE" "$count" "$now" "$wipe_ok" "$fetch_ok" "$fetch_pid" "$fetch_exit" \
        "$cache_valid" "$restore_ok" "$failed_service" "$recovery_pending" "$recovery_exit" "$recovery_state" <<'PYEOF'
import json, os, sys, tempfile
fp = sys.argv[1]
count = int(sys.argv[2])
now = sys.argv[3]
wipe_ok = sys.argv[4] if sys.argv[4] else None
fetch_ok = sys.argv[5] if sys.argv[5] else None
fetch_pid = int(sys.argv[6]) if sys.argv[6].isdigit() else None
fetch_exit = int(sys.argv[7]) if sys.argv[7].isdigit() else None
cache_valid = sys.argv[8] if sys.argv[8] else None
restore_ok = sys.argv[9] if sys.argv[9] else None
failed_service = sys.argv[10] if sys.argv[10] else None
recovery_pending = sys.argv[11] if sys.argv[11] else None
recovery_exit = int(sys.argv[12]) if sys.argv[12].isdigit() else None
recovery_state = sys.argv[13] if sys.argv[13] else None
previous_last_exit = None
try:
    with open(fp, encoding="utf-8") as existing:
        previous = json.load(existing)
    if isinstance(previous, dict) and isinstance(previous.get("last_exit"), dict):
        previous_last_exit = previous["last_exit"]
except (OSError, ValueError):
    pass
doc = {
    "_schema_version": "1.0",
    "ssh_session_count": count,
    "last_updated": now,
}
if wipe_ok is not None:
    doc["last_exit"] = {
        "wipe_ok": wipe_ok == "true",
        "fetch_ok": fetch_ok == "true" if fetch_ok is not None else None,
        "fetch_pid": fetch_pid,
        "fetch_exit_code": fetch_exit,
        "cache_valid": cache_valid == "true" if cache_valid is not None else None,
        "restore_ok": restore_ok == "true" if restore_ok is not None else None,
        "failed_service": failed_service,
        "recovery_pending": recovery_pending == "true" if recovery_pending is not None else None,
        "recovery_exit_code": recovery_exit,
        "recovery_state": recovery_state,
    }
elif previous_last_exit is not None:
    doc["last_exit"] = previous_last_exit
dirn = os.path.dirname(fp) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, fp)
PYEOF
}

stop_managed_services() {
    local svc expected_load _expected_active expected_enabled
    local actual_load actual_active actual_enabled query_output query_rc
    if ! validate_service_snapshot; then
        return 1
    fi

    # Verify every state query before stopping the first unit. This prevents a
    # partial stop when systemd/D-Bus becomes unavailable or unit metadata no
    # longer matches the protected snapshot.
    while IFS=$'\t' read -r svc expected_load _expected_active expected_enabled; do
        query_rc=0
        query_output=$(query_service_state "$svc") || query_rc=$?
        if [ "$query_rc" -ne 0 ]; then
            log "ERROR" "Cannot query ${svc} before SSH maintenance stop"
            return 1
        fi
        IFS=$'\t' read -r actual_load actual_active actual_enabled <<< "$query_output"
        if [ "$actual_load" != "$expected_load" ] || [ "$actual_enabled" != "$expected_enabled" ]; then
            log "ERROR" "Unit metadata changed before stopping ${svc}"
            return 1
        fi
    done < <(service_snapshot_rows)

    while IFS=$'\t' read -r svc expected_load _expected_active expected_enabled; do
        query_output=$(query_service_state "$svc") || return 1
        IFS=$'\t' read -r actual_load actual_active actual_enabled <<< "$query_output"
        if [ "$actual_active" = "active" ]; then
            log "  Stopping ${svc}"
            if ! systemctl stop "$svc" 2>/dev/null; then
                log "ERROR" "Cannot stop ${svc} for SSH maintenance"
                return 1
            fi
            query_rc=0
            query_output=$(query_service_state "$svc") || query_rc=$?
            if [ "$query_rc" -ne 0 ] || [ "$(cut -f2 <<< "$query_output")" != "inactive" ]; then
                log "ERROR" "Cannot verify ${svc} inactive after stop"
                return 1
            fi
        fi
    done < <(service_snapshot_rows)
    if pgrep -x mpg123 &>/dev/null; then
        pkill -9 mpg123 2>/dev/null || true
    fi
}

create_runtime_marker() {
    local marker="$1"
    local content="${2:-}"
    local marker_name tmp owner group mode

    if [ ! -d "$RUN_SIGIL_DIR" ]; then
        log "ERROR" "Runtime directory missing: ${RUN_SIGIL_DIR}"
        return 1
    fi

    marker_name=$(basename "$marker")
    if ! tmp=$(mktemp "${RUN_SIGIL_DIR}/.${marker_name}.XXXXXX"); then
        log "ERROR" "Cannot create temporary marker in ${RUN_SIGIL_DIR}"
        return 1
    fi
    if ! printf '%s\n' "$content" > "$tmp" ||
       ! chown "${MARKER_OWNER}:${MARKER_GROUP}" "$tmp" 2>/dev/null ||
       ! chmod 0640 "$tmp" 2>/dev/null ||
       ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        log "ERROR" "Cannot install runtime marker ${marker}"
        return 1
    fi

    if ! owner=$(stat -c '%U' "$marker" 2>/dev/null) ||
       ! group=$(stat -c '%G' "$marker" 2>/dev/null) ||
       ! mode=$(stat -c '%a' "$marker" 2>/dev/null); then
        log "ERROR" "Cannot verify runtime marker ${marker}"
        return 1
    fi
    if [ "$owner" != "$MARKER_OWNER" ] || [ "$group" != "$MARKER_GROUP" ] || [ "$mode" != "640" ]; then
        log "ERROR" "Runtime marker metadata invalid: ${marker} (${owner}:${group} ${mode})"
        return 1
    fi
    return 0
}

remove_runtime_marker() {
    local marker="$1"
    if ! rm -f -- "$marker" || [ -e "$marker" ]; then
        log "ERROR" "Cannot remove runtime marker ${marker}"
        return 1
    fi
}

get_process_start_time() {
    local pid="$1"
    python3 - "${PROC_ROOT}/${pid}/stat" <<'PYEOF'
import sys

try:
    raw = open(sys.argv[1], encoding="utf-8").read().strip()
except OSError:
    raise SystemExit(1)
end_comm = raw.rfind(")")
if end_comm < 0:
    raise SystemExit(1)
fields = raw[end_comm + 2:].split()
# fields[0] is proc field 3 (state); starttime is proc field 22.
if len(fields) <= 19 or not fields[19].isdigit():
    raise SystemExit(1)
print(fields[19])
PYEOF
}

ensure_monitor_identity() {
    local start_time
    if [ -n "$LOGOUT_COORDINATION_TOKEN" ]; then
        return 0
    fi
    if ! start_time=$(get_process_start_time "$$"); then
        log "ERROR" "Cannot determine ssh-monitor process start time"
        return 1
    fi
    LOGOUT_COORDINATION_TOKEN="ssh-monitor:$$:${start_time}"
}

process_matches_script_identity() {
    local pid="$1"
    local expected_start="$2"
    local expected_script="$3"
    local actual_start
    if ! actual_start=$(get_process_start_time "$pid") || [ "$actual_start" != "$expected_start" ]; then
        return 1
    fi

    python3 - "${PROC_ROOT}/${pid}/cmdline" "$expected_script" <<'PYEOF'
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
PYEOF
}

process_matches_monitor_identity() {
    process_matches_script_identity "$1" "$2" "$SSH_MONITOR_SCRIPT"
}

get_process_group_id() {
    local pid="$1"
    python3 - "${PROC_ROOT}/${pid}/stat" <<'PYEOF'
import sys
try:
    raw = open(sys.argv[1], encoding="utf-8").read().strip()
except OSError:
    raise SystemExit(1)
end = raw.rfind(")")
fields = raw[end + 2:].split() if end >= 0 else []
# fields[0] is state (field 3); fields[2] is pgrp (field 5).
if len(fields) <= 2 or not fields[2].isdigit():
    raise SystemExit(1)
print(fields[2])
PYEOF
}

generate_operation_id() {
    printf 'sshlogout-%s-%s-%s\n' "$(date +%s%N)" "$$" "$RANDOM"
}

write_fetch_operation() {
    local operation_id="$1" state="$2" result_file="$3"
    local launch_pid="${4:-}" launch_start="${5:-}" process_group="${6:-}"
    local worker_pid="${7:-}" worker_start="${8:-}" exit_code="${9:-}"
    local canonical_wrapper canonical_fetcher
    canonical_wrapper=$(readlink -f "$FETCH_WRAPPER" 2>/dev/null) || return 1
    canonical_fetcher=$(readlink -f "$RADIO_FETCHER" 2>/dev/null) || return 1

    if ! python3 - "$FETCH_OPERATION_FILE" "$operation_id" "$state" "$result_file" \
        "$canonical_wrapper" "$canonical_fetcher" "$launch_pid" "$launch_start" \
        "$process_group" "$worker_pid" "$worker_start" "$exit_code" <<'PYEOF'
import json
import os
import sys
import tempfile

(
    path, operation_id, state, result_file, wrapper, fetcher,
    launch_pid, launch_start, process_group, worker_pid, worker_start,
    exit_code,
) = sys.argv[1:]
document = {
    "_schema_version": "1.0",
    "operation_id": operation_id,
    "state": state,
    "result_file": result_file,
    "expected_wrapper": wrapper,
    "expected_fetcher": fetcher,
    "launch_pid": int(launch_pid) if launch_pid.isdigit() else None,
    "launch_start_time_ticks": launch_start or None,
    "process_group_id": int(process_group) if process_group.isdigit() else None,
    "worker_pid": int(worker_pid) if worker_pid.isdigit() else None,
    "worker_start_time_ticks": worker_start or None,
    "exit_code": int(exit_code) if exit_code.isdigit() else None,
}
directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(dir=directory, prefix=".logout-fetch-operation.", suffix=".tmp")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PYEOF
    then
        return 1
    fi
    if ! chown "${MARKER_OWNER}:${MARKER_GROUP}" "$FETCH_OPERATION_FILE" 2>/dev/null ||
       ! chmod 0640 "$FETCH_OPERATION_FILE" 2>/dev/null; then
        rm -f -- "$FETCH_OPERATION_FILE" 2>/dev/null || true
        return 1
    fi
}

read_fetch_operation_fields() {
    python3 - "$FETCH_OPERATION_FILE" "$RUN_SIGIL_DIR" "$FETCH_WRAPPER" "$RADIO_FETCHER" <<'PYEOF'
import json
import os
import re
import sys
try:
    operation = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
run_dir = os.path.realpath(sys.argv[2])
expected_wrapper = os.path.realpath(sys.argv[3])
expected_fetcher = os.path.realpath(sys.argv[4])
required = ("operation_id", "state", "result_file", "expected_wrapper", "expected_fetcher")
if any(not isinstance(operation.get(key), str) or not operation[key] for key in required):
    raise SystemExit(1)
if not re.fullmatch(r"[A-Za-z0-9_-]+", operation["operation_id"]):
    raise SystemExit(1)
if operation["state"] not in ("launching", "running", "complete", "interrupted"):
    raise SystemExit(1)
if os.path.dirname(os.path.realpath(operation["result_file"])) != run_dir:
    raise SystemExit(1)
if os.path.realpath(operation["expected_wrapper"]) != expected_wrapper:
    raise SystemExit(1)
if os.path.realpath(operation["expected_fetcher"]) != expected_fetcher:
    raise SystemExit(1)
values = [
    operation["operation_id"], operation["state"], operation["result_file"],
    operation["expected_wrapper"], operation["expected_fetcher"],
    operation.get("launch_pid"), operation.get("launch_start_time_ticks"),
    operation.get("process_group_id"), operation.get("worker_pid"),
    operation.get("worker_start_time_ticks"), operation.get("exit_code"),
]
print("\x1f".join("" if value is None else str(value) for value in values))
PYEOF
}

process_has_operation_id() {
    local pid="$1" operation_id="$2"
    python3 - "${PROC_ROOT}/${pid}/environ" "$operation_id" <<'PYEOF'
import sys
try:
    environment = open(sys.argv[1], "rb").read().split(b"\0")
except OSError:
    raise SystemExit(1)
needle = ("SIGIL_LOGOUT_OPERATION_ID=" + sys.argv[2]).encode()
raise SystemExit(0 if needle in environment else 1)
PYEOF
}

classify_operation_process() {
    local pid="$1" operation_id="$2" expected_wrapper="$3" expected_fetcher="$4"
    process_has_operation_id "$pid" "$operation_id" || return 1
    python3 - "${PROC_ROOT}/${pid}/cmdline" "$operation_id" "$expected_wrapper" "$expected_fetcher" <<'PYEOF'
import os
import sys
try:
    argv = [os.fsdecode(arg) for arg in open(sys.argv[1], "rb").read().split(b"\0") if arg]
except OSError:
    raise SystemExit(1)
if not argv:
    raise SystemExit(1)
operation_id, wrapper, fetcher = sys.argv[2:]
wrapper = os.path.realpath(wrapper)
fetcher = os.path.realpath(fetcher)
direct = os.path.realpath(argv[0])
if direct == wrapper or (len(argv) >= 2 and os.path.basename(argv[0]) == "bash" and os.path.realpath(argv[1]) == wrapper):
    print("wrapper")
elif direct == fetcher or (len(argv) >= 2 and os.path.basename(argv[0]) == "bash" and os.path.realpath(argv[1]) == fetcher):
    print("worker")
elif os.path.basename(argv[0]) == "sudo" and operation_id in argv and any(os.path.realpath(arg) == wrapper for arg in argv):
    print("launch")
else:
    raise SystemExit(1)
PYEOF
}

operation_live_processes() {
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    if ! IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields); then
        return 1
    fi
    python3 - "$PROC_ROOT" "$operation_id" "$expected_wrapper" "$expected_fetcher" \
        "$launch_pid" "$launch_start" "$process_group" "$worker_pid" "$worker_start" <<'PYEOF'
import glob
import os
import sys

proc_root, operation_id, wrapper, fetcher, launch_pid, launch_start, expected_pgrp, worker_pid, worker_start = sys.argv[1:]
wrapper = os.path.realpath(wrapper)
fetcher = os.path.realpath(fetcher)
needle = ("SIGIL_LOGOUT_OPERATION_ID=" + operation_id).encode()

for directory in glob.glob(os.path.join(proc_root, "[0-9]*")):
    pid = os.path.basename(directory)
    try:
        environment = open(os.path.join(directory, "environ"), "rb").read().split(b"\0")
        if needle not in environment:
            continue
        argv = [os.fsdecode(value) for value in open(os.path.join(directory, "cmdline"), "rb").read().split(b"\0") if value]
        raw_stat = open(os.path.join(directory, "stat"), encoding="utf-8").read().strip()
    except OSError:
        continue
    end = raw_stat.rfind(")")
    fields = raw_stat[end + 2:].split() if end >= 0 else []
    if len(fields) <= 19 or not fields[2].isdigit() or not fields[19].isdigit() or not argv:
        continue
    pgrp, start_time = fields[2], fields[19]
    if expected_pgrp and pgrp != expected_pgrp:
        continue
    direct = os.path.realpath(argv[0])
    if direct == wrapper or (len(argv) >= 2 and os.path.basename(argv[0]) == "bash" and os.path.realpath(argv[1]) == wrapper):
        role = "wrapper"
    elif direct == fetcher or (len(argv) >= 2 and os.path.basename(argv[0]) == "bash" and os.path.realpath(argv[1]) == fetcher):
        role = "worker"
    elif os.path.basename(argv[0]) == "sudo" and operation_id in argv and any(os.path.realpath(arg) == wrapper for arg in argv):
        role = "launch"
    else:
        continue
    if pid == launch_pid and launch_start and start_time != launch_start:
        continue
    if pid == worker_pid and worker_start and start_time != worker_start:
        continue
    print("{}\t{}\t{}\t{}".format(pid, role, start_time, pgrp))
PYEOF
}

fetch_operation_is_live() {
    [ -f "$FETCH_OPERATION_FILE" ] || return 1
    [ -n "$(operation_live_processes 2>/dev/null)" ]
}

discover_fetch_worker() {
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields) || return 1
    local pid role start pgid
    while IFS=$'\t' read -r pid role start pgid; do
        if [ "$role" = "worker" ]; then
            write_fetch_operation "$operation_id" "running" "$result_file" \
                "$launch_pid" "$launch_start" "$process_group" "$pid" "$start" ""
            return $?
        fi
    done < <(operation_live_processes)
    return 1
}

read_fetch_result() {
    local operation_id="$1" result_file="$2"
    python3 - "$result_file" "$operation_id" <<'PYEOF'
import json
import sys
try:
    result = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
if result.get("operation_id") != sys.argv[2] or result.get("state") not in ("complete", "interrupted"):
    raise SystemExit(1)
exit_code = result.get("exit_code")
if not isinstance(exit_code, int) or not 0 <= exit_code <= 255:
    raise SystemExit(1)
print(exit_code)
PYEOF
}

get_recorded_fetch_exit() {
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields) || return 1
    read_fetch_result "$operation_id" "$result_file"
}

kill_fetch_operation() {
    [ -f "$FETCH_OPERATION_FILE" ] || return 0
    local rows pgid
    rows=$(operation_live_processes 2>/dev/null || true)
    [ -n "$rows" ] || return 0
    pgid=$(awk -F '\t' 'NR == 1 {print $4}' <<< "$rows")
    if [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ]; then
        kill -TERM -- "-${pgid}" 2>/dev/null || true
        local _
        for _ in $(seq 1 20); do
            fetch_operation_is_live || return 0
            sleep 0.05
        done
        kill -KILL -- "-${pgid}" 2>/dev/null || true
    fi
}

cleanup_fetch_operation_files() {
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    if IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields); then
        rm -f -- "$result_file" 2>/dev/null || true
    fi
    rm -f -- "$FETCH_OPERATION_FILE" 2>/dev/null || true
}

launch_explicit_fetch() {
    local operation_id result_file launch_pid launch_start="" process_group=""
    local launch_exit=125 result_exit="" _
    LAST_FETCH_EXIT=""
    LAST_FETCH_LAUNCH_PID=""

    if [ -f "$FETCH_OPERATION_FILE" ]; then
        if fetch_operation_is_live; then
            log "ERROR" "An explicit logout fetch operation is already running"
            return 75
        fi
        cleanup_fetch_operation_files
    fi

    operation_id=$(generate_operation_id)
    result_file="${RUN_SIGIL_DIR}/logout-fetch-result-${operation_id}.json"
    if ! write_fetch_operation "$operation_id" "launching" "$result_file"; then
        log "ERROR" "Cannot create explicit fetch operation record"
        return 125
    fi

    SIGIL_LOGOUT_OPERATION_ID="$operation_id" \
        setsid sudo -u sigil env \
            SIGIL_LOGOUT_OPERATION_ID="$operation_id" \
            bash "$FETCH_WRAPPER" "$operation_id" "$result_file" "$RADIO_FETCHER" "$RUN_SIGIL_DIR" \
            >/dev/null 2>&1 &
    launch_pid=$!
    LAST_FETCH_LAUNCH_PID="$launch_pid"
    ACTIVE_FETCH_PID="$launch_pid"

    for _ in $(seq 1 20); do
        launch_start=$(get_process_start_time "$launch_pid" 2>/dev/null || true)
        process_group=$(get_process_group_id "$launch_pid" 2>/dev/null || true)
        if [ -n "$launch_start" ] && [ -n "$process_group" ]; then
            break
        fi
        kill -0 "$launch_pid" 2>/dev/null || break
        sleep 0.01
    done
    if [ -n "$launch_start" ] && [ -n "$process_group" ]; then
        if ! write_fetch_operation "$operation_id" "running" "$result_file" \
            "$launch_pid" "$launch_start" "$process_group"; then
            kill_fetch_operation
            wait "$launch_pid" 2>/dev/null || true
            ACTIVE_FETCH_PID=""
            return 125
        fi
        discover_fetch_worker >/dev/null 2>&1 || true
    fi

    if wait "$launch_pid" 2>/dev/null; then
        launch_exit=0
    else
        launch_exit=$?
    fi
    ACTIVE_FETCH_PID=""

    for _ in $(seq 1 20); do
        result_exit=$(read_fetch_result "$operation_id" "$result_file" 2>/dev/null || true)
        [ -n "$result_exit" ] && break
        sleep 0.01
    done

    if fetch_operation_is_live; then
        # A wrapper that returned while a matching worker remains cannot provide
        # a trustworthy final status. Terminate the isolated operation group.
        kill_fetch_operation
        LAST_FETCH_EXIT=125
        return 125
    fi
    if [ -n "$result_exit" ]; then
        LAST_FETCH_EXIT="$result_exit"
    else
        LAST_FETCH_EXIT="$launch_exit"
    fi
    if [ -n "$result_exit" ]; then
        mark_fetch_operation_complete "$result_exit" || {
            LAST_FETCH_EXIT=125
            return 125
        }
    fi
    return "$LAST_FETCH_EXIT"
}

query_service_state() {
    local svc="$1" output rc load_state="" active_state="" unit_file_state=""
    if output=$(systemctl show "$svc" --no-pager \
        --property=LoadState --property=ActiveState --property=UnitFileState 2>/dev/null); then
        rc=0
    else
        rc=$?
        printf 'ERROR\tsystemctl-show:%s\n' "$rc"
        return 1
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            LoadState) load_state="$value" ;;
            ActiveState) active_state="$value" ;;
            UnitFileState) unit_file_state="$value" ;;
        esac
    done <<< "$output"

    case "$load_state" in
        loaded|masked) ;;
        not-found|'') printf 'ERROR\tload-state:%s\n' "${load_state:-missing}"; return 1 ;;
        *) printf 'ERROR\tload-state:%s\n' "$load_state"; return 1 ;;
    esac
    case "$active_state" in
        active|inactive|failed) ;;
        activating|deactivating)
            printf 'ERROR\ttransitional-active-state:%s\n' "$active_state"
            return 1
            ;;
        *) printf 'ERROR\tactive-state:%s\n' "${active_state:-missing}"; return 1 ;;
    esac
    case "$unit_file_state" in
        enabled|disabled|static|indirect|masked) ;;
        *) printf 'ERROR\tunit-file-state:%s\n' "${unit_file_state:-missing}"; return 1 ;;
    esac
    printf '%s\t%s\t%s\n' "$load_state" "$active_state" "$unit_file_state"
}

write_service_snapshot() {
    local now monitor_start svc load_state active_state unit_file_state query_output query_rc
    local -a states=()
    SNAPSHOT_FAILED_SERVICE=""
    SNAPSHOT_FAILED_QUERY=""
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! monitor_start=$(get_process_start_time "$$"); then
        log "ERROR" "Cannot capture monitor start time for service snapshot"
        return 1
    fi

    for svc in "${MANAGED_SERVICES[@]}"; do
        query_rc=0
        query_output=$(query_service_state "$svc") || query_rc=$?
        if [ "$query_rc" -ne 0 ]; then
            SNAPSHOT_FAILED_SERVICE="$svc"
            SNAPSHOT_FAILED_QUERY="${query_output#*$'\t'}"
            log "ERROR" "Cannot snapshot ${svc}: ${SNAPSHOT_FAILED_QUERY:-state-query-failed}"
            return 1
        fi
        IFS=$'\t' read -r load_state active_state unit_file_state <<< "$query_output"
        states+=("$svc" "$load_state" "$active_state" "$unit_file_state")
    done

    if ! python3 - "$SERVICE_SNAPSHOT_FILE" "$now" "$$" "$monitor_start" "${states[@]}" <<'PYEOF'
import json
import os
import sys
import tempfile

path, created_at, pid_raw, start_time, *items = sys.argv[1:]
if len(items) % 4:
    raise SystemExit(1)
services = {}
for index in range(0, len(items), 4):
    service, load, active, enabled = items[index:index + 4]
    if load not in ("loaded", "masked"):
        raise SystemExit(1)
    if active not in ("active", "inactive", "failed"):
        raise SystemExit(1)
    if enabled not in ("enabled", "disabled", "static", "indirect", "masked"):
        raise SystemExit(1)
    services[service] = {"load": load, "active": active, "enabled": enabled}
document = {
    "_schema_version": "1.0",
    "created_at": created_at,
    "monitor": {"pid": int(pid_raw), "start_time_ticks": start_time},
    "services": services,
}
directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(dir=directory, prefix=".ssh-service-snapshot.", suffix=".tmp")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PYEOF
    then
        log "ERROR" "Cannot atomically write service snapshot ${SERVICE_SNAPSHOT_FILE}"
        return 1
    fi

    if ! chown "${MARKER_OWNER}:${MARKER_GROUP}" "$SERVICE_SNAPSHOT_FILE" 2>/dev/null ||
       ! chmod 0640 "$SERVICE_SNAPSHOT_FILE" 2>/dev/null; then
        rm -f -- "$SERVICE_SNAPSHOT_FILE" 2>/dev/null || true
        log "ERROR" "Cannot protect service snapshot ${SERVICE_SNAPSHOT_FILE}"
        return 1
    fi
    local owner group mode
    if ! owner=$(stat -c '%U' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       ! group=$(stat -c '%G' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       ! mode=$(stat -c '%a' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       [ "$owner" != "$MARKER_OWNER" ] || [ "$group" != "$MARKER_GROUP" ] || [ "$mode" != "640" ]; then
        log "ERROR" "Service snapshot metadata verification failed"
        return 1
    fi
    log "  Service state snapshot created at ${SERVICE_SNAPSHOT_FILE}"
}

validate_service_snapshot() {
    local owner group mode
    if ! owner=$(stat -c '%U' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       ! group=$(stat -c '%G' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       ! mode=$(stat -c '%a' "$SERVICE_SNAPSHOT_FILE" 2>/dev/null) ||
       [ "$owner" != "$MARKER_OWNER" ] || [ "$group" != "$MARKER_GROUP" ] || [ "$mode" != "640" ]; then
        return 1
    fi
    python3 - "$SERVICE_SNAPSHOT_FILE" "${MANAGED_SERVICES[@]}" <<'PYEOF'
import json
import sys

path, *expected = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
services = document.get("services")
if not isinstance(services, dict) or set(services) != set(expected):
    raise SystemExit(1)
for service in expected:
    state = services.get(service)
    if not isinstance(state, dict):
        raise SystemExit(1)
    if state.get("load") not in ("loaded", "masked"):
        raise SystemExit(1)
    if state.get("active") not in ("active", "inactive", "failed"):
        raise SystemExit(1)
    if state.get("enabled") not in ("enabled", "disabled", "static", "indirect", "masked"):
        raise SystemExit(1)
monitor = document.get("monitor")
if not isinstance(monitor, dict) or not isinstance(monitor.get("pid"), int):
    raise SystemExit(1)
if not str(monitor.get("start_time_ticks", "")).isdigit():
    raise SystemExit(1)
PYEOF
}

ensure_service_snapshot() {
    if [ -f "$SERVICE_SNAPSHOT_FILE" ]; then
        if validate_service_snapshot; then
            log "  Preserving existing service snapshot for pending maintenance recovery"
            return 0
        fi
        log "ERROR" "Existing service snapshot is invalid: ${SERVICE_SNAPSHOT_FILE}"
        return 1
    fi
    write_service_snapshot
}

service_snapshot_rows() {
    python3 - "$SERVICE_SNAPSHOT_FILE" "${MANAGED_SERVICES[@]}" <<'PYEOF'
import json
import sys

path, *services = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    states = json.load(handle)["services"]
for service in services:
    state = states[service]
    print(f"{service}\t{state['load']}\t{state['active']}\t{state['enabled']}")
PYEOF
}

restore_managed_services() {
    local svc expected_load expected_active expected_enabled
    local actual_load actual_active actual_enabled query_output query_rc
    RESTORE_FAILED_SERVICE=""
    if ! validate_service_snapshot; then
        RESTORE_FAILED_SERVICE="service-snapshot"
        log "ERROR" "Cannot restore services from invalid snapshot"
        return 1
    fi

    # Enablement is not changed by SSH maintenance. Verify it before starting
    # anything so an external enable/disable change cannot be hidden.
    while IFS=$'\t' read -r svc expected_load expected_active expected_enabled; do
        query_rc=0
        query_output=$(query_service_state "$svc") || query_rc=$?
        if [ "$query_rc" -ne 0 ]; then
            RESTORE_FAILED_SERVICE="$svc"
            log "ERROR" "Cannot query ${svc} before restoration: ${query_output#*$'\t'}"
            return 1
        fi
        IFS=$'\t' read -r actual_load actual_active actual_enabled <<< "$query_output"
        if [ "$actual_load" != "$expected_load" ] || [ "$actual_enabled" != "$expected_enabled" ]; then
            RESTORE_FAILED_SERVICE="$svc"
            log "ERROR" "Unit metadata changed for ${svc}: expected ${expected_load}/${expected_enabled}, got ${actual_load}/${actual_enabled}"
            return 1
        fi
    done < <(service_snapshot_rows)

    while IFS=$'\t' read -r svc expected_load expected_active expected_enabled; do
        query_output=$(query_service_state "$svc") || {
            RESTORE_FAILED_SERVICE="$svc"
            return 1
        }
        IFS=$'\t' read -r actual_load actual_active actual_enabled <<< "$query_output"
        case "$expected_active" in
        active)
            if [ "$actual_active" = "failed" ]; then
                if ! systemctl reset-failed "$svc" 2>/dev/null; then
                    RESTORE_FAILED_SERVICE="$svc"
                    log "ERROR" "Cannot reset failed state for ${svc}"
                    return 1
                fi
            fi
            if [ "$actual_active" != "active" ]; then
                if ! systemctl start "$svc" 2>/dev/null; then
                    RESTORE_FAILED_SERVICE="$svc"
                    log "ERROR" "Cannot restart ${svc} after SSH maintenance"
                    return 1
                fi
            fi
            ;;
        inactive)
            if [ "$actual_active" = "active" ]; then
                if ! systemctl stop "$svc" 2>/dev/null; then
                    RESTORE_FAILED_SERVICE="$svc"
                    log "ERROR" "Cannot preserve inactive state for ${svc}"
                    return 1
                fi
            elif [ "$actual_active" = "failed" ]; then
                if ! systemctl reset-failed "$svc" 2>/dev/null; then
                    RESTORE_FAILED_SERVICE="$svc"
                    log "ERROR" "Cannot restore inactive state for ${svc}"
                    return 1
                fi
            fi
            ;;
        failed)
            # A service that was already failed before maintenance is not
            # started or reset. Exact verification below must still see failed.
            ;;
        esac
    done < <(service_snapshot_rows)

    while IFS=$'\t' read -r svc expected_load expected_active expected_enabled; do
        query_output=$(query_service_state "$svc") || {
            RESTORE_FAILED_SERVICE="$svc"
            return 1
        }
        IFS=$'\t' read -r actual_load actual_active actual_enabled <<< "$query_output"
        if [ "$actual_load" != "$expected_load" ] || [ "$actual_active" != "$expected_active" ] || [ "$actual_enabled" != "$expected_enabled" ]; then
            RESTORE_FAILED_SERVICE="$svc"
            log "ERROR" "Restoration verification failed for ${svc}: expected ${expected_load}/${expected_active}/${expected_enabled}, got ${actual_load}/${actual_active}/${actual_enabled}"
            return 1
        fi
    done < <(service_snapshot_rows)
    return 0
}

validate_rebuilt_cache() {
    sudo -u sigil env SIGIL_RUN_DIR="$RUN_SIGIL_DIR" \
        bash "$RADIO_FETCHER" --validate-active >/dev/null 2>&1
}

fetch_operation_launch_pid() {
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields) || return 1
    [[ "$launch_pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$launch_pid"
}

mark_fetch_operation_complete() {
    local completed_exit="$1"
    local operation_id state result_file expected_wrapper expected_fetcher
    local launch_pid launch_start process_group worker_pid worker_start exit_code
    IFS=$'\x1f' read -r operation_id state result_file expected_wrapper expected_fetcher \
        launch_pid launch_start process_group worker_pid worker_start exit_code < <(read_fetch_operation_fields) || return 1
    local result_worker_fields
    result_worker_fields=$(python3 - "$result_file" "$operation_id" <<'PYEOF'
import json
import sys
try:
    result = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
if result.get("operation_id") != sys.argv[2]:
    raise SystemExit(1)
pid = result.get("child_pid")
start = result.get("child_start_time_ticks")
print("{}\t{}".format(pid if isinstance(pid, int) else "", start if isinstance(start, str) else ""))
PYEOF
    ) || return 1
    IFS=$'\t' read -r worker_pid worker_start <<< "$result_worker_fields"
    write_fetch_operation "$operation_id" "complete" "$result_file" \
        "$launch_pid" "$launch_start" "$process_group" "$worker_pid" "$worker_start" "$completed_exit"
}

recover_stale_logout_marker() {
    local marker_token="" owner_pid="" owner_start="" prefix="" recovery_state=""

    [ -f "$LOGOUT_FETCH_MARKER" ] || return 0
    marker_token=$(head -n 1 "$LOGOUT_FETCH_MARKER" 2>/dev/null || true)
    IFS=: read -r prefix owner_pid owner_start <<< "$marker_token"

    # Trust a live owner only when PID, process start time, and exact script
    # identity all match. A recycled PID belonging to an unrelated process is
    # stale and must not block recovery.
    if [ "$prefix" = "ssh-monitor" ] && [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
        if [[ "$owner_start" =~ ^[0-9]+$ ]]; then
            if process_matches_monitor_identity "$owner_pid" "$owner_start"; then
                log "ERROR" "Logout coordination is still owned by live ssh-monitor PID ${owner_pid}"
                return 1
            fi
        elif [ -d "${PROC_ROOT}/${owner_pid}" ]; then
            log "ERROR" "Legacy logout marker references live PID ${owner_pid} without a safe start-time discriminator"
            return 1
        fi
    elif [ -n "$marker_token" ]; then
        log "ERROR" "Unrecognized logout coordination marker; refusing unsafe removal"
        return 1
    fi
    recovery_state=$(read_ssh_recovery_state 2>/dev/null || true)
    case "$recovery_state" in
        wipe_failed|fetch_failed|cache_invalid|restore_failed|snapshot_failed|coordination_failed)
            log "WARN" "Logout recovery is in terminal state ${recovery_state}; operator action or a new SSH cycle is required"
            return 0
            ;;
        complete)
            if fetch_operation_is_live; then
                log "ERROR" "Completed logout state still has live operation processes"
                return 1
            fi
            # The successful status is written only after exact service
            # restoration. A crash between that write and cleanup may leave
            # the snapshot/markers behind; completing those removals is safe.
            if [ -e "$SERVICE_SNAPSHOT_FILE" ] &&
               { ! rm -f -- "$SERVICE_SNAPSHOT_FILE" || [ -e "$SERVICE_SNAPSHOT_FILE" ]; }; then
                log "ERROR" "Cannot finish completed snapshot cleanup"
                return 1
            fi
            cleanup_fetch_operation_files
            remove_runtime_marker "$LOGOUT_FETCH_MARKER"
            return $?
            ;;
    esac
    if fetch_operation_is_live; then
        RECOVERED_FETCH_IN_PROGRESS=true
        log "WARN" "Recovered a live explicit logout fetch; preserving coordination until it exits"
        return 0
    fi
    if get_recorded_fetch_exit >/dev/null 2>&1; then
        RECOVERED_FETCH_IN_PROGRESS=true
        log "WARN" "Recovered a completed explicit logout fetch; resuming finalization"
        return 0
    fi

    if [ "$recovery_state" = "fetch_in_progress" ] || [ -e "$SERVICE_SNAPSHOT_FILE" ]; then
        log "ERROR" "Logout operation disappeared without a trustworthy result; preserving fail-closed coordination"
        write_ssh_status 0 "true" "false" "" "125" "false" "false" \
            "radio-fetcher.service" "true" "125" "fetch_failed" || return 1
        return 0
    fi

    log "WARN" "Removing stale logout-fetch marker owned by ${marker_token:-unknown}"
    cleanup_fetch_operation_files
    remove_runtime_marker "$LOGOUT_FETCH_MARKER"
}

report_pending_recovery_state() {
    [ -f "$SERVICE_SNAPSHOT_FILE" ] || return 0
    if ! validate_service_snapshot; then
        log "ERROR" "Pending service snapshot is invalid: ${SERVICE_SNAPSHOT_FILE}"
        return 1
    fi
    if [ -f "$SSH_ACTIVE_MARKER" ]; then
        log "WARN" "Recovered state: SSH maintenance remains active; service snapshot preserved"
    elif [ -f "$LOGOUT_FETCH_MARKER" ]; then
        log "WARN" "Recovered state: logout fetch/restoration is still coordinated by another monitor"
    else
        log "WARN" "Recovered state: service restoration remains pending; snapshot preserved for safe retry"
    fi
}

cleanup_logout_coordination() {
    local marker_token=""

    if [ -n "$ACTIVE_FETCH_PID" ]; then
        kill_fetch_operation
        wait "$ACTIVE_FETCH_PID" 2>/dev/null || true
    fi
    ACTIVE_FETCH_PID=""

    if $LOGOUT_COORDINATION_OWNED && [ -f "$LOGOUT_FETCH_MARKER" ]; then
        marker_token=$(head -n 1 "$LOGOUT_FETCH_MARKER" 2>/dev/null || true)
        if [ "$marker_token" = "$LOGOUT_COORDINATION_TOKEN" ]; then
            rm -f -- "$LOGOUT_FETCH_MARKER" 2>/dev/null || true
        fi
    fi
    LOGOUT_COORDINATION_OWNED=false
}

preserve_logout_coordination() {
    # A terminal recovery failure deliberately keeps the marker and operation
    # evidence. The EXIT trap must not remove that diagnostic state.
    LOGOUT_COORDINATION_OWNED=false
    ACTIVE_FETCH_PID=""
}

handle_signal() {
    if $LOGOUT_COORDINATION_OWNED; then
        if [ -n "$ACTIVE_FETCH_PID" ]; then
            kill_fetch_operation
            wait "$ACTIVE_FETCH_PID" 2>/dev/null || true
            ACTIVE_FETCH_PID=""
            write_ssh_status 0 "true" "false" "$LAST_FETCH_LAUNCH_PID" "143" \
                "false" "false" "radio-fetcher.service" "true" "143" "fetch_failed" || true
        else
            write_ssh_status 0 "false" "false" "" "143" \
                "false" "false" "ssh-monitor.service" "true" "143" "coordination_failed" || true
        fi
        preserve_logout_coordination
    else
        cleanup_logout_coordination
    fi
    exit 143
}

# ── Transitions ─────────────────────────────────────────────────────────────

enter_maintenance() {
    log "=== SSH session detected — entering maintenance ==="

    if ! ensure_monitor_identity; then
        return 1
    fi

    # 1. Create SSH-active marker FIRST — before stopping playback or wiping.
    #    This prevents radio-fetcher from starting a swap during the operation.
    #    Must succeed with verified ownership/mode: no fallthrough.
    if ! create_runtime_marker "$SSH_ACTIVE_MARKER" "$LOGOUT_COORDINATION_TOKEN"; then
        log "ERROR" "Cannot create marker ${SSH_ACTIVE_MARKER}"
        return 1
    fi
    log "  Marker created at ${SSH_ACTIVE_MARKER}"

    # Capture the exact pre-maintenance state before stopping any service. If a
    # prior failed cycle left a valid snapshot, preserve it for safe retry.
    if ! ensure_service_snapshot; then
        write_ssh_status "1" "false" "false" "" "" "false" "false" \
            "${SNAPSHOT_FAILED_SERVICE:-service-snapshot}" "true" "1" "snapshot_failed" || true
        return 1
    fi

    # Kill any one-shot fetcher left by an interrupted previous transition.
    stop_background_fetcher

    # 2. Stop only the managed services that were active.
    if ! stop_managed_services; then
        write_ssh_status "1" "false" "false" "" "" "false" "false" \
            "service-stop" "true" "1" "restore_failed" || true
        return 1
    fi

    # 3. Wipe cache — keep marker even if wipe fails
    if [ -x "$CACHE_WIPE" ]; then
        log "  Running cache wipe"
        if bash "$CACHE_WIPE" 2>&1 | while IFS= read -r line; do log "  wipe: ${line}"; done; then
            log "  Cache wipe completed"
        else
            log "ERROR" "Cache wipe returned non-zero — marker kept, SSH remains active"
            write_ssh_status "1" "false" "false" "" "" "false" "false" \
                "cache-wipe" "true" "1" "wipe_failed" || true
            return 1
        fi
    else
        log "ERROR" "Cache wipe executable missing or not executable: ${CACHE_WIPE}"
        write_ssh_status "1" "false" "false" "" "127" "false" "false" \
            "cache-wipe" "true" "127" "wipe_failed" || true
        return 1
    fi

    log "=== Cache wiped, SSH active ==="
}

stop_background_fetcher() {
    if [ -f "$FETCH_OPERATION_FILE" ]; then
        if fetch_operation_is_live; then
            log "  Stopping previously recorded explicit fetch operation"
            kill_fetch_operation
        else
            log "WARN" "Removing stale completed fetch operation record"
        fi
        cleanup_fetch_operation_files
    fi
}

finalize_logout_fetch() {
    local current_count="$1" wipe_ok="$2" fetch_pid="$3" fetch_exit="$4"
    local fetch_ok="false"

    if [ "$fetch_exit" -eq 0 ]; then
        fetch_ok="true"
    else
        if ! write_ssh_status "$current_count" "$wipe_ok" "$fetch_ok" "$fetch_pid" "$fetch_exit" \
            "false" "false" "radio-fetcher.service" "true" "$fetch_exit" "fetch_failed"; then
            log "ERROR" "Cannot persist logout fetch failure"
        fi
        preserve_logout_coordination
        log "ERROR" "=== Cache rebuild failed (exit ${fetch_exit}), services remain stopped ==="
        return "$fetch_exit"
    fi

    # A zero fetch exit is necessary but not sufficient: reuse the fetcher's
    # full active-cache validator before any playback service can restart.
    if ! validate_rebuilt_cache; then
        if ! write_ssh_status "$current_count" "$wipe_ok" "true" "$fetch_pid" "$fetch_exit" \
            "false" "false" "active-cache" "true" "65" "cache_invalid"; then
            log "ERROR" "Cannot persist invalid-cache recovery state"
        fi
        preserve_logout_coordination
        log "ERROR" "=== Fetch exited 0 but active cache validation failed; services remain stopped ==="
        return 65
    fi

    if ! restore_managed_services; then
        if ! write_ssh_status "$current_count" "$wipe_ok" "true" "$fetch_pid" "$fetch_exit" \
            "true" "false" "$RESTORE_FAILED_SERVICE" "true" "1" "restore_failed"; then
            log "ERROR" "Cannot persist service restoration failure"
        fi
        preserve_logout_coordination
        log "ERROR" "=== Service restoration failed at ${RESTORE_FAILED_SERVICE}; snapshot preserved ==="
        return 1
    fi

    if ! write_ssh_status "$current_count" "$wipe_ok" "true" "$fetch_pid" "$fetch_exit" \
        "true" "true" "" "false" "0" "complete"; then
        log "ERROR" "Cannot persist successful logout recovery"
        preserve_logout_coordination
        return 1
    fi

    # Remove the snapshot only after exact restoration and verification.
    if ! rm -f -- "$SERVICE_SNAPSHOT_FILE" || [ -e "$SERVICE_SNAPSHOT_FILE" ]; then
        log "ERROR" "Cannot remove completed service snapshot ${SERVICE_SNAPSHOT_FILE}"
        write_ssh_status "$current_count" "$wipe_ok" "true" "$fetch_pid" "$fetch_exit" \
            "true" "false" "service-snapshot-cleanup" "true" "1" "restore_failed" || true
        preserve_logout_coordination
        return 1
    fi

    cleanup_fetch_operation_files
    if ! remove_runtime_marker "$LOGOUT_FETCH_MARKER"; then
        LOGOUT_COORDINATION_OWNED=false
        log "ERROR" "Logout recovery completed but coordination marker cleanup failed"
        return 1
    fi
    LOGOUT_COORDINATION_OWNED=false

    log "=== Cache rebuild complete and pre-maintenance service state restored ==="
    return 0
}

exit_maintenance() {
    local current_count="$1"
    log "=== Last SSH session closed — triggering cache rebuild ==="

    local wipe_ok="false"
    local fetch_pid=""
    local fetch_exit=""

    if ! ensure_monitor_identity; then
        return 1
    fi
    if ! validate_service_snapshot; then
        log "ERROR" "Service snapshot missing or invalid; SSH marker kept"
        write_ssh_status "$current_count" "$wipe_ok" "false" "" "" "false" "false" \
            "service-snapshot" "true" "1" "snapshot_failed" || true
        return 1
    fi

    # Establish bounded logout-fetch ownership before the residual wipe.  The
    # normal fetch loop skips while this marker exists; only the explicitly
    # authorized --once process below may proceed.
    if ! create_runtime_marker "$LOGOUT_FETCH_MARKER" "$LOGOUT_COORDINATION_TOKEN"; then
        if ! write_ssh_status "$current_count" "$wipe_ok" "false" "" "125" "false" "false" \
            "logout-coordination" "true" "125" "coordination_failed"; then
            log "ERROR" "Cannot persist logout coordination failure"
        fi
        log "ERROR" "Cannot serialize logout fetch; SSH marker kept"
        return 1
    fi
    LOGOUT_COORDINATION_OWNED=true

    # 1. Wipe residual cache FIRST — ssh-active still exists, so fetcher won't start.
    local wipe_failed=false
    if [ -x "$CACHE_WIPE" ]; then
        log "  Running residual cache wipe (marker still active)"
        if bash "$CACHE_WIPE" 2>&1 | while IFS= read -r line; do log "  wipe: ${line}"; done; then
            log "  Residual wipe completed"
            wipe_ok="true"
        else
            log "ERROR" "Cache wipe returned non-zero — keeping marker, blocking fetch"
            wipe_failed=true
        fi
    else
        log "ERROR" "Cache wipe executable missing or not executable: ${CACHE_WIPE}"
        wipe_failed=true
    fi

    if $wipe_failed; then
        # Marker stays, fetch blocked, record the failure
        if ! write_ssh_status "$current_count" "$wipe_ok" "false" "" "" "false" "false" \
            "cache-wipe" "true" "1" "wipe_failed"; then
            log "ERROR" "Cannot persist residual wipe failure"
        fi
        cleanup_logout_coordination
        log "=== Maintenance aborted: marker kept, fetch blocked ==="
        return 1
    fi

    # 2. Wipe succeeded — remove ssh-active.  logout-fetch-active remains in
    # place, preventing the continuous service from racing the explicit fetch.
    local marker_path="$SSH_ACTIVE_MARKER"
    if ! rm -f -- "$marker_path" || [ -e "$marker_path" ]; then
        log "ERROR" "Cannot remove runtime marker ${marker_path}"
        if ! write_ssh_status "$current_count" "$wipe_ok" "false" "" "125" "false" "false" \
            "ssh-active" "true" "125" "coordination_failed"; then
            log "ERROR" "Cannot persist SSH marker removal failure"
        fi
        cleanup_logout_coordination
        return 1
    fi
    log "  Removed marker ${SSH_ACTIVE_MARKER}"

    if ! write_ssh_status "$current_count" "$wipe_ok" "" "" "" \
        "false" "false" "" "true" "" "fetch_in_progress"; then
        log "ERROR" "Cannot persist fetch-in-progress state"
        preserve_logout_coordination
        return 1
    fi

    # 3. Launch one isolated wrapper operation. The launch PID may remain sudo;
    # worker identity and the final exit status are tracked separately.
    if [ ! -x "$RADIO_FETCHER" ] || [ ! -x "$FETCH_WRAPPER" ]; then
        log "ERROR" "Fetch executable or operation wrapper is missing"
        fetch_exit=127
    else
        log "  Running one isolated radio-fetcher --once operation"
        if launch_explicit_fetch; then
            fetch_exit=0
        else
            fetch_exit=$?
        fi
        fetch_pid="$LAST_FETCH_LAUNCH_PID"
        if [ -n "$LAST_FETCH_EXIT" ]; then
            fetch_exit="$LAST_FETCH_EXIT"
        fi
        if [ "$fetch_exit" -eq 0 ]; then
            log "  Fetch operation completed successfully (exit 0)"
        else
            log "WARN" "Fetch operation failed (exit ${fetch_exit})"
        fi
    fi

    finalize_logout_fetch "$current_count" "$wipe_ok" "$fetch_pid" "$fetch_exit"
}

process_ssh_transition() {
    local current_ssh_count="$1" previous_ssh_count="$2"
    if [ "$current_ssh_count" -gt 0 ] && [ "$previous_ssh_count" -eq 0 ]; then
        if enter_maintenance; then
            write_ssh_status "$current_ssh_count"
        else
            local rc=$?
            log "ERROR" "SSH login transition failed (exit ${rc})"
            return "$rc"
        fi
    elif [ "$current_ssh_count" -eq 0 ] && [ "$previous_ssh_count" -gt 0 ]; then
        if exit_maintenance "$current_ssh_count"; then
            return 0
        else
            local rc=$?
            log "ERROR" "SSH logout transition failed (exit ${rc})"
            return "$rc"
        fi
    elif [ "$current_ssh_count" -gt 0 ]; then
        write_ssh_status "$current_ssh_count"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

ssh_monitor_main() {
for arg in "$@"; do
    case "$arg" in
        --once)   ONCE=true ;;
        --status) STATUS_ONLY=true ;;
        --help)   usage ;;
    esac
done

if $STATUS_ONLY; then
    current_count=$(get_ssh_count)
    previous_count=$(read_ssh_status)
    echo "Current SSH sessions: ${current_count}"
    echo "Previous known count: ${previous_count}"
    if [ -f "$SSH_STATUS_FILE" ]; then
        python3 -c "
import json
d = json.load(open('${SSH_STATUS_FILE}'))
print('Last updated:', d.get('last_updated', 'unknown'))
"
    fi
    exit 0
fi

if [ ! -x "$CACHE_WIPE" ]; then
    log "FATAL: ${CACHE_WIPE} not found or not executable"
    exit 1
fi
if [ ! -x "$RADIO_FETCHER" ]; then
    log "FATAL: ${RADIO_FETCHER} not found or not executable"
    exit 1
fi
if [ ! -x "$FETCH_WRAPPER" ]; then
    log "FATAL: ${FETCH_WRAPPER} not found or not executable"
    exit 1
fi
if ! command -v setsid >/dev/null 2>&1; then
    log "FATAL: setsid is required for isolated logout fetch operations"
    exit 1
fi

log "ssh-monitor starting (poll interval: ${POLL_INTERVAL}s)"

trap cleanup_logout_coordination EXIT
trap handle_signal TERM INT

if ! ensure_monitor_identity; then
    log "FATAL" "Cannot establish ssh-monitor process identity"
    return 1
fi
if ! recover_stale_logout_marker; then
    log "FATAL" "Cannot recover logout-fetch coordination"
    return 1
fi
if ! report_pending_recovery_state; then
    log "FATAL" "Cannot validate pending SSH maintenance recovery state"
    return 1
fi

while true; do
    local transition_rc=0
    if $RECOVERED_FETCH_IN_PROGRESS; then
        if fetch_operation_is_live; then
            log "INFO" "Recovered logout fetch is still running; deferring SSH state transitions"
            if $ONCE; then
                return 1
            fi
            sleep "$POLL_INTERVAL"
            continue
        fi
        local recovered_exit recovered_pid
        recovered_pid=$(fetch_operation_launch_pid 2>/dev/null || true)
        if recovered_exit=$(get_recorded_fetch_exit 2>/dev/null); then
            log "WARN" "Recovered logout fetch exited; finalizing recorded operation without relaunch"
            if finalize_logout_fetch 0 "true" "$recovered_pid" "$recovered_exit"; then
                RECOVERED_FETCH_IN_PROGRESS=false
            else
                transition_rc=$?
                RECOVERED_FETCH_IN_PROGRESS=false
                if $ONCE; then
                    return "$transition_rc"
                fi
            fi
        else
            log "ERROR" "Recovered logout operation has no trustworthy final result"
            write_ssh_status 0 "true" "false" "$recovered_pid" "125" \
                "false" "false" "radio-fetcher.service" "true" "125" "fetch_failed" || true
            preserve_logout_coordination
            RECOVERED_FETCH_IN_PROGRESS=false
            if $ONCE; then
                return 125
            fi
        fi
        report_pending_recovery_state || return 1
    fi
    if ! current_ssh_count=$(get_ssh_count); then
        transition_rc=1
        log "ERROR" "SSH session count unavailable; refusing state transition"
        if $ONCE; then
            return "$transition_rc"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    previous_ssh_count=$(read_ssh_status)

    if process_ssh_transition "$current_ssh_count" "$previous_ssh_count"; then
        transition_rc=0
    else
        transition_rc=$?
    fi

    if $ONCE; then
        return "$transition_rc"
    fi
    sleep "$POLL_INTERVAL"
done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ssh_monitor_main "$@"
fi
