#!/bin/bash
# wifi-manager.sh — Gestion inteligente de redes WiFi
# - Prioriza la red mas usada
# - Elimina redes sin uso en 35 dias
# - Funciona sin importar el nombre de la red

LOG="/var/log/wifi-manager.log"
LAST_CONNECTED_FILE="/var/lib/wifi-manager/last_connected"
DAYS_BEFORE_DELETE=35

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

mkdir -p /var/lib/wifi-manager

# ---- DETECTAR RED ACTIVA ----
ACTIVE=$(nmcli -t -f NAME,DEVICE connection show --active | grep wlan0 | cut -d: -f1)

if [ -n "$ACTIVE" ]; then
    # Guardar timestamp de ultima conexion
    echo "$ACTIVE=$(date +%s)" >> "$LAST_CONNECTED_FILE"
    log "Red activa: $ACTIVE"

    # Dar maxima prioridad a la red activa
    nmcli connection modify "$ACTIVE" connection.autoconnect-priority 100 2>/dev/null || true
    log "Prioridad 100 → $ACTIVE"
fi

# ---- AJUSTAR PRIORIDADES DE TODAS LAS REDES ----
# Ordenar por ultima vez conectada (mas reciente = mayor prioridad)
PRIORITY=90
while IFS= read -r CONN; do
    [ "$CONN" = "$ACTIVE" ] && continue  # La activa ya tiene 100

    # Ver si tiene fecha guardada
    LAST=$(grep "^${CONN}=" "$LAST_CONNECTED_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    NOW=$(date +%s)

    if [ -n "$LAST" ]; then
        DAYS_SINCE=$(( (NOW - LAST) / 86400 ))

        # Si no se ha conectado en 35 dias → eliminar
        if [ "$DAYS_SINCE" -ge "$DAYS_BEFORE_DELETE" ]; then
            nmcli connection delete "$CONN" 2>/dev/null || true
            log "ELIMINADA (sin uso $DAYS_SINCE dias): $CONN"
            continue
        fi

        nmcli connection modify "$CONN" connection.autoconnect-priority "$PRIORITY" 2>/dev/null || true
        log "Prioridad $PRIORITY → $CONN (ultimo uso: hace ${DAYS_SINCE}d)"
        PRIORITY=$((PRIORITY - 10))
    else
        # Red nueva sin historial → prioridad baja
        nmcli connection modify "$CONN" connection.autoconnect-priority 10 2>/dev/null || true
        log "Prioridad 10 (nueva) → $CONN"
    fi

done < <(nmcli -t -f NAME,TYPE connection show | grep wifi | grep -v "Sigil" | cut -d: -f1)

nmcli connection reload 2>/dev/null || true
log "Prioridades actualizadas"
