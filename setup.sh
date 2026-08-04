#!/usr/bin/env bash
# ================================================================
# Sigil Flash — Script de instalación de dependencias del sistema
# Ejecutar con: bash setup.sh
# ================================================================

set -e

echo "🔥 Sigil Flash — Setup de dependencias del sistema"
echo "=================================================="

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
    qemu-user-static \
    qemu-user-static-binfmt
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
    qemu-user-static \
    binfmt-support
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
    qemu-user-static
else
  echo "⚠️  No se pudo detectar un gestor de paquetes soportado (pacman, apt-get, dnf)."
  echo "   Instala manualmente las dependencias para Tauri, utilitarios de disco y QEMU static."
  exit 1
fi

echo ""
echo "✅ Dependencias instaladas correctamente"
echo ""
echo "🚀 Para iniciar en modo desarrollo:"
echo "   bun run tauri dev"
echo ""
echo "📦 Para compilar el release:"
echo "   bun run tauri build"
