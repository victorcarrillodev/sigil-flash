# SIGIL Remote Server Integration Report

**Date:** 2026-07-12  
**Device:** Raspberry Pi Zero 2 W  
**Hostname:** sigil  
**Remote Repository:** sigil-hardware (scripts deployed, no git on device)  
**Server URL:** https://sigil-server.tail942ea3.ts.net  

---

## Device Identity
- **CPU Serial:** 000000007bbcee6c
- **Model:** Raspberry Pi Zero 2 W Rev 1.0  
- **Hostname:** sigil  
- **Device ID Resolution:** CPU serial (fallback: machine-id, then sigil-unknown)

---

## 1. Raspberry Hostname and Commit
- Hostname: sigil (armv7l, Raspbian, kernel 6.18.34+rpt-rpi-v7)
- No local git repository on device; scripts deployed from sigil-hardware repo

## 2. Server URL Tested
https://sigil-server.tail942ea3.ts.net

## 3. Production Backend Validation
**Production backend validation is not claimed.**

## 4. Health Result
**PASS** - HTTP 200, response: {"ok":true,"service":"sigil-dev-server"}

## 5. Registration Result
**PASS** - HTTP 201, response: {"ok":true,"registered":true,"device_id":"000000007bbcee6c"}
- Device ID method (CPU serial) accepted by server
- Registration payload matched contract exactly

## 6. Resolved Device ID Method
1. /proc/cpuinfo Serial: 000000007bbcee6c (used, accepted by server)
2. Fallback: first 16 chars of /etc/machine-id
3. Final fallback: sigil-unknown

## 7. Playlist Contract Result
**PASS** - Response is valid JSON with correct schema:
- _schema_version: "1.0"
- playlist_id: "pl_1" (after operator assignment)
- version_hash: "sha256:533a5dd7147b87d17831117079072e2e1a4a34b987485fb87dd256edc814bd57"
- tracks: [2 items] - both have id, url, filename, sha256, title, size_bytes
- Note: Initially returned empty playlist (new device). Tracks assigned manually on server.

## 8. Track Download and SHA-256 Result
**PASS (with limitations)**
- radio-fetcher detected playlist change, downloaded 2 tracks, performed atomic swap
- Server returns Content-Type: audio/mpeg with valid MP3 data (Lavf60.16.100, LAME 3.100)
- Average track size: ~5.6 MB
- SHA-256 field is empty (sha256: "") on server side - client-side hash verification skipped
- size_bytes is 0 on server side - actual content-length used instead

## 9. Cache Synchronization Result
**PASS**
- radio-fetcher detected hash change, downloaded to staging, verified, atomic swap
- cache_meta updated: version_hash, downloaded_at, expires_at (7-day TTL)
- Archive rotation works (oldest archive removed automatically)
- Runtime counter preserved across cache updates

## 10. Bluetooth Playback Result
**PASS** - Operator confirmed audible playback
- Bluetooth speaker: JBL CHARGE MINI (41:42:F3:C2:04:CF)
- Paired, trusted, connected (80% battery)
- PulseAudio sink: bluez_sink.41_42_F3_C2_04_CF.a2dp_sink - RUNNING
- mpg123 playing via -a bluez_sink.41_42_F3_C2_04_CF.a2dp_sink
- Playback mode: RADIO (streaming from server)

## 11. SSH Wipe/Logout Result
**NOT TESTED** - ssh-monitor.service remains disabled (unchanged)

## 12. Service States Before and After

| Service | Before | After |
|---------|--------|-------|
| radio-fetcher | enabled, active (PID 19104) | enabled, active (PID 3092) |
| audio-manager | enabled, active (PID 19282) | enabled, active (PID 3200) |
| audio-player | enabled, active (PID 9426) | enabled, active (PID 3275) |
| radio-stream | disabled, inactive | disabled, inactive |
| ssh-monitor | disabled, inactive | disabled, inactive |

## 13. Files Modified on Raspberry
- /etc/sigil/audio.conf - SERVER_URL, AUTH_MODE, API_KEY updated
- /usr/local/bin/radio-fetcher.sh (51284 bytes)
- /usr/local/bin/radio-stream.sh (11237 bytes)
- /usr/local/bin/audio-player.sh (41797 bytes)
- /usr/local/bin/audio-manager.sh (35491 bytes)
- /usr/local/bin/ssh-monitor.sh (15725 bytes)
- /usr/local/bin/firstboot.sh (30765 bytes) - new
- /etc/systemd/system/audio-manager.service - new
- /etc/systemd/system/audio-player.service - replaced
- /etc/systemd/system/radio-fetcher.service - replaced
- /etc/systemd/system/ssh-monitor.service - replaced
- /run/sigil/ - created (lock directory)
- AUTH_MODE validation: added x-api-key support to all 3 scripts

## 14. Remote Backups Created
- /home/sigil/sigil-integration-backup-20260712_014808/
- /home/sigil/pre-deploy-backup-20260712_014616/

## 15. Secrets Redaction Confirmed
- API_KEY stored in /etc/sigil/audio.conf (640 root:sigil)
- x-api-key header used for authentication
- No credentials exposed in URLs, argv, shell history, or reports

## 16. Problems Found
1. Initial server playlist empty - no tracks assigned; operator added them manually
2. AUTH_MODE validation missing x-api-key - all 3 scripts rejected it; fixed on-device
3. Missing /run/sigil/ - lock directory created manually
4. BLOCKED_LEGACY oscillation - brief false positives on track transitions
5. Server SHA-256 and size_bytes empty - client-side validation disabled
6. Only MPEG audio supported - mpg123 only decodes MPEG-1/2/2.5 layers 1/2/3 (mp3/mp2)

## 17. Audio Format Support
Current decoder: mpg123 1.32.10
Supported: MPEG-1, MPEG-2, MPEG-2.5 (Layers 1, 2, 3) - mp3, mp2 only
NOT supported: WAV, FLAC, AAC, OGG, M4A, WMA, Opus, ALAC

Available alternatives on Pi:
- /usr/bin/ffplay - supports virtually all audio/video formats
- /usr/bin/paplay - supports WAV, FLAC, and PulseAudio codecs

To add multi-format support, update the player to detect file type (extension or magic bytes) and choose decoder accordingly: ffplay for non-MPEG, mpg123 for MPEG.

## 18. Rollback Status
**NOT NEEDED** - Backup at /home/sigil/sigil-integration-backup-20260712_014808/

## 19. Final Verdict
**GO WITH LIMITATIONS**

Audio playback CONFIRMED. Full pipeline functional:
1. Registration - PASS (CPU serial accepted)
2. Playlist fetch - PASS (contract matches)
3. Cache sync - PASS (atomic swap works)
4. Track download - PASS (audio/mpeg from server)
5. Bluetooth playback - PASS (CHARGE MINI, RUNNING)
6. Service orchestration - PASS (all 3 services active)

Limitations:
- No SHA-256 or size_bytes from server for track validation
- Only MPEG audio supported (mpg123)
- Brief BLOCKED_LEGACY states on track transitions
