#!/usr/bin/env bash
# ================================================================
# Sigil Flash — Script de instalación de dependencias del sistema
# Ejecutar con: bash setup.sh
# ================================================================

set -e

echo "🔥 Sigil Flash — Setup de dependencias del sistema"
echo "=================================================="

NEEDS_MANUFACTURING_DOCKER_NOTE=false

if command -v pacman &>/dev/null; then
  echo "📦 Detectado sistema basado en Arch Linux / Manjaro (pacman)..."
  sudo pacman -S --needed --noconfirm \
    webkit2gtk-4.1 \
    gtk3 \
    openssl \
    libappindicator-gtk3 \
    librsvg \
    base-devel \
    curl \
    wget \
    file \
    dpkg \
    cloud-guest-utils \
    polkit \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    gnupg \
    xz \
    qemu-user-static \
    qemu-user-static-binfmt
  sudo pacman -S --needed --noconfirm docker \
    || echo "⚠️  No se pudo instalar docker automáticamente; instalalo manualmente si vas a construir el repositorio APT offline (fabricación) en este sistema."
  NEEDS_MANUFACTURING_DOCKER_NOTE=true
elif command -v apt-get &>/dev/null; then
  echo "📦 Detectado sistema basado en Debian / Ubuntu (apt)..."
  sudo apt-get update
  sudo apt-get install -y \
    libwebkit2gtk-4.1-dev \
    libssl-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    libgtk-3-dev \
    libglib2.0-dev \
    libcairo2-dev \
    libpango1.0-dev \
    build-essential \
    curl \
    wget \
    file \
    libxdo-dev \
    policykit-1 \
    cloud-guest-utils \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    gnupg \
    xz-utils \
    qemu-user-static \
    binfmt-support \
    dpkg-dev \
    apt-utils
elif command -v dnf &>/dev/null; then
  echo "📦 Detectado sistema basado en Fedora / RHEL (dnf)..."
  sudo dnf install -y \
    webkit2gtk4.1-devel \
    openssl-devel \
    libappindicator-gtk3-devel \
    librsvg2-devel \
    gtk3-devel \
    glib2-devel \
    cairo-devel \
    pango-devel \
    curl \
    wget \
    file \
    dpkg \
    cloud-utils-growpart \
    polkit \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    gnupg2 \
    xz \
    qemu-user-static
  sudo dnf install -y moby-engine docker-cli \
    || sudo dnf install -y docker \
    || echo "⚠️  No se pudo instalar docker automáticamente; instalalo manualmente si vas a construir el repositorio APT offline (fabricación) en este sistema."
  NEEDS_MANUFACTURING_DOCKER_NOTE=true
elif command -v zypper &>/dev/null; then
  echo "📦 Detectado sistema basado en openSUSE (zypper)..."
  sudo zypper --non-interactive install \
    webkit2gtk3-soup2-devel \
    libopenssl-devel \
    libappindicator3-devel \
    librsvg-devel \
    gtk3-devel \
    glib2-devel \
    cairo-devel \
    pango-devel \
    curl \
    wget \
    file \
    dpkg \
    patterns-devel-base-devel_basis \
    cloud-utils-growpart \
    polkit \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    gpg2 \
    xz \
    qemu-linux-user
  sudo zypper --non-interactive install docker \
    || echo "⚠️  No se pudo instalar docker automáticamente; instalalo manualmente si vas a construir el repositorio APT offline (fabricación) en este sistema."
  NEEDS_MANUFACTURING_DOCKER_NOTE=true
elif command -v apk &>/dev/null; then
  echo "📦 Detectado sistema basado en Alpine (apk)..."
  echo "   Nota: Alpine usa musl libc; no está tan probado como las demás distros."
  sudo apk add \
    bash \
    webkit2gtk-4.1-dev \
    openssl-dev \
    libappindicator-dev \
    librsvg-dev \
    gtk+3.0-dev \
    glib-dev \
    cairo-dev \
    pango-dev \
    curl \
    wget \
    file \
    dpkg \
    build-base \
    polkit \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    gnupg \
    xz \
    qemu-user-static
  sudo apk add docker \
    || echo "⚠️  No se pudo instalar docker automáticamente; instalalo manualmente si vas a construir el repositorio APT offline (fabricación) en este sistema."
  NEEDS_MANUFACTURING_DOCKER_NOTE=true
else
  echo "⚠️  No se pudo detectar un gestor de paquetes soportado (pacman, apt-get, dnf, zypper, apk)."
  echo "   Instala manualmente: WebKitGTK 4.1, OpenSSL, GTK3, librsvg, herramientas de compilación C,"
  echo "   utilitarios de disco (parted/dosfstools/e2fsprogs/util-linux), polkit y qemu-user-static."
  echo "   Para construir el repositorio APT offline de fabricación necesitás además Docker."
  exit 1
fi

if ! command -v cargo &>/dev/null; then
  echo ""
  echo "🦀 Rust no está instalado. Instalando via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

echo ""
echo "✅ Dependencias instaladas correctamente"

if $NEEDS_MANUFACTURING_DOCKER_NOTE; then
  echo ""
  echo "🐳 Este sistema no tiene las herramientas de empaquetado Debian (apt-get,"
  echo "   dpkg-scanpackages, apt-ftparchive) de forma nativa. scripts/build-offline-repository.sh"
  echo "   lo detecta solo y usa Docker automáticamente para construir el repositorio APT offline"
  echo "   de fabricación. Si instalaste docker recién, agregate al grupo y habilitá el servicio:"
  echo "     sudo usermod -aG docker \$USER && sudo systemctl enable --now docker"
  echo "   (cerrá sesión y volvé a entrar para que el grupo tome efecto)."
fi

echo ""
echo "🚀 Para iniciar en modo desarrollo:"
echo "   bun run tauri dev"
echo ""
echo "📦 Para compilar el release:"
echo "   bun run tauri build"
