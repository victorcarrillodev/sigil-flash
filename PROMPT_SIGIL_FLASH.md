# Prompt — construir SIGIL Flash sobre un `sigil-hardware/` existente

Uso: coloca `sigil-hardware/` dentro de una carpeta vacía, abre una IA con
acceso a terminal y sistema de archivos en esa carpeta, y pega el bloque
completo de abajo.

---

````
Eres un ingeniero senior de sistemas embebidos y aplicaciones de escritorio.

Vas a construir una aplicación de fabricación llamada SIGIL Flash ALREDEDOR de
un árbol de software de dispositivo que YA EXISTE y que recibes como entrada.

Trabaja de forma incremental y verificable: cada fase debe compilar y pasar sus
pruebas antes de avanzar. No inventes requisitos. Si algo queda fuera del
alcance, dilo explícitamente al final con su motivo.


╔══════════════════════════════════════════════════════════════════════════╗
║ 0. REGLA CERO — LO QUE NO DEBES CONSTRUIR                                ║
╚══════════════════════════════════════════════════════════════════════════╝

En tu directorio de trabajo hay una carpeta `sigil-hardware/`. Contiene el
software del producto: el panel web, los servicios, los scripts de runtime, el
instalador que corre dentro de la imagen, el script de primer arranque, los
manifiestos y un motor de validación en Rust.

  · NO la reimplementes.
  · NO la reescribas ni la "mejores".
  · NO muevas sus archivos ni cambies sus rutas.
  · Solo puedes modificarla si encuentras un defecto real y lo justificas.

ESA CARPETA ES TU ESPECIFICACIÓN. Léela antes de escribir una sola línea. Los
contratos que impone son obligatorios: tu aplicación existe para satisfacerlos.

GUÍA DE LECTURA — lee estos archivos en este orden y anota lo que definen:

  sigil-hardware/manifests/offline-package-contract.json
      El contrato canónico de paquetes: esquema, versión de bundle,
      distribución, arquitectura, nombre y SHA-256 exactos de la imagen base,
      política de instalación y la lista completa de paquetes con sus perfiles.
      Cuenta cuántos son obligatorios: ese número aparece como invariante en
      varios validadores.

  sigil-hardware/manifests/offline-package-contract.armhf.json
      La variante de 32 bits. Compara ambos: verás exactamente qué campos
      cambian entre arquitecturas y cuáles NO pueden cambiar nunca.

  sigil-hardware/manifests/flasher-payload-files.txt
      La lista EXACTA de archivos que entran en un payload. Ni uno más.

  sigil-hardware/manifests/install-layout.json
      El mapeo origen → destino con propietario y modo de cada archivo dentro
      de la imagen. Fíjate en los modos 440, 600, 640 y en los grupos.

  sigil-hardware/manifests/services.json
      Qué servicios se habilitan, cuáles quedan deshabilitados a propósito y
      por qué. Las notas del archivo explican decisiones de diseño.

  sigil-hardware/manifests/system-config.json
      El usuario canónico del producto con su UID fijo, shell, grupos y home.

  sigil-hardware/install.sh
      El instalador que TU aplicación invocará dentro de un chroot. Lee su
      cabecera de argumentos: define la interfaz que debes respetar. Observa
      qué hace distinto cuando detecta que está preparando una imagen en vez
      de instalarse en un equipo vivo.

  sigil-hardware/scripts/install-offline-packages.sh
      Todas las validaciones que el repositorio APT que vas a construir tendrá
      que superar. Cada comprobación de este archivo es un requisito de tu
      constructor. Léelo entero: es el contrato más estricto del sistema.

  sigil-hardware/scripts/firstboot.sh
      El primer arranque. Define qué archivos espera encontrar en la imagen,
      con qué permisos, y qué endpoints del backend consume.

  sigil-hardware/scripts/build-flasher-payload.sh
      El generador de payloads. Ya existe: tu aplicación lo invoca, no lo
      reescribe. Fíjate en sus dependencias de Git y en sus rechazos.

  sigil-hardware/flasher-rs/
      El motor de validación. Ya existe. Tu backend lo consume como crate por
      ruta relativa y también como binario CLI. Lee su API pública y su ayuda.

  sigil-hardware/conf/audio.conf
      La configuración del dispositivo. Localiza la clave de URL del servidor:
      tu aplicación tendrá que reescribirla por unidad fabricada.

Cuando termines de leer, escribe un resumen de los contratos detectados y
verifica conmigo que los interpretaste bien ANTES de programar.


╔══════════════════════════════════════════════════════════════════════════╗
║ 1. OBJETIVO                                                              ║
╚══════════════════════════════════════════════════════════════════════════╝

Una aplicación de escritorio Linux que toma una imagen oficial de Raspberry Pi
OS y una microSD, y produce un dispositivo que arranca YA completamente
configurado: con todas sus dependencias instaladas, identidad de fábrica,
credencial única por equipo, panel protegido y red configurada.

RESTRICCIÓN CENTRAL E INNEGOCIABLE:
El primer arranque NO instala nada y NO necesita Internet para funcionar
localmente. Toda la instalación de paquetes ocurre durante el flasheo, en el PC
de fabricación, desde un repositorio APT local firmado que se inyecta en la
imagen y se consume vía chroot.

Cualquier diseño que difiera la instalación de dependencias al primer arranque
es INCORRECTO. El instalador que recibes ya lo refleja: aborta si no se le pasa
un repositorio local.


╔══════════════════════════════════════════════════════════════════════════╗
║ 2. LO QUE SÍ DEBES CONSTRUIR                                             ║
╚══════════════════════════════════════════════════════════════════════════╝

  setup.sh                              Dependencias del PC de fabricación
  index.html, package.json, vite.config.ts, tsconfig*.json
  src/                                  Frontend React + TypeScript
  src-tauri/                            Backend Rust + configuración Tauri
  scripts/extract-official-apt-metadata.sh
  scripts/build-offline-repository.sh
  scripts/rebuild-payloads.sh
  scripts/onboard-base-image.sh
  scripts/build-all-bundles.sh
  docs/                                 Documentación de fabricación
  tests/                                Suites de integración

Estructura del backend:

  src-tauri/src/
    main.rs        Los tres modos de ejecución
    models/        Tipos compartidos con el frontend
    errors/        Jerarquía de errores serializable a IPC
    logging/       tracing con rotación diaria
    commands/      Comandos #[tauri::command], una función por operación
    services/      flash, config, disk, download, verification,
                   offline_package, engine


╔══════════════════════════════════════════════════════════════════════════╗
║ 3. STACK OBLIGATORIO                                                     ║
╚══════════════════════════════════════════════════════════════════════════╝

ESCRITORIO
  Tauri 2 + React 18 + TypeScript 5 + Vite 6 + Bun.
  CSS vainilla con estilo neumórfico. Sin framework de UI, sin Tailwind.

BACKEND (Rust, edition 2021)
  tauri 2, tauri-plugin-dialog 2, tauri-plugin-shell 2
  serde 1 (derive), serde_json 1
  tokio 1 (features = ["full"])
  thiserror 1
  tracing 0.1, tracing-subscriber 0.3 (env-filter, json), tracing-appender 0.2
  directories 5, chrono 0.4 (serde)
  reqwest 0.12 (stream)
  sha2 0.10, futures-util 0.3, getrandom 0.3, libc 0.2
  el motor de sigil-hardware por ruta relativa

  [profile.release]
  panic = "abort"; codegen-units = 1; lto = true; opt-level = "s"; strip = true

TAURI CONFIG
  Ventana 960x660, mínimo 800x560, redimensionable, centrada, con decoraciones.
  devUrl en un puerto propio, distinto del 5173 por defecto de Vite.


╔══════════════════════════════════════════════════════════════════════════╗
║ 4. ARQUITECTURA                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

UN SOLO BINARIO CON TRES MODOS, decididos leyendo argv ANTES de arrancar Tauri:

  (sin argumentos)      GUI Tauri
  --flash-raw           escritor privilegiado, lanzado con pkexec
                        requiere: --src --dest --progress-file
                                  --offline-packages --payload --config-file
  --configure-device    escritor de configuración en la partición BOOT
                        requiere: --device --config-file

Un parámetro faltante produce un error que nombra el flag exacto que falta.

FRONTERA DE PRIVILEGIO
  La GUI NUNCA corre como root. Para escribir el disco relanza su PROPIO
  binario elevado:
    Linux   : pkexec <exe> <args…>
    macOS   : osascript -e 'do shell script "…" with administrator privileges'
    Windows : powershell Start-Process -Verb RunAs

  El flujo de fabricación real solo necesita funcionar en Linux. Las otras dos
  plataformas pueden quedar parciales, pero dilo claramente en la documentación.

PROTOCOLO DE PROGRESO
  El proceso elevado escribe su estado como JSON en un archivo temporal. La GUI
  lo lee cada 200 ms y lo reemite como evento Tauri, calculando velocidad y ETA
  a partir de los bytes escritos y el tiempo transcurrido.

  Reglas de resolución del estado final:
    · El escritor es AUTORITATIVO: un estado "done" gana aunque el proceso
      lanzador haya salido con código de error.
    · Si el lanzador sale y no hay progreso publicado, es fallo SOLO tras 2 s
      de gracia. Mensaje: la autorización administrativa fue cancelada o falló.
    · Sin resultado final tras 45 minutos, es fallo por timeout.
    · Un estado de error o cancelación conserva su mensaje ORIGINAL: no lo
      sustituyas por uno genérico.


╔══════════════════════════════════════════════════════════════════════════╗
║ 5. FASE 1 — ESQUELETO, MODELOS Y ERRORES                                 ║
╚══════════════════════════════════════════════════════════════════════════╝

MODELOS (Rust, Serialize + Deserialize, compartidos con el frontend):

  ImageInfo { path: String, name: String, size: u64, sha256: Option<String> }

  Device {
      name: String, path: String, size: String, model: String,
      #[serde(rename = "type")] device_type: String,
      removable: bool,
      transport: String,
  }

  FlashProgress {
      bytes_written: u64, total_bytes: u64,
      speed_mbps: f64, eta_seconds: f64,
      status: String,   // idle|running|verifying|done|error|cancelled
      message: String,
  }

  #[serde(deny_unknown_fields)]        // OBLIGATORIO
  DeviceConfig {
      hostname: String,
      username: String,
      password: Option<String>,
      #[serde(rename = "wifiSsid")]            wifi_ssid: Option<String>,
      #[serde(rename = "wifiPassword")]        wifi_password: Option<String>,
      #[serde(rename = "sshEnabled")]          ssh_enabled: bool,
      #[serde(rename = "rpiModel")]            rpi_model: Option<String>,
      #[serde(rename = "serialNumber")]        serial_number: Option<String>,
      #[serde(rename = "deviceId", default)]   device_id: Option<String>,
      #[serde(rename = "sigilModel", default)] model_name: Option<String>,
      #[serde(rename = "sigilModelVersion", default)] model_version: Option<String>,
      #[serde(rename = "panelPin")]            panel_pin: Option<String>,
      #[serde(rename = "apiKey")]              api_key: Option<String>,
      #[serde(rename = "serverUrl", default)]  server_url: Option<String>,
  }

  El nombre de usuario y los valores de identidad deben coincidir con los que
  declara sigil-hardware/manifests/system-config.json. No los inventes.

ERRORES
  Enum con thiserror: Io, Tauri, Serialization, Disk, Download, Flash, Config,
  Validation, Internal. Implementa Serialize serializando su Display, para que
  el mensaje cruce el límite IPC como cadena legible.

LOGGING
  tracing con dos capas: stdout con ANSI, y archivo con rotación diaria SIN
  ANSI en el directorio de datos local del usuario. Filtro por variable de
  entorno, nivel "info" por defecto. El guard debe vivir en main durante toda
  la ejecución: si se descarta, los logs se pierden en silencio. Si el logging
  no arranca, termina con código 1 y un mensaje claro.


╔══════════════════════════════════════════════════════════════════════════╗
║ 6. FASE 2 — DETECCIÓN DE DISPOSITIVOS                                    ║
╚══════════════════════════════════════════════════════════════════════════╝

Servicio que lista SOLO unidades extraíbles:

  Linux   lsblk --json --bytes --nodeps --output NAME,SIZE,TYPE,TRAN,MODEL,RM,RO
          filtrar: type == "disk" && !ro && (rm || tran ∈ {usb, mmc, sd})
  macOS   diskutil list buscando "(external, physical)", luego diskutil info
  Windows PowerShell Get-Disk con BusType ∈ {USB, SD} o Removable

SALVAGUARDA INDEPENDIENTE en el proceso elevado, obligatoria aunque la UI ya
haya filtrado:
  · Leer /proc/mounts e identificar el dispositivo que monta "/".
  · Normalizar su disco padre: sdaN→sda, nvme0n1pN→nvme0n1, mmcblk0pN→mmcblk0.
  · RECHAZAR la escritura si el destino coincide, con mensaje explícito.
  · Si no se puede determinar, asume un valor conservador antes que ninguno.

Los dos lados de la frontera de privilegio no se confían mutuamente. Esta
redundancia es deliberada.


╔══════════════════════════════════════════════════════════════════════════╗
║ 7. FASE 3 — ESCRITURA DE LA IMAGEN                                       ║
╚══════════════════════════════════════════════════════════════════════════╝

En el proceso elevado, en ESTE orden exacto:

 1. LEER la configuración privada indicada por --config-file. Antes de abrirla:
    es archivo regular (no symlink), pertenece al usuario efectivo, tamaño
    ≤ 16 KiB, permisos sin bits de grupo ni de otros. Abrir con
    O_NOFOLLOW | O_CLOEXEC y comprobar que dev+inode no cambiaron entre el stat
    previo y el open.

 2. REVALIDAR la configuración con las mismas reglas que aplicó la GUI.

 3. BORRAR el archivo de configuración. Es de un solo uso. Si el borrado falla,
    abortar: no se sigue dejando secretos en disco.

 4. Rechazar discos del sistema.

 5. Validar el par bundle/payload contra la imagen seleccionada.

 6. LOCK EXCLUSIVO en /run/lock/<producto>-<dispositivo>.lock con el PID propio.
    Si existe y el PID sigue vivo, abortar. Si está muerto, reclamar el lock.
    Liberar en Drop SOLO si el archivo todavía contiene el PID propio.

 7. ESCRIBIR por bloques de 4 MB. Si la imagen es .xz:
      · tamaño descomprimido con `xz --robot -l` (campo totals)
      · descompresión al vuelo con `xz -d -c` canalizado
    Publicar progreso en cada bloque.

 8. sync_all() y comprobar que se escribieron EXACTAMENTE los bytes esperados.
    Si el descompresor terminó con error, abortar aunque el conteo cuadre.

 9. EXPANDIR el rootfs:
      partprobe → udevadm settle --timeout=30
      growpart <dev> 2      (aceptar el resultado idempotente "NOCHANGE")
      si falla: parted -s <dev> resizepart 2 100%
      partprobe → udevadm settle
      e2fsck -f -p <rootpart>   (aceptar códigos de salida 0 y 1)
      resize2fs <rootpart>
      sync

10. VERIFICAR la expansión, no asumirla:
      blockdev --getsize64 y --getss
      lsblk --bytes --noheadings --output START,SIZE <rootpart>
      dumpe2fs -h <rootpart>  →  Block count × Block size
    Fallar si queda más de 16 MiB sin asignar al final del dispositivo, o si el
    sistema de archivos no ocupa su partición dentro de esa misma tolerancia.

Las particiones se nombran <dev>p<N> para mmcblk, nvme y loop; <dev><N> para el
resto. Escribe una prueba unitaria de esa regla.


╔══════════════════════════════════════════════════════════════════════════╗
║ 8. FASE 4 — REPOSITORIO APT OFFLINE                                      ║
╚══════════════════════════════════════════════════════════════════════════╝

El contrato ya existe en sigil-hardware/manifests/. Tu constructor debe
producir un repositorio que supere TODAS las validaciones de
sigil-hardware/scripts/install-offline-packages.sh. Léelo y trátalo como la
especificación de aceptación de esta fase.

El constructor debe:

 1. AUTODETECTAR TOOLING. Si el host no tiene apt-get, dpkg-scanpackages,
    apt-ftparchive o dpkg-deb, REEJECUTARSE dentro de un contenedor
    debian:trixie con los mismos argumentos, usando setpriv --reuid/--regid
    para que la salida quede propiedad del usuario del host. Imprimir qué
    camino tomó. Una variable de entorno permite saltar la comprobación cuando
    ya se está dentro de un entorno Debian equivalente.

 2. VALIDAR el contrato entero antes de tocar la red.

 3. EXTRAER LOS METADATOS DE LA IMAGEN OFICIAL, en un script aparte:
      · verificar nombre de archivo y SHA-256 contra el contrato
      · descomprimir si es .xz
      · localizar la ÚNICA partición Linux con `sfdisk --json` (tipo 83)
      · extraer ese rango con dd
      · con `debugfs -R "dump -p …"` sacar DE DENTRO DE LA IMAGEN:
          - el archivo de fuentes del archivo base: en imágenes de 64 bits es
            el de Debian; en las de 32 bits es el de Raspbian, la recompilación
            ARMv6 de la Fundación. Debe existir exactamente uno de los dos.
          - el archivo de fuentes del archivo de Raspberry Pi
          - el keyring del archivo base correspondiente
          - el keyring del archivo de Raspberry Pi
          - os-release y la base de datos dpkg/status
    LOS KEYRINGS DEL HOST NUNCA SE CONFÍAN. La cadena de confianza arranca en
    la imagen oficial verificada por hash, no en el sistema que fabrica.

 4. Permitir un espejo documentado para redes que no alcanzan el archivo
    primario, sustituyendo SOLO el URI. La firma debe seguir autenticándose con
    el keyring extraído de la imagen.

 5. RESOLVER EL CIERRE TRANSITIVO con estado APT completamente aislado y base
    de datos dpkg VACÍA, para que APT no asuma nada instalado en el host.
    Descarga sin instalar, sin recomendados, sin traducciones, sin índices
    DEP-11 ni CNF, con la arquitectura fijada al contrato.

 6. Verificar que CADA paquete descargado sea de una arquitectura permitida.

 7. GENERAR índices:
      dpkg-scanpackages --multiversion packages /dev/null > Packages
      gzip -n -9 -c Packages > Packages.gz
      apt-ftparchive release . > Release

 8. FIRMAR con una clave ed25519 local propia del entorno de fabricación,
    generada automáticamente la primera vez. Producir la firma separada y la
    firma incorporada, y exportar la clave pública al snapshot de fuentes.
    Esta clave solo autentica el repositorio local frente al instalador dentro
    de la imagen: no es una identidad de producto y perderla no es grave.

 9. DEMOSTRAR EL CIERRE: reinstalar en SIMULACIÓN, sin descargar, desde el
    repositorio recién creado con una base de datos dpkg vacía. Si la
    simulación falla, el bundle no se autosatisface y el build debe abortar.
    Nunca se instala ni se ejecuta un paquete de otra arquitectura en el host.

10. ESCRIBIR el manifiesto del bundle con procedencia completa. Los campos
    exactos que debe llevar están enumerados en la validación de
    install-offline-packages.sh: cópialos de ahí, no los inventes.

11. ESCRIBIR checksums que cubran EXACTAMENTE los artefactos: paquetes,
    snapshot de fuentes, índices, firmas y manifiesto. Ni uno de más, ni uno
    de menos. El validador comprueba la igualdad de conjuntos.

12. REEMPLAZAR el directorio de salida de forma ATÓMICA, con respaldo previo y
    restauración automática si algo falla a mitad.


╔══════════════════════════════════════════════════════════════════════════╗
║ 9. FASE 5 — PAYLOADS                                                     ║
╚══════════════════════════════════════════════════════════════════════════╝

El generador de payloads YA EXISTE en sigil-hardware/scripts/. No lo
reescribas. Construye a su alrededor:

  · Un orquestador que regenere el payload canónico más uno por cada contrato
    variante que encuentre, descubriéndolos por patrón de nombre. Añadir una
    arquitectura debe consistir en dejar caer otro archivo de contrato, sin
    tocar ningún script.
  · Un comando de la aplicación que lo invoque.

DEPENDENCIA DE GIT: el generador obtiene el commit de origen con
`git rev-parse HEAD` y comprueba que los archivos estén versionados y limpios.
Documenta que el repositorio Git es OBLIGATORIO para generar payloads.

LOS PAYLOADS SON FOTOS FIJAS: copian archivos, no los enlazan. Documenta de
forma prominente, en el README y en la documentación de fabricación, que editar
el software del dispositivo NO tiene efecto hasta regenerar los payloads. Es el
error operativo más frecuente de este sistema.


╔══════════════════════════════════════════════════════════════════════════╗
║ 10. FASE 6 — INSTALACIÓN DENTRO DE LA IMAGEN                             ║
╚══════════════════════════════════════════════════════════════════════════╝

Tras escribir y expandir la imagen, en el proceso elevado:

 1. partprobe, desmontar restos previos, montar el rootfs CON REINTENTOS
    (10 intentos separados 2 s, ejecutando sync y partprobe entre medias). El
    kernel tarda en releer una tabla de particiones recién escrita.

 2. DETECTAR LA ARQUITECTURA REAL DEL ROOTFS leyendo la cabecera ELF de
    bin/bash, usr/bin/bash, bin/sh, usr/bin/sh o systemd, resolviendo symlinks
    hasta 5 niveles y respetando el orden de bytes declarado en la cabecera.
      e_machine 40 = ARM32/armhf, 183 = ARM64, 62 = x86_64, 3 = x86
    Comparar contra la arquitectura del bundle y ABORTAR con mensaje explícito
    si no coinciden.

    ESTA COMPROBACIÓN ES LA RED DE SEGURIDAD DE TODO EL SISTEMA
    MULTIARQUITECTURA. Nunca la elimines ni la relajes: convierte una
    heurística de selección en un fallo cerrado en vez de una imagen corrupta.

 3. Montar la partición de arranque dentro del rootfs montado.

 4. Escribir en la imagen: el documento de identidad de fabricación, la
    credencial de enrolamiento con modo 0600 mediante temporal + fsync +
    rename atómico, el hostname, y las optimizaciones de arranque del modelo de
    placa entre marcadores propios identificables.

 5. COPIAR EL PAYLOAD validando su manifiesto ANTES y DESPUÉS de copiar.
    Forzar propietario root y RESTAURAR los modos declarados en el manifiesto:
    `cp -a` NO preserva propietario cuando no se ejecuta como root, y un
    payload con dueños equivocados rompe el chroot posterior de forma confusa.
    Normalizar directorios a 0755.

 6. Copiar el repositorio APT validado dentro de la imagen.

 7. Bind-mount de /dev, montar proc y sysfs. Instalar un policy-rc.d con
    "exit 101" y modo 0755 para que NINGÚN demonio arranque dentro del chroot.
    Respaldar el policy-rc.d previo si existía y restaurarlo al terminar.

 8. Si el host no es de la arquitectura destino, localizar el intérprete
    qemu-<arch>-static, copiarlo dentro de la imagen y BORRARLO al terminar
    SOLO si fue este proceso quien lo copió. Si falta, abortar indicando la
    orden exacta de instalación por distribución.

 9. Invocar el instalador de sigil-hardware dentro del chroot, con la interfaz
    que ese script declara. Marca en el entorno que se trata de preparación de
    imagen y desactiva el frontend interactivo. Activa el perfil de paquetes de
    diagnóstico SOLO si el operario pidió acceso remoto; en caso contrario,
    ELIMINA esa variable del entorno explícitamente para que no se herede.

10. Provisión post-instalación (Fase 7).

11. REAFIRMAR A MANO el symlink de habilitación del servicio de primer
    arranque. Dentro de un chroot sin systemd activo, `systemctl enable` puede
    fallar EN SILENCIO, y ese servicio es crítico. Si la unidad no existe en el
    rootfs preparado, abortar.

12. Restaurar el policy-rc.d, sync, y desmontar en ORDEN INVERSO, reportando
    cualquier desmontaje fallido en vez de ignorarlo.


╔══════════════════════════════════════════════════════════════════════════╗
║ 11. FASE 7 — PARÁMETROS Y PROVISIÓN                                      ║
╚══════════════════════════════════════════════════════════════════════════╝

VALIDA EN TRES LUGARES con las mismas reglas: frontend, backend de la GUI y
proceso elevado tras releer la configuración del disco.

  hostname      1–63 caracteres, alfanuméricos y guiones, sin empezar ni
                terminar en guion
  username      el que declara system-config.json; cualquier otro se rechaza
  password      6–128 caracteres, sin \r \n \0
                OBLIGATORIA si el acceso remoto está activo
  panelPin      6–12 dígitos; RECHAZAR repetidos, ascendentes y descendentes
  serialNumber  1–64 caracteres [A-Za-z0-9._-]; OBLIGATORIO
  deviceId      MAC de 17 caracteres; acepta ':' o '-'; normaliza a minúsculas
                con ':'; debe coincidir BYTE A BYTE con la normalización del
                servidor, o una credencial ligada nunca podrá consumirse
  rpiModel      lista cerrada de modelos soportados; los modelos sin Linux
                (microcontroladores) se rechazan en el frontend
  wifi          SSID 1–32 y clave 8–63; AMBOS o NINGUNO, nunca uno solo
  apiKey        8–256 caracteres ASCII gráficos, sin espacios
  serverUrl     https:// obligatorio; http:// SOLO con override explícito por
                variable de entorno, documentado como exclusivo de laboratorio,
                porque por esa conexión viajan la contraseña de fabricación y
                la credencial que se graba en la imagen

OPTIMIZACIONES POR MODELO DE PLACA
  Escribe los ajustes de arranque entre marcadores propios identificables.
  Distingue al menos: modelos de 64 bits con PCIe, modelos de 64 bits sin él,
  modelos de 64 bits de gama baja y modelos de 32 bits. Ajusta el flag de
  64 bits, la memoria de GPU y la corriente USB según gama.

PROVISIÓN DENTRO DE LA IMAGEN

  PIN del panel
    Escribe el secreto en texto plano con modo 0600 en un directorio de
    fabricación 0700, ejecuta el generador de hash que trae sigil-hardware
    DENTRO del chroot —para que la derivación use las mismas bibliotecas que
    usará el dispositivo— y VERIFICA después que el texto plano quedó consumido
    y que existen el hash y su metadato de longitud. Si algo falla, sobrescribe
    con ceros y borra.

  Perfil de red inalámbrica
    Archivo de conexión con modo 0600 y UUID DETERMINISTA derivado de
    SHA-256(serial ‖ 0x00 ‖ ssid), para que reflashear el mismo equipo con la
    misma red no genere perfiles duplicados. Escapa los valores según el
    formato del gestor de red: barras invertidas, tabuladores y espacios
    iniciales o finales.

  Acceso remoto
    Drop-in de configuración con modo 0644 que fija la autenticación por
    contraseña según la elección, prohíbe el acceso de root y restringe los
    usuarios permitidos. Establece la contraseña con un algoritmo moderno
    pasándola por STDIN, nunca por argv. Da de alta al usuario en el grupo de
    administración. VALIDA la configuración generada con el propio demonio en
    modo test, usando una clave de host EFÍMERA —una imagen limpia todavía no
    tiene claves persistentes y el test fallaría sin ella— que se borra al
    terminar. Si el bundle no instaló el servidor, aborta indicando que hay que
    reconstruir el bundle con el perfil de diagnóstico.

  URL del servidor
    Reescribe la clave correspondiente en la configuración del dispositivo,
    ABORTANDO si esa clave no existe: su ausencia significa que la imagen no es
    la esperada, y añadirla en silencio ocultaría el problema.


╔══════════════════════════════════════════════════════════════════════════╗
║ 12. FASE 8 — CREDENCIALES Y BACKEND                                      ║
╚══════════════════════════════════════════════════════════════════════════╝

MODELO OBLIGATORIO:

  Keyring del sistema operativo del PC de fabricación
    └─ contraseña de una cuenta de fábrica dedicada
         ├─ login HTTPS  →  token de sesión de vida corta
         ├─ solicitud de UNA credencial de enrolamiento DE UN SOLO USO,
         │  opcionalmente LIGADA a la MAC del equipo que se va a fabricar
         └─ inyección en la imagen con modo 0600
              └─ primer arranque: canje por un token PERMANENTE
                   └─ borrado de la credencial de un solo uso
                        └─ runtime: el token permanente es la ÚNICA credencial
                           que el dispositivo usa jamás

CONTRATO DEL BACKEND. El script de primer arranque que recibes ya consume estos
endpoints, así que son fijos. Tu aplicación consume los dos primeros:

  POST /api/login
    petición  { "username": <str>, "password": <str> }
    respuesta { "token": <str> }                          token de sesión

  POST /api/admin/enrollment-keys        Authorization: Bearer <token>
    petición  { "device_id": <mac|omitido>, "serial_number": <str|omitido> }
    respuesta { "keys": [ { "enrollment_key": <str> } ] }
    errores   409 el equipo ya tiene una credencial activa
              400 el servidor exige MAC y no se envió
              429 demasiadas solicitudes seguidas

  POST /api/devices/bootstrap            (lo llama el dispositivo)
    petición  { "device_id": <str>, "enrollment_key": <str> }
    respuesta { "token": <str> }         32–256 ASCII, sin espacios
    debe ser DETERMINISTA: el mismo equipo con la misma credencial recibe el
    mismo token, para que un corte de energía a mitad no deje el equipo
    inutilizable

  POST /api/devices/register             header x-api-key: <token permanente>
    respuesta { "ok": true }  o  { "registered": true }

  Si el backend no existe todavía, impleméntalo como servicio aparte o
  documenta con precisión estos contratos para quien lo construya. Sin él, la
  aplicación NO puede flashear: la solicitud de credencial ocurre antes de
  escribir el primer byte.

INVARIANTES SIN EXCEPCIÓN:

  · La contraseña de fábrica vive SOLO en el keyring del sistema. Nunca en un
    archivo de configuración, en argv, en logs, ni en el repositorio.
  · Si el keyring no está disponible, FALLA con un error de dependencia
    explícito que nombre el paquete a instalar. NUNCA caigas a un archivo en
    texto plano ni a una variable de entorno.
  · El dispositivo nunca ve la contraseña de fábrica ni el token de sesión.
  · Los secretos viajan por STDIN o por archivos de configuración con modo 600.
    Nunca por argumentos de línea de comandos ni en la URL.
  · La cuenta de fábrica es de un rol dedicado, no administrativo, y NO se
    instala jamás en un dispositivo.
  · Ligar la credencial a la MAC hace que una imagen extraviada antes del
    primer arranque no pueda enrolar hardware ajeno. Prevé un modo del servidor
    que EXIJA el ligado y rechace las solicitudes sin MAC.
  · El servidor guarda solo HMACs, marca cuándo y por qué dispositivo se
    consumió cada credencial, y registra todo intento —aceptado o rechazado—
    con la IP del llamante. El dispositivo solo ve un error genérico.

CANJE RESISTENTE A CORTES DE ENERGÍA — el script de primer arranque ya
implementa esta secuencia; tu lado debe ser compatible con ella:
  1. escribir el token a un archivo temporal
  2. fijar propietario y modo restrictivos
  3. fsync del archivo
  4. rename atómico a su ubicación final
  5. fsync del DIRECTORIO
  6. RELEER el archivo y COMPARAR
  7. solo entonces borrar la credencial de un solo uso y fsync del directorio

TRADUCCIÓN DE ERRORES: convierte los rechazos del servidor en frases que un
operario de fábrica pueda accionar sin ayuda.


╔══════════════════════════════════════════════════════════════════════════╗
║ 13. FASE 9 — MULTIARQUITECTURA 32/64 BITS                                ║
╚══════════════════════════════════════════════════════════════════════════╝

El sistema debe fabricar con CUALQUIER imagen oficial, de 32 o 64 bits, SIN
tocar código. Los dos contratos que recibes son el punto de partida.

 1. UN CONTRATO POR ARQUITECTURA: el canónico más cualquier hermano con sufijo
    de variante. Añadir una arquitectura debe consistir en dejar caer otro
    archivo de contrato y nada más. Los scripts los descubren solos.

 2. HERRAMIENTA DE ALTA que derive un contrato nuevo DE LA PROPIA IMAGEN:
      · SHA-256 del archivo tal cual
      · arquitectura por cabecera ELF de un binario REAL del rootfs
      · codename y versión desde os-release
      · distribución según el archivo de fuentes que la imagen trae firmado, y
        no según una suposición
      · la lista de paquetes se COPIA del contrato canónico sin modificarla,
        para que las variantes no puedan divergir del contrato de producto
      · opción para construir el bundle y regenerar los payloads en el mismo
        paso

    NUNCA deduzcas la arquitectura del nombre del archivo. Una descarga mal
    etiquetada debe detectarse en segundos, no dentro del chroot tras veinte
    minutos de escritura.

 3. CONSTRUCTOR POR LOTES que genere un bundle por contrato en un directorio
    derivado de la propia identidad del contrato, y regenere todos los
    payloads. Si falta la imagen base de un contrato, SALTAR ese contrato con
    un aviso en lugar de fallar entero.

 4. RESOLUCIÓN DEL PAR bundle/payload en tiempo de flasheo, en tres niveles:
      a) el payload cuyo contrato embebido fija EXACTAMENTE ese nombre de
         imagen, emparejado con el repositorio generado del mismo contrato
         (comparando nombre de imagen base y arquitectura en su manifiesto)
      b) la arquitectura que el nombre anuncia mediante tokens DECISIVOS
         (armhf, armv6, armv7, arm64, aarch64), ignorando los ambiguos como
         "32bits" o "64bits"
      c) los valores por defecto canónicos
    Un payload SIN su repositorio correspondiente NUNCA se selecciona.

 5. La verificación de arquitectura real del rootfs de la Fase 6 permanece
    INTACTA. Una resolución equivocada debe fallar cerrado con mensaje claro.

 6. Las variantes se propagan hasta la UI: los comandos de estado, validación y
    construcción del bundle aceptan un parámetro de variante, validado contra
    path traversal. Omitirlo mantiene el comportamiento canónico.

NOTA SOBRE LOS PINS DE VERSIÓN
  Los validadores que recibes fijan una versión concreta de distribución. Es un
  control cruzado deliberado: el contrato debe coincidir con el os-release de
  la imagen Y con las fuentes que la imagen trae firmadas. No lo relajes por
  comodidad. DOCUMENTA en un solo lugar qué archivos hay que cambiar a la vez
  para subir de release.


╔══════════════════════════════════════════════════════════════════════════╗
║ 14. ERRORES CONOCIDOS QUE DEBES EVITAR                                   ║
╚══════════════════════════════════════════════════════════════════════════╝

Estos defectos aparecieron en una implementación previa. Evítalos por diseño y
escribe una prueba para cada uno:

 1. HOSTNAME PISADO. Si escribes el hostname del operario ANTES de invocar el
    instalador, y el instalador fija su propio hostname canónico, el valor del
    operario se pierde en silencio. Decide quién manda, documéntalo, y aplica
    el valor del operario DESPUÉS del instalador si debe prevalecer.

 2. URL DEL SERVIDOR A MEDIAS. Si individualizas la URL en un solo archivo de
    configuración pero el instalador crea OTRO archivo con una URL por defecto,
    el dispositivo acaba con dos verdades. Localiza TODOS los sitios donde
    aparece y reescríbelos todos, o falla si detectas alguno sin actualizar.

 3. CAMPO DOCUMENTADO PERO NO CABLEADO. Si el modelo de datos y el backend
    soportan ligar la credencial a una MAC pero el formulario no tiene ese
    campo, todas las credenciales salen sin ligar y la protección es papel
    mojado. Cablea de extremo a extremo todo campo que documentes.

 4. CAMPO RECOGIDO Y NO ENVIADO. No pidas al operario datos que no viajan a
    ninguna parte. Si un campo está en el formulario, debe llegar al modelo.

 5. RUTAS ABSOLUTAS DE LA MÁQUINA DEL DESARROLLADOR. Nunca escribas una ruta
    de un home concreto en el código. Resuélvelas desde la raíz del proyecto.

 6. MENSAJES DE ERROR QUE MENCIONAN RUTAS MUERTAS. Si eliminas un mecanismo,
    elimina también los mensajes que le dicen al operario que lo use.

 7. DOCUMENTACIÓN QUE CONTRADICE EL CONTRATO. Si la documentación cita un
    nombre de archivo de imagen distinto al que el contrato exige byte a byte,
    el operario pierde una hora. Genera los ejemplos desde el contrato.

 8. CÓDIGO MUERTO EQUIVALENTE. No dejes dos implementaciones de lo mismo, una
    enlazada y otra no. Borra la que no se usa.


╔══════════════════════════════════════════════════════════════════════════╗
║ 15. INVARIANTES DE SEGURIDAD — NO NEGOCIABLES                            ║
╚══════════════════════════════════════════════════════════════════════════╝

 1. La GUI nunca corre como root. La elevación es un proceso hijo acotado que
    hace una sola cosa y termina.
 2. Nunca se escribe en el disco del sistema. Doble control independiente.
 3. Los secretos nunca viajan por argv, por la URL, ni aparecen en logs.
 4. Los archivos de secretos son 0600 o 0640 con propietario explícito,
    abiertos con O_NOFOLLOW y creados con create_new.
 5. Las escrituras de credenciales son atómicas y VERIFICADAS por relectura.
 6. Los keyrings del host nunca se confían: se extraen de la imagen oficial
    verificada por hash.
 7. El repositorio local va firmado y se verifica antes de instalar.
 8. Cada paquete se verifica por tamaño, hash y metadatos de control REALES
    leídos del propio archivo, no por lo que diga el índice.
 9. La arquitectura se comprueba contra el binario ELF real del rootfs montado.
10. Un payload se valida contra su manifiesto ANTES y DESPUÉS de copiarse.
11. Un solo escritor por dispositivo, con lock de PID reclamable.
12. Ninguna instalación de dependencias se difiere al primer arranque.
13. Los mensajes de error son accionables para un operario de fábrica, en su
    idioma, y no filtran secretos.


╔══════════════════════════════════════════════════════════════════════════╗
║ 16. CRITERIOS DE ACEPTACIÓN                                              ║
╚══════════════════════════════════════════════════════════════════════════╝

Entrega SOLO cuando todo esto sea cierto:

  □ `cargo test --all-targets --all-features --locked --offline` pasa entero.
  □ El frontend compila con tsc en modo estricto y hace build sin avisos.
  □ El repositorio que construyes supera TODAS las validaciones de
    sigil-hardware/scripts/install-offline-packages.sh, comprobado ejecutándolo
    en modo de prueba.
  □ Existen pruebas unitarias de, como mínimo:
      · normalización de MAC, incluyendo el rechazo de una mal tecleada
      · validación de PIN: longitud, no numérico, repetido, ascendente,
        descendente y espacios exteriores accidentales
      · validación de contraseña y hostname en sus límites
      · rutas de partición para dispositivos sd, mmc y nvme
      · resolución del par bundle/payload en sus TRES niveles, más el caso del
        payload sin repositorio
      · reclamación de un lock con PID muerto y rechazo con PID vivo
      · idempotencia de la expansión de partición
      · tolerancia de códigos de salida del chequeo de sistema de archivos
      · máquina de estados del progreso: el escritor gana sobre el lanzador,
        el error conserva su mensaje, el fallo sin progreso respeta la gracia
      · rechazo de un contrato con la arquitectura equivocada
      · rechazo de un nombre de variante con path traversal
      · detección ELF de arquitectura para arm32, arm64 y x86
  □ Existe una prueba de que el payload copiado coincide con su manifiesto, y
    otra que DETECTA un archivo modificado después de generarlo.
  □ Existe una prueba de que la configuración privada usa modo 0600 y se
    elimina al destruirse su guarda.
  □ Existe una prueba de que la identidad escrita en la imagen contiene el
    número de serie pero NUNCA secretos de acceso.
  □ setup.sh soporta apt, pacman, dnf, zypper y apk, e instala Docker donde
    falten las herramientas de empaquetado Debian.
  □ La documentación explica: cómo dar de alta una imagen nueva, POR QUÉ los
    payloads quedan obsoletos y cuándo regenerarlos, cómo se prepara la
    credencial de fábrica, y qué archivos cambiar a la vez para subir de
    versión de distribución.
  □ Ningún secreto aparece en el repositorio ni en los artefactos públicos.
  □ El README describe la dependencia de sigil-hardware/: la aplicación no
    compila ni arranca sin ella.


╔══════════════════════════════════════════════════════════════════════════╗
║ 17. CÓMO TRABAJAR                                                        ║
╚══════════════════════════════════════════════════════════════════════════╝

· PRIMERO lee sigil-hardware/ completo y resume los contratos que detectaste.
  Verifica conmigo esa lectura antes de programar.
· Ve fase por fase. Compila y prueba antes de avanzar. No escribas diez
  archivos y compiles al final.
· Escribe los comentarios en el idioma del código que te rodea, y SOLO donde
  expliquen el PORQUÉ. Un comentario que repite la línea siguiente es ruido.
· Cuando un control parezca redundante —validar dos veces, verificar después de
  copiar, comprobar lo que acabas de escribir— NO lo elimines. Los dos lados de
  una frontera de privilegio no se confían mutuamente, y un sistema de archivos
  puede mentirte entre dos llamadas.
· Prefiere fallar cerrado. Ante la duda entre continuar con una suposición o
  abortar con un mensaje claro, aborta.
· Los mensajes de error son parte del producto. Un operario de fábrica debe
  poder resolver el problema leyéndolos, sin abrir el código.
· Si detectas una ambigüedad, resuélvela con el criterio más seguro y DILO
  explícitamente en tu informe final.
· Al terminar, entrega un resumen honesto: qué quedó completo, qué quedó fuera
  y por qué, y qué pruebas ejecutaste con su resultado REAL, incluidas las que
  fallaron.
````
