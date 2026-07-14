# Sigil OS — Flasher Engine Contract

> Historical architecture document. Its `device.json`, optional-field,
> combined-model, unknown-field, and default-identity descriptions are
> superseded by [DEVICE_IDENTITY_CONTRACT.md](DEVICE_IDENTITY_CONTRACT.md).
> Current implementations must use the strict canonical contract there.

**Documento:** `FLASHER_ENGINE_CONTRACT.md`  
**Versión:** 1.1.0
**Estado:** Oficial  
**Última actualización:** 2026-07-12
**Aplica a:** Sigil Flasher (GUI), flasher-rs (Engine), firstboot (Raspberry Pi)

> **Contrato operativo actual:** la interfaz implementada y validada está en
> `flasher-rs/README.md`. `flasher-rs` 0.3 acepta una imagen `.img` o `.img.xz`
> con SHA-256 obligatorio, un payload generado con manifest de integridad y un
> archivo externo `--provision`. Las referencias históricas de este documento
> a pasar JSON inline, usar directamente un checkout Git como payload o aplicar
> cambios reales no describen capacidades implementadas y no deben usarse en
> producción.

---

## Índice

1. [Arquitectura completa](#1-arquitectura-completa)
2. [Flujo completo](#2-flujo-completo)
3. [Contrato GUI → Engine](#3-contrato-gui--engine)
4. [Contrato Engine → GUI](#4-contrato-engine--gui)
5. [sigil\_provision.json](#5-sigil_provisionjson)
6. [device.json](#6-devicejson)
7. [Procedencia de la información](#7-procedencia-de-la-información)
8. [Cómo agregar un nuevo parámetro](#8-cómo-agregar-un-nuevo-parámetro)
9. [Cómo la GUI llama al Engine](#9-cómo-la-gui-llama-al-engine)
10. [Evolución y versionado](#10-evolución-y-versionado)
11. [Mapa conceptual completo](#11-mapa-conceptual-completo)
12. [Recomendaciones profesionales](#12-recomendaciones-profesionales)
13. [Regla de Oro](#13-regla-de-oro)
14. [Filosofía del Provisioning](#14-filosofía-del-provisioning)

---

## 1. Arquitectura completa

### 1.1 Diagrama de capas

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        USUARIO OPERADOR                                  │
│   (persona en línea de producción o desarrollador)                       │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 1: SIGIL FLASHER (GUI)                                            │
│                                                                         │
│  Lenguaje: Rust u otra tecnología de interfaz (debe respetar este contrato) │
│                                                                         │
│  Responsabilidades:                                                      │
│  • Selección de imagen base                                             │
│  • Selección de dispositivo SD                                          │
│  • Input del operador (serial, modelo, lote, opciones)                  │
│  • Generación de sigil_provision.json                                   │
│  • Escritura de imagen base a SD (dd)                                   │
│  • Montaje de particiones boot + rootfs                                 │
│  • Invocación del Engine                                                │
│  • Parseo de respuesta del Engine                                       │
│  • Desmontaje y sincronización                                          │
│  • Reporte al operador                                                  │
│                                                                         │
│  NO escribe personalización directamente.                               │
│  DELEGA en el Engine.                                                   │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
                       │ subprocess o FFI
                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 2: FLASHER-RS (Engine)                                            │
│                                                                         │
│  Lenguaje: Rust                                                         │
│                                                                         │
│  Comandos: plan | validate | apply | status                             │
│                                                                         │
│  Responsabilidades:                                                     │
│  • Validar paths y estructura del payload                               │
│  • Generar plan de personalización                                     │
│  • Copiar payload (panel, scripts, services, configs)                  │
│  • Crear usuario sigil con grupos y permisos                           │
│  • Configurar PulseAudio, hostapd, Bluetooth, NetworkManager           │
│  • Habilitar/deshabilitar servicios systemd                            │
│  • Configurar boot/config.txt (DAC PCM5102)                            │
│  • Inyectar sigil_provision.json en boot partition                     │
│  • Limpiar machine-id de imagen base                                   │
│  • Reportar resultado estructurado                                     │
│                                                                         │
│  NO escribe imagen a SD.                                               │
│  NO interactúa con el usuario.                                         │
│  NO detecta dispositivos automáticamente.                              │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
                       │ escribe en particiones montadas
                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 3: MICROSD (datos en disco)                                       │
│                                                                         │
│  Partición BOOT:                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ kernel.img, config.txt, cmdline.txt, *.dtb                     │    │
│  │ sigil_provision.json  ← inyectado por el Engine                │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  Partición ROOTFS:                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ /home/sigil/     → panel Flask + preferred_bt.txt               │    │
│  │ /usr/local/bin/  → scripts Sigil (+x)                           │    │
│  │ /etc/systemd/system/ → servicios Sigil                          │    │
│  │ /etc/bluetooth/  → main.conf                                   │    │
│  │ /etc/pulse/      → daemon.conf + default.pa                     │    │
│  │ /etc/hostapd/    → hostapd.conf                                │    │
│  │ /etc/sudoers.d/  → sigil-network.sudoers (440)                  │    │
│  │ /etc/NetworkManager/ → 99-sigil-mac-fixed.conf                 │    │
│  │ /var/lib/wifi-manager/ → estado WiFi                          │    │
│  │ /var/lib/sigil/  → estado Sigil                                │    │
│  │ /etc/sigil/      → panel.env placeholder (600)                 │    │
│  │ /var/log/*.log   → logs (owner sigil, 644)                     │    │
│  │ /etc/machine-id  → vacío (lo genera firstboot)                 │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                            │
                            │ (la SD se inserta en la Raspberry)
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 4: FIRSTBOOT (Raspberry Pi)                                       │
│                                                                         │
│  Servicio: sigil-firstboot.service (one-shot)                          │
│                                                                         │
│  Responsabilidades:                                                     │
│  • Leer sigil_provision.json de /boot/                                 │
│  • Generar /etc/sigil/device.json                                      │
│  • Generar /etc/sigil/panel.env con secreto único                     │
│  • Generar machine-id si está vacío                                    │
│  • Derivar hostname desde serial o cpu_serial                         │
│  • Aplicar provisioning (SSH key, factory mode)                        │
│  • Verificar permisos y ownership del payload                          │
│  • Limpiar sigil_provision.json de /boot/                              │
│  • Deshabilitar su propio servicio                                      │
│                                                                         │
│  NO instala paquetes.                                                  │
│  NO descarga nada.                                                     │
│  NO clona repos.                                                       │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 5: RUNTIME (Raspberry Pi encendida)                               │
│                                                                         │
│  Servicios activos:                                                    │
│  • bluetooth-panel.service  → lee device.json + panel.env              │
│  • bt-connect.service       → conecta Bluetooth                        │
│  • radio-stream.service     → reproduce audio                          │
│  • sigil-leds.service       → controla LEDs                            │
│  • wifi-fallback.service    → AP WiFi si no hay red                    │
│  • NetworkManager           → gestión de redes WiFi                    │
│                                                                         │
│  NO modifica device.json.                                              │
│  Lee device.json como fuente de identidad.                             │
└─────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CAPA 6: SERVIDOR (futuro, opcional)                                    │
│                                                                         │
│  • Recibe reporte de device.json                                       │
│  • Inventario de dispositivos                                           │
│  • Actualizaciones OTA                                                  │
│  • Monitoreo remoto                                                     │
│                                                                         │
│  NO modifica device.json en la Raspberry.                              │
│  Solo lectura remota.                                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Principios arquitectónicos

| Principio | Descripción |
|---|---|
| **Separación de responsabilidades** | GUI: interacción. Engine: personalización. Firstboot: identidad. |
| **Engine sin UI** | El Engine nunca pregunta nada al usuario. Recibe todo por argumentos. |
| **GUI sin personalización** | La GUI nunca copia archivos ni configura servicios. Delega en el Engine. |
| **Firstboot mínimo** | Solo hace lo que requiere hardware real (machine-id, secretos, MAC). |
| **Sin red en firstboot** | Firstboot no descarga ni instala nada. Todo viene preinstalado. |
| **Sin secretos en imagen** | Los secretos (panel.env) se generan en firstboot, no vienen en la imagen. |
| **Contrato JSON estable** | La comunicación GUI ↔ Engine usa JSON. El contrato se versiona. |

---

## 2. Flujo completo

### 2.1 Paso a paso (FLASH → firstboot)

| # | Componente | Acción | Detalle |
|---|---|---|---|
| 1 | **Usuario** | Abre Sigil Flasher | GUI lista |
| 2 | **Usuario** | Selecciona imagen base | Navegador de archivos → `.img` o `.img.xz` |
| 3 | **Usuario** | Selecciona SD | Dropdown con dispositivos de bloque |
| 4 | **Usuario** | Introduce serial | Campo de texto o autogenerado |
| 5 | **Usuario** | Selecciona modelo | Dropdown (ej: Sigil-Streamer-v1) |
| 6 | **Usuario** | Introduce lote | Campo de texto |
|  7 | **Usuario** | Configura opciones | Audio (DAC/HDMI/Jack), hostname inicial (opcional) |
| 8 | **GUI** | Genera sigil_provision.json | Construye JSON desde los campos del formulario |
| 9 | **GUI** | Ejecuta `flasher-rs status` | Verifica que el Engine esté disponible |
| 10 | **GUI** | Ejecuta `flasher-rs validate` | Valida paths de imagen y payload |
| 11 | **GUI** | Muestra errores si falla | Si validación falla → detiene el flujo |
| 12 | **GUI** | **Escribe imagen base a SD** | `dd if=base.img of=/dev/sdX bs=4M status=progress` |
| 13 | **GUI** | Monta partición boot | mount /dev/sdX1 /mnt/sigil/boot |
| 14 | **GUI** | Monta partición rootfs | mount /dev/sdX2 /mnt/sigil/rootfs |
| 15 | **GUI** | Ejecuta `flasher-rs apply` | Engine personaliza rootfs + inyecta provision en boot |
| 16 | **Engine** | Valida entradas | Verifica paths, estructura del payload |
| 17 | **Engine** | Aplica personalización | Copia payload, crea usuario, configura servicios, etc. |
| 18 | **Engine** | Inyecta sigil_provision.json | Escribe JSON en `/mnt/sigil/boot/sigil_provision.json` |
| 19 | **Engine** | Reporta resultado | JSON con éxito/fallo + detalles |
| 20 | **GUI** | Lee resultado | Si falló → muestra error. Si ok → continúa |
| 21 | **GUI** | Sincroniza y desmonta | sync; umount /mnt/sigil/boot; umount /mnt/sigil/rootfs |
| 22 | **GUI** | Reporta éxito | Muestra resumen al operador |
| 23 | **Usuario** | Extrae SD | Inserta en Raspberry Pi |
| 24 | **Raspberry** | Arranca | Carga kernel, systemd, monta rootfs |
| 25 | **Firstboot** | sigil-firstboot.service | One-shot, se ejecuta una vez |
| 26 | **Firstboot** | Lee provision | `/boot/firmware/sigil_provision.json` |
| 27 | **Firstboot** | Genera machine-id | systemd-machine-id-setup o equivalente |
| 28 | **Firstboot** | Genera device.json | `/etc/sigil/device.json` con todos los campos |
| 29 | **Firstboot** | Genera panel.env | `/etc/sigil/panel.env` con SIGIL_SECRET_KEY único |
| 30 | **Firstboot** | Aplica hostname | hostnamectl set-hostname |
|  31 | **Firstboot** | Aplica SSH si aplica | Instala clave pública si se configuró SSH en el sistema |
| 32 | **Firstboot** | Limpia provision | Borra `/boot/firmware/sigil_provision.json` |
| 33 | **Firstboot** | Deshabilita su servicio | systemctl disable sigil-firstboot |
| 34 | **Runtime** | Servicios Sigil arrancan | Panel web, Bluetooth, radio, LEDs, WiFi |
| 35 | **Runtime** | Servicios leen device.json | Identidad del dispositivo disponible |

### 2.2 Diagrama de secuencia

```
USUARIO     GUI              ENGINE           SD              RASPBERRY
   │          │                 │               │                 │
   │─abre────▶│                 │               │                 │
   │─imagen──▶│                 │               │                 │
   │─serial──▶│                 │               │                 │
   │─modelo──▶│                 │               │                 │
   │─FLASH───▶│                 │               │                 │
   │          │──validate──────▶│               │                 │
   │          │◀──────OK───────│               │                 │
   │          │──dd imagen─────│──────────────▶│                 │
   │          │──mount────────│──────────────▶│                 │
   │          │──apply────────▶│               │                 │
   │          │                 │──copia──────▶│                 │
   │          │                 │──config─────▶│                 │
   │          │                 │──provision──▶│                 │
   │          │◀────resultado──│               │                 │
   │          │──umount───────│──────────────▶│                 │
   │◀──listo─│                 │               │                 │
   │                                                            │
   │────extrae SD──────────────────────────────────────────────▶│
   │                                                            │
   │                                                 ──boot────▶│
   │                                                 firstboot─▶│
   │                                                 device.json│
   │                                                 runtime───▶│
```

---

## 3. Contrato GUI → Engine

### 3.1 Parámetros del Engine

La GUI invoca al Engine como subproceso. Los parámetros se pasan por línea de comandos:

| Parámetro | Obligatorio | Tipo | Ejemplo | Propósito |
|---|---|---|---|---|
| `--base-image` | **Sí** | path | `2026-06-18-raspios-trixie-arm64-lite.img.xz` | Imagen `.img` o `.img.xz` inmutable |
| `--base-image-sha256` | **Sí** | hex | `acff…b3` | SHA-256 esperado del archivo exacto de imagen |
| `--payload` | **Sí** | path | `artifacts/payloads/sigil-hardware-payload` | Payload generado; nunca un checkout Git |
| `--target-device` | No | path | `/dev/sda` | Referencia del dispositivo SD (no se escribe) |
| `--provision` | No | path | `/tmp/provision.json` | Archivo de provisioning generado por GUI |
| `--dry-run` | No | flag | — | Impide cualquier escritura (solo plan) |

### 3.2 Reglas de parámetros

1. `--base-image` **siempre es obligatorio** para `plan`, `validate` y `apply`
2. `--base-image-sha256` **siempre es obligatorio** y debe coincidir con el archivo exacto
3. `--payload` **siempre es obligatorio** y debe contener `payload-manifest.json`
4. `--provision` es un archivo externo; identidad o secretos no se pasan inline en argv
5. `--dry-run` es **obligatorio** para `apply` mientras no exista un escritor privilegiado
6. Sin `--provision`, el Engine avisa que la identidad de fábrica no fue validada

### 3.3 Formato de sigil_provision.json

La GUI genera este JSON. Nunca se lo pide al usuario. El usuario llena formularios.

```json
{
  "_schema_version": "1.0",

  "serial_number": "SIGIL-Z2W-2026-0001",
  "model": "Sigil-Streamer-v1",
  "batch": "LOTE-2026-A",
  "hostname": "sigil-0001",

  "capabilities": {
    "i2s_dac": true
  },

  "config": {
    "audio": "dac",
    "dtoverlay": "hifiberry-dac",
    "dtparam_audio": "off"
  }
}
```

### 3.4 Provisioning externo

El provisioning se entrega únicamente mediante `--provision <PATH>`. Esto evita
que identidad futura o material sensible aparezca en argv o listados de procesos.
El Engine valida tamaño, JSON, versión y los campos requeridos antes de aceptar el
archivo.

---

## 4. Contrato Engine → GUI

### 4.1 Códigos de salida

| Código | Significado | Acción recomendada en GUI |
|---|---|---|
| `0` | Éxito | Continuar flujo |
| `1` | Error de validación | Mostrar errores al usuario, detener |
| `2` | Error de argumentos CLI | Mostrar uso, detener (bug de integración) |
| `3` | Error interno del Engine | Mostrar "Error interno", reportar bug |

### 4.2 Salida stdout (modo texto, por defecto)

Cada comando produce texto formateado para humanos:

**`plan`**: 18 secciones con descripciones detalladas, finaliza con `NO CHANGES MADE: DRY-RUN`

**`validate`**: lista items con `[ERROR]`, `[WARNING]`, `[INFO]`, finaliza con `PASSED` o `FAILED`

**`apply --dry-run`**: igual que `plan` pero con header `APPLY (dry-run)`

**`apply`** (futuro): reporta cada paso completado, finaliza con `SUCCESS` o `FAILED`

**`status`**: lista capacidades, paquetes, servicios

### 4.3 Salida stdout (modo JSON, con --json)

Cada comando produce un objeto JSON único en stdout. La GUI parsea este JSON.

#### 4.3.1 `status --json`

```json
{
  "command": "status",
  "success": true,
  "engine": "sigil-flasher-engine",
  "version": "0.2.0",
  "phase": "Phase 2 — behavior model (dry-run only)",
  "capabilities": ["plan", "validate", "apply", "status"],
  "core_packages_count": 22,
  "services_enable": [
    "NetworkManager", "bluetooth-panel", "bt-connect",
    "radio-stream", "sigil-leds", "wifi-fallback"
  ],
  "services_disable": ["hostapd", "dnsmasq"]
}
```

#### 4.3.2 `validate --json`

```json
{
  "command": "validate",
  "success": true,
  "valid": true,
  "items": [
    {
      "severity": "INFO",
      "code": "BASE_IMAGE_FOUND",
      "message": "Base image found at /mnt/sigil/rootfs"
    },
    {
      "severity": "WARNING",
      "code": "PAYLOAD_SUBDIR_MISSING",
      "message": "payload/panel/ not found"
    }
  ],
  "error_count": 0,
  "warning_count": 1
}
```

#### 4.3.3 `plan --json`

```json
{
  "command": "plan",
  "success": true,
  "title": "Sigil OS customization plan",
  "sections": [
    {
      "title": "APT PACKAGES",
      "lines": ["Core (22): python3, ...", "Optional (1): openssh-server"]
    },
    {
      "title": "USER AND GROUPS",
      "lines": [
        "would create user sigil (UID 1001, ...)",
        "would set password sigil:sigil1234 ..."
      ]
    }
  ],
  "section_count": 18,
  "dry_run": true
}
```

#### 4.3.4 `apply --json`

```json
{
  "command": "apply",
  "success": true,
  "dry_run": true,
  "sections": [
    { "title": "...", "lines": ["..."] }
  ],
  "steps_completed": 0,
  "steps_total": 18,
  "message": "Validation passed. Plan generated. No changes made (dry-run)."
}
```

#### 4.3.5 Error genérico

```json
{
  "command": "validate",
  "success": false,
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Base image not found",
    "details": "/path/not/found does not exist"
  }
}
```

### 4.4 Salida stderr (siempre texto)

stderr se reserva para:
- Mensajes de diagnóstico humano
- Logs de debug (si `RUST_LOG=debug`)
- Advertencias de compilación

La GUI **no debe parsear stderr**. Solo debe mostrarlo al usuario si hay un error.

### 4.5 Códigos de error predefinidos

| Código | Comando | Significado |
|---|---|---|
| `VALIDATION_FAILED` | validate, apply | Uno o más errores de validación |
| `ARGUMENT_MISSING` | todos | Falta un argumento obligatorio |
| `ARGUMENT_INVALID` | todos | Argumento con formato inválido |
| `DRY_RUN_REQUIRED` | apply | Faltó `--dry-run` en Phase 2 |
| `PAYLOAD_INCOMPLETE` | apply | Falta panel/, scripts/, services/ o conf/ |
| `INTERNAL_ERROR` | todos | Error inesperado del Engine |

---

## 5. sigil\_provision.json

### 5.1 Propósito

`sigil_provision.json` es el archivo que viaja en la partición boot de la SD.  
Su propósito es comunicar **la identidad deseada del dispositivo** desde el PC operador hasta la Raspberry Pi.

Vive temporalmente en boot y es consumido por firstboot.

### 5.2 Cómo se genera

El archivo puede generarse de tres formas:

#### 5.2.1 Generación automática por la GUI (caso principal)

La GUI presenta formularios al operador:

```
```
┌─────────────────────────────────────┐
│  SIGIL FLASHER — Provisioning       │
│                                     │
│  Serial: [SIGIL-Z2W-2026-0042]     │
│  Modelo: [Sigil-Streamer-v1    ▼]  │
│  Lote:   [LOTE-2026-A]             │
│  Hostname: [sigil-0042]            │
│                                     │
│  Audio:  [DAC PCM5102          ▼]  │
│                                     │
│  [CANCEL]              [FLASH]      │
└─────────────────────────────────────┘
```
```

La GUI construye el JSON internamente. El operador nunca ve JSON.

> **Nota sobre WiFi AP:** El dispositivo crea automáticamente una red inicial con SSID
> `Sigil` para que el operador acceda al panel de configuración desde el móvil o PC.
> El SSID y la clave NO se configuran en fábrica. El usuario puede cambiarlos más adelante
> desde la aplicación si el proyecto lo requiere.


#### 5.2.2 Edición manual por el operador

Un operador avanzado puede editar el archivo directamente en la SD montada:

```bash
# Después de flashear, antes de desmontar:
nano /mnt/sigil/boot/sigil_provision.json
```


Campos que puede editar:
- `serial_number` — cambiar identificador
- `hostname` — personalizar nombre de red
- `config.*` — ajustar configuración de hardware
- `factory_mode` — modo fábrica/QA (opcional, no afecta identidad del dispositivo)

Campos que **no debe** editar:
- `_schema_version` (interno)
- `model` (debe coincidir con producción)
- `batch` (trazabilidad)

#### 5.2.3 Sin archivo (modo default)

Si no hay `sigil_provision.json`, firstboot genera valores por defecto:

```json
{
  "serial_number": "SIGIL-UNKNOWN-<CPU_SERIAL_ABR>",
  "model": "Sigil-Streamer-v1",
  "batch": "DEFAULT"
}
```

### 5.3 Formato oficial

```json
{
  "_schema_version": "1.0",

  "serial_number": "SIGIL-Z2W-2026-0001",
  "model": "Sigil-Streamer-v1",
  "batch": "LOTE-2026-A",
  "hostname": "sigil-0001",

  "config": {
    "audio": "dac",
    "dtoverlay": "hifiberry-dac",
    "dtparam_audio": "off"
  }
}
```

### 5.4 Reglas de validación del JSON

| Condición | Acción |
|---|---|
| JSON mal formado | Engine rechaza con error |
| `serial_number` ausente | Engine asigna default |
| `model` ausente | Engine rechaza con error |
| `batch` ausente | Engine asigna "DEFAULT" |
| `capabilities.i2s_dac` presente y no booleano | Engine rechaza con error |
| `capabilities.i2s_dac: true` | Instalador habilita `hifiberry-dac` y persiste `SIGIL_I2S_DAC_PRESENT=1` |
| Capacidad ausente | Solo `Sigil-Streamer-v1` usa el mapping legacy; los demás quedan en `0` |
| Campo desconocido presente | Engine lo ignora (compatibilidad futura) |
| Archivo > 4KB | Engine rechaza con error |
| UTF-8 con BOM | Engine rechaza con error |
| Final de línea CRLF | Engine lo tolera, normaliza a LF |

### 5.5 Cómo la GUI NO debe pedir editar JSON

❌ **Mal:** Una caja de texto donde el usuario escribe JSON.

✅ **Bien:** Formularios con campos tipados y validación.

La GUI nunca debe mostrar el JSON al usuario a menos que sea:
- Modo desarrollador explícito (toggle oculto)
- Diagnóstico de errores


### 5.6 Seguridad

1. **`sigil_provision.json` no contiene secretos permanentes.** Solo transporta identidad y configuración de fábrica.
2. **`panel.env`** es el archivo designado para secretos runtime (claves API, tokens).
3. **`device.json` no almacena secretos.** Solo identidad y trazabilidad.
4. Si existe una contraseña temporal de fábrica (ej: para WiFi AP), debe ser tratada como **temporal** y nunca como secreto permanente.
5. Las contraseñas WiFi del usuario se gestionan en runtime a través de NetworkManager, no en el provisioning.

### 5.7 Limitación de detección física de audio

La existencia de una tarjeta ALSA o sink PulseAudio `hifiberry-dac` no demuestra
que el PCM5102A esté físicamente instalado. Un probe silencioso solo demuestra
que PulseAudio acepta frames. El PCM5102A tampoco puede detectar por sí mismo un
amplificador, speaker o cable conectado. La presencia física real requiere una
señal adicional de hardware, como GPIO de presencia, jack detect o una salida de
presencia/fallo del amplificador.

### 5.7 Opciones de fábrica

El contrato v1.0 incluye los siguientes parámetros opcionales de fábrica:

- **`factory_mode`**: booleano opcional. Cuando está presente y es `true`, indica que el
  dispositivo debe arrancar en modo fábrica/QA/laboratorio. No forma parte de la identidad
  del dispositivo. Puede desaparecer o ampliarse en versiones futuras.

> **Nota sobre `enable_ssh`:** Este parámetro no forma parte del contrato v1.0.
> Pertenece a la configuración del sistema, no a la identidad del dispositivo.
> Podría agregarse posteriormente mediante una extensión del contrato sin romper
> compatibilidad hacia atrás.

---

## 6. device.json

### 6.1 Propósito

`/etc/sigil/device.json` es el archivo de identidad permanente del dispositivo.  
Contiene toda la información que los servicios runtime necesitan para identificarse.

### 6.2 Quién lo crea

**Firstboot** (`sigil-firstboot.service`) lo crea durante el primer arranque.
La GUI puede enviar un **hostname inicial (opcional)** en el provisioning. Si existe, Firstboot puede utilizarlo. Si no existe, Firstboot genera automáticamente uno (derivado del serial_number o por defecto). El hostname podrá modificarse posteriormente desde runtime si el usuario lo desea.

```json
{
  "serial_number": "SIGIL-Z2W-2026-0001",
  "model": "Sigil-Streamer-v1",
  "batch": "LOTE-2026-A",
  "cpu_serial": "000000001a2b3c4d",
  "wifi_mac": "e4:5f:01:ab:cd:ef",
  "machine_id": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
  "hostname": "sigil-0001",
  "provisioned": true,
  "provisioned_at": "2026-07-01T12:00:00Z",
  "_schema_version": "1.0"
}
```

### 6.3 Quién lo modifica

**Nadie en runtime.** El archivo es inmutable después de firstboot.

Excepciones:
- **root** (SSH física) puede editarlo manualmente para correcciones
- **Factory reset** puede regenerarlo desde sigil_provision.json
- **Actualización de firmware** (futuro) puede modificarlo

### 6.4 Quién lo lee

| Componente | Cuándo |
|---|---|
| `bluetooth-panel.service` | Al iniciar, para identificar el dispositivo |
| `bt-connect.service` | Para logging con serial |
| Cualquier script Sigil | Para reportar identidad |
| Servidor central (futuro) | Para inventario remoto |

### 6.5 Quién nunca debe modificarlo

- **Los servicios runtime** no deben modificar `device.json` bajo ninguna circunstancia
- **El usuario** no debe editarlo salvo emergencia
- **El servidor** no tiene permiso de escritura en la Raspberry

### 6.6 Ciclo de vida

```
PROVISION JSON (boot, temporal)          DEVICE JSON (etc/sigil, permanente)
┌──────────────────────────────┐         ┌──────────────────────────────┐
│ serial_number                │────┐    │ serial_number                │
│ model                        │────┤    │ model                        │
│ batch                        │────┤    │ batch                        │
│ hostname                     │────┤    │ hostname                     │
│ config.audio                 │────┤    │ cpu_serial   ← /proc/cpuinfo │
│ config.dtoverlay             │────┤    │ wifi_mac     ← wlan0         │
│ config.dtparam_audio         │────┤    │ machine_id   ← /etc/machine  │
│ _schema_version              │    │    │ provisioned  ← true          │
└──────────────────────────────┘    │    │ provisioned_at ← timestamp   │
                                    │    └──────────────────────────────┘
                                    │               ▲
                                    │               │
                                    └───▶ firstboot combina:
                                         provision + hardware + tiempo
```


### 6.7 Dirección MAC estable

Raspberry Pi OS puede utilizar direcciones MAC aleatorias por interfaz de red
(randomización de privacidad). Para que `device.json` refleje una identidad
de red consistente, **Sigil OS fuerza una MAC estable** mediante la
configuración de NetworkManager:

```
/etc/NetworkManager/99-sigil-mac-fixed.conf
[connection]
wifi.cloned-mac-address=permanent
ethernet.cloned-mac-address=permanent
```

Este archivo se inyecta durante el flashing por el Engine.
`device.json` almacena la MAC real (permanente) leída durante firstboot desde la interfaz `wlan0`.

---

## 7. Procedencia de la información

### 7.1 Tabla de procedencia

| Campo | Lo escribe | Lo utiliza | ¿Puede cambiar después? |
|---|---|---|---|
| `serial_number` | GUI → Engine (inyecta) → Firstboot (hereda) | Firstboot, Runtime | No (identidad) |
| `model` | GUI → Engine (inyecta) → Firstboot (hereda) | Firstboot, Runtime | No (identidad) |
| `batch` | GUI → Engine (inyecta) → Firstboot (hereda) | Firstboot | No (trazabilidad) |
| `hostname` | GUI (opcional) → Firstboot decide | Runtime | Sí (post-firstboot) |
| `cpu_serial` | Hardware (/proc/cpuinfo) → Firstboot lee | Runtime | No (hardware) |
| `wifi_mac` | Hardware (wlan0) → Firstboot lee | Runtime | No (hardware) |
| `machine_id` | Firstboot genera (systemd-machine-id-setup) | Sistema, journal | No |
| `provisioned` | Firstboot escribe `true` | Runtime (diagnóstico) | No |
| `provisioned_at` | Firstboot escribe timestamp | Runtime (diagnóstico) | No |
| `panel.env` | Firstboot genera secreto único | Servicios runtime | Sí (regenerable por admin) |
| `config.audio` | GUI (selector) → Engine aplica | Capa física | No (decisión de hardware) |
| `config.dtoverlay` | GUI (selector) → Engine aplica | Capa física | No (decisión de hardware) |
| `config.dtparam_audio` | GUI (selector) → Engine aplica | Capa física | No (decisión de hardware) |

### 7.2 Reglas estrictas

1. **La GUI nunca personaliza.** Solo escribe imagen, monta, llama al Engine, desmonta, reporta.
2. **El Engine nunca interactúa con el usuario.** Solo recibe paths, produce resultados.
3. **La Raspberry nunca descarga.** Todo viene preinstalado en la SD.
4. **El firstboot nunca instala paquetes.** Solo finaliza identidad y secretos.
5. **El servidor nunca escribe en la Raspberry.** Solo recibe reportes.
6. **El hardware siempre dice la verdad.** cpu_serial y MAC son autoritativos.

## 8. Cómo agregar un nuevo parámetro

### 8.1 Proceso paso a paso

Agregar un nuevo parámetro requiere cambios en 4 capas.  
Ejemplo concreto: agregar **`timezone`** (zona horaria del dispositivo).

### 8.2 Paso 1: Agregar campo en el contrato

**Archivo:** `docs/FLASHER_ENGINE_CONTRACT.md`

Agregar a la tabla de campos de sigil_provision.json:

```
| `timezone` | string | No | `"America/Argentina/Buenos_Aires"` | Zona horaria del dispositivo |
```

### 8.3 Paso 2: Agregar control en la GUI

La GUI agrega un nuevo campo en el formulario:

```
┌─────────────────────────────────────┐
│  Zona horaria: [America/Argentina…▼]│
└─────────────────────────────────────┘
```

La GUI incluye el campo en el JSON generado:

```json
{
  "serial_number": "...",
  "timezone": "America/Argentina/Buenos_Aires",
  ...
}
```

### 8.4 Paso 3: Agregar lógica en el Engine

El Engine debe:
1. Leer el campo `timezone` del JSON de provision
2. Incluirlo en el plan (salida `plan`)
3. Validar que el valor sea una zona horaria válida
4. Aplicarlo: crear symlink `/etc/localtime` -> `/usr/share/zoneinfo/<timezone>`

En el plan:

```
=== TIMEZONE ===
  would set timezone to America/Argentina/Buenos_Aires
  would create symlink /etc/localtime -> /usr/share/zoneinfo/America/Argentina/Buenos_Aires
```

### 8.5 Paso 4: Agregar lógica en firstboot

Si el parámetro requiere información de hardware (raro para timezone), firstboot lo procesa. En este caso, el Engine ya lo aplica offline, así que firstboot solo lo verifica.

### 8.6 Ficheros que tocar (solo referencia, no implementar)

| Capa | Archivo | Cambio |
|---|---|---|
| Contrato | `docs/FLASHER_ENGINE_CONTRACT.md` | Documentar campo |
| GUI | (futuro) | Agregar campo al formulario |
| Engine | `src/model.rs` | Agregar a constantes/rutas de provision |
| Engine | `src/plan.rs` | Agregar sección al plan |
| Engine | `src/apply.rs` (futuro) | Ejecutar cambio offline |
| Firstboot | (futuro) | Verificar/heredar en runtime |

### 8.7 Reglas para nuevos parámetros

1. **Campos opcionales siempre.** Nunca rompas versiones anteriores que no tienen el campo.
2. **Default sensato.** Si el campo falta, el comportamiento debe ser razonable.
3. **Validación en el Engine.** El Engine valida, no la GUI exclusivamente.
4. **Documentación primero.** Documenta antes de implementar.

### 8.8 Ejemplos de parámetros futuros

| Parámetro | Tipo | Default | Capa que aplica |
|---|---|---|---|
| `timezone` | string | `"UTC"` | Engine (offline) |
| `language` | string | `"en_US.UTF-8"` | Engine (offline) |
| `audio_output` | enum | `"dac"` | Engine (offline) |
| `vpn_enabled` | bool | `false` | Engine (offline) + firstboot |
| `cloud_url` | string | `""` | Engine (inyecta en config) |
| `license_key` | string | `""` | Firstboot (por seguridad) |
| `ntp_server` | string | `"pool.ntp.org"` | Engine (offline) |

---

## 9. Cómo la GUI llama al Engine

### 9.1 Modo CLI (Phase 2, hoy)

La GUI invoca al Engine como subproceso:

```python
import subprocess
import json

def call_engine(command, base_image, payload, target_device=None, provision_json=None, dry_run=False):
    args = [
        "/usr/bin/flasher-rs",
        command,
        "--base-image", base_image,
        "--payload", payload,
    ]

    if target_device:
        args += ["--target-device", target_device]

    if provision_json:
        # Usar inline JSON para evitar archivos temporales
        args += ["--provision-json", json.dumps(provision_json)]

    if dry_run or command == "plan":
        args += ["--dry-run"]

    # Ejecutar
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=120
    )

    if result.returncode == 0:
        return {"success": True, "output": result.stdout}
    else:
        return {
            "success": False,
            "error": result.stderr.strip(),
            "returncode": result.returncode
        }

# Ejemplo de uso:
result = call_engine(
    command="validate",
    base_image="/mnt/sigil/rootfs",
    payload="/opt/sigil-hardware",
    provision_json={
        "serial_number": "SIGIL-Z2W-2026-0001",
        "model": "Sigil-Streamer-v1",
        "batch": "LOTE-2026-A"
    }
)
```

### 9.2 Modo JSON (Phase 3, recomendado)

```python
def call_engine_json(command, **kwargs):
    args = [command, "--json"]  # ← activa salida JSON

    for key, value in kwargs.items():
        cli_key = "--" + key.replace("_", "-")
        args += [cli_key, str(value)]

    result = subprocess.run(["/usr/bin/flasher-rs"] + args, ...)

    # Parsear stdout como JSON
    response = json.loads(result.stdout)

    if response["success"]:
        return response
    else:
        raise EngineError(response["error"])
```

### 9.3 Modo futuro (shared library)

```python
# Load flasher engine as shared library
import ctypes
lib = ctypes.CDLL("/usr/lib/libflasher_engine.so")

# Define structs and call directly
# (requiere bindings, no implementado aún)
```

Este modo es para cuando el rendimiento del subprocess sea un cuello de botella. No implementar hasta tener datos que lo justifiquen.

### 9.4 Ejemplos completos CLI

```bash
# 1. Verificar que el Engine funciona
flasher-rs status

# 2. Validar inputs antes de escribir SD
flasher-rs validate \
  --base-image /home/ubuntu/raspios-lite.img \
  --payload /home/ubuntu/sigil-hardware \
  --provision-json '{"serial_number":"SIGIL-Z2W-2026-0001","model":"Sigil-Streamer-v1","batch":"LOTE-2026-A"}'

# 3. Ver plan antes de aplicar
flasher-rs plan \
  --base-image /home/ubuntu/raspios-lite.img \
  --payload /home/ubuntu/sigil-hardware

# 4. Aplicar personalización (después de escribir imagen y montar)
flasher-rs apply \
  --base-image /mnt/sigil/rootfs \
  --payload /home/ubuntu/sigil-hardware \
  --target-device /dev/sda \
  --provision-json '{"serial_number":"SIGIL-Z2W-2026-0001","model":"Sigil-Streamer-v1","batch":"LOTE-2026-A"}'
```

---

## 10. Evolución y versionado

### 10.1 Versionado del contrato

El contrato se versiona mediante el campo `_schema_version`:

| Versión | Cambios |
|---|---|
| `1.0` | Versión inicial. Campos: serial, model, batch, hostname, config.audio, config.dtoverlay, config.dtparam_audio |

### 10.2 Reglas de compatibilidad

| Tipo de cambio | Versión mayor | Versión menor | Ejemplo |
|---|---|---|---|
| Agregar campo opcional | No cambia | +1 | Agregar `timezone` → 1.1 |
| Agregar campo obligatorio | +1 | 0 | Nueva versión con campo que no puede faltar → 2.0 |
| Cambiar tipo de campo | +1 | 0 | `serial_number` de string a objeto → 2.0 |
| Eliminar campo | +1 | 0 | Eliminar `wifi_ap_password` → 2.0 |
| Renombrar campo | +1 | 0 | `batch` → `manufacturing_batch` → 2.0 |

### 10.3 Cómo agregar nuevos campos sin romper versiones anteriores

1. **El campo debe ser opcional.** Si falta, el Engine usa un default.
2. **El Engine ignora campos que no reconoce.** Así una versión nueva del JSON funciona con Engine viejo.
3. **El firstboot ignora campos que no reconoce.** Así provision nuevo funciona con firstboot viejo.

### 10.4 Estrategia de evolución

```
v1.0 (ahora)
├── serial, model, batch, hostname
├── config.audio, config.dtoverlay, config.dtparam_audio

v1.1 (futuro próximo)
├── + timezone, language, ntp_server

v1.2 (futuro medio)
├── + vpn_enabled, cloud_url

v2.0 (solo si hay breaking changes)
├── Requiere migración explícita
```

---

## 11. Mapa conceptual completo

```
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  USUARIO                                                                                   │
│  (operador de línea de producción)                                                         │
│                                                                                            │
│  ● Selecciona imagen base                                                                  │
│  ● Selecciona SD                                                                           │
│  ● Ingresa serial, modelo, lote                                                            │
│  ● Configura opciones (audio, hostname inicial)                                            │
│  ● Presiona FLASH                                                                          │
│                                                                                            │
└────────────────────────┬───────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  GUI (Sigil Flasher)                                                                       │
│                                                                                            │
│  ● Valida inputs localmente                                                                │
│  ● Genera sigil_provision.json                                                             │
│  ● Escribe imagen base a SD (dd)                                                           │
│  ● Monta boot + rootfs                                                                     │
│  ● Llama al Engine (subprocess)                                                            │
│  ● Lee resultado del Engine                                                                │
│  ● Desmonta                                                                                │
│  ● Reporta al usuario                                                                      │
│                                                                                            │
│  Salida: SD con imagen base escrita y particiones montadas                                │
│                                                                                            │
└────────────────────────┬───────────────────────────────────────────────────────────────────┘
                         │
                         │ flasher-rs <command> [options]
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  ENGINE (flasher-rs)                                                                       │
│                                                                                            │
│  ● Valida paths y estructura del payload                                                   │
│  ● Plan: genera plan de personalización (18 secciones)                                    │
│  ● Validate: verifica inputs                                                               │
│  ● Apply: ejecuta personalización offline:                                                 │
│      ├── Copia panel → /home/sigil/                                                        │
│      ├── Copia scripts → /usr/local/bin/ (+x)                                             │
│      ├── Copia services → /etc/systemd/system/                                             │
│      ├── Copia configs → rutas destino                                                     │
│      ├── Crea usuario sigil (UID 1001, grupos, password)                                  │
│      ├── Crea state directories y state files                                              │
│      ├── Crea log files con ownership                                                        │
│      ├── Configura PulseAudio (module-switch-on-connect)                                   │
│      ├── Configura hostapd (DAEMON_CONF)                                                   │
│      ├── Unmask + disable hostapd/dnsmasq                                                  │
│      ├── Enable servicios Sigil                                                           │
│      ├── Configura boot/config.txt (DAC PCM5102)                                           │
│      ├── Limpia machine-id                                                                 │
│      ├── Crea panel.env placeholder                                                         │
│      └── Inyecta sigil_provision.json en boot                                               │
│  ● Status: reporta capacidades                                                             │
│                                                                                            │
│  Salida: stdout (texto o JSON) + exit code                                                │
│                                                                                            │
└────────────────────────┬───────────────────────────────────────────────────────────────────┘
                         │
                         │ (escribe en particiones montadas)
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  BOOT PARTITION (SD)                     ROOTFS PARTITION (SD)                             │
│  ┌──────────────────────┐                ┌──────────────────────┐                          │
│  │ config.txt           │                │ /home/sigil/          │                          │
│  │ sigil_provision.json │                │ /usr/local/bin/       │                          │
│  │ kernel*.img          │                │ /etc/systemd/system/  │                          │
│  │ *.dtb                │                │ /etc/bluetooth/       │                          │
│  └──────────────────────┘                │ /etc/pulse/           │                          │
│                                          │ /etc/hostapd/         │                          │
│                                          │ /etc/sudoers.d/       │                          │
│                                          │ /etc/NetworkManager/  │                          │
│                                          │ /var/lib/wifi-manager │                          │
│                                          │ /var/lib/sigil/       │                          │
│                                          │ /etc/sigil/           │                          │
│                                          │ /var/log/*.log        │                          │
│                                          │ /etc/machine-id (vacío)│                         │
│                                          └──────────────────────┘                          │
└────────────────────────────────────────────────────────────────────────────────────────────┘
                         │
                         │ (SD insertada en Raspberry Pi)
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  FIRSTBOOT (Raspberry Pi)                                                                  │
│                                                                                            │
│  ● Lee sigil_provision.json de /boot/                                                      │
│  ● Genera machine-id único                                                                 │
│  ● Crea /etc/sigil/device.json:                                                            │
│      ├── serial, model, batch ← del provision                                              │
│      ├── cpu_serial ← /proc/cpuinfo                                                        │
│      ├── wifi_mac ← wlan0                                                                  │
│      ├── machine_id ← recién generado                                                      │
│      ├── hostname ← derivado o fijo                                                        │
│      └── provisioned_at ← timestamp                                                        │
│  ● Crea /etc/sigil/panel.env con secreto real                                              │
│  ● Aplica hostname                                                                         │
│  ● Aplica SSH si enable_ssh=true                                                           │
│  ● Limpia sigil_provision.json de /boot/                                                   │
│  ● Deshabilita sigil-firstboot.service                                                     │
│  ● Reinicia servicios Sigil                                                               │
│                                                                                            │
└────────────────────────┬───────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  RUNTIME (Raspberry Pi encendida)                                                          │
│                                                                                            │
│  ● bluetooth-panel.service → lee device.json + panel.env                                  │
│  ● bt-connect.service      → conecta Bluetooth según preferred_bt.txt                     │
│  ● radio-stream.service    → reproduce audio                                               │
│  ● sigil-leds.service      → controla LEDs                                                 │
│  ● wifi-fallback.service   → AP WiFi si no hay red                                         │
│  ● NetworkManager          → gestiona WiFi                                                  │
│  ● Todos los servicios usan device.json para identidad                                    │
│                                                                                            │
└────────────────────────┬───────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
│  SERVIDOR (futuro, opcional)                                                               │
│                                                                                            │
│  ● Recibe reporte de device.json desde la Raspberry                                       │
│  ● Mantiene inventario de dispositivos                                                     │
│  ● Provee actualizaciones OTA                                                              │
│  ● Monitoreo remoto                                                                        │
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 12. Recomendaciones profesionales

### 12.1 Arquitectura de integración recomendada

En orden de prioridad:

| Enfoque | Cuándo usarlo |
|---|---|
| **Subprocess + JSON** | Fase 3 inmediata. Simple, debuggeable, sin dependencias extra. |
| **Inline provision JSON** | Siempre. Evita archivos temporales, más limpio. |
| **Shared library (FFI)** | Solo si el subprocess demuestra ser cuello de botella en producción. |
| **Unix socket daemon** | Solo si se necesita flashear múltiples dispositivos en lote sin reiniciar el Engine. |

### 12.2 Mejoras concretas para la Fase 3

1. **Agregar flag `--json`** a todos los comandos del Engine
2. **Agregar flag `--provision-json`** para pasar JSON inline
3. **Definir códigos de error estables** (la tabla de la sección 4.5)
4. **El Engine debe ignorar campos desconocidos** en sigil_provision.json (forward compatibility)

### 12.3 Mejoras para la GUI

1. **Validar antes de escribir.** La GUI debe llamar a `validate` antes de `dd`, no después.
2. **Cachear el resultado de `status`.** La GUI debe verificar que el Engine esté disponible al iniciar.
3. **Timeout de 120 segundos.** Las operaciones `apply` no deben colgar la GUI indefinidamente.
4. **Mostrar el plan al usuario.** Antes de aplicar, mostrar las secciones principales del plan para confirmación.
5. **Parser de JSON robusto.** La GUI debe tolerar campos nuevos en la respuesta del Engine.

### 12.4 Mejoras para firstboot

1. **Idempotencia.** `sigil-firstboot.service` debe poder ejecutarse múltiples veces sin romper nada.
2. **Lock de ejecución.** Usar un flag `/etc/sigil/firstboot_completed` para evitar re-ejecución.
3. **Log de firstboot.** Escribir `/var/log/sigil-firstboot.log` con cada paso.

### 12.5 Anti-patrones a evitar

| Anti-patrón | Problema | Alternativa |
|---|---|---|
| GUI escribe personalización directamente | Duplica lógica, difícil de mantener | Delegar todo al Engine |
| Engine pide input al usuario | Rompe separación de responsabilidades | Recibir todo por argumentos |
| Firstboot instala paquetes | Dependencia de red, lento, frágil | Preinstalar offline con el Engine |
| Secretos hardcodeados en imagen | Todas las unidades comparten el mismo secreto | Generar en firstboot por unidad |
| JSON sin versión | Imposible migrar | Campo `_schema_version` siempre presente |
| GUI parsea stderr del Engine | Frágil, cambia sin aviso | Parsear stdout (texto o JSON) |

### 12.6 Checklist de integración

Antes de liberar la GUI:

- [ ] `flasher-rs status` responde con JSON
- [ ] `flasher-rs validate` detecta paths inválidos
- [ ] `flasher-rs plan` genera 18 secciones completas
- [ ] `flasher-rs apply` acepta `--provision-json`
- [ ] La GUI puede parsear todas las respuestas JSON del Engine
- [ ] `git diff --check` no reporta errores de whitespace
- [ ] La documentación del contrato está actualizada
- [ ] firstboot genera device.json correctamente
- [ ] No hay secretos hardcodeados en la imagen
- [ ] La SD flasheada arranca sin emergencia en Raspberry Pi

---


---

## 13. Regla de Oro

La identidad del dispositivo se compone de dos partes complementarias:

| Identidad asignada por fábrica | Identidad descubierta por hardware |
|---|---|
| `serial_number` | `cpu_serial` |
| `model` | `wifi_mac` |
| `batch` | `machine_id` |
| `hostname` inicial (opcional) | |

**Ninguna de las dos reemplaza a la otra.** Ambas coexisten en `device.json`.
La identidad de fábrica aporta contexto comercial y logístico.
La identidad descubierta aporta vinculación física con el hardware real.

Ambas son necesarias para la trazabilidad completa del dispositivo.

## 14. Filosofía del Provisioning

El archivo `sigil_provision.json` **no describe completamente el dispositivo**.

Su única responsabilidad es transportar de forma segura las decisiones iniciales
de fabricación desde el PC operador hasta la Raspberry Pi.

Toda información que la Raspberry pueda descubrir por sí misma durante firstboot
(cpu_serial, wifi_mac, machine_id) **pertenece exclusivamente al proceso de firstboot**
y no debe ser incluida en el provisioning.

Esta división garantiza:
- **Separación de responsabilidades**: fábrica decide identidad, hardware revela identidad.
- **Precisión**: los datos descubiertos son siempre más fiables que los suministrados.
- **Seguridad**: menos datos sensibles viajando en la SD.
- **Evolución**: se pueden agregar nuevos campos sin afectar la integridad del sistema.

## Apéndice A: Glosario

| Término | Definición |
|---|---|
| **Engine** | flasher-rs, el motor Rust que personaliza la SD offline |
| **GUI** | Sigil Flasher, la aplicación gráfica que el operador usa |
| **Firstboot** | Servicio one-shot en la Raspberry que finaliza la identidad |
| **Provision** | Archivo JSON con la identidad deseada del dispositivo |
| **Payload** | Repositorio sigil-hardware con el código funcional |
| **Rootfs** | Partición de la SD con el sistema de archivos de Raspberry Pi OS |
| **Boot partition** | Partición FAT32 con kernel, config.txt y provisioning |
| **device.json** | Archivo de identidad permanente en /etc/sigil/ |
| **sigil_provision.json** | Archivo temporal en boot para comunicar identidad deseada |

## Apéndice B: Historial de revisiones

| Fecha | Versión | Cambios |
|---|---|---|
| 2026-07-01 | 1.0.0 | Documento inicial. Contrato completo v1. |
