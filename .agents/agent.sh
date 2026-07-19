#!/bin/bash
# sigil-bluetooth-agent.sh — Persistent BlueZ pairing agent
# Keeps bluetoothctl alive with a registered NoInputNoOutput default agent.
# Must be started as a systemd service, not from bt-connect.sh or the panel.

set -uo pipefail

BLUETOOTHCTL="${SIGIL_BLUETOOTHCTL:-bluetoothctl}"

# Pre-flight: wait for bluetoothd to be ready
for i in $(seq 1 15); do
    if "$BLUETOOTHCTL" show >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Start bluetoothctl with the agent commands piped in.
# tail -f /dev/null keeps stdin open so bluetoothctl never exits.
{
    echo "agent NoInputNoOutput"
    echo "default-agent"
    tail -f /dev/null
} | "$BLUETOOTHCTL"

# If we reach here, bluetoothctl exited — systemd will restart us.
exit 1
