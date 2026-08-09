# Migración de Arquitectura y de Versión de Distribución

## Archivos que hay que cambiar A LA VEZ para subir de release

Los validadores fijan una versión concreta de distribución. Es un control
cruzado deliberado: el contrato debe coincidir con el `os-release` de la imagen
Y con las fuentes que la imagen trae firmadas. No lo relaje por comodidad.

| Archivo | Cambio requerido |
|---|---|
| `sigil-hardware/manifests/offline-package-contract.json` | `distribution_version`, `distribution_codename`, `base_image_name`, `base_image_sha256` |
| `sigil-hardware/manifests/offline-package-contract.armhf.json` | lo mismo para la variante de 32 bits |
| `sigil-hardware/scripts/install-offline-packages.sh` | comprobaciones de `distribution_version` y `distribution_codename` |
| `sigil-hardware/flasher-rs/src/model.rs` | constantes de servicios habilitados y deshabilitados |
| `docs/manufacturing-guide.md` | tabla de imágenes base esperadas |

Tras cambiarlos: `./scripts/build-all-bundles.sh` y `./tests/run-all.sh`.

El constructor comprueba por su cuenta que el `os-release` extraído de la
imagen y la distribución de sus fuentes firmadas coincidan con el contrato, y
aborta nombrando la discrepancia si no es así.

## Añadir una arquitectura nueva

Consiste en dejar caer otro archivo de contrato en
`sigil-hardware/manifests/offline-package-contract.<variante>.json`. Los
scripts descubren los contratos por patrón de nombre; no hay que tocar código.
La herramienta de alta lo genera desde la propia imagen:

```bash
./scripts/onboard-base-image.sh artifacts/images/<imagen>.img.xz <variante> --build
```

La arquitectura NUNCA se deduce del nombre del archivo. Una descarga mal
etiquetada se detecta en segundos leyendo la cabecera ELF de un binario real
del rootfs, no dentro del chroot tras veinte minutos de escritura.

## Red de Seguridad Multiarquitectura

Control innegociable de la Fase 6, implementado en
`src-tauri/src/services/flash.rs`:

- Lee la cabecera ELF de `bin/bash`, `usr/bin/bash`, `bin/sh`, `usr/bin/sh` o
  `systemd` del rootfs ya montado, resolviendo symlinks hasta 5 niveles y
  respetando el orden de bytes declarado en la cabecera.
- Traduce `e_machine`: 40 = ARM32/armhf, 183 = ARM64, 62 = x86_64, 3 = x86.
- **Compara esa arquitectura real contra la del bundle seleccionado y ABORTA**
  antes de copiar nada o de ejecutar el chroot si no coinciden.

Convierte una heurística de selección en un fallo cerrado en vez de una imagen
corrupta. Nunca la elimine ni la relaje.

## Resolución del par bundle/payload

En tiempo de flasheo, en tres niveles (`src-tauri/src/services/bundle.rs`):

1. El payload cuyo contrato embebido fija EXACTAMENTE ese nombre de imagen,
   emparejado con el repositorio generado del mismo contrato (comparando nombre
   de imagen base y arquitectura en su manifiesto).
2. La arquitectura que el nombre anuncia mediante tokens DECISIVOS (`armhf`,
   `armv6`, `armv7`, `arm64`, `aarch64`), ignorando los ambiguos como `32bits`
   o `64bits`.
3. Los valores por defecto canónicos.

Un payload SIN su repositorio correspondiente nunca se selecciona. El nombre de
variante se valida contra path traversal antes de tocar el disco.

## Empaquetado: por qué no se genera AppImage

`bundle.targets` está fijado a `["deb", "rpm"]` en `src-tauri/tauri.conf.json`.

El objetivo AppImage falla en hosts basados en Arch por dos incompatibilidades
de `linuxdeploy`, ninguna del código de este proyecto:

1. El `strip` que trae `linuxdeploy` (binutils de 2024) no reconoce las
   secciones `.relr.dyn` que genera el toolchain actual:
   `unknown type [0x13] section '.relr.dyn'`. Se puede sortear con `NO_STRIP=1`.

2. Su complemento GTK espera `/usr/lib/gdk-pixbuf-2.0/2.10.0`, que en Arch no
   existe: los cargadores están integrados en la librería. Esto no tiene rodeo
   desde la configuración.

Dejar el objetivo activo hacía que `npm run tauri build` terminara SIEMPRE en
error aunque el binario, el .deb y el .rpm se generaran bien. Una compilación
que siempre falla enseña a ignorar los fallos, y esta sesión ya costó horas por
errores reales escondidos detrás de mensajes que nadie miraba.

Para volver a habilitarlo hay que construir desde un host Debian/Ubuntu, o
esperar a que `linuxdeploy` actualice su binutils y su complemento GTK.
