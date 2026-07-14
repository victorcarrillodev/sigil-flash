#!/bin/bash
# Run one SSH-logout fetch as sigil and persist its real exit status atomically.
# Arguments contain only operation metadata and local paths; credentials are
# loaded internally by radio-fetcher from /etc/sigil/audio.conf.
set -uo pipefail

OPERATION_ID="${1:-}"
RESULT_FILE="${2:-}"
RADIO_FETCHER="${3:-}"
RUN_SIGIL_DIR="${4:-/run/sigil}"
FETCH_PID=""
FETCH_START_TIME=""

case "$OPERATION_ID" in
    ''|*[!a-zA-Z0-9_-]*) exit 64 ;;
esac
[ -n "$RESULT_FILE" ] && [ -n "$RADIO_FETCHER" ] || exit 64
[ -x "$RADIO_FETCHER" ] || exit 127
if ! python3 - "$RESULT_FILE" "$RUN_SIGIL_DIR" <<'PYEOF'
import os
import sys
result = os.path.realpath(sys.argv[1])
run_dir = os.path.realpath(sys.argv[2])
raise SystemExit(0 if os.path.dirname(result) == run_dir else 1)
PYEOF
then
    exit 64
fi

get_start_time() {
    local pid="$1"
    python3 - "/proc/${pid}/stat" <<'PYEOF'
import sys
try:
    raw = open(sys.argv[1], encoding="utf-8").read().strip()
except OSError:
    raise SystemExit(1)
end = raw.rfind(")")
fields = raw[end + 2:].split() if end >= 0 else []
if len(fields) <= 19 or not fields[19].isdigit():
    raise SystemExit(1)
print(fields[19])
PYEOF
}

write_result() {
    local exit_code="$1" state="$2" wrapper_start
    wrapper_start=$(get_start_time "$$" 2>/dev/null || true)
    python3 - "$RESULT_FILE" "$OPERATION_ID" "$state" "$exit_code" \
        "$$" "$wrapper_start" "$FETCH_PID" "$FETCH_START_TIME" <<'PYEOF'
import json
import os
import sys
import tempfile

path, operation_id, state, exit_raw, wrapper_pid, wrapper_start, child_pid, child_start = sys.argv[1:]
document = {
    "_schema_version": "1.0",
    "operation_id": operation_id,
    "state": state,
    "exit_code": int(exit_raw),
    "wrapper_pid": int(wrapper_pid),
    "wrapper_start_time_ticks": wrapper_start or None,
    "child_pid": int(child_pid) if child_pid.isdigit() else None,
    "child_start_time_ticks": child_start or None,
}
directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(dir=directory, prefix=".logout-fetch-result.", suffix=".tmp")
try:
    os.fchmod(fd, 0o640)
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
}

trap '
    if [ -n "$FETCH_PID" ] && kill -0 "$FETCH_PID" 2>/dev/null; then
        kill -TERM "$FETCH_PID" 2>/dev/null || true
        wait "$FETCH_PID" 2>/dev/null || true
    fi
    write_result 143 "interrupted" 2>/dev/null || true
    exit 143
' TERM INT HUP

SIGIL_LOGOUT_FETCH=1 \
SIGIL_LOGOUT_OPERATION_ID="$OPERATION_ID" \
SIGIL_RUN_DIR="$RUN_SIGIL_DIR" \
    bash "$RADIO_FETCHER" --once &
FETCH_PID=$!
FETCH_START_TIME=$(get_start_time "$FETCH_PID" 2>/dev/null || true)

fetch_exit=0
if wait "$FETCH_PID"; then
    fetch_exit=0
else
    fetch_exit=$?
fi

if ! write_result "$fetch_exit" "complete"; then
    exit 125
fi
exit "$fetch_exit"
