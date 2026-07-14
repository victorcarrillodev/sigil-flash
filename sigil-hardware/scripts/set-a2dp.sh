#!/bin/bash
sleep 2
SIGIL_UID=$(id -u sigil 2>/dev/null || echo "1000")
CARD=$(PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse pactl list cards short 2>/dev/null | grep bluez_card | awk '{print $2}' | head -1)
if [ -n "$CARD" ]; then
    PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse pactl set-card-profile "$CARD" a2dp_sink 2>/dev/null
    echo "Perfil A2DP aplicado a $CARD"
else
    echo "No se encontro tarjeta Bluetooth"
fi
# Forzar sink por defecto a la bocina Bluetooth
SINK=$(PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse pactl list sinks short 2>/dev/null | grep bluez | head -1 | awk '{print $2}')
if [ -n "$SINK" ]; then
    PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse pactl set-default-sink "$SINK" 2>/dev/null || true
    echo "Sink por defecto: $SINK"
fi
