#!/bin/bash
sleep 2
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
CARD=$(pactl list cards short 2>/dev/null | grep bluez_card | awk '{print $2}' | head -1)
if [ -n "$CARD" ]; then
    pactl set-card-profile "$CARD" a2dp_sink 2>/dev/null
    echo "Perfil A2DP aplicado a $CARD"
else
    echo "No se encontro tarjeta Bluetooth"
fi
# Forzar sink por defecto a la bocina Bluetooth
SINK=$(pactl list sinks short 2>/dev/null | grep bluez | head -1 | awk '{print $2}')
if [ -n "$SINK" ]; then
    pactl set-default-sink "$SINK" 2>/dev/null || true
    echo "Sink por defecto: $SINK"
fi
