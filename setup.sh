#!/usr/bin/env bash
# =============================================================================
# setup.sh — Instala dependencias del PC de fabricación para SIGIL Flash
# Soporta: apt (Debian/Ubuntu), pacman (Arch), dnf (Fedora), zypper (openSUSE), apk (Alpine)
# Si las herramientas de empaquetado Debian no están disponibles, sugiere/prepara Docker.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$EUID" -ne 0 ]; then
    log_err "Este script requiere privilegios de root (ejecuta con sudo)."
    exit 1
fi

detect_pm() {
    if command -v apt-get &>/dev/null; then echo "apt";
    elif command -v pacman &>/dev/null; then echo "pacman";
    elif command -v dnf &>/dev/null; then echo "dnf";
    elif command -v zypper &>/dev/null; then echo "zypper";
    elif command -v apk &>/dev/null; then echo "apk";
    else echo "unknown"; fi
}

PM=$(detect_pm)
log_info "Gestor de paquetes detectado: ${PM}"

install_apt() {
    log_info "Actualizando e instalando paquetes APT..."
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        wget \
        git \
        pkg-config \
        libwebkit2gtk-4.1-dev \
        libgtk-3-dev \
        libayatana-appindicator3-dev \
        librsvg2-dev \
        patchelf \
        xz-utils \
        parted \
        qemu-user-static \
        dosfstools \
        e2fsprogs \
        cloud-guest-utils \
        gnupg \
        dpkg-dev \
        apt-utils \
        libsecret-tools \
        squashfs-tools \
        python3 \
        python3-pip \
        util-linux
}

install_pacman() {
    log_info "Instalando paquetes Pacman..."
    pacman -Sy --needed --noconfirm \
        base-devel \
        curl \
        wget \
        git \
        webkit2gtk-4.1 \
        gtk3 \
        libappindicator-gtk3 \
        librsvg \
        patchelf \
        xz \
        parted \
        qemu-user-static \
        dosfstools \
        e2fsprogs \
        cloud-guest-utils \
        gnupg \
        dpkg \
        libsecret \
        python \
        python-pip \
        util-linux
}

install_dnf() {
    log_info "Instalando paquetes DNF..."
    dnf install -y \
        @development-tools \
        curl \
        wget \
        git \
        webkit2gtk4.1-devel \
        gtk3-devel \
        libappindicator-gtk3-devel \
        librsvg2-devel \
        patchelf \
        xz \
        parted \
        qemu-user-static \
        dosfstools \
        e2fsprogs \
        gnupg2 \
        dpkg-dev \
        libsecret \
        python3 \
        python3-pip \
        util-linux
}

install_zypper() {
    log_info "Instalando paquetes Zypper..."
    zypper install -y -t pattern devel_basis
    zypper install -y \
        curl \
        wget \
        git \
        webkit2gtk3-devel \
        gtk3-devel \
        libappindicator3-devel \
        librsvg-devel \
        patchelf \
        xz \
        parted \
        qemu-extra \
        dosfstools \
        e2fsprogs \
        gpg2 \
        dpkg \
        libsecret \
        python3 \
        python3-pip \
        util-linux
}

install_apk() {
    log_info "Instalando paquetes APK..."
    apk add --no-cache \
        build-base \
        curl \
        wget \
        git \
        webkit2gtk-4.1 \
        gtk+3.0-dev \
        libappindicator-dev \
        librsvg-dev \
        patchelf \
        xz \
        parted \
        qemu-arm \
        qemu-aarch64 \
        dosfstools \
        e2fsprogs \
        gnupg \
        dpkg \
        libsecret \
        python3 \
        py3-pip \
        util-linux
}

case "$PM" in
    apt) install_apt ;;
    pacman) install_pacman ;;
    dnf) install_dnf ;;
    zypper) install_zypper ;;
    apk) install_apk ;;
    *)
        log_warn "Gestor de paquetes no reconocido. Intentando instalar Docker como fallback..."
        ;;
esac

# Comprobar si existen herramientas Debian de empaquetado (dpkg-scanpackages, apt-ftparchive, etc.)
MISSING_DEB_TOOLS=0
for tool in dpkg-scanpackages apt-ftparchive dpkg-deb; do
    if ! command -v "$tool" &>/dev/null; then
        log_warn "Herramienta Debian ausente: ${tool}"
        MISSING_DEB_TOOLS=1
    fi
done

if [ "$MISSING_DEB_TOOLS" -eq 1 ]; then
    log_warn "Faltan herramientas empaquetadoras de Debian. Verificando disponibilidad de Docker..."
    if ! command -v docker &>/dev/null; then
        log_info "Instalando Docker para la construcción de repositorios APT offline en entornos no-Debian..."
        if [ "$PM" = "apt" ]; then
            apt-get install -y docker.io
        elif [ "$PM" = "pacman" ]; then
            pacman -Sy --needed --noconfirm docker
        elif [ "$PM" = "dnf" ]; then
            dnf install -y docker
        elif [ "$PM" = "zypper" ]; then
            zypper install -y docker
        elif [ "$PM" = "apk" ]; then
            apk add --no-cache docker
        else
            log_err "No se pudo instalar Docker automáticamente. Por favor instálalo manualmente."
        fi
    fi
    log_ok "Docker está listo para su uso como contenedor de construcción Debian."
fi

# Instalar Bun si no existe
if ! command -v bun &>/dev/null; then
    log_info "Instalando Bun..."
    curl -fsSL https://bun.sh/install | bash || true
fi

# Instalar Rust/Cargo si no existe
if ! command -v cargo &>/dev/null; then
    log_info "Instalando Rustup/Cargo..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || true
fi

log_ok "Setup de dependencias del PC de fabricación completado con éxito."
