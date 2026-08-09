# SIGIL Flash — Guía Operativa de Fabricación

Procedimientos de la estación de fabricación SIGIL Flash. Todos los ejemplos de
nombre de imagen salen de los contratos en `sigil-hardware/manifests/`: si un
contrato cambia, esta guía queda desfasada y `tests/test_docs_match_contract.sh`
lo detecta.

---

## 0. Preparación del PC de fabricación

```bash
sudo ./setup.sh
```

Instala las dependencias de compilación y de flasheo en apt, pacman, dnf,
zypper o apk. Donde falten las herramientas de empaquetado Debian
(`dpkg-scanpackages`, `apt-ftparchive`) instala Docker: el constructor del
repositorio se re-ejecuta solo dentro de `debian:trixie`.

Para fabricar imágenes ARM desde un PC x86 hace falta además el intérprete
`qemu-user-static`. Si falta, el flasheo aborta indicando la orden exacta de
instalación de su distribución.

---

## 1. Alta de una Nueva Imagen Base Oficial

Cada arquitectura es un contrato. Añadir una arquitectura consiste en dejar
caer otro archivo de contrato: ningún script se toca.

```bash
./scripts/onboard-base-image.sh artifacts/images/<imagen>.img.xz <variante> --build
```

El script deriva el contrato **de la propia imagen**, nunca de su nombre:

- SHA-256 del archivo tal cual.
- Arquitectura por cabecera ELF de un binario real del rootfs.
- Codename y versión desde `os-release`.
- Distribución (`debian` o `raspbian`) según el archivo de fuentes que la
  imagen trae firmado.
- La lista de paquetes se copia del contrato canónico sin modificarla, para que
  las variantes no diverjan del contrato de producto.

Con `--build` construye además el bundle y regenera los payloads.

---

## 2. Construcción de bundles

```bash
./scripts/build-all-bundles.sh
```

Recorre todos los contratos y genera un bundle por cada uno en
`artifacts/bundles/<contrato>-repo`. Si falta la imagen base de un contrato, ese
contrato se salta con un aviso en lugar de fallar entero.

Las imágenes base se buscan en `artifacts/images/` con el nombre EXACTO que
declara cada contrato:

| Contrato | Imagen base esperada |
|---|---|
| `offline-package-contract.json` | `2026-06-18-raspios-trixie-arm64-lite.img.xz` |
| `offline-package-contract.armhf.json` | `32bits2026-06-18-raspios-trixie-armhf-lite.img.xz` |

> [!IMPORTANT]
> **La cadena de confianza arranca en la imagen, no en el PC.**
> El constructor verifica el SHA-256 de la imagen contra el contrato, localiza
> su única partición Linux y extrae de dentro las fuentes APT firmadas y los
> keyrings. Los keyrings del host nunca se usan. Por eso la imagen base es un
> argumento obligatorio del constructor.

En redes que no alcanzan el archivo primario puede fijarse un espejo, que
sustituye SOLO el URI; la descarga se sigue autenticando con el keyring
extraído de la imagen:

```bash
SIGIL_APT_MIRROR=https://mi-espejo.example/debian ./scripts/build-all-bundles.sh
```

---

## 3. Gestión de Payloads (Fotos Fijas)

> [!WARNING]
> **POR QUÉ los payloads quedan obsoletos y cuándo regenerarlos:**
> Un payload es una **fotografía fija** de `sigil-hardware/`: copia los 70
> archivos listados en `manifests/flasher-payload-files.txt` y genera su
> `payload-manifest.json` con los SHA-256 de cada uno.
> **Editar cualquier script, servicio o panel de `sigil-hardware/` NO TIENE
> EFECTO en el flasheo hasta regenerar los payloads.** Es el error operativo
> más frecuente de este sistema.

```bash
./scripts/rebuild-payloads.sh
```

El generador obtiene el commit de origen con `git rev-parse HEAD` y comprueba
que los archivos estén versionados y limpios: **el repositorio Git es
obligatorio para generar payloads.**

---

## 4. Preparación de la Credencial de Fábrica

La contraseña de la cuenta de fábrica vive **solo** en el keyring del sistema
operativo. Nunca en un archivo, en argv, en logs ni en el repositorio. Si el
keyring no está disponible, la aplicación aborta indicando el paquete a
instalar; jamás cae a un archivo en texto plano.

```bash
sudo apt-get install libsecret-tools
secret-tool store --label="SIGIL Factory" service sigil-factory username sigil
```

En el panel **Credencial de Fábrica** de la aplicación:

1. *Autenticar contra el servidor* — el backend lee la contraseña del keyring y
   hace `POST /api/login`; obtiene un token de sesión de vida corta.
2. *Solicitar credencial de un solo uso* — `POST /api/admin/enrollment-keys`,
   opcionalmente ligada a la MAC del equipo.

Rellenar el campo **Dirección MAC (deviceId)** liga la credencial a ese equipo:
una imagen extraviada antes del primer arranque no puede enrolar hardware
ajeno. Sin credencial, el botón de fabricación permanece bloqueado.

---

## 5. Fabricar una unidad

1. Seleccionar la imagen oficial. La aplicación resuelve su par bundle/payload
   y lo muestra; si no hay bundle construido para esa arquitectura, lo dice y
   bloquea la fabricación.
2. Seleccionar la microSD (solo aparecen unidades extraíbles).
3. Rellenar la configuración. Se valida en el formulario, en el backend de la
   interfaz y otra vez en el proceso elevado tras releerla del disco.
4. Obtener la credencial de enrolamiento.
5. Iniciar la fabricación. `pkexec` pide autorización una sola vez.

Durante el proceso el escritor privilegiado publica su estado y la interfaz lo
refleja en vivo con velocidad y ETA.

---

## 6. Actualización de Versión de Distribución

Ver [architecture-upgrade.md](architecture-upgrade.md): enumera en un solo
lugar todos los archivos que hay que cambiar a la vez.

---

## 7. Suite de pruebas

```bash
./tests/run-all.sh
```

Nueve suites: pruebas unitarias de Rust, compilación del binario, pruebas del
frontend con Vitest, compilación estricta del frontend, contrato de línea de
comandos, contrato de identidad y PIN contra los validadores Python reales de
`sigil-hardware/`, integridad de los payloads, validación de los bundles con
`install-offline-packages.sh` y coherencia de esta documentación con los
contratos.

Dos comprobaciones se omiten en un PC de fabricación x86 y lo dicen por
pantalla en vez de dar un falso verde:

- **`panel_auth`**: necesita el módulo `argon2`, que vive dentro de la imagen
  (`python3-argon2` del bundle), no en el PC.
- **Validación completa del bundle armhf**: `install-offline-packages.sh`
  termina haciendo un `apt-get install` real contra la base de datos dpkg del
  sistema donde corre, así que un bundle de Raspbian necesita una base
  Raspbian. No existe imagen oficial de contenedor de Raspbian trixie; esa
  validación ocurre dentro de la imagen durante el flasheo. El bundle arm64 sí
  se valida aquí, en un contenedor Debian trixie emulado.
