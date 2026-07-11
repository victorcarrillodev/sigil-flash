#!/usr/bin/env bash
# ================================================================
# Sigil Flash — Script de instalación de dependencias del sistema
# Ejecutar con: bash setup.sh
# ================================================================

set -e

echo "🔥 Sigil Flash — Setup de dependencias del sistema"
echo "=================================================="

# Check if running on Debian/Ubuntu
if ! command -v apt-get &>/dev/null; then
  echo "⚠️  Este script es para sistemas basados en Debian/Ubuntu."
  echo "   Instala manualmente: webkit2gtk-4.1-dev, libssl-dev, libgtk-3-dev"
  exit 1
fi

echo "📦 Instalando dependencias de sistema para Tauri..."
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
  policykit-1

echo ""
echo "✅ Dependencias instaladas correctamente"
echo ""
echo "🚀 Para iniciar en modo desarrollo:"
echo "   bun run tauri dev"
echo ""
echo "📦 Para compilar el release:"
echo "   bun run tauri build"
