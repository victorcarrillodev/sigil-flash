#!/usr/bin/env bash
# =============================================================================
# sigil-event-listener.sh — canal de eventos servidor → dispositivo (SSE)
# =============================================================================
# Mantiene abierta una conexión con GET /api/devices/<id>/events y, cuando el
# servidor anuncia un cambio de playlist, despierta a radio-fetcher para que
# sincronice en el acto en vez de esperar al siguiente ciclo.
#
# Es un complemento del sondeo, no un reemplazo. Si este servicio se cae, la
# conexión se corta o el evento se pierde, radio-fetcher converge igual en su
# ciclo periódico. Por eso aquí no hay estado propio ni lógica de sincronización:
# lo único que hace es escribir una línea en un FIFO.
#
# Copiar a: /usr/local/bin/sigil-event-listener.sh
# =============================================================================
set -euo pipefail

LOG_DIR="/var/log/sigil"
LOG="${LOG_DIR}/event-listener.log"
RUN_SIGIL_DIR="${SIGIL_RUN_DIR:-/run/sigil}"
WAKE_FIFO="${SIGIL_WAKE_FIFO:-${RUN_SIGIL_DIR}/playlist-wake}"
AUDIO_CONF="${AUDIO_CONF:-/etc/sigil/audio.conf}"
API_KEY_FILE="${SIGIL_API_KEY_FILE:-/etc/sigil/secrets/device-api-key}"
IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/home/sigil/device_identity.py}"
DEVICE_CONF="${SIGIL_DEVICE_CONF:-/etc/sigil/device.conf}"

SERVER_URL=""
LOG_LEVEL="INFO"
CONNECT_TIMEOUT_SECONDS=10
# Debe superar al latido del servidor (DEVICE_EVENTS_HEARTBEAT_SECONDS, 25 s por
# defecto). Si no llega nada en este plazo la conexión está muerta aunque el
# socket siga abierto, y conviene reconectar.
EVENT_READ_TIMEOUT_SECONDS=90

CURL_CONFIG=""

log() {
    local level="${1:-INFO}" msg="$2"
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "DEBUG" ]; then
        return
    fi
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" >> "$LOG"
    echo "$line"
}

cleanup() {
    # Bajo `set -e`, el código de salida de un trap EXIT reemplaza al del
    # proceso. Sin el `|| true` final, un CURL_CONFIG vacío (nunca se llamó a
    # load_config, p. ej. si SERVER_URL falta) hace que `[ -n "" ]` devuelva 1 y
    # el listener termina "en error" aunque el cuerpo del script haya sido
    # perfectamente exitoso — exactamente el fallo que systemd necesita
    # distinguir para decidir si reinicia el servicio.
    { [ -n "$CURL_CONFIG" ] && [ -f "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"; } || true
}
trap cleanup EXIT

load_config() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -f "$AUDIO_CONF" ]; then
        # shellcheck disable=SC1090
        . "$AUDIO_CONF"
    fi
    if [ -z "$SERVER_URL" ]; then
        log "ERROR" "SERVER_URL no configurado en ${AUDIO_CONF}"
        return 1
    fi
    if [ ! -r "$API_KEY_FILE" ]; then
        log "ERROR" "Credencial del dispositivo ausente en ${API_KEY_FILE}"
        return 1
    fi
    # La credencial va por archivo de configuración con permisos 600, nunca por
    # la línea de comandos: argv es legible por cualquier proceso del sistema.
    CURL_CONFIG=$(mktemp /tmp/sigil-events-curl.XXXXXX)
    chmod 600 "$CURL_CONFIG"
    printf 'header = "x-api-key: %s"\n' "$(cat "$API_KEY_FILE")" > "$CURL_CONFIG"
}

ensure_fifo() {
    mkdir -p "$RUN_SIGIL_DIR" 2>/dev/null || true
    if [ ! -p "$WAKE_FIFO" ]; then
        rm -f "$WAKE_FIFO"
        mkfifo -m 0660 "$WAKE_FIFO"
    fi
}

# Se abre en lectura-escritura para que nunca bloquee: un FIFO abierto sólo para
# escritura se queda esperando a que aparezca un lector, y radio-fetcher puede
# estar reiniciándose justo en ese momento.
wake_fetcher() {
    local reason="$1"
    if [ ! -p "$WAKE_FIFO" ]; then
        log "WARN" "FIFO de despertar ausente; el evento se descarta"
        return 0
    fi
    # `>` (sólo escritura) bloquea hasta que exista un lector. radio-fetcher.sh
    # sólo tiene el FIFO abierto mientras está dormido entre ciclos; si el
    # evento llega mientras está ocupado sincronizando, una apertura de sólo
    # escritura dejaría a ESTE listener colgado hasta que termine ese ciclo, sin
    # poder procesar ningún evento nuevo mientras tanto. `<>` (lectura-escritura)
    # nunca bloquea en un FIFO, así que la escritura siempre vuelve al instante.
    if { exec 204<>"$WAKE_FIFO"; } 2>/dev/null; then
        printf '%s\n' "$reason" >&204 2>/dev/null || log "WARN" "No se pudo escribir en el FIFO de despertar"
        exec 204>&-
    else
        log "WARN" "No se pudo abrir el FIFO de despertar"
    fi
}

# Separada de consume_stream para poder testearla sin abrir una conexión de
# red: sólo interesan las líneas `event:`; el resto del protocolo SSE (data,
# id, comentarios) se ignora deliberadamente, porque el evento no transporta la
# playlist — sólo dice «revisá».
handle_sse_line() {
    local line="$1"
    case "$line" in
        'event: playlist_changed')
            log "INFO" "El servidor anuncia un cambio de playlist"
            wake_fetcher "playlist_changed"
            ;;
        'event: heartbeat')
            log "DEBUG" "Latido recibido"
            ;;
    esac
}

consume_stream() {
    local device_id="$1"
    local url="${SERVER_URL%/}/api/devices/${device_id}/events"
    log "DEBUG" "Conectando al canal de eventos"

    curl --silent --show-error --no-buffer \
        --proto '=https' --proto-redir '=https' --max-redirs 0 \
        --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" \
        --config "$CURL_CONFIG" \
        --header 'Accept: text/event-stream' \
        "$url" 2>>"$LOG" \
    | while IFS= read -r -t "${EVENT_READ_TIMEOUT_SECONDS}" line || [ -n "$line" ]; do
        handle_sse_line "$line"
    done
}

main() {
    load_config || exit 1
    ensure_fifo

    local device_id
    if ! device_id=$(python3 "$IDENTITY_HELPER" --device-conf "$DEVICE_CONF" \
        --audio-conf "$AUDIO_CONF" --field device_id); then
        log "ERROR" "No se pudo resolver la identidad del dispositivo"
        exit 1
    fi
    log "INFO" "Canal de eventos iniciado"

    # Reconexión con retroceso exponencial acotado. Un servidor caído no debe
    # convertirse en un bucle de reconexión que consuma la red del local.
    local backoff=5
    while true; do
        consume_stream "$device_id" || true
        log "WARN" "Canal de eventos cerrado; reintentando en ${backoff}s"
        sleep "$backoff"
        if [ "$backoff" -lt 300 ]; then
            backoff=$((backoff * 2))
            [ "$backoff" -le 300 ] || backoff=300
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
