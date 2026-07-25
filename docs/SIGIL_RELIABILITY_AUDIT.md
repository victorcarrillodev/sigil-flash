# Auditoría de fiabilidad de SIGIL

**Fecha:** 2026-07-25  
**Plataforma observada:** Raspberry Pi Zero 2 W  
**Modalidad:** inspección acotada y de solo lectura

## 1. Veredicto ejecutivo

- **Seguridad térmica inmediata:** la medición puntual fue de **56,4 °C**,
  razonable para una Pi Zero 2 W. `get_throttled` no estuvo disponible, por lo
  que no se confirmó ni descartó histórico de subtensión o throttling.
- **Almacenamiento:** no existe presión de espacio, pero sí riesgo de pérdida
  lógica de caché y desgaste evitable por borrados, escrituras periódicas y una
  promoción que no es totalmente transaccional.
- **Regresión de fiabilidad:** sí. El mantenimiento activado por sesiones SSH
  detiene servicios, mata el reproductor y borra la caché. Además, un fallo
  temporal de PulseAudio/A2DP puede impedir conservar la bocina preferida en la
  versión instalada.
- **Operación continua:** el equipo es apto para pruebas supervisadas, no para
  operación desatendida hasta resolver los puntos P0.

Una carga normal no “daña la RAM”. El calor excesivo provoca throttling; los
cortes durante escrituras pueden corromper el sistema de archivos y las
escrituras repetidas desgastan la microSD.

## 2. Estado observado

| Recurso | Resultado |
|---|---|
| Temperatura | 56,4 °C |
| Carga | 0,87 / 0,77 / 0,61 |
| RAM | 447 MiB totales; 176 MiB usados; 270 MiB disponibles |
| Swap zram | aproximadamente 105–110 MiB usados de 447 MiB |
| Partición raíz | 29 GiB; 2,6 GiB usados; 10 % de ocupación |
| Journal | aproximadamente 8 MiB |
| Logs de SIGIL | aproximadamente 44 KiB |
| Servicios fallidos al inicio | ninguno |
| Procesos de audio | un PulseAudio y un `mpg123`; sin duplicados |
| Bluetooth | MINI emparejada, confiable y conectada; A2DP activo |
| Wi-Fi | conexión de 2,4 GHz |

Abrir y cerrar SSH activó la política de mantenimiento: `audio-player` y
`radio-fetcher` terminaron con código 143 y `audio-manager` se reinició una vez
por bloqueo de caché. Esto evidencia el problema descrito abajo.

## 3. Archivos y rutas sospechosas

| Archivo o unidad | Comportamiento | Riesgo | Severidad |
|---|---|---|---|
| `scripts/ssh-monitor.sh` | Al pasar de cero a una sesión SSH detiene servicios, ejecuta un `pkill -9 mpg123` global y borra la caché. Al salir vuelve a borrar y condiciona la recuperación a una descarga válida. | La administración remota interrumpe música y puede dejar el equipo sin caché si Internet falla. También puede matar procesos ajenos. | P0 |
| `scripts/sigil-logout-fetch-operation.sh` | Ejecuta recuperación y descarga después del cierre SSH. | Acopla el estado operativo del producto a una sesión administrativa. | P0 |
| `scripts/audio-manager.sh` | Al expirar la caché detiene el reproductor y borra primero; solo después intenta descargar si hay Internet. | Una interrupción de red convierte una caché reproducible, aunque antigua, en ausencia total de música. | P0 |
| `scripts/audio-manager.sh` | Reescribe `cache_meta.json`, usando reemplazo seguro, aproximadamente cada 10 segundos para el contador de reproducción. | Cerca de 8.640 actualizaciones diarias innecesarias y mayor desgaste. | P1 |
| `scripts/radio-fetcher.sh` | Descarga a *staging*, valida SHA-256 y rechaza una lista vacía salvo `stop_playback=true`, pero la promoción mueve `active` y `staging` en varios pasos. | Buena protección contra descargas parciales, pero un corte entre movimientos puede dejar estado incompleto. | P0 |
| `scripts/radio-fetcher.sh` | Copia `playlist.active.json` separadamente de la promoción. | Metadatos y pistas pueden quedar desincronizados tras un corte. | P1 |
| `scripts/audio-player.sh` | En modo RADIO usa `curl \| mpg123` aunque exista archivo local válido. | Al perder Internet, la pista actual puede detenerse y la transición a caché no es inmediata. | P1 |
| `scripts/bt-connect.sh` | La versión observada guarda la preferencia solo después de que A2DP termina correctamente. | Una bocina Paired+Trusted puede quedar sin registrar por un fallo transitorio del backend de audio. | P0 |
| `sigil-pulseaudio.service` | Depende de `/run/user/1001/pulse` y reinicia siempre cada 3 segundos. | El socket puede no existir durante cambios de sesión/runtime; una falla persistente puede producir reinicios y logs repetidos. | P0 |
| Unidades de audio y descarga | Varias usan `Restart=always`, intervalos cortos y límites de arranque ilimitados. | Un error persistente puede crear una tormenta de reinicios y registros. | P1 |
| `scripts/wifi-fallback.sh` | Comprueba conectividad cada 30 segundos y puede cambiar a modo AP con backoff. | Puede agravar una interrupción de red; no debería afectar reproducción local, pero hoy los estados están acoplados. | P1 |

`radio-fetcher` usa staging, valida SHA-256, rechaza respuestas vacías
accidentales y normalmente conserva `active` ante fallos. Estas defensas dejan
de servir si `ssh-monitor` o `audio-manager` borran `active` primero.

## 4. Diagnóstico Bluetooth

La identidad de la bocina y la disponibilidad de audio deben ser estados
independientes:

1. `Paired=yes` y `Trusted=yes` identifican la bocina preferida.
2. `Connected=yes` y `ServicesResolved=yes` confirman el enlace Bluetooth.
3. La tarjeta PulseAudio, el perfil A2DP y el sink confirman que se puede
   reproducir.

La versión instalada mezcla los pasos 1 y 3: solo persiste `preferred_bt` al
completar A2DP. Un fallo temporal de PulseAudio, un sink tardío o una bocina
apagada no debe convertirse en `NO_PREFERRED_SPEAKER`. La preferencia solo debe
eliminarse por una acción explícita de olvidar/desemparejar.

Existe un ajuste local no desplegado que guarda al alcanzar Paired+Trusted y
conserva la preferencia en fallos posteriores. Debe validarse.

El runtime es frágil porque los servicios asumen la presencia del socket de
usuario. `linger` y el UID eran correctos, pero hace falta un runtime explícito
y compartido.

La Pi Zero 2 W comparte radio/antena entre Wi-Fi de 2,4 GHz y Bluetooth. No se
encontró soporte comprobado para aumentar legal y seguramente la potencia de
transmisión. Las mejoras realistas son:

- mejor ubicación y orientación, alejadas de metal, cables USB ruidosos y la
  fuente de alimentación;
- fuente estable y carcasa que no bloquee la antena;
- reducir escaneos Wi-Fi innecesarios durante audio;
- elegir en el router un canal de 2,4 GHz menos congestionado;
- mantener cerca la bocina.

Este hardware no soporta Wi-Fi de 5 GHz, por lo que mover SIGIL a esa banda no es
una opción.

## 5. Pérdida de Internet y caché

- **Durante reproducción RADIO:** `curl` puede terminar y detener la pista. El
  gestor detecta la pérdida más tarde y puede pasar a LOCAL si la caché sigue
  válida.
- **Durante sincronización:** un fallo HTTP, DNS o descarga parcial normalmente
  conserva la caché activa.
- **Respuesta vacía:** no reemplaza la caché salvo que el servidor indique
  explícitamente `stop_playback=true`.
- **Descarga parcial:** permanece en staging y no debería sustituir una pista
  validada.
- **Arranque sin Internet:** puede reproducir caché válida, salvo que una ruta de
  mantenimiento o expiración la haya eliminado.
- **Caché expirada:** actualmente se puede borrar antes de confirmar su
  reemplazo; es el fallo offline más grave.
- **Reconexión Bluetooth:** debe continuar en segundo plano sin borrar caché ni
  identidad de la bocina.
- **Fallback Wi-Fi/AP:** no debería detener archivos locales, pero el diseño
  actual carece de una razón de estado única que distinga Internet, servidor,
  autenticación, caché y salida de audio.

## 6. Matriz de experiencia del cliente

| Caso | Comportamiento probable y síntoma | Estado recomendado | Severidad / corrección |
|---|---|---|---|
| Internet se pierde reproduciendo | La transmisión termina; silencio hasta cambiar a local. | `INTERNET_OFFLINE_USING_CACHE` | Alta: reproducir siempre el archivo validado local. |
| Reinicio sin Internet y con caché | Puede reproducir, salvo borrado previo. | `INTERNET_OFFLINE_USING_CACHE` | P0: nunca borrar antes de reemplazar. |
| Servidor no disponible | Fetch falla; caché suele sobrevivir. | `SERVER_UNREACHABLE_USING_CACHE` | Mantener caché y backoff. |
| DNS falla | Equivale a fallo de red y puede cortar RADIO. | `DNS_FAILURE_USING_CACHE` | Separar diagnóstico y continuar local. |
| Credenciales Wi-Fi inválidas | Fallback/AP; no hay sincronización. | `WIFI_DISCONNECTED_USING_CACHE` | Conservar audio local y exponer configuración. |
| Router reinicia | Pausa de red; posible corte del stream. | `INTERNET_OFFLINE_USING_CACHE` | Desacoplar reproducción de conectividad. |
| Bocina apagada o fuera de rango | Espera/reintentos; posible pérdida de preferencia instalada. | `BLUETOOTH_OUTPUT_WAITING` | Conservar preferencia y aplicar backoff. |
| Socket PulseAudio ausente | A2DP falla aunque BlueZ esté conectado. | `A2DP_NOT_READY` | Runtime explícito y orden de servicios. |
| Token rechazado | Sin playlist nueva; causa poco visible. | `DEVICE_AUTH_REJECTED` | No borrar caché; estado explícito sin registrar token. |
| Playlist vacía intencional | Solo debe parar con `stop_playback=true`. | `SERVER_STOP_PLAYBACK` | Mantener contrato y auditar transición. |
| Fetch de playlist falla | Activa suele conservarse. | `SERVER_UNREACHABLE_USING_CACHE` | Backoff y última lista válida. |
| Archivo corrupto | SHA falla; pista no reproducible. | `MEDIA_INTEGRITY_FAILURE` | Aislar pista, conservar las restantes y redescargar. |
| Almacenamiento lleno | Descarga/promoción falla. | `STORAGE_FULL` | Reserva mínima, limpieza segura y alerta. |
| Cortes de energía repetidos | Riesgo de estado parcial o filesystem dañado. | Estado de recuperación | Commit transaccional, fsync y fuente estable. |

## 7. Plan de remediación

### P0 — continuidad y datos

1. Eliminar de la política SSH los borrados de caché, el `pkill` global y la
   descarga obligatoria. SSH debe ser observacional.
2. Cambiar expiración a “descargar, validar y luego promover”; una caché expirada
   continúa siendo reproducible hasta tener sustituto.
3. Hacer la promoción recuperable: `active.next`, manifiesto final atómico,
   `fsync` de archivos/directorios y rollback al iniciar.
4. Administrar PulseAudio con un runtime estable y compartido, por ejemplo
   `/run/sigil-pulse`, en vez de asumir un socket de sesión.
5. Persistir la bocina al confirmar Paired+Trusted; conservarla en cualquier
   fallo temporal de conexión/A2DP; borrarla solo mediante forget/remove.

### P1 — estabilidad prolongada

1. Reproducir archivos locales validados siempre que existan; usar Internet solo
   para sincronización.
2. Sustituir reinicios ilimitados por `Restart=on-failure`, backoff y
   `StartLimitIntervalSec=300`/`StartLimitBurst=5`.
3. Persistir el contador de caché cada 5–15 minutos y en transiciones o apagado,
   no cada 10 segundos.
4. Controlar `mpg123` por PID/cgroup de la unidad, nunca con `pkill` global.
5. Comprobar espacio libre antes de descargar y promover.

### P2 — observabilidad y optimización

1. Unificar logs en journal o configurar rotación explícita para archivos.
2. Escribir estados solo cuando cambien.
3. Exponer un `reason_code` sin secretos para distinguir red, servidor,
   autenticación, caché y salida Bluetooth.
4. Medir reinicios, duración de escaneos, fallos A2DP y promociones de caché.

## 8. Archivos que requerirían cambios

- `sigil-hardware/scripts/ssh-monitor.sh`
- `sigil-hardware/scripts/sigil-logout-fetch-operation.sh`
- `sigil-hardware/scripts/audio-manager.sh`
- `sigil-hardware/scripts/audio-player.sh`
- `sigil-hardware/scripts/radio-fetcher.sh`
- `sigil-hardware/scripts/bt-connect.sh`
- unidades systemd de PulseAudio, audio, descarga y reconexión
- pruebas focalizadas de Bluetooth, caché, reproducción offline y coordinación

## 9. Pruebas focalizadas requeridas

1. Abrir/cerrar SSH no detiene audio, no mata procesos ni altera la caché.
2. Una caché expirada sigue reproduciendo si DNS/HTTP fallan.
3. Respuestas vacías no borran música, salvo `stop_playback=true`.
4. Descarga parcial, SHA inválido, almacenamiento lleno y corte simulado antes de
   cada paso de promoción recuperan el último `active`.
5. Un único reproductor por unidad; no hay `pkill` global.
6. Bocina Paired+Trusted queda preferida aunque PulseAudio/A2DP tarde o falle.
7. Reinicio de PulseAudio conserva preferencia y recupera el sink.
8. Reinicios de servicios quedan limitados y con backoff.
9. Reboot sin Internet reproduce la última caché válida.
10. La telemetría diferencia todos los `reason_code` sin exponer secretos.

## 10. Recomendación final

No se observó una emergencia térmica ni de capacidad de disco. Sin embargo,
SIGIL no debería dejarse en producción desatendida antes de corregir los P0:
una sesión SSH o la expiración de caché pueden eliminar música válida, la
reproducción RADIO depende innecesariamente de Internet y la identidad de la
bocina puede depender de un backend A2DP temporalmente inestable.

Después de aplicar los P0 y superar las pruebas focalizadas, debe realizarse una
prueba física prolongada con pérdida de Internet, apagado de la bocina, reinicio
del router, reinicio del servicio de audio y cortes de energía controlados,
monitorizando temperatura, throttling, reinicios, crecimiento de logs y
consistencia de la caché.
