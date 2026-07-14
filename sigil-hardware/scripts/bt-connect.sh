#!/bin/bash
# bt-connect.sh — Gestor de conexion exclusiva con auto-follow
# La bocina que se conecte (manual o automaticamente) se convierte en la preferida.
# Todas las demas son desconectadas y se les quita la confianza.

PREFERRED=/home/sigil/preferred_bt.txt
LOG=/var/log/bt-connect.log
# Crear archivo de log si no existe (puede fallar si no hay permisos — fallback a journal)
touch "$LOG" 2>/dev/null || LOG=""
BT_SWITCH_LOCK="/tmp/bt-switching.lock"
PREV_MAC=""

# UID del usuario sigil para PulseAudio (resuelto dinámicamente)
SIGIL_UID=$(id -u sigil 2>/dev/null || echo "1000")
export XDG_RUNTIME_DIR=/run/user/${SIGIL_UID}
export PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse
export PULSE_SERVER=unix:/run/user/${SIGIL_UID}/pulse/native

AUDIO_ROUTE_HELPER="${SIGIL_AUDIO_ROUTE_HELPER:-/usr/local/bin/sigil-audio-route.sh}"
if [ -r "$AUDIO_ROUTE_HELPER" ]; then
    # shellcheck source=scripts/sigil-audio-route.sh
    source "$AUDIO_ROUTE_HELPER"
else
    audio_route_activate_bluetooth() { return 1; }
fi

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ -n "$LOG" ]; then echo "$msg" | tee -a "$LOG"; else echo "$msg"; fi
}

# Esperar a que app.py termine de hacer el cambio de bocina
wait_switch_lock() {
    local waited=0
    while [ -f "$BT_SWITCH_LOCK" ] && [ $waited -lt 30 ]; do
        log "Cambio de bocina en progreso — esperando..."
        sleep 3
        waited=$((waited + 3))
    done
    [ -f "$BT_SWITCH_LOCK" ] && rm -f "$BT_SWITCH_LOCK" && log "Lock expirado, continuando."
}

activate_a2dp() {
    local MAC="$1"
    sleep 2
    if audio_route_activate_bluetooth "$MAC"; then
        log "Perfil A2DP activado para $MAC"
    else
        log "A2DP no usable para $MAC (Connected/Trusted, perfil, sink o probe falló)"
    fi
}

# ── Función: esperar a que PulseAudio registre los endpoints A2DP en BlueZ ──
# Sin esto bt-connect intenta conectar antes de que el perfil esté disponible,
# causando: br-connection-profile-unavailable / Protocol not available
wait_a2dp_ready() {
    local MAX_WAIT=60  # segundos máximos
    local waited=0
    log "Esperando a que PulseAudio registre endpoints A2DP en BlueZ..."
    while [ $waited -lt $MAX_WAIT ]; do
        # Verificar que bluetoothd ya vea al menos un endpoint A2DP registrado
        if bluetoothctl show 2>/dev/null | grep -q "UUID: Audio Sink"; then
            log "A2DP detectado en bluetoothctl show — continuando."
            return 0
        fi
        # Alternativa: verificar vía pactl que PulseAudio levantó el módulo BT
        if PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse pactl list modules short 2>/dev/null \
                | grep -q "module-bluetooth"; then
            log "Módulo Bluetooth de PulseAudio activo — continuando."
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    log "Advertencia: A2DP no se detectó en ${MAX_WAIT}s — intentando de todos modos."
}

log "bt-connect iniciado"

# Levantar el adaptador BT con retry — BlueZ puede no estar listo al boot
bt_up=0
for i in $(seq 1 10); do
    # 1. Desbloquear por rfkill (software block)
    sudo rfkill unblock bluetooth 2>/dev/null || true
    # 2. Levantar el adaptador a nivel de kernel
    sudo hciconfig hci0 up 2>/dev/null || true
    # 3. Encender via BlueZ (capa de software)
    bluetoothctl power on 2>/dev/null || true
    sleep 3
    if hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; then
        log "Adaptador BT listo (intento $i)"
        bt_up=1
        break
    fi
    log "Adaptador BT aun DOWN, reintentando ($i/10)..."
done

if [ $bt_up -eq 0 ]; then
    log "ERROR: No se pudo levantar hci0 despues de 10 intentos. Abortando."
    exit 1
fi

# ── ESPERAR A2DP antes de cualquier intento de conexión ──────────────────────
# Este es el punto crítico: sin esto, bt-connect falla con
# "br-connection-profile-unavailable" porque PulseAudio aún no registró A2DP.
wait_a2dp_ready

# Si app.py esta cambiando bocina ahorita, esperar a que termine
wait_switch_lock

# Verificar y corregir permisos del archivo preferred_bt.txt
# bt-connect corre como sigil, el archivo puede estar owned por root si se creó con sudo
if [ -f "$PREFERRED" ] && [ ! -w "$PREFERRED" ]; then
    log "ADVERTENCIA: $PREFERRED no tiene permisos de escritura para sigil. Intentando corregir..."
    sudo chown sigil:sigil "$PREFERRED" 2>/dev/null || true
    sudo chmod 644 "$PREFERRED" 2>/dev/null || true
fi

# Conectar al preferido al arrancar (solo si no esta conectado ya)
if [ -f "$PREFERRED" ]; then
    INIT_MAC=$(tr -d '[:space:]' < "$PREFERRED")
    if [ -n "$INIT_MAC" ]; then
        CONNECTED_MACS=$(bluetoothctl devices Connected 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
        if echo "$CONNECTED_MACS" | grep -qI "$INIT_MAC" || bluetoothctl info "$INIT_MAC" 2>/dev/null | grep -qI "Connected: yes"; then
            log "Preferido inicial $INIT_MAC ya conectado al arrancar"
            activate_a2dp "$INIT_MAC"
        else
            log "Conectando al preferido inicial: $INIT_MAC"
            bluetoothctl unblock "$INIT_MAC" 2>/dev/null
            bluetoothctl trust "$INIT_MAC" 2>/dev/null
            bluetoothctl connect "$INIT_MAC" 2>/dev/null
            sleep 6
            # Doble verificación: devices Connected + bluetoothctl info
            PREF_CONNECTED=0
            CONNECTED_CHECK=$(bluetoothctl devices Connected 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
            if echo "$CONNECTED_CHECK" | grep -qI "$INIT_MAC"; then
                PREF_CONNECTED=1
            elif bluetoothctl info "$INIT_MAC" 2>/dev/null | grep -qI 'Connected: yes'; then
                PREF_CONNECTED=1
            fi
            if [ "$PREF_CONNECTED" -eq 1 ]; then
                log "Conexión inicial exitosa: $INIT_MAC"
                activate_a2dp "$INIT_MAC"
            else
                log "Conexión inicial fallida para $INIT_MAC (se reintentará en el loop)"
            fi
        fi
    fi
fi

while true; do
    sleep 5

    # Si app.py esta haciendo un cambio de bocina, no interferir
    if [ -f "$BT_SWITCH_LOCK" ]; then
        log "Cambio de bocina en progreso — saltando ciclo"
        continue
    fi

    # Ver cuales bocinas estan conectadas ahora mismo
    CONNECTED_MACS=$(bluetoothctl devices Connected 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')

    # Leer el preferido actual
    PREF=""
    if [ -f "$PREFERRED" ]; then
        PREF=$(tr -d '[:space:]' < "$PREFERRED")
    fi

    if [ -z "$CONNECTED_MACS" ]; then
        # Nadie conectado: intentar reconectar al preferido
        if [ -n "$PREF" ]; then
            # Verificar por segunda vez usando info por si fue un retraso de bluetoothctl
            if bluetoothctl info "$PREF" 2>/dev/null | grep -qI "Connected: yes"; then
                log "Omitiendo reconexion: $PREF ya esta conectado segun info."
                PREV_MAC="$PREF"
                continue
            fi

            log "Sin conexion — reconectando a $PREF..."
            bluetoothctl unblock "$PREF" 2>/dev/null
            bluetoothctl trust "$PREF" 2>/dev/null
            bluetoothctl connect "$PREF" 2>/dev/null

            # Dar un breve margen y verificar si la conexión pegó
            sleep 6
            CONNECTED_MACS_CHECK=$(bluetoothctl devices Connected 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')
            # Doble verificación: devices Connected + bluetoothctl info (más confiable)
            PREF_CONNECTED=0
            if echo "$CONNECTED_MACS_CHECK" | grep -qI "$PREF"; then
                PREF_CONNECTED=1
            elif bluetoothctl info "$PREF" 2>/dev/null | grep -qI 'Connected: yes'; then
                PREF_CONNECTED=1
            fi
            if [ "$PREF_CONNECTED" -eq 1 ]; then
                log "Conexion exitosa a $PREF"
                activate_a2dp "$PREF"
                PREV_MAC="$PREF"
            else
                # Si fallo, esperar un tiempo aleatorio para evitar bucles de colision
                # con los propios intentos de auto-conexion de la bocina
                COOLDOWN=$(( (RANDOM % 10) + 12 ))
                log "Fallo al conectar. Cooldown de ${COOLDOWN}s para romper sincronia..."
                sleep "$COOLDOWN"
                PREV_MAC=""
            fi
        fi
        continue
    fi

    # Determinar cual es el dispositivo activo (CURRENT_MAC)
    # Si el preferido está en la lista de conectados, ese es el activo.
    # Si no, tomamos el primero de la lista.
    CURRENT_MAC=""
    if [ -n "$PREF" ] && echo "$CONNECTED_MACS" | grep -qI "$PREF"; then
        CURRENT_MAC="$PREF"
    else
        CURRENT_MAC=$(echo "$CONNECTED_MACS" | head -1)
    fi

    # Desconectar cualquier otro dispositivo conectado que no sea el activo
    echo "$CONNECTED_MACS" | while read -r DEV; do
        if [ -n "$DEV" ] && [ "$DEV" != "$CURRENT_MAC" ]; then
            log "Desconectando conexion extra: $DEV"
            bluetoothctl disconnect "$DEV" 2>/dev/null
        fi
    done

    # Si el dispositivo activo cambio: actualizar preferido y activar A2DP
    if [ "$CURRENT_MAC" != "$PREV_MAC" ]; then
        log "Nueva bocina activa: $CURRENT_MAC — guardando como preferido"
        echo "$CURRENT_MAC" > "$PREFERRED"

        # Volver a confiar en el nuevo preferido
        bluetoothctl trust "$CURRENT_MAC" 2>/dev/null
        activate_a2dp "$CURRENT_MAC"
        PREV_MAC="$CURRENT_MAC"
    fi
done
