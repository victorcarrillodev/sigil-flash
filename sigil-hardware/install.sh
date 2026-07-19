#!/bin/bash
# =============================================================================
# install.sh — Instalador completo de Sigil en Raspberry Pi Zero 2 W
# Ejecutar desde la raíz del repositorio clonado:
#   sudo bash install.sh --offline-repo /opt/sigil/offline-repo
# =============================================================================
set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
log_ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
log_err()   { echo -e "  ${RED}✘${NC} $*"; }
log_info()  { echo -e "  ${CYAN}•${NC} $*"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "  ███████╗██╗ ██████╗ ██╗██╗     "
echo "  ██╔════╝██║██╔════╝ ██║██║     "
echo "  ███████╗██║██║  ███╗██║██║     "
echo "  ╚════██║██║██║   ██║██║██║     "
echo "  ███████║██║╚██████╔╝██║███████╗"
echo "  ╚══════╝╚═╝ ╚═════╝ ╚═╝╚══════╝"
echo -e "${NC}${CYAN}  Instalador — Raspberry Pi Zero 2 W${NC}\n"

# ── Comprobaciones previas ────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_err "Este script debe ejecutarse como root: sudo bash install.sh"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_info "Directorio del repositorio: ${REPO_DIR}"

OFFLINE_REPO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --offline-repo)
            [ "$#" -ge 2 ] || { log_err "Falta el valor de --offline-repo"; exit 1; }
            OFFLINE_REPO="$2"
            shift 2
            ;;
        --help|-h)
            printf 'Uso: sudo bash install.sh --offline-repo <directorio>\n'
            exit 0
            ;;
        *)
            log_err "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

for dir in panel scripts services conf manifests; do
    if [[ ! -d "${REPO_DIR}/${dir}" ]]; then
        log_err "No se encontró la carpeta '${dir}'. Ejecuta desde la raíz del repositorio."
        exit 1
    fi
done
log_ok "Estructura del repositorio verificada"

if [ -z "$OFFLINE_REPO" ]; then
    log_err "La instalación requiere --offline-repo; nunca descarga paquetes de Internet"
    exit 1
fi

AUDIO_CAPABILITY_HELPER="${REPO_DIR}/scripts/sigil-audio-capability.sh"
IDENTITY_HELPER="${REPO_DIR}/panel/device_identity.py"
if [ ! -r "$AUDIO_CAPABILITY_HELPER" ]; then
    log_err "No se encontró el helper de capacidades: ${AUDIO_CAPABILITY_HELPER}"
    exit 1
fi
# shellcheck source=scripts/sigil-audio-capability.sh
source "$AUDIO_CAPABILITY_HELPER"
if [ ! -r "$IDENTITY_HELPER" ]; then
    log_err "No se encontró el helper de identidad: ${IDENTITY_HELPER}"
    exit 1
fi

# ── Variables de configuración ────────────────────────────────────────────────
SIGIL_USER="sigil"
SIGIL_HOME="/home/sigil"
SIGIL_UID=1001          # UID fijo para evitar conflictos
PANEL_INSTALL_DIR="/opt/sigil/panel"

SERVICES="sigil-wifi-control bluetooth-panel bt-connect sigil-leds wifi-fallback ssh-monitor"
PHASE2_AUDIO_SERVICES="radio-fetcher audio-manager audio-player"

# ── Paso 1: Paquetes del sistema ──────────────────────────────────────────────
log_step "Instalando contrato de paquetes desde repositorio local"

SIGIL_PACKAGE_CONTRACT="${REPO_DIR}/manifests/offline-package-contract.json" \
    bash "${REPO_DIR}/scripts/install-offline-packages.sh" "$OFFLINE_REPO"

# Verificar que pinctrl quedó disponible tras instalar raspi-utils
if ! command -v pinctrl &>/dev/null; then
    log_warn "pinctrl no disponible tras instalar raspi-utils — los LEDs pueden no funcionar"
fi

log_ok "Paquetes del sistema y Python listos sin acceso a Internet"

# ── Paso 2: Usuario sigil ─────────────────────────────────────────────────────
log_step "Configurando usuario '${SIGIL_USER}'"

if id "${SIGIL_USER}" &>/dev/null; then
    log_ok "Usuario '${SIGIL_USER}' ya existe"
else
    useradd \
        --uid "${SIGIL_UID}" \
        --create-home \
        --home-dir "${SIGIL_HOME}" \
        --shell /bin/bash \
        --comment "Sigil Service Account" \
        "${SIGIL_USER}"
    log_ok "Usuario '${SIGIL_USER}' creado (UID=${SIGIL_UID})"
fi

# Agregar a grupos necesarios (bluetooth, pulse-access, audio)
for grp in bluetooth audio pulse-access; do
    if getent group "$grp" &>/dev/null; then
        if usermod -aG "$grp" "${SIGIL_USER}" 2>/dev/null; then
            log_ok "'${SIGIL_USER}' añadido al grupo '$grp'"
        fi
    fi
done

# ── Configuración adicional de usuario para Bluetooth/PulseAudio ─────────────
configure_bluetooth_user() {
    local user="$1"

    if ! id "$user" &>/dev/null; then
        log_warn "Usuario '$user' no existe — saltando configuración Bluetooth"
        return
    fi

    # Grupos adicionales (solo si existen en el sistema)
    local extra_groups=("netdev" "gpio" "i2c" "spi")
    for grp in "${extra_groups[@]}"; do
        if getent group "$grp" &>/dev/null; then
            if usermod -aG "$grp" "$user" 2>/dev/null; then
                log_ok "'${user}' añadido al grupo '$grp'"
            fi
        fi
    done

    # Habilitar lingering para el usuario (necesario para PulseAudio
    # cuando no hay sesión activa)
    if [ "${SIGIL_IMAGE_PREPARATION:-0}" = "1" ]; then
        log_info "Preparación de imagen: user lingering se aplicará en firstboot"
    elif command -v loginctl &>/dev/null; then
        local linger_state
        linger_state=$(loginctl show-user "$user" 2>/dev/null | grep "^Linger=" | cut -d= -f2 || true)
        if [[ "$linger_state" == "yes" ]]; then
            log_ok "User lingering ya habilitado para '${user}'"
        else
            if loginctl enable-linger "$user" 2>/dev/null; then
                log_ok "User lingering habilitado para '${user}' (necesario para PulseAudio sin sesión activa)"
            else
                log_warn "No se pudo habilitar lingering para '${user}'"
            fi
        fi
    else
        log_warn "loginctl no disponible — no se puede habilitar user lingering"
    fi
}

configure_bluetooth_user "${SIGIL_USER}"


# ── Paso 4: Panel Python ──────────────────────────────────────────────────────
log_step "Instalando panel Python → ${PANEL_INSTALL_DIR}"

# Flask and the root-run NetworkManager dispatcher import code only from this
# root-owned tree.  SIGIL_HOME remains writable for service runtime state.
install -d -o root -g root -m 0755 \
    "/opt/sigil" \
    "${PANEL_INSTALL_DIR}" \
    "${PANEL_INSTALL_DIR}/templates" \
    "${PANEL_INSTALL_DIR}/static" \
    "${PANEL_INSTALL_DIR}/static/css" \
    "${PANEL_INSTALL_DIR}/static/js" \
    "${PANEL_INSTALL_DIR}/static/img" \
    "${PANEL_INSTALL_DIR}/static/video"

for panel_file in "${REPO_DIR}"/panel/*.py; do
    install -o root -g root -m 0644 \
        "$panel_file" "${PANEL_INSTALL_DIR}/$(basename "$panel_file")"
done

for template_file in "${REPO_DIR}"/panel/templates/*; do
    install -o root -g root -m 0644 \
        "$template_file" "${PANEL_INSTALL_DIR}/templates/$(basename "$template_file")"
done

for asset_dir in css js img video; do
    for asset_file in "${REPO_DIR}/panel/static/${asset_dir}"/*; do
        install -o root -g root -m 0644 \
            "$asset_file" "${PANEL_INSTALL_DIR}/static/${asset_dir}/$(basename "$asset_file")"
    done
done

# Re-assert the complete tree on every install so an interrupted or legacy
# installation cannot leave a writable file on a privileged import path.
chown -R root:root "${PANEL_INSTALL_DIR}"
find "${PANEL_INSTALL_DIR}" -type d -exec chmod 0755 {} +
find "${PANEL_INSTALL_DIR}" -type f -exec chmod 0644 {} +

# Compatibility for existing non-root runtime and provisioning scripts.  The
# NetworkManager dispatcher imports this helper from PANEL_INSTALL_DIR instead.
install -o root -g root -m 0644 \
    "${REPO_DIR}/panel/device_identity.py" "${SIGIL_HOME}/device_identity.py"

log_ok "Panel web instalado root:root y de solo lectura en ${PANEL_INSTALL_DIR}"

# ── Paso 5: Scripts de sistema ────────────────────────────────────────────────
log_step "Instalando scripts → /usr/local/bin"

SCRIPTS=(
    bt-connect.sh
    radio-stream.sh
    set-a2dp.sh
    sigil-leds.sh
    sigil-wifi-control.py
    wifi-fallback.sh
    wifi-manager.sh
    audio-manager.sh
    radio-fetcher.sh
    audio-player.sh
    sigil-validate-state.sh
    sigil-healthcheck.sh
    sigil-audio-route.sh
    sigil-audio-capability.sh
    sigil-cache-meta-perms.sh
    sigil-cache-wipe.sh
    sigil-logout-fetch-operation.sh
    ssh-monitor.sh
    firstboot.sh
)

for script in "${SCRIPTS[@]}"; do
    cp "${REPO_DIR}/scripts/${script}" "/usr/local/bin/${script}"
    chmod +x "/usr/local/bin/${script}"
    log_ok "${script} → /usr/local/bin/ (chmod +x)"
done

# ── Paso 6: Servicios systemd ─────────────────────────────────────────────────
log_step "Instalando servicios systemd → /etc/systemd/system"

for svc_file in "${REPO_DIR}"/services/*.service; do
    svc_name=$(basename "$svc_file")
    install -o root -g root -m 0644 \
        "$svc_file" "/etc/systemd/system/${svc_name}"
    log_ok "${svc_name} copiado"
done

if [ "${SIGIL_IMAGE_PREPARATION:-0}" = "1" ]; then
    log_info "Preparación de imagen: daemon-reload se aplicará en firstboot"
else
    systemctl daemon-reload
    log_ok "systemd daemon recargado"
fi

# ── Paso 7: Configuración del sistema ────────────────────────────────────────
log_step "Aplicando configuración del sistema"

# 7a. Config backup before overwriting
    for _cfg in bluetooth-main.conf pulse-daemon.conf dnsmasq.conf hostapd.conf; do
        _target=""
        case "$_cfg" in
            bluetooth-main.conf) _target="/etc/bluetooth/main.conf" ;;
            pulse-daemon.conf)   _target="/etc/pulse/daemon.conf" ;;
            dnsmasq.conf)        _target="/etc/dnsmasq.conf" ;;
            hostapd.conf)        _target="/etc/hostapd/hostapd.conf" ;;
        esac
        if [ -n "$_target" ] && [ -f "$_target" ]; then
            cp "$_target" "${_target}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
    done

# 7b. BlueZ
cp "${REPO_DIR}/conf/bluetooth-main.conf" /etc/bluetooth/main.conf
log_ok "bluetooth: /etc/bluetooth/main.conf"

# 7b. PulseAudio daemon
cp "${REPO_DIR}/conf/pulse-daemon.conf" /etc/pulse/daemon.conf
log_ok "pulseaudio: /etc/pulse/daemon.conf"

# 7c. PulseAudio default.pa — solo AÑADIR la línea, no reemplazar
PULSE_LINE="load-module module-switch-on-connect"
if grep -qxF "${PULSE_LINE}" /etc/pulse/default.pa 2>/dev/null; then
    log_ok "pulseaudio: module-switch-on-connect ya presente en default.pa"
else
    {
        echo ""
        echo "# Sigil: conectar automáticamente al sink BT cuando aparece"
        echo "${PULSE_LINE}"
    } >> /etc/pulse/default.pa
    log_ok "pulseaudio: module-switch-on-connect añadido a /etc/pulse/default.pa"
fi

# 7d. tmpfiles.d — /run/sigil directory
if [ -f "${REPO_DIR}/conf/sigil-tmpfiles.conf" ]; then
    cp "${REPO_DIR}/conf/sigil-tmpfiles.conf" /etc/tmpfiles.d/sigil.conf
    log_ok "tmpfiles: /etc/tmpfiles.d/sigil.conf"
    systemd-tmpfiles --create /etc/tmpfiles.d/sigil.conf
fi

# 7e. dnsmasq
cp "${REPO_DIR}/conf/dnsmasq.conf" /etc/dnsmasq.conf
log_ok "red: /etc/dnsmasq.conf"

# 7e. hostapd
mkdir -p /etc/hostapd
cp "${REPO_DIR}/conf/hostapd.conf" /etc/hostapd/hostapd.conf
# Apuntar hostapd al config file si no está ya configurado
if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    # Si la línea no estaba comentada o no existe, asegurarse
    if ! grep -q 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' /etc/default/hostapd; then
        echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
    fi
fi
log_ok "red: /etc/hostapd/hostapd.conf"

# 7f. Sudoers
for sudoers_file in sigil-network.sudoers sigil.sudoers; do
    target="/etc/sudoers.d/${sudoers_file%.sudoers}"
    install -o root -g root -m 0440 \
        "${REPO_DIR}/conf/${sudoers_file}" "$target"
    if visudo -c -f "$target" &>/dev/null; then
        log_ok "sudoers: ${target} (chmod 440, validado)"
    else
        log_err "El archivo sudoers ${sudoers_file} no es válido — revertiendo"
        rm -f "$target"
        exit 1
    fi
done

# 7g. DAC de Audio I2S (PCM5102) — solo por capacidad declarada
log_step "Evaluando capacidad DAC PCM5102 (I2S)"
CONFIG_TXT="/boot/firmware/config.txt"
if [[ ! -f "$CONFIG_TXT" ]]; then
    CONFIG_TXT="/boot/config.txt"
fi

I2S_PROVISION_FILE="${SIGIL_PROVISION_FILE:-}"
if [ -z "$I2S_PROVISION_FILE" ]; then
    for candidate in /boot/firmware/sigil_provision.json /boot/sigil_provision.json; do
        if [ -f "$candidate" ]; then
            I2S_PROVISION_FILE="$candidate"
            break
        fi
    done
fi

if [ "${SIGIL_IMAGE_PREPARATION:-0}" = "1" ]; then
    I2S_DAC_PRESENT=0
    log_info "Preparación de imagen: identidad y capacidad I2S se aplicarán en firstboot"
elif [ -n "$I2S_PROVISION_FILE" ]; then
    if ! I2S_DAC_PRESENT=$(python3 "$IDENTITY_HELPER" \
        --device-conf /etc/sigil/device.conf \
        --persist-provision "$I2S_PROVISION_FILE"); then
        log_err "Provision inválido: se requieren serial_number, model, model_version, batch y capabilities.i2s_dac"
        exit 1
    fi
    log_ok "Identidad de fabricación persistida en /etc/sigil/device.conf (640, root:sigil)"
else
    if [ ! -f /etc/sigil/device.conf ]; then
        log_err "No hay sigil_provision.json ni /etc/sigil/device.conf; la identidad de fabricación es obligatoria"
        exit 1
    fi
    if ! I2S_DAC_PRESENT=$(python3 "$IDENTITY_HELPER" \
        --device-conf /etc/sigil/device.conf \
        --audio-conf /etc/sigil/audio.conf \
        --field i2s_dac); then
        log_err "Identidad existente inválida; los dispositivos legacy requieren migración explícita de model_version"
        exit 1
    fi
    log_ok "Identidad existente validada; capacidad I2S preservada o resuelta por mapping legacy confirmado"
fi

if [[ -f "$CONFIG_TXT" ]]; then
    if ! sigil_configure_i2s_overlay "$CONFIG_TXT" "$I2S_DAC_PRESENT"; then
        log_err "No se pudo aplicar la capacidad I2S en ${CONFIG_TXT}"
        exit 1
    fi
    if [ "$I2S_DAC_PRESENT" = "1" ]; then
        log_ok "DAC PCM5102 declarado: hifiberry-dac habilitado en $CONFIG_TXT"
    else
        log_ok "DAC PCM5102 no declarado: hifiberry-dac deshabilitado en $CONFIG_TXT"
    fi
else
    log_warn "No se encontró config.txt; capacidad I2S=${I2S_DAC_PRESENT} se conservará en audio.conf"
fi

# ── Paso 8: Directorios de trabajo ───────────────────────────────────────────
log_step "Creando directorios de trabajo"

mkdir -p /var/lib/wifi-manager
log_ok "/var/lib/wifi-manager"

# Phase 1: State and music directories
mkdir -p /var/lib/sigil/download_locks
log_ok "/var/lib/sigil/ (state directory)"

mkdir -p /home/sigil/music/active/tracks
mkdir -p /home/sigil/music/staging/tracks
mkdir -p /home/sigil/music/archive
chown -R "${SIGIL_USER}:${SIGIL_USER}" /home/sigil/music
log_ok "/home/sigil/music/{active,staging,archive}/tracks/"

# bt-connect.sh is the sole writer of this state. Reject a legacy symlink,
# preserve a regular file across upgrades, and enforce private permissions.
if [ -L "${SIGIL_HOME}/preferred_bt.txt" ]; then
    rm -f -- "${SIGIL_HOME}/preferred_bt.txt"
fi
if [ ! -f "${SIGIL_HOME}/preferred_bt.txt" ]; then
    install -o "${SIGIL_USER}" -g "${SIGIL_USER}" -m 0600 \
        /dev/null "${SIGIL_HOME}/preferred_bt.txt"
else
    chown "${SIGIL_USER}:${SIGIL_USER}" "${SIGIL_HOME}/preferred_bt.txt"
    chmod 0600 "${SIGIL_HOME}/preferred_bt.txt"
fi
log_ok "${SIGIL_HOME}/preferred_bt.txt (estado BT, owner: ${SIGIL_USER}, perms: 600)"

touch "${SIGIL_HOME}/now_playing.txt" 2>/dev/null || true
chown "${SIGIL_USER}:${SIGIL_USER}" "${SIGIL_HOME}/now_playing.txt" 2>/dev/null || true
chmod 644 "${SIGIL_HOME}/now_playing.txt" 2>/dev/null || true
log_ok "${SIGIL_HOME}/now_playing.txt (pista actual, owner: ${SIGIL_USER}, perms: 644)"

# Log files — bt-connect y radio-stream corren como 'sigil' pero escriben en /var/log/
# Crear los archivos y darle ownership a sigil antes del primer arranque
for logfile in bt-connect radio-stream; do
    touch "/var/log/${logfile}.log"
    chown "${SIGIL_USER}:${SIGIL_USER}" "/var/log/${logfile}.log"
    chmod 644 "/var/log/${logfile}.log"
    log_ok "/var/log/${logfile}.log (owner: ${SIGIL_USER})"
done

# Compatibility log path retained for existing diagnostics.
touch /var/log/audio-manager.log
chown "${SIGIL_USER}:${SIGIL_USER}" /var/log/audio-manager.log
chmod 644 /var/log/audio-manager.log
log_ok "/var/log/audio-manager.log (owner: ${SIGIL_USER})"

# Phase 2A/2B/2C: Segregated log directory for new services
# Permissions: 750 for directory (sigil: read/write, group: read, other: none)
#              640 for log files (sigil: read/write, group: read, other: none)
# Production image should tighten further (e.g., 700 / 600).
mkdir -p /var/log/sigil
for logfile in radio-fetcher audio-player audio-manager; do
    touch "/var/log/sigil/${logfile}.log"
    chown "${SIGIL_USER}:${SIGIL_USER}" "/var/log/sigil/${logfile}.log"
    chmod 640 "/var/log/sigil/${logfile}.log"
    log_ok "/var/log/sigil/${logfile}.log (owner: ${SIGIL_USER}, perms: 640)"
done
chmod 750 /var/log/sigil

# ── Paso 9: Secrets del panel ────────────────────────────────────────────────
log_step "Configurando secrets del panel"

mkdir -p /etc/sigil
chmod 755 /etc/sigil
install -d -o root -g sigil -m 0750 /etc/sigil/secrets
install -d -o root -g root -m 0700 /etc/sigil/manufacturing

if [[ -f /etc/sigil/panel.env ]]; then
    log_ok "/etc/sigil/panel.env ya existe"
else
    if command -v openssl &>/dev/null; then
        _secret_key=$(openssl rand -hex 32)
    else
        _secret_key=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    fi
    cat > /etc/sigil/panel.env << ENVEOF
SIGIL_SECRET_KEY=${_secret_key}
SIGIL_SERVER_URL=https://sigil-server.tail942ea3.ts.net
ENVEOF
    chmod 600 /etc/sigil/panel.env
    chown root:root /etc/sigil/panel.env
    log_ok "/etc/sigil/panel.env creado (600, root:root)"
    unset _secret_key _api_key
fi

# ── Paso 9b: Configuración de audio y seguridad (Phase 1) ─────────────────────
log_step "Instalando configuración de audio y seguridad"

if [[ -f /etc/sigil/audio.conf ]]; then
    log_ok "/etc/sigil/audio.conf ya existe"
else
    cp "${REPO_DIR}/conf/audio.conf" /etc/sigil/audio.conf
fi

if ! sigil_write_i2s_capability /etc/sigil/audio.conf "$I2S_DAC_PRESENT"; then
    log_err "No se pudo persistir SIGIL_I2S_DAC_PRESENT"
    exit 1
fi
chown root:sigil /etc/sigil/audio.conf
chmod 640 /etc/sigil/audio.conf
log_ok "/etc/sigil/audio.conf (640, root:sigil, I2S=${I2S_DAC_PRESENT})"

# Permanent API credentials are created by firstboot from the injected,
# one-use enrollment key. Never generate or embed a shared token here.
rm -f -- /etc/sigil/secrets/device-api-key
log_ok "API credential deferred to firstboot enrollment"

if [[ -f /etc/sigil/security.conf ]]; then
    log_ok "/etc/sigil/security.conf ya existe"
else
    cp "${REPO_DIR}/conf/security.conf" /etc/sigil/security.conf
    chmod 600 /etc/sigil/security.conf
    chown root:root /etc/sigil/security.conf
    log_ok "/etc/sigil/security.conf (600, root:root)"
fi

if [[ -f /etc/sigil/wifi-fallback.conf ]]; then
    log_ok "/etc/sigil/wifi-fallback.conf ya existe"
else
    cp "${REPO_DIR}/conf/wifi-fallback.conf" /etc/sigil/wifi-fallback.conf
fi
chown root:root /etc/sigil/wifi-fallback.conf
chmod 644 /etc/sigil/wifi-fallback.conf
log_ok "/etc/sigil/wifi-fallback.conf (644, root:root)"

# Persist bounded journal evidence across normal reboots.  Do not restart
# journald while preparing an image; the target boot activates this policy and
# systemd-journal-flush moves early volatile records into /var/log/journal.
install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
install -o root -g root -m 0644 \
    "${REPO_DIR}/conf/90-sigil-persistent-journal.conf" \
    /etc/systemd/journald.conf.d/90-sigil-persistent.conf
install -d -o root -g systemd-journal -m 2755 /var/log/journal
install -o root -g root -m 0644 \
    "${REPO_DIR}/conf/sigil-logrotate" /etc/logrotate.d/sigil
log_ok "Journal persistente acotado (64 MiB, retención máxima 14 días)"
log_ok "/etc/logrotate.d/sigil instalado para logs heredados"

# ── Paso 10: Configuración de NetworkManager ──────────────────────────────────
log_step "Configurando NetworkManager"

# Deshabilitar MAC randomization en WiFi — la Pi debe presentar siempre
# su MAC real para que el servidor y el router la reconozcan de forma estable.
mkdir -p /etc/NetworkManager/conf.d
if grep -Eq '^[[:space:]]*unmanaged-devices[[:space:]]*=.*wlan0' \
    "${REPO_DIR}/conf/99-sigil-mac-fixed.conf"; then
    log_err "La política MAC no puede marcar wlan0 permanentemente como unmanaged"
    exit 1
fi
cp "${REPO_DIR}/conf/99-sigil-mac-fixed.conf" /etc/NetworkManager/conf.d/99-sigil-mac-fixed.conf
log_ok "MAC randomization deshabilitada (/etc/NetworkManager/conf.d/99-sigil-mac-fixed.conf)"

# Desactivar dhcpcd en wlan0 si está activo (conflicto con NM)
if systemctl is-enabled dhcpcd &>/dev/null 2>&1; then
    # Agregar wlan0 a denyinterfaces para que dhcpcd no lo gestione
    if [[ -f /etc/dhcpcd.conf ]] && ! grep -q "denyinterfaces wlan0" /etc/dhcpcd.conf; then
        echo "denyinterfaces wlan0" >> /etc/dhcpcd.conf
        log_ok "dhcpcd: wlan0 excluido (denyinterfaces)"
    fi
fi

if systemctl enable NetworkManager 2>/dev/null; then
    log_ok "NetworkManager habilitado"
else
    log_warn "NetworkManager ya estaba habilitado"
fi

# ── Dispatcher de geolocalización WiFi ───────────────────────────────────────
log_step "Instalando dispatcher de geolocalización WiFi"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
install -d -o root -g root -m 0755 "$DISPATCHER_DIR"
install -o root -g root -m 0755 \
    "${REPO_DIR}/conf/90-sigil-geolocate" "${DISPATCHER_DIR}/90-sigil-geolocate"
log_ok "Instalado: ${DISPATCHER_DIR}/90-sigil-geolocate (se ejecuta al conectar WiFi)"

# ── Estado y logs de geolocalización ────────────────────────────────────────
log_step "Preparando estado y logs de geolocalización WiFi"
mkdir -p /var/lib/sigil
touch /var/lib/sigil/geolocation_state.json
chmod 660 /var/lib/sigil/geolocation_state.json
chown "${SIGIL_USER}:${SIGIL_USER}" /var/lib/sigil/geolocation_state.json
touch /var/log/sigil-geolocate.log
chmod 640 /var/log/sigil-geolocate.log
chown "${SIGIL_USER}:${SIGIL_USER}" /var/log/sigil-geolocate.log
log_ok "/var/lib/sigil/geolocation_state.json + /var/log/sigil-geolocate.log"

# ── Paso 11: Habilitar servicios ─────────────────────────────────────────────
log_step "Habilitando servicios Sigil"

# hostapd y dnsmasq: deshabilitados por defecto (wifi-fallback los maneja)
systemctl unmask hostapd dnsmasq 2>/dev/null || true
systemctl disable hostapd dnsmasq 2>/dev/null || true
log_ok "hostapd y dnsmasq: deshabilitados (wifi-fallback los controla)"

for svc in $SERVICES; do
    if systemctl enable "${svc}.service" 2>/dev/null; then
        log_ok "${svc}.service habilitado"
    else
        log_warn "${svc}.service ya estaba habilitado"
    fi
done

# Phase 2 is the production audio runtime.  The legacy unit remains installed
# as an explicit rollback path, but it must never coexist with audio-player.
systemctl disable radio-stream.service 2>/dev/null || true
log_ok "radio-stream.service: inactivo y deshabilitado (rollback explícito)"

for svc in $PHASE2_AUDIO_SERVICES; do
    if systemctl enable "${svc}.service" 2>/dev/null; then
        log_ok "${svc}.service habilitado"
    else
        log_err "No se pudo habilitar ${svc}.service"
        exit 1
    fi
done

if systemctl enable sigil-firstboot.service 2>/dev/null; then
    log_ok "sigil-firstboot.service habilitado para identidad y secretos del primer arranque"
else
    log_err "No se pudo habilitar sigil-firstboot.service"
    exit 1
fi

# ── Paso 12: Variables de entorno opcionales ──────────────────────────────────
log_step "Variables de entorno"

# Si no existe una clave personalizada, mostrar aviso
if ! grep -q "SIGIL_SECRET_KEY" /etc/systemd/system/bluetooth-panel.service 2>/dev/null; then
    log_warn "SIGIL_SECRET_KEY usa el valor por defecto."
    log_warn "Para cambiarla, edita /etc/systemd/system/bluetooth-panel.service:"
    log_info "  [Service]"
    log_info "  Environment=SIGIL_SECRET_KEY=tu_clave_segura"
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  ✔  Instalación completada${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Archivos del panel:${NC}  ${PANEL_INSTALL_DIR}/app.py"
echo -e "  ${CYAN}Scripts:${NC}             /usr/local/bin/*.sh"
echo -e "  ${CYAN}Servicios:${NC}           /etc/systemd/system/"
echo ""
echo -e "  ${BOLD}Próximo paso — reiniciar el dispositivo:${NC}"
echo -e "  ${YELLOW}  sudo reboot${NC}"
echo ""
echo -e "  ${BOLD}O para arrancar los servicios sin reiniciar:${NC}"
echo -e "  ${YELLOW}  sudo systemctl start bluetooth-panel bt-connect sigil-leds wifi-fallback ssh-monitor${NC}"
echo ""
echo -e "  ${BOLD}Panel web:${NC} conectarte al WiFi ${CYAN}Sigil${NC} (pass: ${CYAN}sigil1234${NC}) → ${CYAN}http://192.168.4.1${NC}"
echo ""
