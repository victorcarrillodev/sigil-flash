# sigil-hardware

Repositorio de configuración y software del dispositivo **Sigil** — un streamer de audio Bluetooth con panel web de configuración.

---

## Estructura del repositorio

```
sigil-hardware/
│
├── panel/                  # Panel web (Flask / Python 3)
│   ├── app.py              # Punto de entrada — rutas Flask + lógica BT/WiFi
│   └── templates/
│       └── index.html      # UI del panel (Jinja2 + CSS + JS)
│
├── scripts/                # Shell scripts del sistema
│   ├── bt-connect.sh       # Gestor de conexión BT exclusiva con auto-follow
│   ├── radio-stream.sh     # Reproductor de audio — auto-reconecta, anti-zombies
│   ├── set-a2dp.sh         # Aplica perfil A2DP al sink BT activo
│   ├── sigil-leds.sh       # Daemon de control de LEDs de hardware
│   ├── wifi-fallback.sh    # Fallback AP cuando no hay WiFi disponible
│   └── wifi-manager.sh     # Gestión inteligente de redes WiFi (cron/manual)
│
├── services/               # Unidades systemd
│   ├── bluetooth-panel.service   # Panel web Flask (puerto 80)
│   ├── bt-connect.service        # Gestor BT en background
│   ├── radio-stream.service      # Stream de audio
│   ├── sigil-leds.service        # Daemon de LEDs
│   └── wifi-fallback.service     # Fallback AP
│
└── conf/                   # Archivos de configuración del sistema
    ├── bluetooth-main.conf       # BlueZ — /etc/bluetooth/main.conf
    ├── default.pa                # PulseAudio — configuración de sink (append)
    ├── dnsmasq.conf              # DHCP para el AP de Sigil
    ├── hostapd.conf              # Configuración del AP WiFi
    ├── pulse-daemon.conf         # Daemon PulseAudio
    └── sigil-network.sudoers     # Reglas sudoers para nmcli, iw, systemctl
```

---

## Instalación rápida

Clona el repositorio en la Raspberry Pi y ejecuta el instalador:

```bash
git clone https://github.com/victorcarrillodev/sigil-hardware.git
cd sigil-hardware
sudo bash install.sh
sudo reboot
```

El script `install.sh` hace todo automáticamente:
- Instala paquetes del sistema (Python 3, BlueZ, PulseAudio, hostapd, dnsmasq, mpg123, NetworkManager…)
- Crea el usuario `sigil`
- Copia los archivos a sus rutas correctas
- Configura y habilita todos los servicios systemd
- Aplica las reglas sudoers
- Configura NetworkManager para controlar `wlan0`

---

## Deployment manual (referencia)

Los archivos del repositorio se copian manualmente al dispositivo. Las rutas de destino son las que usan los servicios systemd.

### Panel Python

```bash
# Copiar todos los archivos Python y el template al home de sigil
sudo cp panel/app.py /home/sigil/
sudo mkdir -p /home/sigil/templates
sudo cp panel/templates/index.html /home/sigil/templates/
```

### Scripts de sistema

```bash
# Los scripts van a /usr/local/bin/ y necesitan ser ejecutables
sudo cp scripts/bt-connect.sh scripts/radio-stream.sh scripts/set-a2dp.sh \
        scripts/sigil-leds.sh scripts/wifi-fallback.sh scripts/wifi-manager.sh \
        /usr/local/bin/
sudo chmod +x /usr/local/bin/*.sh
```

### Servicios systemd

```bash
sudo cp services/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bluetooth-panel bt-connect radio-stream sigil-leds wifi-fallback
```

### Configuración del sistema

```bash
# Bluetooth
sudo cp conf/bluetooth-main.conf /etc/bluetooth/main.conf

# PulseAudio — añadir directiva al final del default.pa existente
# (no sobreescribir completo; solo agregar la línea si no existe)
grep -qxF 'load-module module-switch-on-connect' /etc/pulse/default.pa \
  || echo 'load-module module-switch-on-connect' | sudo tee -a /etc/pulse/default.pa
sudo cp conf/pulse-daemon.conf /etc/pulse/daemon.conf

# Red
sudo cp conf/dnsmasq.conf /etc/dnsmasq.conf
sudo cp conf/hostapd.conf /etc/hostapd/hostapd.conf

# Sudoers
sudo cp conf/sigil-network.sudoers /etc/sudoers.d/sigil-network
sudo chmod 440 /etc/sudoers.d/sigil-network
```

---

## Dependencias Python

```bash
pip3 install flask qrcode[pil]
```

- **flask** — servidor web del panel
- **qrcode** *(opcional)* — generación de QR para la URL del panel

---

## Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `SIGIL_SECRET_KEY` | `sig_sasso_panel_2026` | Secret key de la sesión Flask. Sobreescribir en producción. |

Para sobreescribir en producción, agregar al servicio `bluetooth-panel.service`:
```ini
[Service]
Environment=SIGIL_SECRET_KEY=tu_clave_segura_aqui
```

---

## Notas de compatibilidad (Raspberry Pi Zero 2 W)

- `conf/bluetooth-main.conf` — configura BlueZ con `FastConnectable=true` y `AutoEnable=true`. **Requiere reiniciar `bluetooth.service`** después de copiarlo.
- `conf/default.pa` — **solo añadir la línea** `load-module module-switch-on-connect` al final del `default.pa` existente en la Pi, no reemplazarlo completo.
- `scripts/wifi-manager.sh` — no tiene servicio systemd asociado. Se ejecuta manualmente o via cron para limpiar perfiles WiFi viejos:
  ```bash
  # Ejemplo: ejecutar cada noche
  0 3 * * * /usr/local/bin/wifi-manager.sh
  ```
- El panel Flask corre como `root` (puerto 80). Las operaciones de `bluetoothctl` / `nmcli` se ejecutan bajo el usuario `sigil` donde es posible, y el resto via `sudo` controlado por `sigil-network.sudoers`.

---

## Arquitectura rápida

```
Celular/Tablet
    └─ WiFi → AP Sigil (hostapd) → Panel Flask :80
                                        ├─ /            → index.html
                                        ├─ /scan/stream → SSE BT scan
                                        ├─ /connect/<mac>
                                        ├─ /pair
                                        ├─ /wifi/scan
                                        └─ /wifi/connect

Sigil
    └─ PulseAudio → BT A2DP → Altavoz
    └─ bt-connect.service   → mantiene la conexión BT activa
    └─ radio-stream.service → reproduce el stream de audio
```

### WiFi Fallback v3

`scripts/wifi-fallback.sh` implementa una máquina de estados de radio única:
`CLIENT_CONNECTING`, `CLIENT_ONLINE`, `CLIENT_LOCAL_ONLY`,
`CLIENT_LINK_DEAD`, `AP_ACTIVE` y `RECOVERY_PROBING`. La disponibilidad se
comprueba por capas (asociación, dirección, ruta, gateway, DNS y dos endpoints
HTTPS); una caída sólo de Internet permanece en `CLIENT_LOCAL_ONLY` y no activa
el AP. La histéresis, los timeouts y los backoffs se configuran en
`/etc/sigil/wifi-fallback.conf`.

El panel usa `/run/sigil/wifi-transition.lock` y un inhibit acotado con identidad
de proceso para que el AP no reaparezca mientras NetworkManager asocia y obtiene
DHCP. En `AP_ACTIVE`, hostapd y el modo cliente nunca se usan simultáneamente:
la recuperación detiene temporalmente el AP, prueba un perfil guardado y lo
restaura una sola vez si la transición falla. Las contraseñas WiFi no se guardan
en el estado ni se escriben en logs.

El estado persistido separa el modo de radio (`STATE`) de la última condición
cliente (`CLIENT_STATE`); por ejemplo, tras confirmar un enlace fantasma puede
registrar `STATE=AP_ACTIVE` y `CLIENT_STATE=CLIENT_LINK_DEAD` simultáneamente.

---

## Manifests (v2)

Since 2026-07-01, `sigil-hardware/manifests/` contains the canonical specs:

- `offline-package-contract.json` — canonical distribution, architecture, required/optional packages and version policy
- `install-layout.json` — file copy mapping
- `services.json` — systemd enable/disable
- `system-config.json` — boot/config/user settings

These manifests replace `pi-gen/stage-sigil` as the source of truth.
pi-gen remains as legacy/reference until the flasher is validated.
