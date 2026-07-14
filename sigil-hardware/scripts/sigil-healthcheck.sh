#!/bin/bash
# sigil-healthcheck.sh — Comprehensive Sigil device health check
#
# Validates:
#   - Audio state files (JSON validity + _schema_version)
#   - Music cache status (track count, size)
#   - Disk space on key directories
#   - Bluetooth A2DP sink presence
#   - Systemd service states
#
# Usage:
#   sigil-healthcheck.sh              # human-readable output
#   sigil-healthcheck.sh --json       # JSON output (machine-readable)
#   sigil-healthcheck.sh --quiet      # exit code only, no output
#   sigil-healthcheck.sh --help       # show this message
#
# Exit codes:
#   0 = HEALTHY      — all checks pass
#   1 = DEGRADED     — non-critical issues (no BT sink, some services down)
#   2 = UNHEALTHY    — critical issues (state files corrupt, no disk space)
# =============================================================================
set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────
SIGIL_STATE_DIR="/var/lib/sigil"
SIGIL_MUSIC_DIR="/home/sigil/music"
SIGIL_LOG_DIR="/var/log/sigil"
SIGIL_CONFIG_DIR="/etc/sigil"

STATE_FILES=(
    "registration.json"
    "audio_mode.json"
    "playback_state.json"
    "playlist.active.json"
    "playlist.staging.json"
    "cache_meta.json"
    "bluetooth_state.json"
)

SERVICES=(
    "bluetooth-panel"
    "bt-connect"
    "radio-stream"
    "sigil-leds"
    "wifi-fallback"
    "audio-manager"
    "radio-fetcher"
    "audio-player"
)

# ── Flags ───────────────────────────────────────────────────────────────────
JSON_MODE=false
QUIET_MODE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--json] [--quiet]

Options:
  --json    Machine-readable JSON output
  --quiet   Suppress all output, return exit code only
  --help    Show this message

Exit codes:
  0 = HEALTHY       all checks pass
  1 = DEGRADED      non-critical issues found
  2 = UNHEALTHY     critical issues found
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --json)  JSON_MODE=true ;;
        --quiet) QUIET_MODE=true ;;
        --help)  usage ;;
    esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────
ts_iso8601() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

hostname_val() {
    hostname 2>/dev/null || echo "unknown"
}

# ── Check: State files ──────────────────────────────────────────────────────
check_state_files() {
    local py_script='import json,sys; files=[]; failed=0; dir=sys.argv[1]
for fname in sys.argv[2:]:
    fp=f"{dir}/{fname}"
    try:
        with open(fp) as f:
            data=json.load(f)
        sv=data.get("_schema_version","MISSING")
        files.append({"file":fname,"status":"OK","schema_version":sv})
    except FileNotFoundError:
        files.append({"file":fname,"status":"ERROR","reason":"File not found"})
        failed+=1
    except json.JSONDecodeError as e:
        files.append({"file":fname,"status":"ERROR","reason":str(e)})
        failed+=1
    except Exception as e:
        files.append({"file":fname,"status":"ERROR","reason":str(e)})
        failed+=1
ov="OK" if failed==0 else "ERROR"
print(json.dumps({"status":ov,"failed":failed,"files":files}))'

    python3 -c "$py_script" "$SIGIL_STATE_DIR" "${STATE_FILES[@]}"
}

# ── Check: Cache status ─────────────────────────────────────────────────────
check_cache() {
    local active_dir="${SIGIL_MUSIC_DIR}/active/tracks"
    local staging_dir="${SIGIL_MUSIC_DIR}/staging/tracks"
    local archive_dir="${SIGIL_MUSIC_DIR}/archive"
    local cache_meta="${SIGIL_STATE_DIR}/cache_meta.json"

    local active_count=0 active_size=0 staging_count=0 archive_count=0
    local status="OK"

    if [ -d "$active_dir" ]; then
        active_count=$(find "$active_dir" -type f 2>/dev/null | wc -l)
        active_size=$(du -sb "$active_dir" 2>/dev/null | awk '{print $1}')
        active_size=${active_size:-0}
    fi

    if [ -d "$staging_dir" ]; then
        staging_count=$(find "$staging_dir" -type f 2>/dev/null | wc -l)
    fi

    if [ -d "$archive_dir" ]; then
        archive_count=$(find "$archive_dir" -type f 2>/dev/null | wc -l)
    fi

    if [ "$active_count" -gt 0 ] && [ ! -f "$cache_meta" ]; then
        status="WARNING"
    fi

    echo "{\"status\": \"${status}\", \"active_tracks\": ${active_count}, \"active_size_bytes\": ${active_size}, \"staging_tracks\": ${staging_count}, \"archive_files\": ${archive_count}}"
}

# ── Check: Disk space ───────────────────────────────────────────────────────
check_disk() {
    local overall="OK"
    local paths_json='[]'
    local critical_threshold=100 # MB

    for p in "$SIGIL_STATE_DIR" "$SIGIL_MUSIC_DIR" "$SIGIL_LOG_DIR" "$SIGIL_CONFIG_DIR"; do
        if [ ! -d "$p" ]; then
            paths_json=$(python3 -c "
import json, sys
r = json.loads('$paths_json')
r.append({'path': '$p', 'status': 'WARNING', 'reason': 'Directory not found'})
print(json.dumps(r))
")
            if [ "$overall" = "OK" ]; then overall="WARNING"; fi
            continue
        fi

        local stats
        stats=$(df -m "$p" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
        if [ -z "$stats" ]; then
            paths_json=$(python3 -c "
import json, sys
r = json.loads('$paths_json')
r.append({'path': '$p', 'status': 'WARNING', 'reason': 'Cannot query disk stats'})
print(json.dumps(r))
")
            if [ "$overall" = "OK" ]; then overall="WARNING"; fi
            continue
        fi

        local total_mb used_mb avail_mb pct
        read -r total_mb used_mb avail_mb pct <<<"$stats"
        pct=${pct%\%}

        local path_status="OK"
        if [ "$avail_mb" -lt "$critical_threshold" ]; then
            path_status="ERROR"
            overall="ERROR"
        elif [ "$pct" -gt 90 ]; then
            path_status="WARNING"
            if [ "$overall" = "OK" ] || [ "$overall" = "WARNING" ]; then
                :
            fi
            if [ "$overall" = "OK" ]; then overall="WARNING"; fi
        fi

        paths_json=$(python3 -c "
import json, sys
r = json.loads('$paths_json')
r.append({'path': '$p', 'status': '$path_status', 'total_mb': $total_mb, 'used_mb': $used_mb, 'avail_mb': $avail_mb, 'used_pct': $pct})
print(json.dumps(r))
")
    done

    echo "{\"status\": \"${overall}\", \"paths\": ${paths_json}}"
}

# ── Check: Bluetooth sink ───────────────────────────────────────────────────
check_bluetooth_sink() {
    local status="WARNING"
    local sink_name=""
    local connected=false

    # Query PulseAudio sinks as sigil user
    local pactl_out
    pactl_out=$(sudo -u sigil pactl list sinks short 2>/dev/null || true)

    if [ -n "$pactl_out" ]; then
        local sink_line
        sink_line=$(echo "$pactl_out" | grep -i bluez 2>/dev/null | head -1 || true)
        if [ -n "$sink_line" ]; then
            sink_name=$(echo "$sink_line" | awk '{print $2}')
            status="OK"
            connected=true
        fi
    else
        # pactl not accessible — check via D-Bus or fall back to bluetoothctl
        local bt_info
        bt_info=$(sudo -u sigil bluetoothctl info 2>/dev/null || true)
        if echo "$bt_info" | grep -q "Connected: yes"; then
            status="OK"
            connected=true
            sink_name="(bluetoothctl reported connected)"
        fi
    fi

    echo "{\"status\": \"${status}\", \"sink_name\": $(echo "$sink_name" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"), \"connected\": ${connected}}"
}

# ── Check: Systemd services ─────────────────────────────────────────────────
check_services() {
    local -a svc_names=("${SERVICES[@]}")
    local -a svc_states=()
    local overall="OK"
    local inactive_count=0

    for svc in "${svc_names[@]}"; do
        local unit="${svc}.service"
        local state
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        if [ -z "$state" ]; then
            state="not-found"
        fi
        svc_states+=("$state")
        if [ "$state" != "active" ]; then
            inactive_count=$((inactive_count + 1))
            if [ "$svc" != "wifi-fallback" ]; then
                overall="DEGRADED"
            fi
        fi
    done

    # Build JSON via Python subprocess with explicit data pipe
    local py_script='import json,sys; ic=int(sys.argv[1]); ov=sys.argv[2]; sd=[]; il=[];
for l in sys.stdin:
 l=l.strip()
 if not l: continue
 p=l.split(",",1); n=p[0]; s=p[1] if len(p)>1 else "unknown"
 sd.append({"service":n,"state":s})
 if s!="active": il.append(n)
print(json.dumps({"status":ov,"inactive_count":ic,"inactive_services":il,"services":sd}))'
    {
        for i in "${!svc_names[@]}"; do
            echo "${svc_names[$i]},${svc_states[$i]}"
        done
    } | python3 -c "$py_script" "$inactive_count" "$overall"
}

# ── Assemble report ─────────────────────────────────────────────────────────
run_checks() {
    local state_result cache_result disk_result bt_result svc_result

    state_result=$(check_state_files)
    cache_result=$(check_cache)
    disk_result=$(check_disk)
    bt_result=$(check_bluetooth_sink)
    svc_result=$(check_services)

    # Determine overall result
    local result="HEALTHY"

    local state_status cache_status disk_status bt_status svc_status
    state_status=$(echo "$state_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    cache_status=$(echo "$cache_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    disk_status=$(echo "$disk_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    bt_status=$(echo "$bt_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    svc_status=$(echo "$svc_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

    for s in "$state_status" "$disk_status"; do
        if [ "$s" = "ERROR" ]; then result="UNHEALTHY"; fi
    done

    if [ "$result" != "UNHEALTHY" ]; then
        for s in "$cache_status" "$bt_status" "$svc_status"; do
            if [ "$s" != "OK" ]; then
                result="DEGRADED"
                break
            fi
        done
        if [ "$state_status" = "WARNING" ] || [ "$disk_status" = "WARNING" ]; then
            result="DEGRADED"
        fi
    fi

    local now
    now=$(ts_iso8601)
    local host
    host=$(hostname_val)

    echo "{\"timestamp\": \"${now}\", \"hostname\": \"${host}\", \"result\": \"${result}\", \"checks\": {\"state_files\": ${state_result}, \"cache\": ${cache_result}, \"disk\": ${disk_result}, \"bluetooth_sink\": ${bt_result}, \"services\": ${svc_result}}}"
}

# ── Output formatting ───────────────────────────────────────────────────────

format_human() {
    local report="$1"

    local result host ts
    result=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")
    host=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['hostname'])")
    ts=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['timestamp'])")

    echo "=== Sigil Health Check ==="
    echo "Hostname:   ${host}"
    echo "Timestamp:  ${ts}"
    echo ""

    # State files
    echo "## Audio State Files"
    local files
    files=$(echo "$report" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for f in r['checks']['state_files']['files']:
    s = f['status']
    if s == 'OK':
        print('  OK    {}  (_schema_version={})'.format(f['file'], f.get('schema_version', '?')))
    else:
        print('  {}  {}  ({})'.format(s.ljust(5), f['file'], f.get('reason', 'unknown')))
")
    echo "$files"
    echo ""

    # Cache
    echo "## Cache Status"
    local cache_status active_tracks active_size staging_tracks archive_files
    cache_status=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['cache']['status'])")
    active_tracks=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['cache']['active_tracks'])")
    active_size=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['cache']['active_size_bytes'])")
    staging_tracks=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['cache']['staging_tracks'])")
    archive_files=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['cache']['archive_files'])")

    local size_hr
    size_hr=$(python3 -c "
import sys
b = $active_size
if b > 1073741824:
    print(f'{b/1073741824:.1f} GB')
elif b > 1048576:
    print(f'{b/1048576:.1f} MB')
else:
    print(f'{b/1024:.1f} KB')
")

    echo "  Status:        ${cache_status}"
    echo "  Active tracks: ${active_tracks} (${size_hr})"
    echo "  Staging:       ${staging_tracks} tracks"
    echo "  Archive:       ${archive_files} files"
    echo ""

    # Disk
    echo "## Disk Space"
    echo "$report" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for p in r['checks']['disk']['paths']:
    s = p['status']
    if s == 'OK':
        print('  OK    {:<25} {} MB used / {} MB avail ({}%)'.format(p['path'], p['used_mb'], p['avail_mb'], p['used_pct']))
    elif s == 'WARNING':
        print('  WARN  {:<25} {} MB used / {} MB avail ({}%)'.format(p['path'], p['used_mb'], p['avail_mb'], p['used_pct']))
    else:
        print('  FAIL  {:<25} {}'.format(p['path'], p.get('reason', 'error')))
"
    echo ""

    # Bluetooth
    echo "## Bluetooth Sink"
    local bt_sink bt_connected
    bt_sink=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['bluetooth_sink'].get('sink_name', 'none'))")
    bt_connected=$(echo "$report" | python3 -c "import json,sys; print(json.load(sys.stdin)['checks']['bluetooth_sink']['connected'])")
    if [ "$bt_connected" = "True" ]; then
        echo "  OK    Sink: ${bt_sink} (Connected)"
    else
        echo "  WARN  No Bluetooth A2DP sink found"
    fi
    echo ""

    # Services
    echo "## Service Status"
    echo "$report" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for s in r['checks']['services']['services']:
    svc = s['service']
    st = s['state']
    if st == 'active':
        icon = '●'
        print('  OK    {} {}'.format(svc.ljust(20), icon))
    elif st == 'inactive':
        icon = '○'
        print('  WARN  {} {} (inactive)'.format(svc.ljust(20), icon))
    elif st == 'not-found':
        icon = '✘'
        print('  FAIL  {} {} (not found)'.format(svc.ljust(20), icon))
    else:
        icon = '○'
        print('  WARN  {} {} ({})'.format(svc.ljust(20), icon, st))
"
    echo ""

    # Summary
    echo "---"
    case "$result" in
        HEALTHY)   echo "Result: HEALTHY — all checks pass" ;;
        DEGRADED)  echo "Result: DEGRADED — non-critical issues detected" ;;
        UNHEALTHY) echo "Result: UNHEALTHY — critical issues detected" ;;
    esac
}

# ── Main ────────────────────────────────────────────────────────────────────
REPORT=$(run_checks)

if $JSON_MODE; then
    echo "$REPORT" | python3 -m json.tool 2>/dev/null || echo "$REPORT"
elif $QUIET_MODE; then
    :
else
    format_human "$REPORT"
fi

# Determine exit code (0=healthy, 1=degraded, 2=unhealthy)
echo "$REPORT" | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; sys.exit(0 if r=='HEALTHY' else (1 if r=='DEGRADED' else 2))"
