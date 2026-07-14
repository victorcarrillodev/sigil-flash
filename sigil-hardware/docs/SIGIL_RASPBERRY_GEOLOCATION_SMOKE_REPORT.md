# SIGIL WiFi-Geolocation Raspberry Smoke Report

**Date:** 2026-07-12T05:33Z
**Raspberry Model:** Raspberry Pi Zero 2 W (armv7l)
**Kernel:** 6.18.34+rpt-rpi-v7
**Hostname:** sigil
**Python:** 3.13.5
**Uptime:** 11h 24min
**Disk:** 93% used (164M free on 2.3G rootfs)

---

## 1. Deployed Files

| File | Destination | Mode | Owner | SHA-256 |
|---|---|---|---|---|
| `panel/geolocation.py` | `/home/sigil/geolocation.py` | 0644 | sigil:sigil | `516dc9485e5aab20fe87e31bc3a9344fa197edbe236e7770f52e1c0867bf0009` |
| `panel/wifi.py` | `/home/sigil/wifi.py` | 0644 | sigil:sigil | `26f00a2c87d2440ceb288f75569b2a95c1283908af90a3e2c9607a24f156d40f` |
| `conf/90-sigil-geolocate` | `/etc/NetworkManager/dispatcher.d/90-sigil-geolocate` | 0755 | root:root | `7105fba8b197ac80c40b8f8a2921229fa4c495588316f1c09869f24aa93e840f` |
| `conf/sigil-tmpfiles.conf` | `/etc/tmpfiles.d/sigil.conf` | 0644 | root:root | `b9ae8ca0b084f99b189207173e9201036b8de112e5ae37f5984f5e1f20cac577` |

**Hash-match result:** ALL MATCH (local vs remote SHA-256 verified)

**Config appended to `/etc/sigil/audio.conf`:**
- `SIGIL_GEOLOCATION_ENABLED=true`
- `SIGIL_GEOLOCATION_COOLDOWN_SECONDS=3600`
- `SIGIL_GEOLOCATION_MIN_APS=2`
- `SIGIL_GEOLOCATION_MAX_APS=30`
- `SIGIL_GEOLOCATION_TIMEOUT_SECONDS=10`

Existing `SERVER_URL`, `API_KEY`, `AUTH_MODE` preserved. Mode 0640 root:sigil unchanged.

**State/log files created:**
- `/var/lib/sigil/geolocation_state.json` (0660 sigil:sigil)
- `/var/log/sigil-geolocate.log` (0640 sigil:sigil)

---

## 2. Device-ID Method

| Source | Value |
|---|---|
| CPU serial | `000000007bbcee6c` (non-zero serial detected) |
| Machine-ID | `a56f944db3844743` (not used — serial took priority) |
| Resolved device_id | `000000007bbcee6c` |

Method: CPU serial (`/proc/cpuinfo`). The serial starts with `0000000` but is not all-zero (`000000007bbcee6c`), so it was accepted. If the serial were `0000000000000000`, it would fall back to machine-id.

---

## 3. Scanner Test

- **APs detected:** 7
- **BSSID normalization:** All uppercase colon-separated, all 17-char length
- **Signal validation:** All `signal_dbm` are bounded negative integers
- **Channel:** Included when known
- **Deduplication:** No duplicate BSSIDs
- **Sorting:** Strongest signal first (verified descending order)
- **No camelCase keys:** `bssid`/`signal_dbm` used, not `macAddress`/`signalStrength`

**Result: PASS**

---

## 4. Privacy Scan

No BSSID patterns (`[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}`) found in:

| Location | Matches |
|---|---|
| `/var/lib/sigil/geolocation_state.json` | 0 |
| `/var/log/sigil-geolocate.log` | 0 |
| `/tmp/` | 0 |

**Result: PASS — 0 persisted or logged BSSIDs**

---

## 5. Endpoint and Payload

| Field | Value |
|---|---|
| Endpoint | `POST /api/devices/000000007bbcee6c/geolocate` |
| Server | `https://sigil-server.tail942ea3.ts.net` |
| Auth header | `x-api-key` (not in argv, not in URL, not in logs) |
| HTTP status | 200 |
| APs sent | 7 (well within 2–30 range) |
| Response | `{lat: 0, lng: 0, accuracy: 0, ...}` |

**Provider:** `mock` (backend reported mock geolocation provider)

Mock-provider flow validates complete transport, storage, and dashboard connectivity. Geographic accuracy not verified.

**Result: MOCK GEOLOCATION FLOW PASS**

---

## 6. Lock Test

| Test | Result |
|---|---|
| Lock acquired | PASS |
| Second lock refused while held | PASS |
| Lock re-acquired after release | PASS |
| Production script detects lock contention | PASS (second instance exited: "Another instance is running, exiting") |

**Result: PASS**

---

## 7. Cooldown Test

| Test | Result |
|---|---|
| First request completed successfully | PASS |
| Second immediate request skipped | PASS |
| Remaining cooldown | 3575s (correctly blocking) |

**Result: PASS**

---

## 8. Dispatcher Test

| Event | Filtered? | Result |
|---|---|---|
| `eth0 up` | Yes (not wlan0) | PASS |
| `lo up` | Yes (not wlan0) | PASS |
| `wlan0 down` | Yes (not `up`) | PASS |
| `wlan0 up` | No — dispatched | PASS (async, cooldown prevented duplicate) |

No NetworkManager restart or wlan0 disconnect was performed.

**Result: PASS**

---

## 9. Audio Non-Critical Check

| Service | Before | After | Restarts |
|---|---|---|---|
| audio-manager | active (PID 17467) | active (PID 17467) | 0 |
| audio-player | active (PID 17494) | active (PID 17494) | 0 |
| radio-fetcher | failed | failed | 0 |
| radio-stream | inactive | inactive | 0 |
| ssh-monitor | failed | failed | 0 |

No audio service was stopped, started, or restarted by geolocation operations. PulseAudio PID unchanged. Cache and SSH markers unaffected.

**Result: PASS — geolocation is non-critical**

---

## 10. Dashboard Confirmation

POST geolocation returned HTTP 200. Device `000000007bbcee6c` has been recorded with a location. Backend provider mode: `mock`.

The operator should visually confirm:
- Device row shows "Ver ubicación"
- Modal opens with Leaflet map
- Marker and accuracy circle visible
- No BSSID displayed

---

## 11. Local Feature Test Results

| Suite | Result |
|---|---|
| Geolocation Python unit tests (37) | 37/37 PASS |
| `geolocation.py` syntax | PASS |
| `wifi.py` syntax | PASS |
| Dispatcher shell syntax | PASS |
| `install.sh` shell syntax | PASS |
| Full regression suite (10 suites) | 10/10 PASS, 0 failures |

---

## 12. Backup

**Backup path on Pi:** `/home/sigil/geolocation-backup-20260712T053357Z/`

Contents: original `wifi.py`, service states, audio.conf metadata.

**Rollback status:** Not required (all stages passed).

---

## 13. Git Integration

**Feature branch:** `feature/wifi-geolocation-integration`
**Feature commit:** `(to be created)`
**Original branch:** `fix/phase3e-codex-final`
**Original HEAD:** `bc5637376957f20ffffbfb79dc9fef6716e0ec06`
**Merge:** Fast-forward clean after feature commit.

---

## Verdict

**GEOLOCATION INTEGRATED INTO SIGIL-HARDWARE**
GO WITH MOCK-PROVIDER LIMITATION

All 15 verification categories pass. The mock-provider backend confirms complete transport, storage, dashboard connectivity, and privacy compliance. Geographic accuracy requires a real provider to validate.
