#!/bin/bash
# radio-stream.sh — Playlist Iterativa + Vigía MD5 + Memoria de Pista (Versión Mejorada)
LOG=/var/log/radio-stream.log
# Crear archivo de log si no existe (puede fallar si no hay permisos — fallback a journal)
touch "$LOG" 2>/dev/null || LOG=""
URL_BASE="https://devproserver.tail942ea3.ts.net"

# Load non-secret settings from shared config; token stays in its protected file.
if [ -f /etc/sigil/audio.conf ]; then
    # shellcheck source=conf/audio.conf
    source /etc/sigil/audio.conf
fi
API_KEY=""
API_KEY_FILE="${SIGIL_API_KEY_FILE:-/etc/sigil/secrets/device-api-key}"
if [ -r "$API_KEY_FILE" ]; then
    IFS= read -r API_KEY < "$API_KEY_FILE" || true
fi

# Build curl auth config to keep secrets off the command line
CURL_AUTH_CONFIG=""
init_curl_auth() {
    CURL_AUTH_CONFIG=""
    [ -n "$API_KEY" ] || return 0
    CURL_AUTH_CONFIG=$(mktemp /tmp/sigil-curl-auth.XXXXXX)
    chmod 600 "$CURL_AUTH_CONFIG"
    printf 'header = "x-api-key: %s"\n' "$API_KEY" > "$CURL_AUTH_CONFIG"
}
cleanup_curl_auth() {
    if [ -n "$CURL_AUTH_CONFIG" ] && [ -f "$CURL_AUTH_CONFIG" ]; then
        rm -f "$CURL_AUTH_CONFIG"
    fi
}
init_curl_auth

# --- IDENTIFICADOR PERMANENTE DEL DISPOSITIVO ---
IDENTITY_HELPER="${SIGIL_IDENTITY_HELPER:-/home/sigil/device_identity.py}"
DEVICE_ID=$(python3 "$IDENTITY_HELPER" --field device_id) || exit 1

# --- ARCHIVOS DE MEMORIA PERSISTENTE ---
TRACK_MEMORY_FILE="/home/sigil/last_track.txt"
HASH_MEMORY_FILE="/home/sigil/last_hash.txt"
NOW_PLAYING_FILE="/home/sigil/now_playing.txt"

STREAM_PID=""
CURRENT_SINK=""
NO_OUTPUT_LOGGED=false

SIGIL_UID=$(id -u sigil 2>/dev/null || echo "1000")
export XDG_RUNTIME_DIR=/run/user/${SIGIL_UID}
export PULSE_SERVER=unix:/run/user/${SIGIL_UID}/pulse/native
export PULSE_RUNTIME_PATH=/run/user/${SIGIL_UID}/pulse

AUDIO_ROUTE_HELPER="${SIGIL_AUDIO_ROUTE_HELPER:-/usr/local/bin/sigil-audio-route.sh}"
if [ -r "$AUDIO_ROUTE_HELPER" ]; then
    # shellcheck source=scripts/sigil-audio-route.sh
    source "$AUDIO_ROUTE_HELPER"
else
    select_audio_route() { return 1; }
    AUDIO_ROUTE_REASON="audio_route_helper_missing"
fi

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ -n "$LOG" ]; then echo "$msg" >> "$LOG"; else echo "$msg"; fi
}

# --- FUNCIÓN ANTI-ZOMBIES ---
stop_stream() {
    if [ -n "$STREAM_PID" ]; then
        kill -TERM "$STREAM_PID" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$STREAM_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$STREAM_PID" 2>/dev/null; then
            kill -KILL "$STREAM_PID" 2>/dev/null || true
        fi
        wait "$STREAM_PID" 2>/dev/null || true
    fi

    # Limpiar archivo de pista actual cuando se detiene
    echo "" > "$NOW_PLAYING_FILE" 2>/dev/null || true

    STREAM_PID=""
    CURRENT_SINK=""
}

cleanup() {
    stop_stream
    cleanup_curl_auth
    exit 0
}
trap cleanup EXIT TERM INT

log "Radio stream iniciado — URL_BASE=$URL_BASE"

while true; do
    if ! select_audio_route; then
        if [ -n "$CURRENT_SINK" ]; then
            stop_stream
        fi
        if ! $NO_OUTPUT_LOGGED; then
            log "no_audio_output — Bluetooth A2DP and PCM5102A are unavailable"
            NO_OUTPUT_LOGGED=true
        fi
        sleep 10
        continue
    fi
    SINK="$AUDIO_ROUTE_SINK"
    if $NO_OUTPUT_LOGGED; then
        log "Audio output available again: ${AUDIO_ROUTE_TYPE}/${SINK}"
    fi
    NO_OUTPUT_LOGGED=false
    if [ "$SINK" != "$CURRENT_SINK" ]; then
        log "Bocina disponible: $SINK — iniciando reproducción de Playlist"
        stop_stream
        sleep 2
        CURRENT_SINK="$SINK"

        # --- MOTOR DE PLAYLIST EN SEGUNDO PLANO ---
        (
            PLAYLIST_FILE="/tmp/rpi_playlist_$$.txt"
            LEGACY_MPG123_PID=""

            # Called indirectly from signal/EXIT traps in this subshell.
            # shellcheck disable=SC2317
            stop_owned_player() {
                if [ -n "$LEGACY_MPG123_PID" ] && kill -0 "$LEGACY_MPG123_PID" 2>/dev/null; then
                    kill -TERM "$LEGACY_MPG123_PID" 2>/dev/null || true
                    for _ in $(seq 1 20); do
                        kill -0 "$LEGACY_MPG123_PID" 2>/dev/null || break
                        sleep 0.1
                    done
                    if kill -0 "$LEGACY_MPG123_PID" 2>/dev/null; then
                        kill -KILL "$LEGACY_MPG123_PID" 2>/dev/null || true
                    fi
                    wait "$LEGACY_MPG123_PID" 2>/dev/null || true
                fi
                LEGACY_MPG123_PID=""
            }
            trap 'stop_owned_player; exit 0' TERM INT
            trap stop_owned_player EXIT

            while true; do
                if [ -n "$CURL_AUTH_CONFIG" ]; then
                    PLAYLIST=$(curl -s --max-time 10 --config "$CURL_AUTH_CONFIG" "$URL_BASE/api/devices/$DEVICE_ID/playlist")
                else
                    PLAYLIST=$(curl -s --max-time 10 "$URL_BASE/api/devices/$DEVICE_ID/playlist")
                fi

                echo "$PLAYLIST" | tr -d '\r' | grep -o '"url":"[^"]*"' | cut -d'"' -f4 > "$PLAYLIST_FILE"
                TRACK_COUNT=$(grep -c "." "$PLAYLIST_FILE" 2>/dev/null || echo 0)

                if [ "$TRACK_COUNT" -eq 0 ]; then
                    sleep 15
                    continue
                fi

                TRACKS_HASH=$(md5sum "$PLAYLIST_FILE" | awk '{print $1}')
                echo "$TRACKS_HASH" > /tmp/rpi_playlist_hash.txt

                # --- LÓGICA DE MEMORIA ---
                SAVED_HASH=$(cat "$HASH_MEMORY_FILE" 2>/dev/null)
                if [ "$SAVED_HASH" != "$TRACKS_HASH" ]; then
                    # Si la lista cambió o es la primera vez, empezamos en la 1
                    LINE_NUM=1
                    echo "$TRACKS_HASH" > "$HASH_MEMORY_FILE"
                    echo "$LINE_NUM" > "$TRACK_MEMORY_FILE"
                    log "Nueva lista detectada. Empezando desde la pista 1."
                else
                    # Si es la misma lista, leemos dónde nos quedamos
                    LINE_NUM=$(cat "$TRACK_MEMORY_FILE" 2>/dev/null)
                    if ! [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || [ "$LINE_NUM" -gt "$TRACK_COUNT" ]; then
                        LINE_NUM=1
                    fi
                    log "Misma lista detectada. Retomando desde la pista $LINE_NUM de $TRACK_COUNT."
                fi
                # -------------------------

                while [ "$LINE_NUM" -le "$TRACK_COUNT" ]; do
                    TRACK_URL=$(sed -n "${LINE_NUM}p" "$PLAYLIST_FILE")
                    if [ -z "$TRACK_URL" ]; then
                        LINE_NUM=$((LINE_NUM + 1))
                        echo "$LINE_NUM" > "$TRACK_MEMORY_FILE"
                        continue
                    fi

                    CURRENT_HASH=$(cat /tmp/rpi_playlist_hash.txt 2>/dev/null)
                    if [ "$CURRENT_HASH" != "$TRACKS_HASH" ]; then
                        log "Cambio de lista detectado, abortando ciclo actual..."
                        break
                    fi

                    SAFE_URL="${TRACK_URL// /%20}"

                    # Guardar pista actual para la API del panel
                    echo "${TRACK_URL}" > "$NOW_PLAYING_FILE" 2>/dev/null || true
                    log "Reproduciendo pista $LINE_NUM/$TRACK_COUNT: $TRACK_URL"

                    # Reproducción blindada
                    if [ -n "$CURL_AUTH_CONFIG" ]; then
                        curl -s -m 600 --config "$CURL_AUTH_CONFIG" "${URL_BASE}${SAFE_URL}" \
                            | mpg123 -o pulse -a "$SINK" -b 2048 -q - 2>/dev/null &
                    else
                        curl -s -m 600 "${URL_BASE}${SAFE_URL}" \
                            | mpg123 -o pulse -a "$SINK" -b 2048 -q - 2>/dev/null &
                    fi
                    LEGACY_MPG123_PID=$!
                    wait "$LEGACY_MPG123_PID" 2>/dev/null || true
                    LEGACY_MPG123_PID=""

                    # Verificamos si nos cortaron a la mitad
                    CURRENT_HASH=$(cat /tmp/rpi_playlist_hash.txt 2>/dev/null)
                    if [ "$CURRENT_HASH" != "$TRACKS_HASH" ]; then
                        break
                    fi

                    # Avanzamos y guardamos memoria
                    LINE_NUM=$((LINE_NUM + 1))
                    if [ "$LINE_NUM" -gt "$TRACK_COUNT" ]; then
                        LINE_NUM=1
                    fi
                    echo "$LINE_NUM" > "$TRACK_MEMORY_FILE"

                    sleep 1
                done

            done
            rm -f "$PLAYLIST_FILE"
        ) &
        STREAM_PID=$!
        log "Motor sonando (PID: $STREAM_PID)"
    fi

    # Control 1 - Motor muerto
    if [ -n "$STREAM_PID" ] && ! kill -0 "$STREAM_PID" 2>/dev/null; then
        log "Motor de playlist caído — limpiando..."
        wait "$STREAM_PID" 2>/dev/null
        STREAM_PID=""
        CURRENT_SINK=""
        sleep 5
        continue
    fi

    # Control 2 - EL VIGÍA INTELIGENTE
    if [ -n "$STREAM_PID" ]; then
        CURRENT_HASH=$(cat /tmp/rpi_playlist_hash.txt 2>/dev/null)
        if [ -n "$CURRENT_HASH" ]; then
            if [ -n "$CURL_AUTH_CONFIG" ]; then
                NEW_JSON=$(timeout 3 curl -s --config "$CURL_AUTH_CONFIG" "$URL_BASE/api/devices/$DEVICE_ID/playlist")
            else
                NEW_JSON=$(timeout 3 curl -s "$URL_BASE/api/devices/$DEVICE_ID/playlist")
            fi

            if [ -n "$NEW_JSON" ]; then
                echo "$NEW_JSON" | tr -d '\r' | grep -o '"url":"[^"]*"' | cut -d'"' -f4 > /tmp/rpi_playlist_check.txt
                CHECK_COUNT=$(grep -c "." /tmp/rpi_playlist_check.txt 2>/dev/null || echo 0)

                if [ "$CHECK_COUNT" -gt 0 ]; then
                    NEW_HASH=$(md5sum /tmp/rpi_playlist_check.txt | awk '{print $1}')

                    if [ "$NEW_HASH" != "$CURRENT_HASH" ]; then
                        log "NUEVA LISTA DETECTADA DESDE EL PANEL! Interrumpiendo pista actual..."
                        echo "$NEW_HASH" > /tmp/rpi_playlist_hash.txt
                        stop_stream
                    fi
                fi
            fi
        fi
    fi

    sleep 5
done
