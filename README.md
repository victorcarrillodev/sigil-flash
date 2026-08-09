# SIGIL Flash — Estación de Fabricación y Flasheador Offline

Aplicación de escritorio Linux (Tauri 2 + React 18 + Rust) que toma una imagen
oficial de Raspberry Pi OS y una microSD y produce un dispositivo que arranca ya
completamente configurado: dependencias instaladas, identidad de fábrica,
credencial única por equipo, panel protegido y red configurada.

> [!IMPORTANT]
> **DEPENDENCIA CRÍTICA DE `sigil-hardware/`**
> Esta aplicación existe alrededor del árbol de software de dispositivo
> `sigil-hardware/`. **No compila ni arranca sin esa carpeta en la raíz del
> proyecto**: el backend consume su motor `flasher-rs` como crate por ruta
> relativa, y los contratos de paquetes, manifiestos de payload e instalador se
> leen directamente de ella.

> [!WARNING]
> **LOS PAYLOADS SON FOTOS FIJAS.**
> Editar cualquier script, servicio o panel de `sigil-hardware/` **no tiene
> efecto en el flasheo** hasta ejecutar `./scripts/rebuild-payloads.sh`. Es el
> error operativo más frecuente de este sistema.

---

## Restricción central

El primer arranque **no instala nada** y no necesita Internet para funcionar
localmente. Toda la instalación de paquetes ocurre durante el flasheo, en el PC
de fabricación, desde un repositorio APT local que se inyecta en la imagen y
se consume vía chroot.

## Características

- **Instalación 100 % offline** desde un repositorio APT local.
- **Integridad por hash**: el repositorio local no va firmado. Lo cubren
  `checksums.sha256` sobre el conjunto exacto de artefactos y, paquete a
  paquete, el tamaño, el SHA-256 y los metadatos de control leídos del propio
  `.deb`. APT lo consume con `trusted=yes`.
- **Cadena de confianza desde la imagen**: las fuentes APT y los keyrings se
  extraen de dentro de la imagen oficial verificada por hash. Los keyrings del
  host nunca se confían.
- **Frontera de privilegio**: la GUI nunca corre como root; para escribir el
  disco relanza su propio binario con `pkexec`. Doble control independiente
  contra escribir en el disco del sistema.
- **Red de seguridad multiarquitectura**: la arquitectura se comprueba leyendo
  la cabecera ELF de un binario real del rootfs montado y se compara contra el
  bundle; si no coinciden, aborta antes de tocar nada.
- **Credenciales en el keyring del SO** (`secret-tool` / libsecret); nunca en
  archivos, argv ni logs.
- **Interfaz neumórfica** en CSS vainilla y TypeScript estricto.

## Soporte de plataforma

El flujo real de fabricación **solo está soportado en Linux**. La elevación de
privilegios está declarada para macOS (`osascript`) y Windows
(`Start-Process -Verb RunAs`), pero el resto del flujo —montaje, chroot,
expansión de particiones— es específico de Linux y **no está validado en esas
plataformas**.

## Requisitos

- Linux x86_64 o AArch64
- Node.js (o Bun) y Rust (Cargo)
- `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `libsecret-tools`, `parted`,
  `qemu-user-static`, `dosfstools`, `e2fsprogs`, `cloud-guest-utils`
- Docker, solo si el host no trae las herramientas de empaquetado Debian

```bash
sudo ./setup.sh
```

Cubre apt, pacman, dnf, zypper y apk.

## Puesta en marcha

```bash
npm install
./scripts/build-all-bundles.sh
npx tauri dev
```

`build-all-bundles.sh` necesita las imágenes base en `artifacts/images/` con el
nombre exacto que declara cada contrato. Sin bundle construido, la aplicación
lo dice y bloquea la fabricación en vez de fallar a mitad de la escritura.

## Pruebas

```bash
./tests/run-all.sh
```

Suites individuales:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --all-targets --all-features --locked --offline
npm test                # Vitest: lógica pura, componentes y accesibilidad
npm run test:coverage   # con informe de cobertura
npm run build
bash tests/test_cli_modes.sh
bash tests/test_identity_contract.sh
bash tests/test_payload_integrity.sh
bash tests/test_bundle_validation.sh
bash tests/test_docs_match_contract.sh
```

El frontend se desarrolla con pruebas primero: las reglas de validación, el
cálculo de estado previo al flasheo, el formato de cifras y el contrato de
accesibilidad de cada componente están fijados por pruebas antes de escribir la
interfaz. Las reglas de `src/services/validation.ts` son un espejo de
`src-tauri/src/services/config.rs`: cada caso tiene su gemelo en Rust, porque si
divergen el operario ve un formulario en verde y el proceso elevado aborta
veinte minutos después.

## Documentación

- [Guía Operativa de Fabricación](docs/manufacturing-guide.md)
- [Flujo de Credenciales](docs/credential-flow.md)
- [Migración de Arquitectura y Versiones](docs/architecture-upgrade.md)
