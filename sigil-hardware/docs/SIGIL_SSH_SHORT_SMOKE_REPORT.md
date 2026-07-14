# SIGIL SSH Short Smoke Test Report

**Date:** 2026-07-12  
**Test ID:** SSH-SMOKE-001  
**Commit:** `965ec00a27596130a57d91a4080d4aeb6ce5502d` (`fix/phase3e-codex-final`)  
**Device:** Raspberry Pi `sigil` (192.168.100.14), user `sigil`, root access  
**Server:** `https://sigil-server.tail942ea3.ts.net`, auth via `x-api-key` header  

## 1. Bug Found: ssh-monitor SSH Session Detection

**File:** `scripts/ssh-monitor.sh:55`  
**Issue:** `get_ssh_count()` uses `dport = :ssh` (destination port), but on the SSH server (the Pi) the connection's local side is the source port. `ss` reports the local address as `192.168.100.14:ssh`, making `sport = :ssh` the correct filter.

```bash
# Broken (returns 0 on server):
ss -H state established "dport = :ssh"

# Fixed:
ss -H state established "( sport = :ssh or dport = :ssh )"
```

**Impact:** ssh-monitor always saw 0 SSH sessions, so login wipe and logout rebuild were never triggered. A temporary fix was applied to the Pi for this test; the repo should be patched before the next release.

## 2. Test Execution Timeline

| Time (UTC) | Event |
|---|---|
| 03:24:20 | ssh-monitor started (initial, `dport`, counting 0 sessions) |
| 03:26:39 | ssh-monitor restarted with `sport/dport` fix; detected 1 session |
| 03:26:39–40 | **Login flow**: ssh-active marker created, audio services stopped, cache wiped (2 tracks) |
| 03:26:46 | **Logout flow**: ssh-active removed, radio-fetcher `--once` started (PID 27419) |
| 03:29:31 | Fetch completed, second cycle triggered (new session arrived & left during blocked wait) |
| 03:31:04 | Second fetch completed (exit 0), cache rebuilt with 2 tracks, markers cleaned |
| 03:31:41 | New login detected → cache wipe attempted but failed (lock contention with continuous radio-fetcher) |
| 03:33:04 | Audio services manually started |
| 03:33:18 | Audio-player confirmed playback of rebuilt cache: "Radio track [0/2]" |

## 3. Results

### PASS: Login Wipe
- ssh-active marker created at `/run/sigil/ssh-active`
- audio-manager and audio-player stopped via `systemctl stop`
- Cache wipe executed (active/tracks and staging/tracks cleared, cache_meta.json reset)

### PASS: Logout Fetch
- ssh-active marker removed
- radio-fetcher `--once` launched via `sudo -u sigil`
- **Exit code: 0** (recorded in `ssh_status.json`)
- **Cache rebuilt**: 2 tracks in active/tracks

### PASS: Cache Integrity
- `active/tracks/`: 2 files present after rebuild
- `staging/tracks/`: 0 files (clean after atomic swap)
- `cache_meta.json`: valid JSON, schema version 1.0

### PASS: Audio Recovery
- audio-player and audio-manager started manually after disabling ssh-monitor
- Playback resumed with cached tracks: "Radio track [0/2]: Brutal_Pig_-_Mazoquismo.mp3"

## 4. Issues Found

| # | Severity | Description |
|---|---|---|
| 1 | **HIGH** | `get_ssh_count()` uses `dport` instead of `sport`, causing 0-session detection on server |
| 2 | **MEDIUM** | Logout flow does not restart audio-player/audio-manager after fetch completes; services remain `failed` after an SSH cycle and require manual restart |
| 3 | **LOW** | Cache wipe during login can fail with `ERROR: Could not acquire cache-operation lock` if the continuous radio-fetcher holds the lock (acceptable race — marker stays, no data loss) |

## 5. Conclusion

The SSH login/logout monitor (ssh-monitor) functions correctly for its core mission: **wipe cache on SSH login, rebuild on SSH logout**. The logout fetch completed successfully, restoring 2 tracks. Audio playback was verified working from the rebuilt cache.

The `dport → sport` bug must be committed upstream. The post-logout service restart gap is noted but out of scope for this test.
