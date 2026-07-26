#!/bin/bash
# Focused contract for session-independent PulseAudio ownership.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0

run() {
    local label="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n' "$label"
    fi
}

UNIT="$ROOT/services/sigil-pulseaudio.service"
SUPERVISOR="$ROOT/scripts/sigil-pulseaudio-supervisor.sh"
ENV_FILE="$ROOT/conf/pulse-runtime.env"

run "Pulse runtime is independent from login sessions" \
    bash -c '! grep -R -q "/run/user" "$1/scripts" "$1/services" "$1/conf"' _ "$ROOT"
run "canonical native socket is declared once" \
    grep -q '^PULSE_SERVER=unix:/run/sigil-pulse/native$' "$ENV_FILE"
run "systemd owns the private runtime directory" \
    grep -q '^RuntimeDirectory=sigil-pulse$' "$UNIT"
run "fresh-image Pulse config setup retains root privileges" \
    grep -q '^ExecStartPre=+/usr/bin/install -d -o sigil -g sigil -m 0700 /home/sigil/.config/pulse$' "$UNIT"
run "service readiness is explicit" grep -q '^Type=notify$' "$UNIT"
run "service watchdog is bounded" grep -q '^WatchdogSec=45$' "$UNIT"
run "restart storms are limited" \
    bash -c 'grep -q "^StartLimitIntervalSec=60$" "$1" && grep -q "^StartLimitBurst=10$" "$1" && grep -q "^Restart=on-failure$" "$1"' _ "$UNIT"
run "supervisor requires both native socket and pactl" \
    bash -c 'grep -q "\\[ -S.*native" "$1" && grep -q "pactl info" "$1"' _ "$SUPERVISOR"
run "two failed health checks trigger controlled restart" \
    grep -q 'SIGIL_PULSE_MAX_HEALTH_FAILURES:-2' "$SUPERVISOR"
run "Pulse supervisor shell syntax is valid" bash -n "$SUPERVISOR"

printf '\nPulse runtime: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
