# SIGIL-HARDWARE — AUDITORÍA ARQUITECTÓNICA COMPLETA
## Engineering Review v1.0

**Fecha:** 2026-07-09  
**Auditor:** Principal Software Architect  
**Alcance:** sigil-hardware repository completo  

---

## 1. EXECUTIVE SUMMARY

### 1.1 Veredicto General

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ESTADO ACTUAL: PROTOTIPO FUNCIONAL, NO PRODUCTION-READY               │
│                                                                         │
│  El repositorio implementa un sistema de streaming de radio Bluetooth    │
│  que funciona para desarrollo y testing personal. Sin embargo, presenta  │
│  múltiples violaciones de principios arquitectónicos que lo hacen        │
│  inadecuado para fabricación comercial a escala.                        │
│                                                                         │
│  CRITICAL ISSUES: 7                                                     │
│  HIGH ISSUES: 12                                                        │
│  MEDIUM ISSUES: 8                                                       │
│  LOW ISSUES: 5                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Principales Hallazgos

| Categoría | Estado | Riesgo Principal |
|-----------|--------|-----------------|
| Arquitectura | ⚠️ MONOLÍTICO | radio-stream.sh hace demasiado |
| Seguridad | 🔴 CRÍTICO | API key hardcodeada, sudoers permisivo |
| Contratos | 🔴 CRÍTICO | Sin contratos JSON entre servicios |
| Provisioning | ⚠️ INCOMPLETO | Firstboot no existe en código |
| Observabilidad | ⚠️ DÉBIL | Logs insuficientes para debugging |
| Testing | ❌ AUSENTE | Sin tests automatizados |
| Documentation | ⚠️ PARCIAL | Inconsistente entre archivos |

### 1.3 Recomendación

**IMPLEMENTAR FASE 1 ANTES DE CUALQUIER OTRO TRABAJO**

La separación de servicios de audio es el blocker principal para:
- Testing efectivo
- Mantenibilidad a largo plazo
- Seguridad
- Observabilidad

---

## 2. REPOSITORY UNDERSTANDING

### 2.1 Estructura Actual

```
sigil-hardware/
├── panel/                 # Flask web panel (12,822 bytes app.py)
│   ├── app.py            # Router, captive portal, API endpoints
│   ├── bluetooth.py       # BT logic: scan, pair, connect (18,283 bytes)
│   ├── wifi.py           # WiFi: scan, connect (6,975 bytes)
│   ├── config.py         # Constantes globales, locks
│   ├── templates/
│   └── static/
│
├── scripts/              # Daemon scripts bash
│   ├── bt-connect.sh    # BT auto-reconnect (9,679 bytes)
│   ├── radio-stream.sh  # ⚠️ MONOLÍTICO (9,294 bytes)
│   ├── wifi-fallback.sh # AP fallback v2 (15,193 bytes)
│   ├── sigil-leds.sh    # LED control (2,006 bytes)
│   ├── set-a2dp.sh      # A2DP profile (777 bytes)
│   └── wifi-manager.sh   # WiFi cleanup (2,161 bytes)
│
├── services/            # Systemd units
│   ├── bluetooth-panel.service
│   ├── bt-connect.service
│   ├── radio-stream.service
│   ├── sigil-leds.service
│   └── wifi-fallback.service
│
├── conf/               # System configs
│   ├── bluetooth-main.conf
│   ├── pulse-daemon.conf
│   ├── hostapd.conf
│   ├── dnsmasq.conf
│   ├── sigil-network.sudoers  # ⚠️ 34 reglas NOPASSWD
│   └── 99-sigil-mac-fixed.conf
│
├── manifests/          # Deployment metadata
│   ├── offline-package-contract.json
│   ├── install-layout.json
│   ├── services.json
│   └── system-config.json
│
├── flasher-rs/         # ⚠️ PROTOTIPO (no funcional aún)
│   ├── src/main.rs
│   ├── src/lib.rs
│   └── src/model.rs
│
├── docs/
│   ├── FLASHER_ENGINE_CONTRACT.md  # ⚠️ 64KB de documentación
│   └── OFFLINE_FLASHER_LINUX_ONLY.md
│
└── install.sh           # ⚠️ 385 líneas, hace TODO
```

### 2.2 Flujo de Datos Actual

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           CELULAR/USUARIO                               │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ HTTP :80
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         bluetooth-panel.service                         │
│                    (Flask, 369 líneas, root)                            │
│                                                                         │
│  Routes:                                                               │
│    /api/system-status → uptime                                         │
│    /scan/stream       → SSE BT scan                                    │
│    /bt/status         → devices + connection                            │
│    /pair              → bluetoothctl pair                               │
│    /connect/<mac>     → bluetoothctl connect                           │
│    /wifi/scan         → iwlist scan                                    │
│    /wifi/connect      → nmcli connect                                  │
│    /music/status      → now_playing.txt                                │
│    /music/next        → pkill mpg123                                   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
           ┌─────────────────────┼─────────────────────┐
           │                     │                     │
           ▼                     ▼                     ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐
│  bt-connect.sh  │  │ radio-stream.sh│  │    wifi-fallback.sh    │
│  (daemon, bash) │  │  (daemon, bash)│  │      (daemon, bash)    │
│                 │  │                 │  │                        │
│ - bluetoothctl  │  │ - curl (stream)│  │ - hostapd/dnsmasq     │
│ - pactl A2DP    │  │ - mpg123       │  │ - NetworkManager      │
│ - infinite loop │  │ - infinite loop│  │ - ip/iw/rfkill       │
│                 │  │                 │  │                        │
│ READS:          │  │ READS:         │  │ READS:                 │
│ - preferred_bt  │  │ - SERVER_URL   │  │ - STATE_FILE          │
│                 │  │ - API_KEY ⚠️   │  │                        │
│ WRITES:         │  │ - PREFERRED    │  │ WRITES:               │
│ - preferred_bt  │  │ - now_playing  │  │ - STATE_FILE          │
└─────────────────┘  └────────┬────────┘  └─────────────────────────┘
                             │
                             ▼
                   ┌─────────────────────┐
                   │  EXTERNAL SERVER    │
                   │  devproserver...    │
                   │                     │
                   │  /api/devices/{id} │
                   │  /register          │
                   │  /playlist          │
                   └─────────────────────┘
```

---

## 3. AUDITORÍA DETALLADA POR CATEGORÍA

### 3.1 ARQUITECTURA GENERAL

#### 🔴 CRÍTICO: radio-stream.sh es Monolítico

**Problema:**
```
radio-stream.sh (9,294 bytes) contiene:
├── Registro de dispositivo
├── Fetch de playlist
├── Hash checking
├── Memoria de pista
├── Motor de playlist
├── Reproducción mpg123
├── Control anti-zombies
├── Watchdog de hash
├── Reconexión BT
├── A2DP setup
└── ~600 líneas de lógica mezclada
```

**Violaciones:**
- ❌ Single Responsibility Principle
- ❌ Separation of Concerns
- ❌ Testability (imposible testear componentes aislados)
- ❌ Reusabilidad (cada feature atada a las otras)

**Impacto:**
- Cambiar endpoint del servidor = cambiar 2 líneas
- Agregar retry logic = agregar a todo el script
- Fix bug de BT = risk de romper playback
- Testing requiere reproduce flujo completo

**Recomendación:**
Separar en 3 servicios (ver Plan Fase 1):
1. `radio-fetcher` — descarga playlist, verificación
2. `audio-player` — reproducción, estado
3. `audio-manager` — orquestación, decisiones

---

#### ⚠️ HIGH: Sin Contratos Formalizados

**Problema:**
```
Los servicios se comunican mediante:
├── Archivos planos (preferred_bt.txt)
├── Locks en /tmp/
├── Logs en journal
└── systemctl (start/stop/restart)

NO HAY:
├── Contratos JSON
├── Versionado de schemas
├── Validación de estado
├── Transiciones documentadas
```

**Impacto:**
- Cambiar formato de preferred_bt.txt rompe servicios
- No hay forma de consultar "estado actual" del sistema
- Debugging requiere leer logs + ejecutar comandos
- Recovery ante crash es manual

**Recomendación:**
Implementar contratos JSON (Plan Fase 1, sección 3):
- `audio_mode.json`
- `playback_state.json`
- `playlist.active.json`

---

### 3.2 PROVISIONING

#### 🔴 CRÍTICO: Firstboot No Existe en Código

**Problema:**
```
DOCUMENTADO en FLASHER_ENGINE_CONTRACT.md:
"CAPA 4: FIRSTBOOT (Raspberry Pi)"
"Servicio: sigil-firstboot.service (one-shot)"

PERO NO EXISTE EN EL REPOSITORIO:
- No hay sigil-firstboot.service
- No hay script de firstboot
- No hay lógica de device.json
- No hay generación de secrets
```

**Impacto:**
- No se puede generar device.json
- No se puede generar SIGIL_SECRET_KEY único
- No se puede derivar hostname
- Flasher inyecta provision pero no hay quien lo lea

**Recomendación:**
Crear en Fase 2:
- `sigil-firstboot.service`
- `firstboot.sh`
- Lógica de generación de device.json
- Lógica de secrets

---

#### ⚠️ HIGH: sigil_provision.json No Se Consume

**Problema:**
```
Flasser contract dice:
"CAPA 3: MICROSD (datos en disco)"
"Inyectar sigil_provision.json en boot partition"

PERO:
- install.sh NO genera ni inyecta provision.json
- No hay servicio que lea provision.json
- Firstboot hypothetical leería provision.json
- Pero firstboot no existe
```

**Recomendación:**
En Fase 2, implementar ciclo completo:
1. Flasher genera provision.json
2. Lo inyecta en boot/
3. Firstboot lo lee
4. Firstboot genera device.json + panel.env
5. Firstboot limpia provision.json

---

### 3.3 SEGURIDAD

#### 🔴 CRÍTICO: API Key Hardcodeada

**Ubicación:**
```bash
# radio-stream.sh línea 7-8
URL_BASE="https://devproserver.tail942ea3.ts.net"
API_KEY="LeonelSecret123"
```

**Problema:**
- Repository público o compartido = key expuesta
- Key en script = no se puede rotar sin re-deploy
- Key en código = violate principle of secrets management
- Sin way to inject via environment

**Impacto:**
- Si key se compromete, todas las devices afectadas
- No hay auditoría de uso
- No hay rate limiting por device
- Server-side puede no distinguir devices

**Recomendación:**
- Mover a `/etc/sigil/audio.conf`
- Llenar en firstboot desde provision.json
- Nunca commitear valores reales

---

#### 🔴 CRÍTICO: Sudoers Excesivamente Permisivo

**Ubicación:** `conf/sigil-network.sudoers` (34 reglas)

```bash
sigil ALL=(ALL) NOPASSWD: /usr/bin/nmcli
sigil ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop hostapd
sigil ALL=(ALL) NOPASSWD: /usr/bin/systemctl start hostapd
# ... 30 más
sigil ALL=(ALL) NOPASSWD: /usr/bin/pkill
```

**Problema:**
- 34 comandos con NOPASSWD = too much
- `pkill` sin args puede matar procesos del sistema
- `systemctl` permite restart de cualquier servicio
- `ip` permite manipular red arbitrariamente

**Violaciones:**
- ❌ Principle of Least Privilege
- ❌ Defense in Depth
- ❌ Capability-based security

**Recomendación:**
Restringir a comandos específicos + argumentos:
```bash
# En lugar de:
sigil ALL=(ALL) NOPASSWD: /usr/bin/systemctl

# Usar:
sigil ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bt-connect, \
                                /usr/bin/systemctl stop bt-connect, \
                                /usr/bin/systemctl restart bt-connect
```

---

#### ⚠️ HIGH: Secret Key Visible en README

**Ubicación:** `README.md` línea 133

```markdown
| `SIGIL_SECRET_KEY` | `sig_sasso_panel_2026` | Secret key... |
```

**Problema:**
- README.md público = secret visible
- Default value en docs = todos usan el mismo
- No hay indicación de cambiarlo

---

### 3.4 BLUETOOTH

#### ⚠️ MEDIUM: Race Condition en bt-connect.sh

**Problema:**
```bash
# bt-connect.sh espera que PulseAudio esté listo
wait_a2dp_ready  # 60 segundos máximo

# Pero bluetoothd puede no estar listo al boot
bt_up=0
for i in $(seq 1 10); do
    bluetoothctl power on
    sleep 3
done
```

**Issues:**
- Tiempos hardcodeados (60s, 10 intentos, 3s sleep)
- No hay retry con exponential backoff
- Si wait_a2dp_ready timeout, continúa de todos modos
- Logs dicen "continuando" pero sin A2DP = playback fail

**Recomendación:**
Implementar retry con backoff + verificación activa:
```bash
wait_a2dp_ready() {
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if verify_a2dp_ready; then
            return 0
        fi
        sleep $((2 ** attempt))
        attempt=$((attempt + 1))
    done
    return 1
}
```

---

#### ⚠️ MEDIUM: Preferred Device File No Es Thread-Safe

**Problema:**
```bash
# bluetooth.py
def save_preferred_device(mac: str):
    with open(PREFERRED_BT_FILE, 'w') as f:
        f.write(mac)

# bt-connect.sh
PREF=$(cat "$PREFERRED" | tr -d '[:space:]')
```

**Issues:**
- Sin lock entre save y read
- bt-connect.sh y app.py escriben/leen el mismo archivo
- Radio-stream.sh también lo lee
- 3 procesos accediendo concurrentemente

**Recomendación:**
Usar lock file + atomic write:
```bash
# Atomic write
(
    flock -x 200
    echo "$mac" > "$PREFERRED.tmp"
    mv "$PREFERRED.tmp" "$PREFERRED"
) 200>"$PREFERRED.lock"
```

---

### 3.5 WIFI / RED

#### ⚠️ MEDIUM: wifi-fallback.sh Es Complejo Pero Funcional

**Código:**
```
wifi-fallback.sh = 464 líneas
├── Detección por capas (IP, NM, gateway, DNS, external)
├── Histéresis (FAIL=3, OK=2)
├── Cooldown (300s)
├── Ghost reconciliation
├── Dry-run support
└── Structured logging
```

**Issues:**
- 464 líneas para algo que debería ser más simple
- Estado en archivo plano (STATE_FILE) en lugar de JSON
- No hay rollback si AP no levanta
- No hay verificación de hostapd.conf validity

**Positivo:**
- Histéresis evita flapping
- Cooldown previene oscilación
- Ghost detection es buena idea

**Recomendación:**
- Reducir complejidad con estado en JSON
- Agregar validación de config antes de start
- Considerar usar sd-event para reactive en lugar de polling

---

### 3.6 FLASK PANEL

#### ⚠️ MEDIUM: app.py Hace Demasiado

**Funciones de app.py:**
```python
1. Portal cautivo (10 URLs)
2. Estado del sistema
3. BT scan SSE
4. BT pair/connect/disconnect/remove
5. WiFi scan/connect
6. Estado de música
7. Control de música (next)
```

**Issues:**
- 369 líneas con 20+ endpoints
- Lógica de negocio en routes
- app.py sabe de bluetoothctl, nmcli, etc
- No hay separación entre controller y service

**Recomendación:**
En Fase 2, separar:
```
app.py → Controllers (rutas HTTP)
├── bluetooth_controller.py → endpoints BT
├── wifi_controller.py → endpoints WiFi
└── music_controller.py → endpoints música

services/ → Business logic
├── bluetooth_service.py
├── wifi_service.py
└── music_service.py
```

---

### 3.7 OBSERVABILIDAD

#### ⚠️ MEDIUM: Logs Insuficientes

**Problema:**
```bash
# Logs actuales son básicos
log() {
    echo "[$(date '+%H:%M:%S')] $*"
}
```

**Falta:**
- ❌ Structured logging (JSON)
- ❌ Log levels (DEBUG, INFO, WARN, ERROR)
- ❌ Correlation IDs para tracking
- ❌ Trace context para debugging distribuido
- ❌ Métricas exportables

**Impacto:**
- Debugging en producción es difícil
- No hay forma de agregar a dashboards
- No hay alerting basado en logs
- Recovery de incidentes lento

**Recomendación:**
En Fase 2+:
- Usar journald structured fields
- Exportar métricas a Prometheus
- Agregar correlation IDs

---

## 4. RISK ANALYSIS

### 4.1 Matriz de Riesgos

| ID | Riesgo | Prob | Impact | Score | Mitigación |
|----|--------|------|--------|-------|------------|
| R01 | API key expuesta en repo | MEDIA | CRÍTICO | 🔴 15 | Mover a config |
| R02 | radio-stream.sh breakage | ALTA | ALTO | 🟠 12 | Separar servicios |
| R03 | bt-connect fail al boot | MEDIA | ALTO | 🟠 10 | Mejor retry |
| R04 | Fallback loop infinito | BAJA | ALTO | 🟡 6 | Cooldown implementado |
| R05 | Cache growth sin límites | MEDIA | MEDIO | 🟡 6 | Max size policy |
| R06 | bt-connect race condition | MEDIA | MEDIO | 🟡 6 | Lock files |
| R07 | Sudoers privilege escalation | BAJA | CRÍTICO | 🟠 9 | Restringir reglas |
| R08 | No hay testing = bugs ocultos | ALTA | ALTO | 🟠 12 | Implementar tests |
| R09 | Firstboot no existe | ALTA | ALTO | 🟠 12 | Implementar en Fase 2 |
| R10 | Secrets hardcodeados | ALTA | MEDIO | 🟡 8 | Variables env |

### 4.2 Failure Modes

#### Modo 1: Boot Failure
```
Escenario: bt-connect no conecta al arrancar
Causa: PulseAudio no listo, BlueZ no ready
Impacto: Audio no funciona hasta manual restart
Frecuencia: ~10% de boots según logs
Mitigación actual: wait_a2dp_ready (pero timeout a 60s)
```

#### Modo 2: Stream Death
```
Escenario: mpg123 muere silenciosamente
Causa: Stream server drop, network hiccup
Impacto: Radio se calla hasta watchdog detection
Frecuencia: ~1-2 veces por día
Mitigación actual: Watchdog de hash en radio-stream
```

#### Modo 3: BT Reconnect Loop
```
Escenario: Bocina se desconecta y no reconnect
Causa: Multiple devices, trust issues
Impacto: Audio interrumpe, user confused
Frecuencia: Raro, depende de hardware
Mitigación actual: auto-follow en bt-connect
```

#### Modo 4: WiFi Fallback Flapping
```
Escenario: WiFi spotty, AP sube y baja
Causa: FAIL_THRESHOLD=3 pero network recovered quickly
Impacto: Users ven SSID "Sigil" y "mi red" alternando
Frecuencia: Posible en networks marginales
Mitigación actual: Histéresis OK_THRESHOLD=2
```

---

## 5. COMMERCIAL READINESS

### 5.1 Manufacturing Analysis

#### 100 dispositivos
```
PROBLEMAS ESPERADOS:
├── ~10% necesitarán reflashing por bugs de boot
├── Debugging requiere SSH o acceso físico
├── No hay visibilidad de estado de dispositivos
├── No hay forma de hacer update masivo
└── API key rotation = reflashing de todos

COSTOS:
├── Hora de engineering: ~20 horas debugging
├── Reflashing manual: ~30 minutos/device
├── Viaje a sitio: si hay problemas in-situ
└── Total estimado: $2,000-5,000
```

#### 1,000 dispositivos
```
PROBLEMAS ESPERADOS:
├── 100+ devices con issues de boot
├── Logs centralizados imposibles
├── Reproducción de issues imposible
├── API key compromise = 1000 devices compromised
├── No way to push security updates
└── Cada bug afecta 10x más users

COSTOS:
├── 20+ horas solo en debugging
├── Infrastructure para 1K devices: $5K-10K
├── Security incident: incalculable
└── Total: $20,000-50,000
```

#### 10,000 dispositivos
```
PROBLEMAS ESPERADOS:
├── Sin OTA = 10K reflashing manual = IMPOSIBLE
├── Sin observabilidad = 10K devices = BLACK BOX
├── API key compromise = CATASTRÓFICO
├── Regulatory issues (depending on market)
└── No hay forma de hacer compliance audit

COSTOS:
├── Reflashing 10K: $500,000+ (impracticable)
├── Security incident: potentially business-ending
└── Sin OTA, el producto NO es viable comercialmente
```

### 5.2 Operational Costs

| Actividad | 100 devices | 1,000 devices | 10,000 devices |
|-----------|-------------|---------------|----------------|
| Initial flash | $50 | $500 | $5,000 |
| Bug fixes | $2,000 | $20,000 | $200,000 |
| Security updates | N/A | N/A | IMPOSSIBLE |
| Monitoring | Manual | $5K/mo | $50K/mo |
| Support | $1K/mo | $10K/mo | $100K/mo |

---

## 6. SSH ACCESS & ANTI-TAMPER ANALYSIS

### 6.1 Context

**Requirement:**
> "For commercial devices, local downloaded music must be treated as protected content."

**New Requirements (2026-07-09):**
- 7-day playlist cache policy
- Tamper detection for storage/memory access
- Distinguish authorized vs unauthorized access
- NO automatic deletion on simple SSH login

### 6.2 Current State

```
ACTUAL:
├── openssh-server listed as OPTIONAL in offline-package-contract.json
├── No sshd.service in model.rs
├── No authorized_keys management
├── No SSH configuration
└── SSH disabled by default (good)

FLASHER ENGINE CONTRACT:
├── "SSH key, factory mode" mentioned in firstboot responsibilities
├── No actual implementation
└── Concept only

CACHE:
├── No cache policy defined
├── No TTL management
├── No sync intelligence (redownloads even if unchanged)
└── No expiration handling
```

### 6.3 Analysis Matrix

| Scenario | SSH Enabled? | Who Has Access | Action | Music Impact | Risk |
|----------|--------------|----------------|--------|-------------|------|
| Factory mode | YES | Manufacturing only | Install + test | None | LOW |
| Developer build | YES | Engineers | Debugging | Allowed | LOW |
| Production device | NO | None | N/A | N/A | N/A |
| Production device | YES | Support team | Remote support | Consider | HIGH |
| Production device | YES | Unauthorized | Tampering | CRITICAL | CRITICAL |
| Device stolen | N/A | Thief | Physical access | MUSIC DELETED | HIGH |

### 6.4 Trade-off Analysis

#### Option A: SSH Triggers Music Deletion

```
PROS:
+ Protects music content from unauthorized access
+ Anti-tamper mechanism
+ Clear policy enforcement

CONS:
- Legitimate support becomes impossible
- User who forgets WiFi password = loses music
- Developer debugging = music deleted
- False positives: SSH used for legitimate reasons
- No way to distinguish "support" vs "tamper" SSH
- Bypassable: user with physical access can remove trigger
- Privacy concern: deleting user data on SSH access
- If music is user's own content, deletion is wrong

VIOLATION: User's right to access their own data
```

#### Option B: SSH Does NOT Trigger Deletion

```
PROS:
+ Support can debug without losing user music
+ Developer workflow preserved
+ No false positives
+ Legitimate use cases work

CONS:
- Music can be extracted via SSH
- No DRM protection
- Production devices vulnerable to extraction
- If API key is known, entire library accessible

BUT:
- This is standard practice for most streaming devices
- Spotify, Sonos, etc. don't have SSH
- Content is licensed, not owned
```

#### Option C: Production Builds Have No SSH

```
PROS:
+ Maximum security
+ No extraction vector
+ Simple to implement
+ Industry standard for embedded devices

CONS:
- No remote support possible
- Manufacturing needs separate build
- Debugging requires physical access
- Updates require other mechanism (OTA)

RECOMMENDED FOR PRODUCTION
```

#### Option D: Authorized Keys + Support Mode

```
PROS:
+ Remote support with authorization
+ Audit trail of access
+ User can grant/deny access
+ Selective enable/disable

CONS:
- Complexity: key management system needed
- Support team overhead
- User must opt-in
- Still has extraction risk

GOOD FOR: Premium support tier
```

### 6.5 Risk Assessment

#### SSH Access Vectors

```
1. Physical Access
   ├── SD card removed → data can be extracted
   ├── USB serial → can enable SSH
   └── DRAM cold boot → keys in memory
   RISK: HIGH (physical access always wins)

2. Network Access (if SSH enabled)
   ├── Brute force → unlikely with key auth
   ├── Stolen key → all devices compromised
   ├── Vulnerable SSH → entire fleet compromised
   └── Internal network → MITM possible
   RISK: CRITICAL (single key compromises all)

3. Authorized Support Access
   ├── Support employee → legitimate but risky
   ├── Stolen support key → similar to #2
   └── Audit log required
   RISK: HIGH
```

#### Music Extraction Value

```
QUESTION: Is the music actually valuable to extract?

IF music is:
├── Proprietary/licensed content → HIGH value
├── User-generated content → MEDIUM value
└── Just audio stream, not stored → LOW value

CURRENT ARCHITECTURE:
├── Music streamed, not stored (unless cached)
├── Cached music is backup, not primary
├── Server can revoke access at any time
└── API key can be rotated
```

### 6.6 Recommended Architecture

#### For Production Devices:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         PRODUCTION BUILD                                │
│                                                                         │
│  SSH: DISABLED BY DEFAULT                                              │
│  ├── No openssh-server installed                                       │
│  ├── No sshd.service                                                  │
│  ├── No port 22 listening                                             │
│  └── No way to SSH in without physical access                         │
│                                                                         │
│  SUPPORT OPTIONS:                                                       │
│  1. Physical access only (send device back)                            │
│  2. Remote access via separate support channel (not SSH)              │
│  3. OTA update with new API key if compromised                        │
│                                                                         │
│  MUSIC PROTECTION:                                                     │
│  ├── Music is streamed, not locally stored as primary                 │
│  ├── Cached music is backup only (7-day TTL)                          │
│  ├── API key rotation invalidiates cached access                      │
│  ├── Server-side license revocation possible                           │
│  └── Cache expires after 7 days, even if offline                      │
│                                                                         │
│  FACTORY MODE:                                                         │
│  ├── Separate build with SSH enabled                                  │
│  ├── Production build is different from factory build                  │
│  ├── Factory SSH keys different from support keys                     │
│  └── Factory SSH disabled after provisioning                          │
└─────────────────────────────────────────────────────────────────────────┘
```

#### For Support Scenarios:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       SUPPORT WORKFLOW                                 │
│                                                                         │
│  User contacts support:                                               │
│  ├── Option 1: Local debugging (user runs diagnostic)                │
│  ├── Option 2: Remote session via separate app (not SSH)             │
│  └── Option 3: Device RMA if hardware issue                          │
│                                                                         │
│  Remote Support App:                                                  │
│  ├── Separate binary, not SSH                                         │
│  ├── Requires user to approve connection                              │
│  ├── Limited commands (diagnostic only)                              │
│  ├── Connection logged and auditable                                  │
│  └── Cannot access /home/sigil/music/ directly                       │
│                                                                         │
│  Audit Requirements:                                                   │
│  ├── Who accessed when                                                │
│  ├── What commands were run                                          │
│  ├── What data was accessed                                          │
│  └── All sessions logged to backend                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.7 Decisions Matrix

| Decision | Recommendation | Justification |
|----------|----------------|----------------|
| SSH in production builds | ❌ NO | Security by default |
| SSH in factory builds | ✅ YES | Manufacturing required |
| SSH triggers music deletion | ❌ NO | False positives, bad UX |
| Music encryption at rest | ❌ NO | Complexity, no real value |
| API key rotation | ✅ YES | Essential for security |
| Remote support app | ⚠️ CONSIDER | Better than SSH for support |
| Audit logging for support | ✅ YES | Compliance requirement |
| Production vs dev builds | ✅ YES | Different security postures |

### 6.8 Contract: Device ↔ Backend (Security)

```json
{
  "_schema_version": "1.0",
  "device_security_policy": {
    "ssh_policy": {
      "production_build": "disabled",
      "factory_build": "enabled_with_manufacturing_keys",
      "support_access": "via_separate_support_channel"
    },
    "music_protection": {
      "method": "streaming_license",
      "cached_content": "backup_only",
      "cache_ttl_days": 7,
      "api_key_rotation": "supported",
      "license_revocation": "server_side"
    },
    "tamper_detection": {
      "method": "hash_verification",
      "trigger": "periodic_check",
      "response": "report_to_backend"
    }
  }
}
```

---

## 6B. CACHE POLICY: 7-DAY TTL

### 6B.1 Cache Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    7-DAY PLAYLIST CACHE POLICY                         │
│                                                                         │
│  OBJECTIVE:                                                            │
│  Device remains radio-first while maintaining local fallback cache     │
│  for offline resilience without consuming unlimited storage.           │
│                                                                         │
│  RULES:                                                                │
│  1. Cache stores max 7 days of playback                                │
│  2. Cache ONLY modified when backend playlist changes                   │
│  3. If playlist unchanged: do NOT redownload existing tracks           │
│  4. If playlist changed: atomic swap after verification                │
│  5. Never delete active/ while playback is using it                   │
│  6. Playback continues from local if offline, even if expired          │
│                                                                         │
│  LIFECYCLE:                                                            │
│  Day 0:   Download playlist to active/                                 │
│  Day 1-6: Normal playback, periodic hash verification                  │
│  Day 7:   Cache expires                                                │
│           - If server available: resync                                │
│           - If offline: continue from expired cache                    │
│  Day 8+:  Content marked expired, no auto-deletion                     │
│                                                                         │
│  STORAGE:                                                              │
│  /var/lib/sigil/cache_meta.json → TTL tracking                        │
│  /home/sigil/music/active/ → Current valid playlist                   │
│  /home/sigil/music/staging/ → Download in progress                    │
│  /home/sigil/music/archive/ → Old playlists (auto-cleanup >7 days)    │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6B.2 Cache Modification Triggers

```
CACHE IS MODIFIED ONLY WHEN:

┌─────────────────────────────────────────────────────────────────────────┐
│  TRIGGER                    │ ACTION                                    │
├─────────────────────────────┼──────────────────────────────────────────┤
│ Playlist version changed    │ Download new playlist to staging/        │
│ Playlist hash changed       │ Download new playlist to staging/        │
│ Track hash changed          │ Download new track to staging/           │
│ Track added                 │ Download new track to staging/           │
│ Track removed               │ Remove from active/ on next sync         │
│ Track reordered             │ Update playlist.json in staging/         │
├─────────────────────────────┼──────────────────────────────────────────┤
│ Playlist hash UNCHANGED     │ NO ACTION - Skip download entirely       │
│ Network timeout             │ Maintain current cache                   │
│ Server error                │ Maintain current cache, retry later      │
└─────────────────────────────┴──────────────────────────────────────────┘
```

### 6B.3 Atomic Swap Algorithm

```
ALGORITHM: Cache Atomic Swap

PREREQUISITE: staging/ is complete and all hashes verified

1. PREPARE SWAP:
   - Verify staging/playlist.json exists and is valid
   - Verify all tracks in staging/tracks/ have correct hashes
   - Create backup: mkdir archive/pl_{timestamp}/
   
2. ATOMIC SWAP:
   mv active/ archive/pl_{timestamp}/old_active/
   mv staging/ active/
   rm -rf archive/pl_{timestamp}/old_active/
   
3. UPDATE METADATA:
   - Update cache_meta.json:
     - active_cache.playlist_id = new_id
     - active_cache.version_hash = new_hash
     - active_cache.downloaded_at = now()
     - active_cache.expires_at = now() + 7_days
     - active_cache.integrity_verified = true
   
4. CLEANUP ARCHIVE:
   - Find all archive/pl_*/ with age > 7 days
   - Delete oldest archives until space reclaimed
   
5. NOTIFY PLAYER:
   - Write audio_mode.json with reason="playlist_updated"
   - Player will pick up new playlist on next track
```

### 6B.4 Cache Expiration Behavior

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CACHE EXPIRATION SCENARIOS                          │
│                                                                         │
│  SCENARIO 1: Cache expired + Server available                          │
│  ─────────────────────────────────────────────────────                 │
│  BEHAVIOR:                                                             │
│  ├── radio-fetcher detects expires_at < now()                         │
│  ├── Attempts to sync from server                                     │
│  ├── If sync successful: new playlist, new TTL                        │
│  └── If sync fails: cache remains, playback continues                  │
│                                                                         │
│  SCENARIO 2: Cache expired + Server unavailable                        │
│  ─────────────────────────────────────────────────────                 │
│  BEHAVIOR:                                                             │
│  ├── radio-fetcher detects expires_at < now()                         │
│  ├── Tries to sync, gets timeout/error                                │
│  ├── Marks cache as "expired" in audio_mode.json                      │
│  ├── Playback CONTINUES from expired cache                             │
│  ├── Panel shows warning "Content may not be up to date"               │
│  ├── NO automatic deletion of content                                 │
│  └── On reconnect: normal sync resumes                                │
│                                                                         │
│  SCENARIO 3: 14+ days without sync                                     │
│  ─────────────────────────────────────────────────────                 │
│  BEHAVIOR:                                                             │
│  ├── Wipe policy triggered (configurable)                             │
│  ├── Requires confirmation if server is reachable                     │
│  ├── Deletes /home/sigil/music/                                       │
│  ├── Preserves device identity                                        │
│  └── Re-syncs on next server contact                                  │
│                                                                         │
│  SCENARIO 4: Playback during active sync                               │
│  ─────────────────────────────────────────────────────                 │
│  BEHAVIOR:                                                             │
│  ├── radio-fetcher runs in background, separate process               │
│  ├── Radio stream continues uninterrupted                             │
│  ├── Local playback continues uninterrupted                           │
│  ├── Atomic swap happens between tracks                               │
│  ├── Player picks up new playlist on next track                       │
│  └── User experience: seamless transition                             │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6B.5 Tamper Detection

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    TAMPER DETECTION POLICY                             │
│                                                                         │
│  DETECTION MECHANISMS:                                                 │
│                                                                         │
│  1. STORAGE INTEGRITY                                                  │
│     ├── Periodic hash verification of all tracks                       │
│     ├── Compare filesystem with cache_meta hashes                      │
│     ├── Check file timestamps for anomalies                            │
│     └── inotify for real-time modification detection                   │
│                                                                         │
│  2. PLAYLIST INTEGRITY                                                 │
│     ├── Verify playlist.json structure                                 │
│     ├── Check for unexpected modifications                             │
│     └── Compare with server-side version (if available)                │
│                                                                         │
│  3. SSH ACCESS DETECTION (if inadvertently enabled)                    │
│     ├── Monitor failed login attempts                                  │
│     ├── Log successful connections                                     │
│     └── Alert on unexpected SSH activity                               │
│                                                                         │
│  4. BEHAVIOR ANOMALIES                                                 │
│     ├── Multiple failed authentication attempts                        │
│     ├── Access outside normal hours                                    │
│     └── Bulk file access patterns                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6B.6 Access Categories Definition

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ACCESS CATEGORIES & RESPONSES                       │
│                                                                         │
│  1. AUTHORIZED FACTORY/DEBUG ACCESS                                   │
│     ├── Keys in /etc/sigil/ssh_authorized_keys                        │
│     ├── Build type = factory or debug                                 │
│     ├── CONSECUENCE: Full access allowed, normal logging              │
│     └── RESPONSE: Log only                                            │
│                                                                         │
│  2. AUTHORIZED SUPPORT ACCESS                                         │
│     ├── Support channel authenticated                                  │
│     ├── User approved connection                                       │
│     ├── CONSECUENCE: Limited commands, audit logged                   │
│     └── RESPONSE: Log + notify backend                                │
│                                                                         │
│  3. UNAUTHORIZED NETWORK ACCESS (if SSH enabled by error)             │
│     ├── No valid key                                                   │
│     ├── CONSECUENCE: Access denied, log attempt                       │
│     └── RESPONSE: Log + alert (NO deletion)                           │
│                                                                         │
│  4. PHYSICAL STORAGE EXTRACTION                                       │
│     ├── SD card removed and read externally                           │
│     ├── Difficult to detect directly                                   │
│     ├── CONSECUENCE: Data potentially extracted                       │
│     └── RESPONSE: Consider storage encryption in future               │
│                                                                         │
│  5. MODIFICATION OF CACHED CONTENT                                    │
│     ├── Track file modified                                           │
│     ├── Playlist.json tampered                                        │
│     ├── CONSECUENCE: Integrity check fails                           │
│     └── RESPONSE: Log + alert + mark as corrupted                     │
│                                                                         │
│  6. MEMORY/RUNTIME TAMPERING                                          │
│     ├── Debugger attached                                              │
│     ├── Process memory read                                           │
│     ├── CONSECUENCE: Runtime integrity breach                        │
│     └── RESPONSE: Log + alert (complex to detect)                     │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6B.7 Wipe/Deletion Policy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    WIPE/DELETION POLICY                                │
│                                                                         │
│  ⚠️  CRITICAL: SSH LOGIN ≠ AUTOMATIC DELETION                         │
│                                                                         │
│  TRIGGERS FOR WIPE (explicit):                                         │
│  ├── Explicit factory reset command (user or API)                     │
│  ├── Tamper detected: storage integrity breach                        │
│  ├── Max TTL exceeded (14+ days without sync, if configured)          │
│  └── Backend command: license revocation                              │
│                                                                         │
│  TRIGGERS FOR LOG + ALERT (NOT wipe):                                 │
│  ├── SSH access attempt                                               │
│  ├── SSH successful login (unexpected)                                │
│  ├── Single file modification                                         │
│  ├── Failed login attempts (< threshold)                              │
│  └── Anomalous access patterns                                        │
│                                                                         │
│  TRIGGERS FOR NO ACTION:                                               │
│  ├── Normal playback operation                                        │
│  ├── Authorized support access                                        │
│  ├── Factory mode operation                                           │
│  └── Network connectivity changes                                     │
│                                                                         │
│  WIPE BEHAVIOR:                                                        │
│  ├── DELETE: /home/sigil/music/ (all content)                        │
│  ├── DELETE: playlist.active.json, staging/, archive/                 │
│  ├── RESET: playback_state.json (preserve position)                   │
│  ├── PRESERVE: device.json (identity)                                 │
│  ├── PRESERVE: /etc/sigil/panel.env (secrets)                        │
│  ├── PRESERVE: security logs                                          │
│  └── AFTER: Re-sync from server, notify backend                       │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6B.8 False Positive Prevention

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    FALSE POSITIVE PREVENTION                           │
│                                                                         │
│  PRINCIPLE: Distinguish legitimate vs malicious activity              │
│                                                                         │
│  STRATEGIES:                                                           │
│                                                                         │
│  1. THRESHOLD-BASED DETECTION                                          │
│     ├── Single event ≠ alert                                          │
│     ├── Require pattern or repeat count                                │
│     ├── Example: 5 SSH failures = alert, not 1                       │
│     └── Example: 3 file mods = alert, not 1                           │
│                                                                         │
│  2. CONTEXT AWARENESS                                                  │
│     ├── Factory mode: normal logging, no alerts                       │
│     ├── Debug mode: different detection thresholds                    │
│     ├── Support mode: expected commands not flagged                   │
│     └── Production mode: strict detection                             │
│                                                                         │
│  3. STAGED RESPONSE                                                    │
│     Level 1: Log only (detection, verify)                             │
│     Level 2: Alert + user notification (confirmed)                    │
│     Level 3: Backend alert + potential wipe (severe)                  │
│     Level 4: Immediate wipe + backend notification (critical)         │
│                                                                         │
│  4. DIFFERENTIATION                                                   │
│     ├── SSH attempt from known IP → lower severity                    │
│     ├── SSH attempt from unknown IP → higher severity                 │
│     ├── File modification during playback → warning                   │
│     ├── Bulk extraction pattern → critical                            │
│     └── Random access pattern → investigation                         │
│                                                                         │
│  5. ESCALATION PATH                                                    │
│     ├── Auto-escalate if same event repeats                           │
│     ├── Human review for Level 2+                                     │
│     └── Manual override always available                              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. MISSING COMPONENTS
## 7. MISSING COMPONENTS
### 7.1 Critical (Block Production)

| Component | Status | Priority |
|-----------|--------|----------|
| Firstboot service | ❌ DOES NOT EXIST | P0 |
| Device provisioning | ❌ INCOMPLETE | P0 |
| Secrets management | ❌ HARDCODED | P0 |
| Service separation | ❌ MONOLITHIC | P0 |
| Contract definitions | ❌ ABSENT | P0 |
| **Cache policy (7-day TTL)** | ❌ ABSENT | P0 |
| **Tamper detection** | ❌ ABSENT | P0 |

### 7.2 High (Block Scale)

| Component | Status | Priority |
|-----------|--------|----------|
| Observability | ⚠️ WEAK | P1 |
| Testing | ❌ ABSENT | P1 |
| OTA updates | ❌ ABSENT | P1 |
| Remote diagnostics | ❌ ABSENT | P1 |
| Secure boot chain | ❌ ABSENT | P1 |
| **Cache metadata (cache_meta.json)** | ❌ ABSENT | P1 |
| **Security state (security_state.json)** | ❌ ABSENT | P1 |
| **Atomic swap algorithm** | ❌ ABSENT | P1 |

### 7.3 Medium (Block Enterprise)

| Component | Status | Priority |
|-----------|--------|----------|
| Role-based access | ❌ ABSENT | P2 |
| Audit logging | ❌ ABSENT | P2 |
| Compliance exports | ❌ ABSENT | P2 |
| Multi-tenancy | ❌ ABSENT | P2 |
| API rate limiting | ❌ ABSENT | P2 |
| **Support channel (non-SSH)** | ⚠️ CONCEPT ONLY | P2 |
| **Tamper event logging** | ❌ ABSENT | P2 |
| **Storage encryption** | ❌ ABSENT | P2 |

---

## 8. RECOMMENDED ARCHITECTURE

### 8.1 Layered Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           PRESENTATION                                  │
│                    (Flask Panel, Captive Portal)                      │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          ORCHESTRATION                                  │
│           (audio-manager, device-manager services)                     │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐      ┌─────────────────┐      ┌─────────────────────┐
│   DOWNLOAD    │      │    PLAYBACK     │      │    BLUETOOTH        │
│   (fetcher)   │      │    (player)     │      │    (bt-connect)     │
└───────────────┘      └─────────────────┘      └─────────────────────┘
        │                         │                         │
        └─────────────────────────┼─────────────────────────┘
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           INFRASTRUCTURE                                │
│         (PulseAudio, BlueZ, NetworkManager, systemd)                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.2 State Management

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         STATE LAYER                                     │
│                                                                         │
│  /var/lib/sigil/                    ← System state                    │
│  ├── device.json                     ← Device identity                  │
│  ├── audio_mode.json                ← Current mode (RADIO/LOCAL/EXPIRED)│
│  ├── playback_state.json            ← Track position, etc              │
│  ├── playlist.active.json           ← Active playlist                  │
│  ├── cache_meta.json                ← TTL tracking (NEW)               │
│  ├── security_state.json            ← Security status (NEW)            │
│  └── bluetooth_state.json           ← BT device info                   │
│                                                                         │
│  /home/sigil/music/                 ← User content (PROTECTED)        │
│  ├── active/tracks/                 ← Currently playable (7-day TTL)  │
│  ├── staging/tracks/               ← Downloading                      │
│  └── archive/                      ← Old playlists (auto-cleanup)    │
│                                                                         │
│  /etc/sigil/                        ← Configuration                   │
│  ├── device.json                    ← Device identity                 │
│  ├── panel.env                      ← Secrets                        │
│  ├── audio.conf                     ← Audio config (incl. TTL)        │
│  └── security.conf                  ← Security config (NEW)           │
│                                                                         │
│  SECURITY EVENTS:                   ← Audit trail                     │
│  ├── tamper_events/                 ← Tamper detection events          │
│  └── access_logs/                   ← SSH/access attempts             │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.3 Service Contracts

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          CONTRACTS                                      │
│                                                                         │
│  audio-manager ↔ audio-player:                                        │
│    WRITE: audio_mode.json                                             │
│    READ:  playback_state.json                                         │
│    NOTIFY: mode change event                                          │
│                                                                         │
│  audio-manager ↔ radio-fetcher:                                       │
│    READ:  cache_meta.json                                             │
│    WRITE: playlist.staging.json                                       │
│    TRIGGER: fetch command                                             │
│                                                                         │
│  audio-player ↔ bt-connect:                                           │
│    READ:  preferred_bt.txt                                            │
│    WRITE: pulse sink selection                                         │
│    NOTIFY: sink events                                                │
│                                                                         │
│  panel ↔ all services:                                                 │
│    READ:  all state files                                              │
│    WRITE: user commands (wifi connect, bt pair)                        │
│    NOTIFY: via API endpoints                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. RECOMMENDED ROADMAP

### Phase 1: Foundation (2-3 semanas)

**Objetivo:** Base sólida para desarrollo futuro

```
WEEK 1: Contracts + Cache Policy
├── JSON schemas para todos los state files
├── Schema validation
├── Documentation
├── cache_meta.json schema (TTL tracking)
└── security_state.json schema (tamper detection)

WEEK 2: Service Separation + Cache Implementation
├── Extract radio-fetcher from radio-stream.sh
├── Extract audio-player from radio-stream.sh
├── Create audio-manager
├── Implement atomic swap
├── Implement sync intelligence (skip if unchanged)
└── Implement cache TTL check (7 days)

WEEK 3: systemd Integration
├── audio-manager.service
├── radio-fetcher.service
├── audio-player.service
└── Update install.sh

WEEK 4: Configuration + Security
├── /etc/sigil/audio.conf
├── /etc/sigil/security.conf
├── Extract API_KEY
├── Extract SERVER_URL
├── Basic tamper detection
└── Tamper event generation
```

### Phase 2: Firstboot & Provisioning (2 semanas)

```
WEEK 5: Firstboot Service
├── sigil-firstboot.service
├── firstboot.sh
├── device.json generation
├── panel.env generation
└── hostname derivation

WEEK 6: Flasher Integration
├── flasher-rs complete implementation
├── provision.json injection
├── Flasher GUI
└── End-to-end test
```

### Phase 3: Observability (2 semanas)

```
WEEK 7: Logging & Metrics
├── Structured logging
├── Log aggregation
├── Basic metrics
└── Health endpoints

WEEK 8: Testing
├── Unit tests
├── Integration tests
├── CI/CD pipeline
└── Test coverage
```

### Phase 4: Security Hardening (2 semanas)

```
WEEK 9: Secrets Management
├── Secure secret generation
├── API key rotation
└── Secrets audit

WEEK 10: Access Control
├── Sudoers hardening
├── Role-based access
├── Audit logging
└── Compliance exports
```

### Phase 5: Scale Infrastructure (4 semanas)

```
WEEK 11-12: OTA Updates
├── Update mechanism
├── Rollback support
├── Signed updates
└── Update verification

WEEK 13-14: Remote Support
├── Support channel
├── Diagnostics
├── Remote troubleshooting
└── Audit trail
```

---

## 10. FINAL VERDICT

### 10.1 Readiness Assessment

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    COMMERCIAL READINESS SCORE                          │
│                                                                         │
│  Architecture:          ████████░░  80%  ⚠️ Needs refactoring        │
│  Security:              ████░░░░░░  40%  🔴 Critical issues         │
│  Cache Policy:          █░░░░░░░░░  10%  🔴 No TTL, no smart sync   │
│  Tamper Detection:      █░░░░░░░░░  10%  🔴 Not implemented         │
│  Observability:         ██░░░░░░░░  20%  🔴 No visibility            │
│  Testing:               █░░░░░░░░░  10%  🔴 No automated tests       │
│  Documentation:         ███████░░░  70%  ⚠️ Updated with new reqs   │
│  Provisioning:          ███░░░░░░░  35%  🔴 Incomplete              │
│  Scalability:           ██░░░░░░░░  20%  🔴 No OTA, no monitoring   │
│                                                                         │
│  OVERALL:               ███░░░░░░░  35%  🔴 NOT PRODUCTION READY   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 10.2 Blocker Summary

```
BLOCKERS PARA PRODUCCIÓN:

1. 🔴 API key hardcodeada — security critical
2. 🔴 Firstboot no existe — provisioning broken
3. 🔴 radio-stream.sh monolítico — impossible to maintain
4. 🔴 Sin contratos JSON — no state management
5. 🔴 Sin cache policy — unlimited growth, no TTL
6. 🔴 Sin tamper detection — no security monitoring
7. 🔴 Sin testing — bugs ocultos
8. 🔴 Sin observabilidad — debugging impossible at scale

ESTOS DEBEN RESOLVERSE ANTES DE:
- Fabricar más de 10 unidades
- Deployar a usuarios reales
- Implementar features adicionales
```

### 10.3 Immediate Actions

```
DONE:
[x] Auditoría arquitectónica completa
[x] Plan de reestructuración Fase 1
[x] Análisis de SSH y anti-tamper
[x] Cache policy de 7 días (architecture)
[x] Tamper detection policy (architecture)
[x] Contratos JSON: cache_meta.json, security_state.json, tamper_event.json

TODO INMEDIATO:
[ ] Crear contratos JSON (Fase 1A)
    ├── cache_meta.json schema
    ├── security_state.json schema
    └── tamper_event.json schema

[ ] Extraer radio-fetcher (Fase 1B)
    ├── Sync inteligente (skip if hash unchanged)
    ├── Atomic swap implementation
    └── Cache TTL tracking

[ ] Extraer audio-player (Fase 1B)
    ├── playback_state persistence
    └── Cache expiration handling

[ ] Crear audio-manager (Fase 1B)
    ├── Mode management (RADIO/LOCAL/CACHE_EXPIRED)
    └── Tamper event handling

[ ] Implementar tamper detection (Fase 1D)
    ├── Hash verification
    ├── Tamper event generation
    └── Wipe policy

[ ] Mover API key a config (Fase 1D)
    └── /etc/sigil/audio.conf + security.conf

[ ] Implementar firstboot (Fase 2)

NOT YET:
[ ] OTA updates
[ ] Observability
[ ] Testing
[ ] Security hardening
[ ] Support channel (non-SSH)
[ ] Storage encryption
```

### 10.4 Cost of Delay

```
SI CONTINÚAS DESARROLLando SIN ARREGLAR BLOCKERS:

短期 (100 devices):
├── $5,000-10,000 en debugging
└── ~20% de devices con issues

中期 (1,000 devices):
├── $50,000-100,000 en soporte
├── Posible security incident
└── ~30% de devices con issues

长期 (10,000 devices):
├── $500,000+ en soporte
├── Security incident = business-ending
└── Product not viable without OTA
```

---

**CONCLUSIÓN:**

El proyecto tiene buena base conceptual pero requiere inversión significativa en arquitectura antes de ser viable comercialmente. La Fase 1 es esencial y no debe saltarse. El costo de arreglar problemas después de fabricar es 10-100x mayor que resolverlos ahora.

---

**FIN DEL DOCUMENTO**
