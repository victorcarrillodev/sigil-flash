#!/bin/bash
# Own the single SIGIL PulseAudio daemon and only report READY after pactl can
# use its native socket. systemd owns /run/sigil-pulse via RuntimeDirectory.

set -euo pipefail

PULSE_RUNTIME_ENV="${SIGIL_PULSE_RUNTIME_ENV:-/etc/sigil/pulse-runtime.env}"
if [ -r "$PULSE_RUNTIME_ENV" ]; then
    # shellcheck disable=SC1090
    set -a
    . "$PULSE_RUNTIME_ENV"
    set +a
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/sigil-pulse}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/run/sigil-pulse}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"

READY_TIMEOUT="${SIGIL_PULSE_READY_TIMEOUT:-10}"
PACTL_TIMEOUT="${SIGIL_PACTL_TIMEOUT:-3}"
HEALTH_INTERVAL="${SIGIL_PULSE_HEALTH_INTERVAL:-15}"
MAX_HEALTH_FAILURES="${SIGIL_PULSE_MAX_HEALTH_FAILURES:-2}"
PULSE_PID=""

log() {
    printf 'sigil-pulseaudio: %s\n' "$*"
}

stop_child() {
    [ -n "${PULSE_PID:-}" ] || return 0
    if kill -0 "$PULSE_PID" 2>/dev/null; then
        kill -TERM "$PULSE_PID" 2>/dev/null || true
        local waited=0
        while kill -0 "$PULSE_PID" 2>/dev/null && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        kill -KILL "$PULSE_PID" 2>/dev/null || true
    fi
    wait "$PULSE_PID" 2>/dev/null || true
}

trap 'stop_child; exit 0' TERM INT
trap 'stop_child' EXIT

mkdir -p "$PULSE_RUNTIME_PATH"
chmod 0700 "$PULSE_RUNTIME_PATH"

pulseaudio --daemonize=no --log-target=journal &
PULSE_PID=$!

ready=0
for ((attempt = 0; attempt < READY_TIMEOUT; attempt++)); do
    if ! kill -0 "$PULSE_PID" 2>/dev/null; then
        log "daemon exited before readiness"
        wait "$PULSE_PID" || true
        exit 1
    fi
    if [ -S "${PULSE_RUNTIME_PATH}/native" ] \
        && timeout --kill-after=1s "$PACTL_TIMEOUT" pactl info >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    log "native socket did not become usable in ${READY_TIMEOUT}s"
    exit 1
fi

systemd-notify --ready --status="PulseAudio listo en ${PULSE_RUNTIME_PATH}" || true
log "ready"

failures=0
while kill -0 "$PULSE_PID" 2>/dev/null; do
    sleep "$HEALTH_INTERVAL"
    if [ -S "${PULSE_RUNTIME_PATH}/native" ] \
        && timeout --kill-after=1s "$PACTL_TIMEOUT" pactl info >/dev/null 2>&1; then
        failures=0
        systemd-notify WATCHDOG=1 --status="PulseAudio saludable" || true
        continue
    fi
    failures=$((failures + 1))
    log "health check failed (${failures}/${MAX_HEALTH_FAILURES})"
    if [ "$failures" -ge "$MAX_HEALTH_FAILURES" ]; then
        systemd-notify --status="PulseAudio no responde; reinicio controlado" || true
        exit 1
    fi
done

wait "$PULSE_PID"
