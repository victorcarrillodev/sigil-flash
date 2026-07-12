% ⚡ Funcionamiento Interno de Sigil Flash
%
% Este archivo contiene una descripción de alto nivel del funcionamiento de Sigil Flash.
% Para ver la documentación detallada con diagramas de arquitectura en formato Markdown,
% por favor abre el archivo: docs/funcionamiento.md
%
% ==============================================================================
% 🛠️ CAPAS DE LA APLICACIÓN
% ==============================================================================
% 1. Frontend: Escrito en React + TypeScript y estilizado con Neumorphism en CSS.
%    - Se comunica con el backend mediante invokes IPC (Inter-Process Communication).
%    - Escucha eventos de progreso en tiempo real ("flash-progress", "download-progress").
%
% 2. Backend: Escrito en Rust utilizando el framework Tauri 2.0.
%    - Controla los comandos expuestos (list_devices, start_flash, cancel_flash, etc.).
%    - Administra la elevación de privilegios de forma segura.
%
% ==============================================================================
% 💾 DETECCION DE DISPOSITIVOS (DiskService)
% ==============================================================================
% - Linux: Ejecuta `lsblk` para filtrar discos extraíbles (USB/SD) y no de sistema.
% - macOS: Usa `diskutil list` e info para identificar discos físicos externos.
% - Windows: Usa un comando de PowerShell `Get-Disk` en formato JSON.
%
% ==============================================================================
% 🔒 ELEVACIÓN DE PRIVILEGIOS Y ESCRITURA (FlashService)
% ==============================================================================
% - Para escribir directamente en unidades físicas se requieren permisos de Root/Admin.
% - Tauri ejecuta una copia de sí mismo usando:
%   - Linux: `pkexec` (Polkit).
%   - macOS: `osascript` con administrator privileges.
%   - Windows: PowerShell `Start-Process ... -Verb RunAs`.
% - El proceso secundario se arranca con el parámetro especial `--flash-raw`.
% - La escritura se realiza secuencialmente con un búfer de 4 MB en Rust.
% - Se guardan las actualizaciones en un JSON temporal que la app principal lee cada 200ms.
% - Se invoca `sync_all` en el disco antes de terminar.
%
% ==============================================================================
% ⚙️ INYECCIÓN DE CONFIGURACIÓN (ConfigService)
% ==============================================================================
% - Después del flasheo, monta la partición boot de la tarjeta.
% - Escribe un archivo `device-config.json` con los parámetros de Wi-Fi, SSH y usuario.
% - Si SSH está habilitado, crea un archivo vacío llamado `ssh` para activar el servicio.
% - Finalmente desmonta el volumen de forma limpia.
%
% Para más información, consulte:
% file:///home/dev-pro/Escritorio/sigil-flash/docs/funcionamiento.md
