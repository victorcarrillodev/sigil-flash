#!/bin/bash
# sigil-leds.sh — Daemon de control para Hardware - Fix WiFi Red Real

LED_WIFI=17  # Pin 11
LED_BT=27    # Pin 13
LED_PWR=22   # Pin 15
PREF_FILE="/home/sigil/preferred_bt.txt"

cleanup() {
    pinctrl set ${LED_PWR} dl 2>/dev/null
    pinctrl set ${LED_WIFI} dl 2>/dev/null
    pinctrl set ${LED_BT} dl 2>/dev/null
    exit 0
}
trap cleanup EXIT TERM INT

pinctrl set ${LED_PWR} op
pinctrl set ${LED_WIFI} op
pinctrl set ${LED_BT} op

# Encender LED de Power fijo al arrancar
pinctrl set ${LED_PWR} dh

TICK=0
BLINK_STATE=0
WIFI_STATE="disconnected"
BT_STATE="disconnected"

while true; do
    if [ $((TICK % 4)) -eq 0 ]; then
        
        # 1. Revisar estado del WiFi (Conexión a una red real / router)
        # 'iw link' solo responde afirmativo cuando la Raspberry actúa como cliente de un módem.
        # Si está creando la red "sigil" (modo AP), esto fallará y el LED parpadeará.
        if iw dev wlan0 link 2>/dev/null | grep -q "Connected to"; then
            WIFI_STATE="connected"
            pinctrl set ${LED_WIFI} dh # Fijo porque ya está colgada a un WiFi real
        else
            WIFI_STATE="disconnected"
        fi

        # 2. Revisar estado del Bluetooth
        PREF_MAC=$( (cat "$PREF_FILE" 2>/dev/null; echo "") | tr -d '\r' | grep -o -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n 1)
        if [ -n "$PREF_MAC" ] && bluetoothctl info "$PREF_MAC" 2>/dev/null | grep -q "Connected: yes"; then
            BT_STATE="connected"
            pinctrl set ${LED_BT} dh
        else
            BT_STATE="disconnected"
        fi
    fi

    if [ "$BLINK_STATE" -eq 0 ]; then
        BLINK_STATE=1
        VAL="dh"
    else
        BLINK_STATE=0
        VAL="dl"
    fi

    # Aplicar parpadeo SOLAMENTE si no hay conexión real
    if [ "$WIFI_STATE" = "disconnected" ]; then
        pinctrl set ${LED_WIFI} $VAL
    fi

    if [ "$BT_STATE" = "disconnected" ]; then
        pinctrl set ${LED_BT} $VAL
    fi

    sleep 0.5
    TICK=$((TICK + 1))
done