# SIGIL-HARDWARE — PLAN DE REESTRUCTURACIÓN
## Fase 1: Foundation

**Estado:** Plan de Arquitectura  
**Fecha:** 2026-07-09  
**Versión:** 2.0 (Actualizado con Cache Policy + Security)

---

## 1. ANÁLISIS DEL ESTADO ACTUAL

### 1.1 Problemas Identificados en la Auditoría

| Problema | Criticidad | Impacto |
|----------|-----------|---------|
| radio-stream.sh es monolítico (900+ líneas) | CRÍTICO | Imposible mantener,testing, o modificar una feature sin romper otras |
| Sin contratos JSON entre servicios | CRÍTICO | Acoplamiento隐性 entre componentes |
| API key hardcodeada en script | CRÍTICO | Seguridad: no se puede rotar sin re-flash |
| URL del servidor hardcodeada | ALTO | No hay forma de cambiar endpoint remotamente |
| Playback state solo en memoria | ALTO | Al reiniciar, siempre empieza desde track 1 |
| No hay política de caché definida | ALTO | Caché crece sin límites, sin expiración |
| No hay detección de tampering | ALTO | No se protege contenido de acceso no autorizado |
| Sudoers muy permisivo (34 reglas NOPASSWD) | ALTO | Principio de mínimo privilegio violado |

### 1.2 Lo que NO se toca en Fase 1

```
✗ Flask panel (app.py, bluetooth.py, wifi.py)
✗ TLS/cifrado de red
✗ DRM de contenido
✗ OTA updates
✗ Backend server
✗ Autenticación robusta
✗ Tests automatizados
```

### 1.3 Nuevos Requisitos: Caché de 7 Días

```
REQUISITO: El dispositivo almacena información de playlist/audio
           localmente por un máximo de 7 días de reproducción.

POLÍTICA:
├── TTL máximo: 7 días
├── Se renueva solo si la playlist cambia en el servidor
├── Si la playlist no cambió, no se redescarga nada
├── Si la playlist cambió:
│   ├── Descargar a staging/
│   ├── Verificar hashes
│   ├── Swap atómico
│   └── Eliminar tracks no autorizados
└── Contenido se elimina:
    ├── Después de 7 días
    ├── Si se detecta acceso no autorizado
    └── Si se detecta tampering de storage/memory
```

---

## 2. ARQUITECTURA OBJETIVO: Separación de Servicios de Audio

### 2.1 Diagrama de Arquitectura Propuesta

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        CAPA DE ORQUESTACIÓN                              │
│                    audio-manager.service                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                 │
│  │ playlist.json│  │playback_state│  │ audio_mode  │                 │
│  │  (activo)   │  │    .json     │  │   .json     │                 │
│  └──────────────┘  └──────────────┘  └──────────────┘                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                 │
│  │ cache_meta  │  │security_state│  │  device.json │                 │
│  │   .json     │  │   .json      │  │             │                 │
│  └──────────────┘  └──────────────┘  └──────────────┘                 │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐  ┌───────────────────┐  ┌──────────────────┐
│radio-fetcher  │  │  audio-player     │  │ bt-connect       │
│.service       │  │  .service         │  │ .service (existe)│
│               │  │                   │  │                  │
│- Escucha API  │  │- Reproduce audio  │  │- Sin cambios     │
│- Descarga    │  │- Gestiona sink    │  │  en Fase 1      │
│  playlist     │  │  PulseAudio       │  │                  │
│- Verifica     │  │- Lee playlists    │  │                  │
│  hashes       │  │  locales          │  │                  │
│- Atomic swap  │  │- Modo RADIO o     │  │                  │
│- TTL check    │  │  LOCAL            │  │                  │
│- tamper check │  │                   │  │                  │
└───────┬───────┘  └────────┬──────────┘  └──────────────────┘
        │                    │
        │                    │
        ▼                    ▼
┌─────────────────┐  ┌─────────────────────────────────────────────────────┐
│  /var/lib/      │  │              /home/sigil/music/                      │
│  sigil/         │  │  ┌─────────────┬─────────────┬─────────────┐        │
│                 │  │  │  active/  │  staging/  │  archive/  │        │
│  playlist.json   │  │  │  (uso actual)│ (nueva)  │  (backup) │        │
│  cache_meta.json│  │  │            │            │            │        │
│  security_state │  │  │  tracks/  │  tracks/  │  tracks/  │        │
│                 │  │  │  playlist │  playlist │  playlist │        │
│                 │  │  │  .json    │  .json    │  .json    │        │
│                 │  │  └─────────────┴─────────────┴─────────────┘        │
└─────────────────┘  └─────────────────────────────────────────────────────┘
```

### 2.2 Responsabilidades de Cada Servicio

#### audio-manager.service (ORQUESTADOR)
```
Responsabilidades:
├── Lee estado de red (wifi-fallback)
├── Lee playlist.active.json + cache_meta.json
├── Decide modo: RADIO | LOCAL
├── Gestiona políticas de caché (7 días TTL)
├── Detecta eventos de tampering
├── Notifica a audio-player del cambio
├── Persiste playback_state.json
└── Loguea transiciones de modo y seguridad

NO hace:
├── No descarga nada
├── No reproduce audio
├── No toma decisiones de tampering directamente
```

#### radio-fetcher.service (DESCARGADOR)
```
Responsabilidades:
├── Consulta /api/devices/{id}/playlist al servidor
├── Detecta cambios de hash (playlist + tracks)
├── SI playlist cambió:
│   ├── Descarga playlist nueva a staging/
│   ├── Descarga tracks faltantes a staging/
│   ├── Verifica SHA256 de cada track
│   ├── Si TODO válido: atomic swap a active/
│   └── Si FALLA: mantiene active/, limpia staging/
├── SI playlist NO cambió:
│   └── NO descarga nada (ahorra bandwidth)
├── Actualiza cache_meta.json con timestamps
├── Reporta progreso a través de cache_meta.json
├── Verifica TTL de caché en cada ciclo
├── Detecta signs de tampering de storage
└── Corre cada 5 minutos (configurable)

NO hace:
├── No reproduce nada
├── No toma decisiones de playback
├── No inicia wipe por cuenta propia
```

#### audio-player.service (REPRODUCTOR)
```
Responsabilidades:
├── Lee audio_mode.json para saber modo actual
├── Si RADIO:
│   ├── Conecta a stream del servidor (curl | mpg123)
│   └── NO cachea localmente durante playback
├── Si LOCAL:
│   ├── Lee playlist.active.json
│   ├── Lee playback_state.json (posición actual)
│   ├── Lee cache_meta.json (verifica no expirado)
│   ├── Si caché expirado → notifica a audio-manager
│   ├── Reproduce desde track X
│   └── Maneja sink PulseAudio
├── Detecta desconexión de sink → reconecta
├── Al terminar playlist → loop desde inicio
├── Persiste playback_state.json cada track
└── Reporta estado de caché expirado si necesario

NO hace:
├── No descarga nada
├── No decide modo
├── No inicia wipe
```

---

## 3. CONTRATOS JSON (ARCHIVOS DE ESTADO)

### 3.1 device.json (YA EXISTE - Referencia)

```json
{
  "_schema_version": "1.0",
  "device_id": "SIGIL-Z2W-2026-0001",
  "model": "Sigil-Streamer-v1",
  "serial": "0000000012345678",
  "batch": "LOTE-2026-A",
  "hostname": "sigil-0001",
  "firmware_version": "1.0.0",
  "build_type": "production",
  "created_at": "2026-07-01T00:00:00Z"
}
```

### 3.2 playlist.active.json

```json
{
  "_schema_version": "1.0",
  "playlist_id": "pl_abc123",
  "version_hash": "sha256:8f14e45fceea1673",
  "source": "server",
  "created_at": "2026-07-09T10:00:00Z",
  "downloaded_at": "2026-07-09T10:05:00Z",
  "tracks": [
    {
      "id": "track_001",
      "url": "/music/track001.mp3",
      "filename": "track001.mp3",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "duration_seconds": 180,
      "title": "Canción 1"
    }
  ]
}
```

### 3.3 playlist.staging.json (Temporal)

```json
{
  "_schema_version": "1.0",
  "playlist_id": "pl_xyz789",
  "version_hash": "sha256:newHashHere",
  "source": "server",
  "created_at": "2026-07-09T12:00:00Z",
  "download_status": {
    "total_tracks": 50,
    "downloaded_tracks": 47,
    "verified_tracks": 47,
    "failed_tracks": [],
    "progress_percent": 94,
    "started_at": "2026-07-09T12:00:00Z"
  },
  "tracks": [ /* misma estructura */ ]
}
```

### 3.4 playback_state.json

```json
{
  "_schema_version": "1.0",
  "mode": "RADIO",
  "radio": {
    "last_check": "2026-07-09T12:00:00Z",
    "last_hash": "sha256:abc123"
  },
  "local": {
    "playlist_hash": "sha256:8f14e45f",
    "current_track_index": 7,
    "current_track_id": "track_007",
    "position_seconds": 45,
    "last_updated": "2026-07-09T12:05:00Z"
  },
  "statistics": {
    "total_plays": 1234,
    "mode_switches": 5,
    "last_server_contact": "2026-07-09T12:00:00Z"
  }
}
```

### 3.5 audio_mode.json

```json
{
  "_schema_version": "1.0",
  "mode": "RADIO",
  "reason": "server_available",
  "since": "2026-07-09T10:00:00Z",
  "fallback_count": 0
}
```

**Valores posibles de `mode`:**
- `RADIO` — reproduciendo desde servidor
- `LOCAL` — reproduciendo desde caché local
- `TRANSITIONING` — transicionando entre modos
- `IDLE` — sin reproducción (sink no disponible)
- `CACHE_EXPIRED` — caché expirado, esperando sync

**Valores posibles de `reason`:**
- `server_available` — servidor responde normalmente
- `server_unreachable` — timeout o error de conexión
- `network_lost` — sin conectividad
- `manual_switch` — usuario pidió cambio manual
- `playlist_updated` — nueva playlist activada
- `cache_expired` — TTL de 7 días alcanzado

### 3.6 bluetooth_state.json

```json
{
  "_schema_version": "1.0",
  "preferred_device": {
    "mac": "AA:BB:CC:DD:EE:FF",
    "name": "JBL Flip 5",
    "paired_at": "2026-06-15T08:00:00Z",
    "last_connected": "2026-07-09T12:00:00Z"
  },
  "connection_status": {
    "connected": true,
    "profile": "A2DP",
    "since": "2026-07-09T10:30:00Z"
  }
}
```

### 3.7 cache_meta.json (NUEVO - Metadata de Caché)

```json
{
  "_schema_version": "1.0",
  "cache_policy": {
    "max_ttl_days": 7,
    "auto_renew": true,
    "delete_on_expire": true,
    "preserve_on_server_unavailable": false
  },
  "active_cache": {
    "playlist_id": "pl_abc123",
    "version_hash": "sha256:8f14e45f",
    "downloaded_at": "2026-07-09T10:05:00Z",
    "expires_at": "2026-07-16T10:05:00Z",
    "tracks_count": 50,
    "total_size_bytes": 524288000,
    "last_verified_at": "2026-07-09T10:05:00Z",
    "last_hash_check": "sha256:abc123",
    "integrity_verified": true
  },
  "staging_cache": {
    "playlist_id": null,
    "version_hash": null,
    "download_started_at": null,
    "progress_percent": 0,
    "tracks_downloaded": 0,
    "tracks_total": 0
  },
  "statistics": {
    "total_sync_operations": 150,
    "successful_syncs": 145,
    "failed_syncs": 5,
    "last_successful_sync": "2026-07-09T10:05:00Z",
    "last_failed_sync": "2026-07-08T22:30:00Z",
    "bytes_downloaded_total": 78643200000,
    "bandwidth_saved_by_skipping": 52428800000
  },
  "expiration_warning_sent": false,
  "expiration_warning_at": null
}
```

**Política de Caché:**
- `max_ttl_days: 7` — Máximo 7 días de contenido cacheado
- `auto_renew: true` — Se renueva automáticamente si playlist cambió
- `delete_on_expire: true` — Se elimina cuando expira
- `preserve_on_server_unavailable: false` — No preserva si servidor no disponible al expirar

### 3.8 security_state.json (NUEVO - Estado de Seguridad)

```json
{
  "_schema_version": "1.0",
  "device_mode": "production",
  "build_type": "production",
  "ssh_enabled": false,
  "authorized_access": {
    "factory_keys_installed": false,
    "debug_keys_installed": false,
    "support_mode_active": false,
    "last_authorized_access": null
  },
  "tamper_detection": {
    "enabled": true,
    "last_check": "2026-07-09T12:00:00Z",
    "storage_integrity": {
      "status": "verified",
      "last_verified": "2026-07-09T12:00:00Z",
      "hash": "sha256:abc123"
    },
    "memory_integrity": {
      "status": "not_applicable",
      "last_check": null
    },
    "boot_integrity": {
      "status": "not_applicable",
      "last_check": null
    }
  },
  "tamper_events": [],
  "wipe_policy": {
    "enabled": true,
    "triggers": [
      "explicit_factory_reset",
      "tamper_detected_storage",
      "max_ttl_exceeded"
    ],
    "preserve_device_identity": true
  }
}
```

### 3.9 tamper_event.json (NUEVO - Evento de Tampering)

```json
{
  "_schema_version": "1.0",
  "event_id": "evt_abc123",
  "event_type": "storage_integrity_mismatch",
  "severity": "high",
  "detected_at": "2026-07-09T14:30:00Z",
  "details": {
    "description": "Hash mismatch detected in /home/sigil/music/active/tracks/",
    "expected_hash": "sha256:abc123",
    "actual_hash": "sha256:def456",
    "affected_files": ["track003.mp3", "track007.mp3"]
  },
  "source": "radio-fetcher.service",
  "auto_response": "alert_only",
  "user_notified": true,
  "resolved": false,
  "resolved_at": null,
  "resolution": null
}
```

---

## 4. DIRECTORIOS Y RUTAS

### 4.1 Estructura de Directorios Propuesta

```
/var/lib/sigil/                          # Estado del sistema
├── device.json                          # Identidad del dispositivo
├── playlist.active.json                  # Playlist en uso
├── playlist.staging.json                # Playlist descargándose
├── playback_state.json                  # Estado de reproducción
├── audio_mode.json                      # Modo actual
├── bluetooth_state.json                 # Estado BT
├── cache_meta.json                     # Metadata de caché (NUEVO)
├── security_state.json                 # Estado de seguridad (NUEVO)
└── download_locks/                      # Locks de descarga
    └── staging.lock

/home/sigil/music/                       # Música cacheada (PROTEGIDA)
├── active/                              # Playlist activa (en uso)
│   ├── playlist.json                    # Copia de playlist.active.json
│   ├── metadata.json                    # Info de descarga, hash
│   └── tracks/
│       ├── track001.mp3
│       ├── track002.mp3
│       └── ...
├── staging/                             # Playlist nueva (descargando)
│   ├── playlist.json
│   └── tracks/
│       └── ...
└── archive/                             # Backups de playlists (7 días máx)
    ├── pl_20260708/
    │   ├── playlist.json
    │   └── tracks/
    └── pl_20260707/
        └── ...

/etc/sigil/                              # Configuración
├── device.json                          # Identidad del dispositivo
├── panel.env                            # Secrets del panel
├── audio.conf                           # Config de audio
│   ├── SERVER_URL=https://devproserver.tail942ea3.ts.net
│   ├── API_KEY=<placeholder>
│   ├── CACHE_TTL_DAYS=7
│   ├── CACHE_INTERVAL_SECONDS=300
│   ├── PLAYBACK_MODE=radio-first
│   └── FALLBACK_THRESHOLD=3
├── security.conf                        # Config de seguridad (NUEVO)
│   ├── TAMPER_DETECTION_ENABLED=true
│   ├── WIPE_ON_TAMPER=false
│   ├── FACTORY_MODE=false
│   └── SUPPORT_MODE=false
└── ssh_authorized_keys                  # Keys SSH (factory/debug solo)
```

---

## 5. POLÍTICA DE CACHÉ: 7 DÍAS

### 5.1 Reglas de Caché

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    POLÍTICA DE CACHÉ DE 7 DÍAS                         │
│                                                                         │
│  1. ALMACENAMIENTO                                                    │
│     ├── Máximo: 7 días de playback desde última sync                   │
│     ├── Base: downloaded_at + 7 días = expires_at                      │
│     └── tracks/ contiene solo lo necesario para esos días              │
│                                                                         │
│  2. MODIFICACIÓN DE CACHÉ                                             │
│     ├── SOLO cuando backend playlist cambia:                            │
│     │   ├── Playlist version cambió                                    │
│     │   ├── Playlist hash cambió                                       │
│     │   ├── Track hash cambió                                         │
│     │   └── Track added/removed/reordered                              │
│     └── SI playlist NO cambió: NO descargar nada                       │
│                                                                         │
│  3. CICLO DE VIDA                                                     │
│     ├── Día 0: Descarga playlist a active/                             │
│     ├── Día 1-6: Playback normal, sync verifica hash                   │
│     ├── Día 7: Caché expira                                           │
│     │   ├── Si servidor disponible: sync nueva playlist                 │
│     │   └── Si servidor NO disponible: playback desde local (expired)   │
│     └── Día 8+: Si no hay sync, contenido se marca expirado           │
│                                                                         │
│  4. LIMPIEZA                                                          │
│     ├── Archive/ se limpia automáticamente (>7 días)                   │
│     ├── Tracks no autorizados se eliminan en atomic swap              │
│     └── Nunca eliminar active/ mientras se reproduce                  │
│                                                                         │
│  5. PLAYBACK MIENTRAS SYNC                                            │
│     ├── Sync corre en background, nunca interrumpe playback            │
│     ├── Radio sigue sonando durante staging                            │
│     ├── Solo cuando staging completo + validado: swap                  │
│     └── Playback transiciona a nuevo contenido en siguiente track      │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Algoritmo de Sync de Caché

```
ALGORITMO: Smart Cache Sync

1. CADA_SYNC_INTERVAL (default: 5 minutos):

2. OBTENER PLAYLIST DEL SERVIDOR:
   remote_playlist = GET /api/devices/{id}/playlist
   remote_hash = sha256(remote_playlist)

3. LEER CACHÉ ACTUAL:
   local_playlist = READ playlist.active.json
   local_hash = local_playlist.version_hash
   cache_meta = READ cache_meta.json

4. COMPARAR HASH:
   IF remote_hash == local_hash:
       # Playlist NO cambió
       LOG "Playlist unchanged, skipping download"
       UPDATE cache_meta.statistics.bandwidth_saved
       RETURN
       
   # Playlist CAMBIÓ - iniciar descarga

5. DESCARGAR NUEVA PLAYLIST:
   a. CREAR staging/
      mkdir -p /home/sigil/music/staging/tracks
   
   b. COPIAR playlist a staging/
      cp remote_playlist /home/sigil/music/staging/playlist.json
   
   c. PARA CADA track en remote_playlist:
      local_track_path = "/home/sigil/music/active/tracks/{filename}"
      staging_track_path = "/home/sigil/music/staging/tracks/{filename}"
      
      IF exists(local_track_path) AND hash_matches(local, remote):
          # Track no cambió - hardlink o copy
          ln local_track_path staging_track_path
          LOG "Track {filename} unchanged, linked"
      ELSE:
          # Track cambió o no existe - descargar
          DOWNLOAD track TO staging_track_path
          VERIFY sha256(staging_track_path) == expected
          IF FAILED:
              CLEANUP staging/
              LOG "Track download failed"
              RETURN ERROR
          
   d. SI TODOS LOS TRACKS DESCARGADOS Y VERIFICADOS:
      # ATOMIC SWAP
      mv active/ old_active/
      mv staging/ active/
      rm -rf old_active/
      
      # ACTUALIZAR METADATA
      UPDATE cache_meta.active_cache = {
          "playlist_id": remote_playlist.id,
          "version_hash": remote_hash,
          "downloaded_at": now(),
          "expires_at": now() + 7_days,
          "tracks_count": len(remote_playlist.tracks),
          "integrity_verified": true
      }
      
      LOG "Cache updated successfully"
      
6. VERIFICAR EXPIRACIÓN:
   IF cache_meta.active_cache.expires_at < now():
       IF cache_meta.cache_policy.preserve_on_server_unavailable:
           # Mantener pero marcar como expirado
           audio-manager.notificar("CACHE_EXPIRED")
       ELSE:
           # Marcar para cleanup en próxima sync exitosa
           audio-manager.notificar("CACHE_EXPIRED")
```

### 5.3 Comportamiento: Caché Expirado Offline

```
ESCENARIO: Caché expirado + servidor no disponible

COMPORTAMIENTO:
├── Playback CONTINÚA desde caché expirado
├── Modo permanece LOCAL (no hay servidor para RADIO)
├── audio_mode.json.mode = "CACHE_EXPIRED"
├── audio_mode.json.reason = "cache_expired"
├── Panel muestra warning "Contenido puede no estar actualizado"
├── NO se elimina contenido automáticamente
├── Al reconectar servidor:
│   ├── radio-fetcher detecta cambio de hash
│   ├── Descarga nueva playlist
│   ├── Atomic swap
│   └── audio_manager.transición normal
└── Si pasan 14+ días sin sync:
    ├── audio-manager puede iniciar cleanup
    ├── Requiere confirmación de servidor (si disponible)
    └── Preservation policy configurable
```

---

## 6. SEGURIDAD: DETECCIÓN DE TAMPERING

### 6.1 Categorías de Acceso

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CATEGORÍAS DE ACCESO                                │
│                                                                         │
│  1. ACCESO AUTORIZADO (FACTORY/DEBUG)                                 │
│     ├── Keys SSH de manufacturing instaladas                           │
│     ├── Keys SSH de engineering/debug instaladas                       │
│     ├── Support mode activo (con authentication)                     │
│     └── CONSECUENCIA: Acceso total permitido                          │
│                                                                         │
│  2. ACCESO NO AUTORIZADO (PRODUCTION)                                 │
│     ├── SSH habilitado en producción (error de configuración)         │
│     ├── Acceso físico no autorizado                                     │
│     ├── Modificación directa de archivos                               │
│     └── CONSECUENCIA: Logging + alerta + considerar wipe             │
│                                                                         │
│  3. EXTRACCIÓN DE STORAGE FÍSICO                                      │
│     ├── SD card removida y leída en otro dispositivo                  │
│     ├── Acceso a /home/sigil/music/ via mount externo                │
│     └── CONSECUENCIA: Difícil detectar, considerar encrypt           │
│                                                                         │
│  4. TAMPERING DE MEMORY/RUNTIME                                       │
│     ├── Debugger adjunto                                               │
│     ├── Modificación de proceso en runtime                             │
│     ├── Memoria accedida externamente                                  │
│     └── CONSECUENCIA: Detección difícil, runtime checks necesarios   │
│                                                                         │
│  5. SUPPORT MODE                                                      │
│     ├── Canal separado (no SSH)                                       │
│     ├── Requiere autenticación de usuario                             │
│     ├── Comandos limitados                                             │
│     └── Audit logging completo                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 NO: SSH Login NO es Deletion Automática

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ⚠️  DECISIÓN DE DISEÑO: SSH ≠ DELETION AUTOMÁTICA                   │
│                                                                         │
│  PROBLEMA CON DELETE AUTOMÁTICO EN SSH:                               │
│  ├── False positives: soporte legítimo parece ataque                  │
│  ├── User experience: cliente pierde música por hacer debug           │
│  ├── Bypass trivial: attacker sabe que SSH triggerea deletion        │
│  ├── Legitimate SSH: developer, support, debugging todos afectados    │
│  └── Violación de privacidad: usuario pierde acceso a SU contenido    │
│                                                                         │
│  POLÍTICA CORRECTA:                                                   │
│  ├── SSH en producción: DESHABILITADO por default                    │
│  ├── Si SSH enabled por error: logging + alerta, NO deletion        │
│  ├── Acceso físico: difícil de detectar, considerar full-disk encrypt │
│  ├── Soporte: canal separado (no SSH), auditado                      │
│  └── Tampering real: logging detallado + respuesta proporcional        │
│                                                                         │
│  RESPUESTA PROPORCIONAL:                                              │
│  ├── Acceso no autorizado detectado → alerta + log                   │
│  ├── Intento de extracción masiva → alerta + potential wipe         │
│  ├── Modificación de contenido → marcar como corrupto                │
│  └── Physical tampering → factory reset (solo si configured)        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Detección de Tampering

```
MECANISMOS DE DETECCIÓN:

1. INTEGRIDAD DE STORAGE
   ├── Verificación periódica de hashes de tracks
   ├── Comparación de playlist.json vs filesystem
   ├── Verificación de timestamps de modificación
   └── Alert si mismatch detectado

2. DETECCIÓN DE SSH (si inadvertidamente enabled)
   ├── Monitoreo de intentos de conexión
   ├── Verificación de authorized_keys changes
   └── Logueo de sesiones SSH activas

3. MONITOREO DE ARCHIVOS
   ├── inotify en /home/sigil/music/
   ├── Detección de archivos nuevos/modificados/eliminados
   └── Verificación de permisos

4. BOOT INTEGRITY (futuro)
   ├── Secure boot chain
   ├── Measured boot
   └── Firmware verification

5. RUNTIME DETECTION (futuro)
   ├── ptrace detection
   ├── /proc access monitoring
   └── Memory dumping detection
```

### 6.4 Políticas de Wipe/Deletion

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    POLÍTICA DE WIPE/DELETION                           │
│                                                                         │
│  TRIGGERS DE WIPE:                                                    │
│  ├── Explicit factory reset (usuario o API)                            │
│  ├── Tamper detected: storage integrity breach                        │
│  ├── Max TTL exceeded (14+ días sin sync)                             │
│  └── Command from backend (license revocation)                        │
│                                                                         │
│  NO TRIGGERS DE WIPE:                                                 │
│  ├── SSH login (ERROR: usar logging + alerta)                         │
│  ├── Acceso físico casual                                             │
│  ├── Power loss                                                       │
│  └── Normal operation                                                 │
│                                                                         │
│  COMPORTAMIENTO EN WIPE:                                               │
│  ├── /home/sigil/music/ → DELETE                                     │
│  ├── playlist.active.json → DELETE                                     │
│  ├── staging/ → DELETE                                               │
│  ├── archive/ → DELETE                                               │
│  ├── playback_state.json → RESET (preserve position)                  │
│  ├── device.json → PRESERVE (identidad)                              │
│  ├── /etc/sigil/panel.env → PRESERVE (secrets)                      │
│  └── Security logs → PRESERVE (auditoría)                            │
│                                                                         │
│  AFTER WIPE:                                                          │
│  ├── Re-sync desde servidor                                           │
│  ├── Playback desde inicio (radio)                                   │
│  ├── Log event de wipe                                               │
│  └── Notificar backend (si disponible)                                │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.5 Evitar False Positives

```
ESTRATEGIAS PARA EVITAR FP:

1. THRESHOLD BÁSED DETECTION
   ├── No alerta en 1 acceso inusual, requiere patrón
   ├── Ejemplo: 5 intentos SSH fallidos = alerta
   ├── Ejemplo: 3 modificaciones de archivo = alerta
   └── Ejemplo: acceso en hora inusual = warning

2. CONTEXT AWARENESS
   ├── Factory mode: logging normal, no alertas
   ├── Support mode: comandos esperados, no alertas
   ├── Debug builds: diferentes expectativas
   └── Production builds: strict detection

3. STAGED RESPONSE
   ├── Level 1: Log + warning (detección)
   ├── Level 2: Alert + user notification (confirmado)
   ├── Level 3: Wipe + backend notification (severo)
   └── Escalation based on severity + repeat count

4. GRACEFUL DEGRADATION
   ├── Si detection subsystem fails → fail open vs fail closed?
   ├── Recomendado: fail closed (seguro)
   └── Log error + continue with conservative defaults

5. DISTINGUISH ACCIDENTAL VS INTENTIONAL
   ├── Archivo modificado una vez → warning
   ├── Múltiples archivos → alerta
   ├── Archivos específicos críticos → severa
   └── Patrón de extracción → crítico
```

### 6.6 Contrato: Detección de Tampering

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    FLUJO DE DETECCIÓN DE TAMPERING                      │
│                                                                         │
│  radio-fetcher.service                        audio-manager.service   │
│         │                                             │                 │
│         │ 1. Periódicamente:                        │                 │
│         │    verify_storage_integrity()             │                 │
│         │    ├── sha256(tracks/*)                  │                 │
│         │    ├── Compare with cache_meta            │                 │
│         │    └── Check file timestamps              │                 │
│         │                                             │                 │
│         │ 2. SI mismatch detectado:                  │                 │
│         │    CREATE tamper_event.json ───────────────▶│                │
│         │    {                                      │                 │
│         │      "event_type": "storage_mismatch",   │                 │
│         │      "severity": "high"                  │                 │
│         │    }                                    │                 │
│         │                                             │                 │
│         │ 3. audio-manager evalúa:                  │                 │
│         │    IF severity == "critical":            │                 │
│         │        INITIATE_WIPE                     │                 │
│         │    ELIF severity == "high":              │                 │
│         │        ALERT + LOG + user notification   │                 │
│         │    ELSE:                                 │                 │
│         │        LOG + continue                    │                 │
│         │                                             │                 │
│         │ 4. backend notification (si disponible)  │                 │
│         │    POST /api/devices/{id}/tamper-event  │                 │
│         │                                             │                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. CONTRATOS ENTRE SERVICIOS

### 7.1 Contrato: radio-fetcher ↔ audio-manager

```
EVENTO: Nueva playlist detectada
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
radio-fetcher                    audio-manager
    │                                  │
    │  publishes                        │
    │  playlist.staging.json ───────────▶│
    │  (con download_status)            │
    │                                  │
    │  (al completar)                   │
    │  atomic swap                     │
    │  staging → active                │
    │                                  │
    │  publishes                       │
    │  playlist.active.json ───────────▶│
    │                                  │
    │  publishes                       │
    │  cache_meta.json ────────────────▶│
    │  (actualizado expires_at)        │
    │                                  │
    │  (si tampering detectado)        │
    │  tamper_event.json ───────────────▶│
    │                                  │
```

### 7.2 Contrato: audio-manager ↔ audio-player

```
COMANDO: Cambio de modo
━━━━━━━━━━━━━━━━━━━━━━━
audio-manager                    audio-player
    │                                  │
    │  writes                           │
    │  audio_mode.json ────────────────▶│
    │  (contiene modo, razón, etc)     │
    │                                  │
    │  writes                           │
    │  cache_meta.json ────────────────▶│
    │  (para verificar TTL)           │
    │                                  │
    │  ←───────────────────────────────│
    │  playback_state.json              │
    │  (responde con estado)            │
```

### 7.3 Contrato: audio-player → audio-manager (Cache Expirado)

```
NOTIFICACIÓN: Caché Expirado
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
audio-player                     audio-manager
    │                                  │
    │  reads                            │
    │  ◀── cache_meta.json             │
    │  (verifica expires_at)           │
    │                                  │
    │  IF expires_at < now():          │
    │  writes                           │
    │  audio_mode.json ────────────────▶│
    │  {mode: "CACHE_EXPIRED"}         │
    │                                  │
    │  CONTINÚA playback desde local    │
    │  (no interrumpe)                  │
    │                                  │
```

---

## 8. FLUJO: Radio-First con Caché de 7 Días

### 8.1 Diagrama de Estados (Actualizado)

```
                    ┌─────────────────────────────────────┐
                    │                                     │
                    ▼                                     │
            ┌───────────────┐                            │
            │    IDLE       │◀────────────────────────┐  │
            │ (sin sink)   │                         │  │
            └───────┬───────┘                         │  │
                    │ sink disponible                 │  │
                    ▼                                 │  │
            ┌───────────────┐                         │  │
            │    RADIO     │─────────────────────────┼──┘│
            │ (servidor OK)│  servidor caído 3x       │   │
            └───────┬───────┘                         │   │
                    │                                  │   │
        servidor OK│                                  │   │
        + playlist │                                  │   │
        actualizada│                                  │   │
                    ▼                                  │   │
            ┌───────────────┐                         │   │
            │ TRANSITIONING │                         │   │
            │ (sync staging)│                         │   │
            └───────┬───────┘                         │   │
                    │ sync completo                    │   │
                    ▼                                  │   │
            ┌───────────────┐     servidor OK          │   │
            │    LOCAL      │─────────────────────────┘   │
            │ (caché local) │     FALLBACK_THRESHOLD=3  │
            └───────┬───────┘                            │
                    │                                    │
        servidor OK│  + modo noforced                   │
                    ▼                                    │
            ┌───────────────┐                            │
            │   BACK TO     │                            │
            │    RADIO      │────────────────────────────┘
            │               │  (opcional, según policy)
            └───────────────┘
            
            ┌───────────────┐
            │CACHE_EXPIRED │◀────────────────────────────────┐
            │ (TTL 7 días)  │                                 │
            └───────┬───────┘                                 │
                    │                                          │
        servidor OK│  + sync exitosa                           │
                    ▼                                          │
            ┌───────────────┐                                  │
            │   RESYNC      │──────────────────────────────────┘
            │  nueva lista  │
            └───────────────┘
```

### 8.2 Algoritmo: Radio-First + Cache 7 Días

```
ALGORITMO: Radio-First Fallback con Cache Policy

VARIABLES:
  FALLBACK_THRESHOLD = 3
  CACHE_TTL_DAYS = 7
  SYNC_INTERVAL_SECONDS = 300

1. INICIO:
   audio-manager inicia en modo RADIO
   radio-fetcher inicia sync loop

2. SYNC_LOOP (cada 30 segundos):
   
   a. CHECK CACHÉ TTL:
      cache_meta = READ cache_meta.json
      IF cache_meta.active_cache.expires_at < now():
          IF audio_mode.mode == "LOCAL":
              SET audio_mode.mode = "CACHE_EXPIRED"
              audio_mode.reason = "cache_expired"
              LOG "Cache expired at {expires_at}"
              # NO STOP PLAYBACK
      
   b. CHECK SERVIDOR:
      servidor_ok = ping_servidor()
      
      IF modo_actual == "RADIO":
          IF NOT servidor_ok:
              fallidos += 1
              IF fallidos >= FALLBACK_THRESHOLD:
                  SI cache_meta.active_cache EXISTS:
                      cambiar_modo("LOCAL")
                  ELSE:
                      cambiar_modo("IDLE")
                      
      ELIF modo_actual == "LOCAL" OR "CACHE_EXPIRED":
          IF servidor_ok:
              # Attempt resync
              resync_result = radio-fetcher.attempt_sync()
              IF resync_result.success:
                  IF modo_actual == "CACHE_EXPIRED":
                      cambiar_modo("LOCAL")
                  # Continue normally
                  
3. RADIO-FETCHER SYNC (cada 5 minutos):

   a. FETCH REMOTE PLAYLIST:
      remote = GET /api/devices/{id}/playlist
      remote_hash = sha256(remote)
      
   b. COMPARE WITH LOCAL:
      local = READ playlist.active.json
      local_hash = local.version_hash
      
      IF remote_hash == local_hash:
          # No changes - skip download
          UPDATE cache_meta.statistics.bandwidth_saved
          LOG "Playlist unchanged, skipped"
          RETURN
          
   c. NEW PLAYLIST DETECTED:
      # Download to staging, verify, atomic swap
      # (See Algorithm 5.2)
      
4. PLAYBACK BEHAVIOR DURING SYNC:

   a. radio-fetcher corre en background, no afecta playback
   b. Radio continua sonando si modo == RADIO
   c. Local playback continua si modo == LOCAL
   d. Al completar staging:
      - playback.transición natural en siguiente track
      - no hay gap ni restart
```

---

## 9. CONFIGURACIÓN /etc/sigil/audio.conf

```bash
# =============================================================================
# audio.conf — Configuración del sistema de audio Sigil
# =============================================================================

# --- Servidor ---
SERVER_URL="https://devproserver.tail942ea3.ts.net"
API_KEY="<placeholder>"  # Se llena en firstboot desde provision

# --- Comportamiento ---
# radio-first: mantiene RADIO como modo primario
# local-first: usa LOCAL como modo primario
PLAYBACK_MODE="radio-first"

# Intentos fallidos antes de hacer fallback a LOCAL
FALLBACK_THRESHOLD=3

# Intervalo de check al servidor (segundos)
SERVER_CHECK_INTERVAL=30

# Intervalo de sync de playlist (segundos)
PLAYLIST_SYNC_INTERVAL=300

# --- Cache Policy (7 DÍAS) ---
CACHE_TTL_DAYS=7
CACHE_AUTO_RENEW=true
CACHE_DELETE_ON_EXPIRE=true
CACHE_PRESERVE_WHEN_OFFLINE=false

# --- Logging ---
LOG_LEVEL="INFO"
```

### 9.1 Configuración /etc/sigil/security.conf (NUEVO)

```bash
# =============================================================================
# security.conf — Configuración de seguridad Sigil
# =============================================================================

# --- Build Type ---
BUILD_TYPE="production"  # production | factory | debug
DEVICE_MODE="production" # production | support | factory

# --- Tamper Detection ---
TAMPER_DETECTION_ENABLED=true
TAMPER_CHECK_INTERVAL=60
TAMPER_LOG_ONLY=true  # Si true, solo log. Si false, puede wipe

# --- Wipe Policy ---
WIPE_ON_TAMPER=false  # NO recomendado: usar log + alert
WIPE_ON_MAX_TTL=false  # 14+ días sin sync
FACTORY_RESET_AVAILABLE=true

# --- SSH ---
SSH_ENABLED=false  # Production: siempre false
SSH_FACTORY_ONLY=true
SSH_AUTHORIZED_KEYS_FILE="/etc/sigil/ssh_authorized_keys"

# --- Support Mode ---
SUPPORT_MODE_ENABLED=false
SUPPORT_CHANNEL="none"  # none | api | vpn | custom
SUPPORT_AUTH_REQUIRED=true

# --- Storage Encryption (FUTURE) ---
STORAGE_ENCRYPTION=false
ENCRYPTION_KEY_SOURCE="server"  # server | hardware | derived
```

---

## 10. IMPLEMENTACIÓN EN ETAPAS

### Fase 1A: Contratos JSON (1-2 días)

```
TAREAS:
[ ] Crear schema de device.json (ya existe, documentar)
[ ] Crear playlist.active.json schema
[ ] Crear playlist.staging.json schema  
[ ] Crear playback_state.json schema
[ ] Crear audio_mode.json schema
[ ] Crear bluetooth_state.json schema
[ ] Crear cache_meta.json schema (NUEVO)
[ ] Crear security_state.json schema (NUEVO)
[ ] Crear tamper_event.json schema (NUEVO)
[ ] Crear validación de schemas

ENTREGABLE:
- JSON schemas validados
- Documentación de cada campo
- Ejemplos de cada archivo
```

### Fase 1B: Separación de Scripts (3-5 días)

```
TAREAS:
[ ] Extraer lógica de descarga de radio-stream.sh → radio-fetcher.sh
[ ] Extraer lógica de reproducción de radio-stream.sh → audio-player.sh
[ ] Crear audio-manager.sh como orquestador
[ ] Implementar atomic swap en radio-fetcher.sh
[ ] Implementar playback_state persistence en audio-player.sh
[ ] Implementar cambio de modo en audio-manager.sh
[ ] Implementar cache TTL check en radio-fetcher.sh
[ ] Implementar sync inteligente (hash comparison) en radio-fetcher.sh
[ ] Mantener compatibilidad con sink Bluetooth existente

ENTREGABLE:
- 3 scripts funcionales
- playback_state sobrevive a reinicios
- Cambio de modo funciona sin interrumpir playback
- Cache se renueva SOLO si playlist cambió
```

### Fase 1C: Servicios systemd (1-2 días)

```
TAREAS:
[ ] Crear radio-fetcher.service
[ ] Crear audio-manager.service
[ ] Crear audio-player.service (reemplazo de radio-stream.service)
[ ] Actualizar install.sh para incluir nuevos servicios
[ ] Actualizar manifests/services.json
[ ] Actualizar orden de dependencias en bt-connect.service

ENTREGABLE:
- 3 servicios systemd funcionando
- Orden de startup correcta
- Reinicios automáticos funcionan
```

### Fase 1D: Cache + Seguridad (2 días)

```
TAREAS:
[ ] Implementar cache_meta.json en radio-fetcher.sh
[ ] Implementar TTL check (7 días)
[ ] Implementar sync inteligente (skip if unchanged)
[ ] Crear security_state.json template
[ ] Implementar basic tamper detection en radio-fetcher.sh
[ ] Crear tamper_event.json generation
[ ] Extraer API_KEY y SERVER_URL a /etc/sigil/audio.conf
[ ] Crear /etc/sigil/security.conf

ENTREGABLE:
- Cache policy funcionando (7 días)
- Sync inteligente (no redownload si no cambió)
- Basic tamper detection implementado
- Configuración centralizada
```

---

## 11. VERIFICACIÓN DE CONTRATOS

### 11.1 Contratos a Verificar en Fase 1

| Contrato | Descripción | Verificación |
|----------|-------------|--------------|
| radio-fetcher → filesystem | staging/ se crea y popula | Count files in staging/ |
| atomic swap | old → archive, staging → active | Compare hashes before/after |
| cache TTL | expires_at se actualiza correctamente | Check dates |
| sync skip | Si hash igual, no descarga | Monitor network traffic |
| audio-manager → audio-player | audio_mode.json se actualiza | Parse JSON on mode change |
| playback persistence | position survives restart | Compare playback_state before/after |
| fallback threshold | 3 fallos = LOCAL mode | Inject 3 server failures |
| tamper detection | Mismatch genera evento | Modify track, verify event |

### 11.2 Test Cases Mínimos

```
TEST 1: Primera Playlist
  - Apagar servidor
  - Iniciar servicios
  - radio-fetcher debe crear staging/
  - Verificar tracks descargados
  - Verificar cache_meta.expires_at = now + 7 días

TEST 2: Sync Inteligente
  - Playlist en servidor no cambia
  - Esperar sync interval
  - Verificar NO hay descarga
  - Verificar bandwidth_saved incrementa

TEST 3: Playlist Cambia
  - Modificar playlist en servidor
  - Esperar sync
  - Verificar staging/ se crea
  - Verificar atomic swap
  - Verificar archive/ tiene old playlist

TEST 4: Atomic Swap
  - Simular nueva playlist en servidor
  - Esperar sync interval
  - Verificar old en archive/
  - Verificar new en active/
  - Verificar playback no interrumpe

TEST 5: Cache Expira
  - Forzar expires_at < now
  - Verificar modo = CACHE_EXPIRED
  - Verificar playback continúa
  - Verificar NO se elimina contenido automáticamente

TEST 6: Fallback a LOCAL
  - Modo RADIO activo
  - Fallar 3 checks consecutivos
  - Verificar modo = LOCAL
  - Verificar playback desde caché

TEST 7: Persistencia
  - Reproducir track 5 de playlist
  - Reiniciar audio-player.service
  - Verificar continúa en track 5

TEST 8: Tamper Detection
  - Modificar archivo en active/tracks/
  - Esperar próxima verificación
  - Verificar tamper_event.json creado
  - Verificar log entry
```

---

## 12. LO QUE NO SE IMPLEMENTA EN FASE 1

| Feature | Razón | Fase |
|---------|-------|------|
| TLS/certificados | Premature | Fase 2+ |
| Firma digital de tracks | Premature | Fase 2+ |
| OTA updates | No hay backend | Fase 3 |
| Storage encryption | Premature, alto overhead | Fase 2+ |
| Full tamper detection (memory) | Premature | Fase 2+ |
| Secure boot chain | Premature | Fase 3+ |
| Remote wipe | No hay backend | Fase 3+ |
| Audit logging centralizado | Premature | Fase 2+ |

---

## 13. RESUMEN: SSH ≠ AUTOMATIC DELETION

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DECISIÓN FINAL DE SEGURIDAD                         │
│                                                                         │
│  SSH LOGIN:                                                           │
│  ├── Production: SSH DESHABILITADO                                    │
│  ├── Factory: SSH HABILITADO con keys manufacturing                   │
│  ├── Debug: SSH HABILITADO con keys engineering                       │
│  └── Support: Canal SEPARADO (no SSH)                                 │
│                                                                         │
│  SSH ≠ DELETION AUTOMÁTICA                                            │
│  ├── Logging + alerta en intento de acceso                           │
│  ├── NO deletion automática                                           │
│  ├── Diferenciar authorized vs unauthorized                            │
│  └── Respuesta proporcional al riesgo                                 │
│                                                                         │
│  ACCESO NO AUTORIZADO REAL:                                           │
│  ├── Detección de tampering en storage                                │
│  ├── Modificación de tracks                                           │
│  ├── Extracción masiva                                                │
│  └── Posible factory reset si configured                              │
│                                                                         │
│  CONTENIDO DEL USUARIO:                                               │
│  ├── Música es licensed, no owned                                     │
│  ├── Server puede revocar access                                       │
│  ├── API key rotation invalida cache                                  │
│  └── No hay bypass real sin romper el sistema                        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## APÉNDICE A: Referencia de Schemas

### A.1 JSON Schema Draft

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "definitions": {
    "cache_meta": {
      "type": "object",
      "required": ["_schema_version", "cache_policy", "active_cache"],
      "properties": {
        "_schema_version": { "const": "1.0" },
        "cache_policy": {
          "type": "object",
          "required": ["max_ttl_days", "auto_renew", "delete_on_expire"],
          "properties": {
            "max_ttl_days": { "type": "integer", "minimum": 1, "maximum": 30 },
            "auto_renew": { "type": "boolean" },
            "delete_on_expire": { "type": "boolean" },
            "preserve_on_server_unavailable": { "type": "boolean" }
          }
        },
        "active_cache": {
          "type": "object",
          "properties": {
            "playlist_id": { "type": "string" },
            "version_hash": { "type": "string" },
            "downloaded_at": { "type": "string", "format": "date-time" },
            "expires_at": { "type": "string", "format": "date-time" },
            "tracks_count": { "type": "integer" },
            "total_size_bytes": { "type": "integer" },
            "integrity_verified": { "type": "boolean" }
          }
        }
      }
    },
    "security_state": {
      "type": "object",
      "required": ["_schema_version", "device_mode", "build_type"],
      "properties": {
        "_schema_version": { "const": "1.0" },
        "device_mode": { 
          "enum": ["production", "factory", "debug", "support"]
        },
        "build_type": { 
          "enum": ["production", "factory", "debug"]
        },
        "ssh_enabled": { "type": "boolean" },
        "tamper_detection": {
          "type": "object",
          "properties": {
            "enabled": { "type": "boolean" },
            "storage_integrity": {
              "type": "object",
              "properties": {
                "status": { "enum": ["verified", "mismatch", "unknown"] },
                "last_verified": { "type": "string", "format": "date-time" },
                "hash": { "type": "string" }
              }
            }
          }
        },
        "wipe_policy": {
          "type": "object",
          "properties": {
            "enabled": { "type": "boolean" },
            "triggers": { "type": "array", "items": { "type": "string" } },
            "preserve_device_identity": { "type": "boolean" }
          }
        }
      }
    },
    "tamper_event": {
      "type": "object",
      "required": ["_schema_version", "event_id", "event_type", "severity"],
      "properties": {
        "_schema_version": { "const": "1.0" },
        "event_id": { "type": "string" },
        "event_type": { 
          "enum": [
            "storage_integrity_mismatch",
            "ssh_access_attempt",
            "unauthorized_modification",
            "extraction_detected",
            "runtime_integrity_breach"
          ]
        },
        "severity": { 
          "enum": ["low", "medium", "high", "critical"]
        },
        "detected_at": { "type": "string", "format": "date-time" },
        "resolved": { "type": "boolean" },
        "auto_response": { "enum": ["none", "alert_only", "wipe"] }
      }
    }
  }
}
```

---

## APÉNDICE B: Glosario de Seguridad

| Término | Definición |
|---------|------------|
| Authorized access | Acceso con keys válidas de factory/debug/support |
| Unauthorized access | Acceso sin credenciales válidas |
| Tampering | Modificación no autorizada de archivos/estado |
| Storage tampering | Modificación de archivos en /home/sigil/music/ |
| Memory tampering | Modificación de proceso en runtime |
| Wipe | Eliminación completa de contenido cacheado |
| Factory reset | Restablecimiento a estado inicial |
| Support mode | Modo especial para diagnóstico remoto |
| False positive | Alerta triggered por causa legítima, no amenaza |

---

## APÉNDICE C: Matriz de Respuesta a Incidentes

| Evento | Severity | Auto Response | User Notification | Backend Alert |
|--------|----------|---------------|-------------------|---------------|
| SSH attempt (prod) | Low | Log only | No | No |
| SSH success (prod) | High | Alert + log | Optional | Yes |
| File modified (1x) | Low | Log only | No | No |
| File modified (3x) | Medium | Alert | Yes | Optional |
| Track hash mismatch | High | Alert + event | Yes | Yes |
| Extraction pattern | Critical | Alert + log | Yes | Yes |
| Cache TTL expired | Low | Mode change | Yes | No |
| Tamper: storage | High | Alert | Yes | Yes |
| Tamper: runtime | Critical | Alert | Yes | Yes |

---

**FIN DEL DOCUMENTO - v2.0**
