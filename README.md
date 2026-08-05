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
- 📦 **Dependencias offline** — Construye, valida e instala el repositorio ARM64 dentro de la imagen

## Fabricación sin Internet en la Raspberry

`sigil-hardware` mantiene el contrato canónico de paquetes. SIGIL Flash resuelve
y descarga su cierre transitivo, genera el repositorio APT local, valida hashes
y arquitectura, y lo instala dentro de la imagen durante el flasheo real. El
primer arranque no instala dependencias. Consulta
[`docs/OFFLINE_PACKAGES.md`](docs/OFFLINE_PACKAGES.md) para el flujo y los
prerrequisitos de fabricación.

## 🚀 Inicio Rápido

### 1. Instalar dependencias del sistema (solo primera vez)

```bash
bash setup.sh
```

Detecta el gestor de paquetes (`apt`, `pacman`, `dnf`, `zypper` o `apk`) e instala
WebKitGTK, OpenSSL, GTK3, librsvg, herramientas de compilación, utilitarios de
disco, Polkit, QEMU estático y Rust (si falta). En distros no basadas en Debian
también instala Docker, necesario solo para construir el repositorio APT offline
de fabricación (ver [`docs/OFFLINE_PACKAGES.md`](docs/OFFLINE_PACKAGES.md)).

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

- Linux — `setup.sh` detecta y soporta Debian/Ubuntu (apt), Arch/Manjaro (pacman),
  Fedora/RHEL (dnf), openSUSE (zypper) y Alpine (apk)
- Polkit instalado (para `pkexec`)
- `dd` disponible (incluido en coreutils)
- `lsblk` disponible (incluido en util-linux)
- Rust 1.80+ (instalado automáticamente por `setup.sh` si falta `cargo`)
- Docker — solo necesario para construir el repositorio APT offline de fabricación
  en distros no basadas en Debian (`setup.sh` lo instala; ver
  [`docs/OFFLINE_PACKAGES.md`](docs/OFFLINE_PACKAGES.md))
