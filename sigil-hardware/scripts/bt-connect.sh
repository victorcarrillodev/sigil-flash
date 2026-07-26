#!/bin/bash
# Canonical SIGIL Bluetooth connection owner and automatic reconnect daemon.
# The lock wrapper invokes operation functions by name.
# shellcheck disable=SC2317

set -uo pipefail
umask 077

PREFERRED="${SIGIL_BT_PREFERRED_FILE:-/home/sigil/preferred_bt.txt}"
BT_STATE_FILE="${SIGIL_BT_STATE_FILE:-/var/lib/sigil/bluetooth_state.json}"
BT_HISTORY_FILE="${SIGIL_BT_HISTORY_FILE:-/var/lib/sigil/bluetooth_ever_preferred}"
BT_LOCK="${SIGIL_BT_LOCK_FILE:-/run/sigil/bluetooth-transition.lock}"
USER_DISCONNECT_MARKER="${SIGIL_BT_USER_DISCONNECT_MARKER:-/run/sigil/bluetooth-user-disconnected}"
LOCK_TIMEOUT="${SIGIL_BT_LOCK_TIMEOUT:-30}"
LOG="${SIGIL_BT_LOG_FILE:-/var/log/bt-connect.log}"
BLUETOOTHCTL="${SIGIL_BLUETOOTHCTL:-bluetoothctl}"
PREV_MAC=""
RESULT_CODE="internal_error"
RESULT_MESSAGE="Error Bluetooth"
RESULT_MAC=""
COMMAND_MODE=0
BT_LAST_RC=0
AUTO_RETRY_INITIAL="${SIGIL_BT_RETRY_INITIAL:-5}"
# A saved speaker can be temporarily off, but a five-minute retry interval makes
# a recovered speaker feel broken.  Keep trying in the background at least once
# per minute while the panel gives the customer a bounded waiting screen.
AUTO_RETRY_MAX="${SIGIL_BT_RETRY_MAX:-60}"
AUTO_HEALTH_INTERVAL="${SIGIL_BT_HEALTH_INTERVAL:-15}"
BT_PHASE="NO_PREFERRED_SPEAKER"
BT_REASON="startup"
BT_A2DP_READY=false

if [ "${1:-}" = "request" ]; then
    COMMAND_MODE=1
fi

touch "$LOG" 2>/dev/null || LOG=""

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
    if [ -n "$LOG" ]; then
        printf '%s\n' "$msg" >> "$LOG"
    fi
    if [ "$COMMAND_MODE" -eq 1 ]; then
        printf '%s\n' "$msg" >&2
    else
        printf '%s\n' "$msg"
    fi
}

normalize_mac() {
    local mac
    mac=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
    if [[ "$mac" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
        printf '%s\n' "$mac"
        return 0
    fi
    return 1
}

read_preferred() {
    python3 - "$PREFERRED" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("preferred state is not a regular file")
        value = os.read(fd, 64).decode("ascii").strip().upper()
    finally:
        os.close(fd)
except (OSError, UnicodeError):
    raise SystemExit(1)

if not re.fullmatch(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}", value):
    raise SystemExit(1)
print(value)
PY
}

atomic_preferred_value() {
    local value="$1" directory temporary
    directory=${PREFERRED%/*}
    [ "$directory" != "$PREFERRED" ] || directory="."
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ ! -L "$PREFERRED" ] || return 1

    temporary=$(mktemp "${directory}/.preferred_bt.XXXXXX") || return 1
    if ! chmod 0600 "$temporary" \
        || ! printf '%s\n' "$value" > "$temporary" \
        || ! sync -f "$temporary" 2>/dev/null \
        || ! mv -fT -- "$temporary" "$PREFERRED"; then
        rm -f -- "$temporary"
        return 1
    fi
    return 0
}

write_preferred() {
    local mac
    mac=$(normalize_mac "${1:-}") || return 1
    atomic_preferred_value "$mac" || return 1
    : > "$BT_HISTORY_FILE"
    chmod 0600 "$BT_HISTORY_FILE" 2>/dev/null || true
}

clear_preferred() {
    atomic_preferred_value ""
}

write_bt_state() {
    local phase="$1" reason="${2:-}" retry_after="${3:-0}"
    local preferred="" info="" name="" paired=false trusted=false
    local connected=false resolved=false profile="" sink="" active_device=""
    preferred=$(read_preferred 2>/dev/null || true)
    if [ -n "$preferred" ]; then
        info=$(device_info "$preferred" 2>/dev/null || true)
        name=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Name:[[:space:]]*//p' | head -n 1)
        grep -qiE '^[[:space:]]*Paired:[[:space:]]*yes$' <<< "$info" && paired=true
        grep -qiE '^[[:space:]]*Trusted:[[:space:]]*yes$' <<< "$info" && trusted=true
        grep -qiE '^[[:space:]]*Connected:[[:space:]]*yes$' <<< "$info" && connected=true
        services_resolved "$preferred" && resolved=true
    fi
    if [ "$BT_A2DP_READY" = true ] && [ -n "$preferred" ]; then
        active_device="$preferred"
        profile="a2dp_sink"
        sink="${AUDIO_ROUTE_SINK:-}"
    fi

    python3 - "$BT_STATE_FILE" "$phase" "$reason" "$retry_after" \
        "$preferred" "$name" "$paired" "$trusted" "$connected" "$resolved" \
        "$BT_A2DP_READY" "$profile" "$sink" "$active_device" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

(
    path, phase, reason, retry_after, mac, name, paired, trusted,
    connected, resolved, a2dp_ready, profile, sink, active_device,
) = sys.argv[1:]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

preferred = None
if mac:
    preferred = {
        "mac": mac,
        "name": name or "",
        "paired": paired == "true",
        "trusted": trusted == "true",
    }

doc = {
    "_schema_version": "2.0",
    "phase": phase,
    "reason": reason or None,
    "preferred_device": preferred,
    "active_output_device": active_device or None,
    "connection_status": {
        "connected": connected == "true",
        "services_resolved": resolved == "true",
        "profile": profile or "",
        "sink": sink or None,
    },
    "a2dp_ready": a2dp_ready == "true",
    "retry_after_seconds": max(0, int(retry_after or 0)),
    "updated_at": now,
}

directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".bluetooth-state.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

set_bt_phase() {
    BT_PHASE="$1"
    BT_REASON="${2:-}"
    BT_A2DP_READY="${3:-false}"
    write_bt_state "$BT_PHASE" "$BT_REASON" "${4:-0}" || \
        log "No se pudo actualizar bluetooth_state.json"
}

with_bluetooth_lock() {
    local rc
    if ! exec {BT_LOCK_FD}> "$BT_LOCK"; then
        RESULT_CODE="lock_unavailable"
        RESULT_MESSAGE="Bloqueo Bluetooth no disponible"
        return 73
    fi
    if ! flock -w "$LOCK_TIMEOUT" "$BT_LOCK_FD"; then
        exec {BT_LOCK_FD}>&-
        RESULT_CODE="busy"
        RESULT_MESSAGE="Otra operación Bluetooth está en progreso"
        return 75
    fi
    "$@"
    rc=$?
    flock -u "$BT_LOCK_FD" || true
    exec {BT_LOCK_FD}>&-
    return "$rc"
}

run_bt() {
    local seconds="$1" rc
    shift
    # BlueZ commands occasionally ignore SIGTERM while D-Bus is recovering.
    # Escalate two seconds later so a stuck client cannot hold the canonical
    # transition lock forever and prevent the next automatic reconnect.
    BT_LAST_OUTPUT=$(timeout --kill-after=2s "$seconds" "$BLUETOOTHCTL" "$@" 2>&1)
    rc=$?
    BT_LAST_RC=$rc
    if [ "$rc" -ne 0 ]; then
        log "bluetoothctl $1 falló (rc=$rc)"
        return "$rc"
    fi
    if grep -qiE '(^|[[:space:]])(failed|error)([[:space:]:]|$)' \
        <<< "$BT_LAST_OUTPUT"; then
        log "bluetoothctl $1 informó un error"
        return 1
    fi
    return 0
}

device_info() {
    timeout 5 "$BLUETOOTHCTL" info "$1" 2>/dev/null
}

is_connected() {
    local info
    info=$(device_info "$1") || return 1
    grep -qiE '^[[:space:]]*Connected:[[:space:]]*yes$' <<< "$info"
}

services_resolved() {
    local info object_path result
    info=$(device_info "$1") || return 1
    if grep -qiE '^[[:space:]]*ServicesResolved:[[:space:]]*yes$' <<< "$info"; then
        return 0
    fi
    object_path="/org/bluez/hci0/dev_${1//:/_}"
    result=$(timeout 3 busctl get-property org.bluez "$object_path" \
        org.bluez.Device1 ServicesResolved 2>/dev/null || true)
    [ "$result" = "b true" ]
}

wait_services_resolved() {
    local mac="$1" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        services_resolved "$mac" && return 0
        sleep 1
    done
    return 1
}

is_paired() {
    local info
    info=$(device_info "$1") || return 1
    grep -qiE '^[[:space:]]*Paired:[[:space:]]*yes$' <<< "$info"
}

is_trusted() {
    local info
    info=$(device_info "$1") || return 1
    grep -qiE '^[[:space:]]*Trusted:[[:space:]]*yes$' <<< "$info"
}

connected_devices() {
    timeout 5 "$BLUETOOTHCTL" devices Connected 2>/dev/null \
        | awk '$1 == "Device" && $2 ~ /^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$/ {print toupper($2)}' \
        | awk '!seen[$0]++'
}

# Returns 0 for confirmed audio, 1 for informative non-audio metadata, and 2
# when BlueZ has not supplied enough metadata to decide.
audio_device_status() {
    local mac="$1" info
    info=$(device_info "$mac") || return 2
    audio_info_status "$info"
}

audio_info_status() {
    local info="$1" class_hex class_value major_class informative=0

    if grep -qiE 'UUID:.*(Audio Sink|Advanced Audio|0000110[bBdD]-)' \
        <<< "$info"; then
        return 0
    fi
    if grep -qiE '^[[:space:]]*UUID:' <<< "$info"; then
        informative=1
    fi

    class_hex=$(printf '%s\n' "$info" \
        | awk '/^[[:space:]]*Class:[[:space:]]*0x[[:xdigit:]]+/ {sub(/^.*0x/, ""); print; exit}')
    if [[ "$class_hex" =~ ^[[:xdigit:]]+$ ]]; then
        informative=1
        class_value=$((16#$class_hex))
        major_class=$(((class_value >> 8) & 31))
        [ "$major_class" -eq 4 ] && return 0
    fi

    [ "$informative" -eq 1 ] && return 1
    return 2
}

wait_disconnected() {
    local mac="$1" attempt
    for attempt in 1 2 3 4 5 6 7 8; do
        is_connected "$mac" || return 0
        sleep 0.5
    done
    return 1
}

connect_target() {
    local mac="$1" attempt command_ok
    for attempt in 1 2; do
        command_ok=1
        run_bt 15 connect "$mac" || command_ok=0
        if [ "$attempt" -eq 1 ]; then sleep 4; else sleep 5; fi
        if is_connected "$mac"; then
            if ! wait_services_resolved "$mac"; then
                log "Servicios Bluetooth aún no resueltos para $mac"
                continue
            fi
            [ "$command_ok" -eq 1 ] || log "Conexión confirmada pese al retorno de bluetoothctl"
            return 0
        fi
        log "Intento $attempt de conexión falló para $mac"
    done
    return 1
}

activate_a2dp() {
    local mac="$1"
    sleep 2
    if audio_route_activate_bluetooth "$mac"; then
        log "Ruta A2DP activada para $mac"
        return 0
    fi
    log "A2DP no usable para $mac"
    return 1
}

disconnect_previous_preferred() {
    local keep_mac="$1" previous="${2:-}"
    [ -n "$previous" ] || return 0
    [ "$previous" != "$keep_mac" ] || return 0
    is_connected "$previous" || return 0
    log "Desconectando la bocina preferida anterior: $previous"
    run_bt 8 disconnect "$previous" || return 1
    wait_disconnected "$previous" || return 1
    return 0
}

rollback_new_target() {
    local mac="$1" previous_preferred="${2:-}"
    if [ "$previous_preferred" != "$mac" ] && is_connected "$mac"; then
        run_bt 8 disconnect "$mac" || true
    fi
}

prepare_target() {
    local mac="$1" audio_status info
    info=$(device_info "$mac") || {
        RESULT_CODE="not_paired"
        RESULT_MESSAGE="La bocina no está emparejada"
        return 1
    }
    if ! grep -qiE '^[[:space:]]*Paired:[[:space:]]*yes$' <<< "$info"; then
        RESULT_CODE="not_paired"
        RESULT_MESSAGE="La bocina no está emparejada"
        return 1
    fi

    audio_info_status "$info"
    audio_status=$?
    if [ "$audio_status" -eq 1 ]; then
        RESULT_CODE="not_audio"
        RESULT_MESSAGE="El dispositivo no anuncia capacidad de audio"
        return 1
    fi

    run_bt 5 unblock "$mac" || {
        RESULT_CODE="unblock_failed"
        RESULT_MESSAGE="No se pudo desbloquear la bocina"
        return 1
    }
    run_bt 5 trust "$mac" || {
        RESULT_CODE="trust_failed"
        RESULT_MESSAGE="No se pudo confiar en la bocina"
        return 1
    }
    if ! is_trusted "$mac"; then
        RESULT_CODE="trust_failed"
        RESULT_MESSAGE="BlueZ no confirmó la confianza de la bocina"
        return 1
    fi
    return 0
}

complete_target_connection() {
    local mac="$1" previous_preferred="${2:-}"
    if ! connect_target "$mac"; then
        RESULT_CODE="connect_failed"
        RESULT_MESSAGE="No se pudo conectar. Verifica que la bocina esté encendida y cerca."
        return 1
    fi

    if ! activate_a2dp "$mac"; then
        RESULT_CODE="a2dp_failed"
        RESULT_MESSAGE="La bocina quedó guardada; la ruta A2DP aún no está disponible y se reintentará"
        return 1
    fi
    if ! disconnect_previous_preferred "$mac" "$previous_preferred"; then
        rollback_new_target "$mac" "$previous_preferred"
        RESULT_CODE="exclusive_failed"
        RESULT_MESSAGE="No se pudo desconectar la bocina preferida anterior"
        return 1
    fi
    RESULT_MAC="$mac"
    return 0
}

request_pair_locked() {
    local mac="$1" audio_status previous_preferred=""
    run_bt 5 scan off || log "No se pudo detener el escaneo; se continúa bajo flock"
    run_bt 5 power on || {
        RESULT_CODE="power_failed"
        RESULT_MESSAGE="No se pudo encender Bluetooth"
        return 1
    }
    # The local adapter is discoverable/pairable only for the pairing request;
    # it is always closed again before continuing with trust/connect/A2DP.
    if ! run_bt 5 pairable on || ! run_bt 5 discoverable on; then
        run_bt 5 discoverable off || true
        run_bt 5 pairable off || true
        RESULT_CODE="pairing_visibility_failed"
        RESULT_MESSAGE="No se pudo preparar Bluetooth para el emparejamiento"
        return 1
    fi
    if ! run_bt 20 pair "$mac" && ! is_paired "$mac"; then
        run_bt 5 discoverable off || true
        run_bt 5 pairable off || true
        RESULT_CODE="pair_failed"
        if [ "$BT_LAST_RC" -eq 124 ]; then
            RESULT_MESSAGE="La bocina no respondió antes del límite; confirma que siga en modo de emparejamiento"
        else
            RESULT_MESSAGE="BlueZ rechazó el emparejamiento; verifica visibilidad, distancia o PIN"
        fi
        return 1
    fi
    run_bt 5 discoverable off || log "No se pudo desactivar descubrimiento tras emparejar"
    run_bt 5 pairable off || log "No se pudo desactivar emparejamiento tras emparejar"
    if ! is_paired "$mac"; then
        RESULT_CODE="pair_failed"
        RESULT_MESSAGE="BlueZ no confirmó el emparejamiento"
        return 1
    fi

    audio_device_status "$mac"
    audio_status=$?
    if [ "$audio_status" -eq 1 ]; then
        RESULT_CODE="not_audio"
        RESULT_MESSAGE="El dispositivo no anuncia capacidad de audio; usa Eliminar si deseas borrarlo"
        return 1
    fi
    prepare_target "$mac" || return 1
    previous_preferred=$(read_preferred 2>/dev/null || true)
    if ! write_preferred "$mac"; then
        RESULT_CODE="state_write_failed"
        RESULT_MESSAGE="No se pudo guardar la bocina preferida"
        return 1
    fi
    rm -f -- "$USER_DISCONNECT_MARKER"
    complete_target_connection "$mac" "$previous_preferred" || return 1
    set_bt_phase "READY" "paired_and_a2dp_ready" true
    RESULT_CODE="paired"
    RESULT_MESSAGE="Bocina emparejada y conectada exitosamente"
    return 0
}

request_connect_locked() {
    local mac="$1" previous_preferred=""
    run_bt 5 scan off || log "No se pudo detener el escaneo; se continúa bajo flock"
    prepare_target "$mac" || return 1
    previous_preferred=$(read_preferred 2>/dev/null || true)
    if ! write_preferred "$mac"; then
        RESULT_CODE="state_write_failed"
        RESULT_MESSAGE="No se pudo guardar la bocina preferida"
        return 1
    fi
    rm -f -- "$USER_DISCONNECT_MARKER"
    complete_target_connection "$mac" "$previous_preferred" || return 1
    set_bt_phase "READY" "connected_and_a2dp_ready" true
    RESULT_CODE="connected"
    RESULT_MESSAGE="Conectado exitosamente"
    return 0
}

request_disconnect_locked() {
    local mac=""
    mac=$(read_preferred 2>/dev/null || true)
    if [ -n "$mac" ] && is_connected "$mac"; then
        if ! run_bt 8 disconnect "$mac" || ! wait_disconnected "$mac"; then
            RESULT_CODE="disconnect_failed"
            RESULT_MESSAGE="No se pudo desconectar la bocina"
            return 1
        fi
    fi
    if [ -n "$mac" ]; then
        printf '%s\n' "$mac" > "${USER_DISCONNECT_MARKER}.tmp" \
            && mv -f "${USER_DISCONNECT_MARKER}.tmp" "$USER_DISCONNECT_MARKER"
    fi
    set_bt_phase "DISCONNECTED_BY_USER" "explicit_disconnect" false
    RESULT_CODE="disconnected"
    RESULT_MESSAGE="Bocina desconectada; permanece como preferida para la reconexión automática"
    return 0
}

request_remove_locked() {
    local mac="$1" preferred=""
    preferred=$(read_preferred 2>/dev/null || true)
    if is_connected "$mac"; then
        if ! run_bt 8 disconnect "$mac" || ! wait_disconnected "$mac"; then
            RESULT_CODE="disconnect_failed"
            RESULT_MESSAGE="No se pudo desconectar la bocina antes de eliminarla"
            return 1
        fi
    fi
    run_bt 5 untrust "$mac" || log "La bocina ya estaba sin confianza antes de eliminarla"
    if ! run_bt 8 remove "$mac"; then
        RESULT_CODE="remove_failed"
        RESULT_MESSAGE="BlueZ no pudo eliminar la bocina"
        return 1
    fi
    if is_paired "$mac"; then
        RESULT_CODE="remove_failed"
        RESULT_MESSAGE="BlueZ no confirmó la eliminación de la bocina"
        return 1
    fi
    if [ "$preferred" = "$mac" ] && ! clear_preferred; then
        RESULT_CODE="state_write_failed"
        RESULT_MESSAGE="La bocina se eliminó, pero no se pudo limpiar el estado preferido"
        return 1
    fi
    rm -f -- "$USER_DISCONNECT_MARKER"
    set_bt_phase "NO_PREFERRED_SPEAKER" "explicit_forget" false
    RESULT_CODE="removed"
    RESULT_MESSAGE="Bocina eliminada"
    RESULT_MAC="$mac"
    return 0
}

emit_result() {
    local success="$1"
    python3 - "$success" "$RESULT_CODE" "$RESULT_MESSAGE" "$RESULT_MAC" \
        "$BT_PHASE" "$BT_A2DP_READY" <<'PY'
import json
import sys

print(json.dumps({
    "success": sys.argv[1] == "true",
    "code": sys.argv[2],
    "message": sys.argv[3],
    "mac": sys.argv[4] or None,
    "phase": sys.argv[5],
    "a2dp_ready": sys.argv[6] == "true",
    "retryable": sys.argv[2] in {
        "busy", "connect_failed", "a2dp_failed", "power_failed",
        "disconnect_failed", "exclusive_failed",
    },
}, ensure_ascii=False))
PY
}

handle_request() {
    local operation="${1:-}" raw_mac="${2:-}" mac="" rc=0
    case "$operation" in
        pair|connect|remove)
            mac=$(normalize_mac "$raw_mac") || {
                RESULT_CODE="invalid_mac"
                RESULT_MESSAGE="MAC inválida"
                emit_result false
                return 2
            }
            ;;
        disconnect)
            [ -z "$raw_mac" ] || {
                RESULT_CODE="invalid_request"
                RESULT_MESSAGE="La desconexión no acepta una MAC"
                emit_result false
                return 2
            }
            ;;
        *)
            RESULT_CODE="invalid_request"
            RESULT_MESSAGE="Operación Bluetooth inválida"
            emit_result false
            return 2
            ;;
    esac

    case "$operation" in
        pair)       with_bluetooth_lock request_pair_locked "$mac" || rc=$? ;;
        connect)    with_bluetooth_lock request_connect_locked "$mac" || rc=$? ;;
        disconnect) with_bluetooth_lock request_disconnect_locked || rc=$? ;;
        remove)     with_bluetooth_lock request_remove_locked "$mac" || rc=$? ;;
    esac
    if [ "$rc" -eq 0 ]; then
        emit_result true
    else
        emit_result false
    fi
    return "$rc"
}

prepare_adapter_locked() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        sudo rfkill unblock bluetooth 2>/dev/null || true
        sudo hciconfig hci0 up 2>/dev/null || true
        run_bt 5 power on || true
        sleep 3
        if hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; then
            log "Adaptador Bluetooth listo (intento $attempt)"
            return 0
        fi
    done
    log "ERROR: no se pudo levantar hci0"
    return 1
}

auto_cycle_locked() {
    local connected preferred=""
    connected=$(connected_devices)
    preferred=$(read_preferred 2>/dev/null || true)

    if [ -z "$preferred" ]; then
        if [ -e "$BT_HISTORY_FILE" ]; then
            set_bt_phase "NO_PREFERRED_SPEAKER" "no_preferred_speaker" false
        else
            set_bt_phase "NO_PREFERRED_SPEAKER" "first_install" false
        fi
        return 0
    fi
    if [ -r "$USER_DISCONNECT_MARKER" ] \
        && grep -qxF "$preferred" "$USER_DISCONNECT_MARKER" 2>/dev/null; then
        set_bt_phase "DISCONNECTED_BY_USER" "explicit_disconnect" false
        return 0
    fi
    if ! is_paired "$preferred" || ! is_trusted "$preferred"; then
        set_bt_phase "STATE_CORRUPT" "preferred_device_not_paired_or_trusted" false \
            "$AUTO_RETRY_MAX"
        return 1
    fi
    if printf '%s\n' "$connected" | grep -qxF "$preferred"; then
        set_bt_phase "WAITING_FOR_SERVICES" "bluetooth_connected" false
        if ! wait_services_resolved "$preferred"; then
            set_bt_phase "WAITING_FOR_SERVICES" "services_not_resolved" false \
                "$AUTO_RETRY_INITIAL"
            return 1
        fi
        set_bt_phase "WAITING_FOR_A2DP" "services_resolved" false
        if activate_a2dp "$preferred"; then
            PREV_MAC="$preferred"
            set_bt_phase "READY" "a2dp_route_confirmed" true
            return 0
        fi
        set_bt_phase "WAITING_FOR_A2DP" "audio_runtime_or_sink_not_ready" false \
            "$AUTO_RETRY_INITIAL"
        return 1
    fi

    log "Bocina preferida ausente; intentando reconexión: $preferred"
    set_bt_phase "WAITING_FOR_BLUETOOTH" "preferred_device_disconnected" false
    if ! prepare_target "$preferred"; then
        set_bt_phase "RETRY_BACKOFF" "prepare_target_failed" false "$AUTO_RETRY_INITIAL"
        return 1
    fi
    if connect_target "$preferred" && activate_a2dp "$preferred"; then
        PREV_MAC="$preferred"
        set_bt_phase "READY" "reconnected_and_a2dp_ready" true
        return 0
    fi
    log "Reconexión automática fallida para $preferred"
    PREV_MAC=""
    set_bt_phase "RETRY_BACKOFF" "connect_or_a2dp_failed" false "$AUTO_RETRY_INITIAL"
    return 1
}

run_daemon() {
    local retry_delay="$AUTO_RETRY_INITIAL"
    log "bt-connect iniciado"
    with_bluetooth_lock prepare_adapter_locked || return 1
    # A preferred speaker is connected immediately after BlueZ is ready.
    # The panel and audio workers start in parallel; endpoint discovery below
    # only gates A2DP activation, never panel availability.
    with_bluetooth_lock auto_cycle_locked || true
    if [ "${SIGIL_BT_RUN_ONCE:-0}" = "1" ]; then
        return 0
    fi
    while true; do
        sleep "$AUTO_HEALTH_INTERVAL"
        if with_bluetooth_lock auto_cycle_locked; then
            retry_delay="$AUTO_RETRY_INITIAL"
        else
            log "Recuperación Bluetooth en ${retry_delay}s"
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
            [ "$retry_delay" -le "$AUTO_RETRY_MAX" ] || retry_delay="$AUTO_RETRY_MAX"
        fi
    done
}

case "${1:-}" in
    request)
        shift
        handle_request "$@"
        exit $?
        ;;
    "")
        run_daemon
        exit $?
        ;;
    *)
        printf 'usage: %s [request pair|connect|disconnect|remove [MAC]]\n' "$0" >&2
        exit 2
        ;;
esac
