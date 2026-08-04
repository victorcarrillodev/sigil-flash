#!/usr/bin/env bash
# =============================================================================
# test_flash_microsd.sh - Prueba de flasheo completa para microSD 16GB
# =============================================================================
# Uso: bash test_flash_microsd.sh (usa pkexec para elevar privilegios)
# Requiere: sesión gráfica activa (polkit agent)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[✓ OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[✗ ERROR]${NC} $1"; }
section() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BLUE}  $*${NC}\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

PROJECT_DIR="/home/vic/Escritorio/Proyectos/sigil-flash"
BINARY="${PROJECT_DIR}/src-tauri/target/release/sigil-flash"
IMAGE_PATH="/home/vic/Descargas/2026-06-18-raspios-trixie-arm64-lite.img.xz"
DEVICE="/dev/sdb"
PAYLOAD_DIR="${PROJECT_DIR}/artifacts/payloads/sigil-hardware-payload"
OFFLINE_PACKAGES="${PROJECT_DIR}/artifacts/offline-packages/trixie-arm64"
EXPECTED_SHA256="acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
RPI_MODEL="${RPI_MODEL:-"Raspberry Pi 4 (64-bit)"}"

PROGRESS_FILE=$(mktemp /tmp/sigil-flash-progress-XXXXXX.json)
CONFIG_FILE=$(mktemp /tmp/sigil-manufacturing-config-XXXXXX.json)
LOG_FILE=$(mktemp /tmp/sigil-flash-test-XXXXXX.log)
chmod 600 "$CONFIG_FILE"

FLASH_PID=""
PROGRESS_FILE_ROOT=""  # Se define en Fase 4; declarado aquí para que cleanup pueda referenciarlo

cleanup() {
    local exit_code=$?
    # Matar proceso de flasheo si sigue corriendo
    if [ -n "$FLASH_PID" ] && kill -0 "$FLASH_PID" 2>/dev/null; then
        warn "Terminando proceso de flasheo (PID: $FLASH_PID)..."
        kill "$FLASH_PID" 2>/dev/null || true
    fi
    section "Limpieza de archivos temporales"
    rm -f "$PROGRESS_FILE" "$CONFIG_FILE" 2>/dev/null || true
    # Limpiar archivo de progreso de root si existe
    [ -n "${PROGRESS_FILE_ROOT:-}" ] && rm -f "$PROGRESS_FILE_ROOT" 2>/dev/null || true
    if [ $exit_code -eq 0 ]; then
        echo ""
        ok "══════════════════════════════════════════"
        ok " PRUEBA DE FLASHEO COMPLETADA EXITOSAMENTE"
        ok "══════════════════════════════════════════"
    else
        echo ""
        error "══════════════════════════════════════"
        error " PRUEBA DE FLASHEO FALLIDA (exit: $exit_code)"
        error "══════════════════════════════════════"
        if [ -f "$LOG_FILE" ]; then
            error "Últimas 30 líneas del log:"
            tail -30 "$LOG_FILE" | sed 's/^/  /'
        fi
    fi
    rm -f "$LOG_FILE" 2>/dev/null || true
}
trap cleanup EXIT

section "PRUEBA DE FLASHEO SIGIL — microSD 16GB"
info "Dispositivo destino: $DEVICE"
info "Imagen fuente:       $(basename $IMAGE_PATH)"
info "Log temporal:        $LOG_FILE"
echo "Fecha/Hora: $(date)"

# ─── Fase 1: Pre-requisitos ─────────────────────────────────────────────────
section "Fase 1: Verificaciones pre-flasheo"

[ -f "$BINARY" ] && ok "Binario compilado: $BINARY" || { error "Binario no encontrado: $BINARY"; exit 1; }
[ -f "$IMAGE_PATH" ] && ok "Imagen fuente encontrada" || { error "Imagen no encontrada: $IMAGE_PATH"; exit 1; }
[ -d "$PAYLOAD_DIR" ] && ok "Payload SIGIL: $PAYLOAD_DIR" || { error "Payload no encontrado: $PAYLOAD_DIR"; exit 1; }
[ -d "$OFFLINE_PACKAGES" ] && ok "Paquetes offline: $OFFLINE_PACKAGES" || { error "No encontrado: $OFFLINE_PACKAGES"; exit 1; }

info "Verificando SHA256 de la imagen (30-60s)..."
ACTUAL_SHA256=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    error "SHA256 NO coincide!"
    error "  Esperado: $EXPECTED_SHA256"
    error "  Obtenido: $ACTUAL_SHA256"
    exit 1
fi
ok "SHA256 verificado: $ACTUAL_SHA256"

[ -b "$DEVICE" ] || { error "$DEVICE no existe o no es bloque"; exit 1; }
REMOVABLE=$(cat "/sys/block/$(basename $DEVICE)/removable" 2>/dev/null || echo "0")
[ "$REMOVABLE" = "1" ] || { error "$DEVICE no es extraíble — abortando por seguridad"; exit 1; }
ok "Dispositivo $DEVICE verificado como extraíble"

DEVICE_SECTORS=$(cat "/sys/block/$(basename $DEVICE)/size" 2>/dev/null || echo "0")
DEVICE_SIZE_GB=$(( DEVICE_SECTORS * 512 / 1024 / 1024 / 1024 ))
info "Tamaño del dispositivo: ${DEVICE_SIZE_GB}GB"
[ "$DEVICE_SIZE_GB" -ge 14 ] || { error "Dispositivo demasiado pequeño: ${DEVICE_SIZE_GB}GB (mínimo 14GB)"; exit 1; }
ok "Capacidad suficiente: ${DEVICE_SIZE_GB}GB"

PKG_COUNT=$(ls "$OFFLINE_PACKAGES/packages/" 2>/dev/null | wc -l)
ok "Paquetes offline listos: $PKG_COUNT paquetes"

# ─── Fase 2: Desmontar SD ───────────────────────────────────────────────────
section "Fase 2: Desmontando particiones de $DEVICE"

# Desmontar con pkexec para tener privilegios
MOUNTS=$(lsblk -o MOUNTPOINT -n "$DEVICE" 2>/dev/null | { grep -v '^$' || true; })
if [ -n "$MOUNTS" ]; then
    info "Particiones montadas encontradas. Desmontando con pkexec..."
    # Crear script temporal de desmontaje
    UMOUNT_SCRIPT=$(mktemp /tmp/sigil-umount-XXXXXX.sh)
    cat > "$UMOUNT_SCRIPT" << EOF
#!/bin/bash
set -e
for part in \$(lsblk -o NAME,MOUNTPOINT -n $DEVICE | awk '\$2!="" {print "/dev/"\$1}'); do
    echo "Desmontando \$part..."
    umount "\$part" || echo "WARN: No se pudo desmontar \$part"
done
echo "Desmontaje completado"
EOF
    chmod +x "$UMOUNT_SCRIPT"
    pkexec bash "$UMOUNT_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    rm -f "$UMOUNT_SCRIPT"
else
    info "No hay particiones montadas en $DEVICE"
fi

sleep 2
STILL_MOUNTED=$(lsblk -o MOUNTPOINT -n "$DEVICE" 2>/dev/null | { grep -v '^$' || true; } | wc -l | tr -d ' \n')
STILL_MOUNTED="${STILL_MOUNTED:-0}"
if [ "$STILL_MOUNTED" -gt 0 ]; then
    error "Aún hay $STILL_MOUNTED particiones montadas en $DEVICE"
    lsblk "$DEVICE"
    exit 1
fi
ok "Todas las particiones de $DEVICE desmontadas"

# ─── Fase 3: Preparar config de dispositivo ──────────────────────────────────
section "Fase 3: Configuración de dispositivo de prueba"

ENROLLMENT_KEY_FILE="${PROJECT_DIR}/artifacts/secrets/enrollment-key"
if [ -f "$ENROLLMENT_KEY_FILE" ]; then
    API_KEY=$(tr -d '\n\r' < "$ENROLLMENT_KEY_FILE")
    KEY_LEN=${#API_KEY}
    ok "Enrollment key leída: $KEY_LEN chars"
else
    error "No se encontró enrollment key en: $ENROLLMENT_KEY_FILE"
    exit 1
fi
(( KEY_LEN >= 8 && KEY_LEN <= 256 )) || { error "Enrollment key con longitud inválida: $KEY_LEN chars"; exit 1; }

SERIAL="TEST-$(date +%Y%m%d%H%M%S)"
HOSTNAME="sigil-flash-test-$(date +%s)"

cat > "$CONFIG_FILE" << JSON
{
    "hostname": "$HOSTNAME",
    "username": "sigil",
    "password": "sigil-test-password-2026",
    "wifiSsid": null,
    "wifiPassword": null,
    "sshEnabled": true,
    "rpiModel": "$RPI_MODEL",
    "serialNumber": "$SERIAL",
    "deviceId": null,
    "sigilModel": null,
    "sigilModelVersion": null,
    "panelPin": "482951",
    "apiKey": "$API_KEY",
    "serverUrl": "https://sigil-server.sphinx-pickerel.ts.net"
}
JSON
ok "Config creado: hostname=$HOSTNAME | serial=$SERIAL"

# ─── Fase 4: Ejecutar el flasheo con pkexec ──────────────────────────────────
section "Fase 4: Ejecutando flasheo completo (15-45 minutos estimado)"
info "Esto mostrará un diálogo de autenticación polkit si es necesario"
info ""
info "  Imagen:   $(basename $IMAGE_PATH)"
info "  Destino:  $DEVICE"
info "  Payload:  $(basename $PAYLOAD_DIR)"
info "  Paquetes: $PKG_COUNT paquetes offline"
info ""

# Inicializar archivo de progreso en /run/lock donde root tiene acceso para escribir
# (AppArmor puede bloquear escrituras de root en /tmp de otros usuarios)
PROGRESS_FILE_ROOT="/run/lock/sigil-flash-progress-$$.json"
echo '{"bytes_written":0,"total_bytes":0,"speed_mbps":0.0,"eta_seconds":0.0,"status":"pending","message":"Iniciando..."}' > "$PROGRESS_FILE"
chmod 666 "$PROGRESS_FILE"

# Lanzar el proceso de flasheo via pkexec en background
# Usamos el PROGRESS_FILE_ROOT (en /run/lock) que root puede escribir sin restricciones AppArmor
pkexec "$BINARY" \
    --flash-raw \
    --src "$IMAGE_PATH" \
    --dest "$DEVICE" \
    --progress-file "$PROGRESS_FILE_ROOT" \
    --offline-packages "$OFFLINE_PACKAGES" \
    --payload "$PAYLOAD_DIR" \
    --config-file "$CONFIG_FILE" \
    > "$LOG_FILE" 2>&1 &

FLASH_PID=$!
info "Proceso de flasheo iniciado (PID: $FLASH_PID)"
info "Log en tiempo real: $LOG_FILE"
echo ""

# Monitor de progreso: primero intenta archivo de progreso de root (/run/lock),
# luego monitorea el log del proceso como fallback
LAST_MSG=""
LAST_LOG_LINE=0
START_TIME=$(date +%s)

while kill -0 "$FLASH_PID" 2>/dev/null; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    ELAPSED_FMT=$(printf "%02d:%02d" $((ELAPSED/60)) $((ELAPSED%60)))

    # Intentar leer el archivo de progreso de root
    if [ -f "$PROGRESS_FILE_ROOT" ]; then
        STATUS=$(python3 -c "
import json, sys
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('status', ''))
except: print('')
" 2>/dev/null || true)
        BW=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('bytes_written', 0))
except: print(0)
" 2>/dev/null || echo 0)
        TB=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('total_bytes', 1))
except: print(1)
" 2>/dev/null || echo 1)
        MSG=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('message', ''))
except: print('')
" 2>/dev/null || true)

        if [ "$MSG" != "$LAST_MSG" ] && [ -n "$MSG" ]; then
            if [ "${TB:-0}" -gt 0 ] && [ "${BW:-0}" -gt 0 ]; then
                PCT=$(( BW * 100 / TB ))
                BW_MB=$(( BW / 1024 / 1024 ))
                TB_MB=$(( TB / 1024 / 1024 ))
                info "[$ELAPSED_FMT] [${PCT}%] ${BW_MB}MB/${TB_MB}MB — $MSG"
            else
                info "[$ELAPSED_FMT] $MSG"
            fi
            LAST_MSG="$MSG"
        fi

        if [ "$STATUS" = "done" ]; then
            ok "[$ELAPSED_FMT] Estado de progreso: COMPLETADO ✓"
            break
        elif [ "$STATUS" = "error" ]; then
            error "[$ELAPSED_FMT] Error reportado: $MSG"
            break
        elif [ "$STATUS" = "cancelled" ]; then
            error "[$ELAPSED_FMT] Operación cancelada"
            break
        fi
    fi

    # Fallback: mostrar nuevas líneas del log del proceso
    if [ -f "$LOG_FILE" ]; then
        CURRENT_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$CURRENT_LINES" -gt "$LAST_LOG_LINE" ]; then
            tail -n "+$((LAST_LOG_LINE + 1))" "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                [ -n "$line" ] && info "[$ELAPSED_FMT] LOG: $line"
            done
            LAST_LOG_LINE=$CURRENT_LINES
        fi
    fi

    sleep 2
done

# Esperar fin del proceso
wait "$FLASH_PID"
FLASH_EXIT=$?
FLASH_PID=""

# ─── Fase 5: Verificar resultado ────────────────────────────────────────────
section "Fase 5: Verificación post-flasheo"

if [ "$FLASH_EXIT" -ne 0 ]; then
    error "Proceso de flasheo terminó con código: $FLASH_EXIT"
    if [ $FLASH_EXIT -eq 126 ] || [ $FLASH_EXIT -eq 127 ]; then
        error "pkexec: autenticación cancelada o permisos denegados (código $FLASH_EXIT)"
    fi
    error "=== Salida del proceso ==="
    cat "$LOG_FILE" | sed 's/^/  /'
    exit "$FLASH_EXIT"
fi
ok "Proceso de flasheo terminó correctamente (exit 0)"

# Verificar estado final: primero el archivo de progreso en /run/lock (escrito por root)
# Si no está disponible, usar el log del proceso como fuente de verdad
FINAL_STATUS="unknown"
FINAL_MSG=""

if [ -f "$PROGRESS_FILE_ROOT" ]; then
    FINAL_STATUS=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('status', 'unknown'))
except: print('parse_error')
" 2>/dev/null || echo "error_reading")
    FINAL_MSG=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('message', ''))
except: print('')
" 2>/dev/null || true)
    FINAL_BW=$(python3 -c "
import json
try:
    d = json.load(open('$PROGRESS_FILE_ROOT'))
    print(d.get('bytes_written', 0))
except: print(0)
" 2>/dev/null || echo 0)
    info "Estado final (archivo de progreso): $FINAL_STATUS"
    info "Mensaje: $FINAL_MSG"
    info "Bytes escritos: $FINAL_BW"
    # Limpiar archivo de progreso de root
    rm -f "$PROGRESS_FILE_ROOT" 2>/dev/null || true
elif [ -f "$LOG_FILE" ]; then
    # Fallback: verificar el log del proceso para determinar éxito
    warn "Archivo de progreso de root no disponible, verificando log del proceso..."
    if grep -q 'Imagen preparada' "$LOG_FILE" 2>/dev/null || \
       grep -q 'completados exitosamente' "$LOG_FILE" 2>/dev/null || \
       grep -q 'firstboot m' "$LOG_FILE" 2>/dev/null; then
        FINAL_STATUS="done"
        FINAL_MSG="Detectado en log del proceso (exit 0 + mensaje de éxito)"
        ok "Éxito confirmado por log del proceso"
    fi
fi

if [ "$FINAL_STATUS" = "done" ]; then
    ok "Estado de progreso: DONE ✓"
elif [ "$FLASH_EXIT" -eq 0 ]; then
    # El proceso exit 0 significa éxito aunque el archivo de progreso no se pudo leer
    warn "El proceso terminó con exit 0 pero el archivo de progreso no confirmó 'done'"
    warn "Estado leído: $FINAL_STATUS — Verificando via log..."
    # Re-verificar con el log
    if grep -q 'firstboot\|completado\|preparada\|instalados' "$LOG_FILE" 2>/dev/null; then
        ok "Flasheo confirmado como exitoso (exit 0 + log contiene mensajes de éxito)"
    else
        warn "No se pudo confirmar completamente, pero exit code 0 indica éxito"
    fi
else
    error "Estado final inesperado: $FINAL_STATUS"
    error "Mensaje: $FINAL_MSG"
    exit 1
fi

# Verificar particiones resultantes
info "Verificando tabla de particiones resultante..."
sleep 2
partprobe "$DEVICE" 2>/dev/null || true
sleep 1

echo ""
info "━━━ Tabla de particiones: $DEVICE ━━━"
fdisk -l "$DEVICE" 2>&1 | sed 's/^/  /'
echo ""
info "━━━ Bloques: $DEVICE ━━━"
lsblk "$DEVICE" 2>&1 | sed 's/^/  /'
echo ""

PART_COUNT=$(lsblk -o TYPE -n "$DEVICE" 2>/dev/null | grep -c part || echo 0)
if [ "$PART_COUNT" -ge 2 ]; then
    ok "Tabla de particiones correcta: $PART_COUNT particiones encontradas"
else
    error "Solo se encontraron $PART_COUNT particiones (esperado >= 2)"
    exit 1
fi

# ─── Resumen final ──────────────────────────────────────────────────────────
TOTAL_TIME=$(( $(date +%s) - START_TIME ))
TOTAL_FMT=$(printf "%02d:%02d" $((TOTAL_TIME/60)) $((TOTAL_TIME%60)))

section "RESUMEN FINAL DE LA PRUEBA"
ok "✅ SHA256 imagen:  VERIFICADO ($EXPECTED_SHA256)"
ok "✅ Dispositivo:    $DEVICE (${DEVICE_SIZE_GB}GB)"
ok "✅ Flasheo:        COMPLETADO sin errores"
ok "✅ Particiones:    $PART_COUNT particiones creadas"
ok "✅ Tiempo total:   $TOTAL_FMT"
echo ""
info "La microSD está lista. Puedes retirarla del lector."

exit 0
