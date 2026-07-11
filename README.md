# ⚡ Sigil Flash

**Flasheador de imágenes para Raspberry Pi** — Tauri 2 + React + Neumorphism UI

![App Icon](./src-tauri/icons/icon.png)

## ✨ Características

- 🖼️ **Drag & Drop** — Arrastra archivos `.img`, `.iso`, `.bin`
- 💾 **Detección automática** de tarjetas SD y USB extraíbles
- ⚡ **Flasheo con progreso en tiempo real** (velocidad, bytes, ETA)
- 🔒 **Seguro** — Valida que el destino sea extraíble antes de escribir
- 🎨 **Neumorphism UI** — Interfaz elegante con sombras suaves
- 📋 **Consola de logs** en tiempo real
- 🔐 **pkexec** — Solicita privilegios de admin con diálogo nativo de Polkit

## 🚀 Inicio Rápido

### 1. Instalar dependencias del sistema (solo primera vez)

```bash
bash setup.sh
```

O manualmente:

```bash
sudo apt-get install -y \
  libwebkit2gtk-4.1-dev \
  libssl-dev \
  libgtk-3-dev \
  librsvg2-dev \
  build-essential
```

### 2. Instalar dependencias de Node/Bun

```bash
bun install
```

### 3. Ejecutar en modo desarrollo

```bash
bun run tauri dev
```

### 4. Compilar para producción

```bash
bun run tauri build
```

## 🏗️ Stack Técnico

| Capa | Tecnología |
|------|-----------|
| Desktop framework | Tauri 2.0 |
| Frontend | React 18 + TypeScript |
| CSS | Vanilla CSS (Neumorphism) |
| Package manager | Bun |
| Backend | Rust |
| Flasheo | `dd` via `pkexec` |

## 📁 Estructura del Proyecto

```
sigil-flash/
├── src/                     # Frontend React
│   ├── App.tsx              # Componente raíz + estado global
│   ├── main.tsx             # Entry point React
│   ├── index.css            # Design system Neumorphism
│   └── components/
│       ├── Header.tsx       # Logo + título
│       ├── ImageSelector.tsx # Drag & drop de imágenes
│       ├── DeviceList.tsx   # Lista de dispositivos detectados
│       ├── FlashProgress.tsx # Progreso + logs
│       └── ConfirmModal.tsx # Confirmación antes de flashear
├── src-tauri/
│   ├── src/
│   │   ├── main.rs          # Entry point Tauri
│   │   └── flash.rs         # Comandos: list_devices, start_flash, etc.
│   ├── Cargo.toml
│   └── tauri.conf.json
├── setup.sh                 # Script de instalación de dependencias
└── package.json
```

## ⚙️ Comandos Rust/Tauri

| Comando | Descripción |
|---------|-------------|
| `list_devices` | Lista dispositivos USB/SD via `lsblk` |
| `get_image_info` | Retorna nombre y tamaño del archivo imagen |
| `start_flash` | Flashea via `dd` + `pkexec` con eventos de progreso |
| `cancel_flash` | Cancela el proceso de flasheo activo |

## 🔒 Seguridad

- Solo permite escribir en dispositivos **removibles** (USB, SD/MMC)
- Rechaza automáticamente discos internos del sistema
- Muestra diálogo de confirmación antes de flashear
- Usa `pkexec` (Polkit) para autenticación de root de forma segura

## 📋 Requisitos del Sistema

- Linux (Ubuntu/Debian recomendado)
- Polkit instalado (para `pkexec`)
- `dd` disponible (incluido en coreutils)
- `lsblk` disponible (incluido en util-linux)
- Rust 1.80+ (instalado automáticamente si usas `setup.sh`)
