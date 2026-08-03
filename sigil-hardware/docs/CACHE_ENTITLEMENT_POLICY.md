# SIGIL cache entitlement and remote-lock policy

## Status

**Implemented in the hardware runtime.**

This document records the intended policy so that future implementation work,
tests, and Graphify queries distinguish it from the currently deployed cache
behaviour.  It does not itself change playback behaviour.

## Purpose

SIGIL may play authenticated media from a validated local cache while the
device is offline, but cached content must not remain usable indefinitely.
The cache is a time-bounded entitlement, not permanent media storage.

## Authoritative policy

1. A fully validated cache generation is usable for at most **604800
   accumulated runtime seconds** after its last successful authenticated server
   validation. Wall clock does not grant extra time after rollback or reboot.
2. During those seven days, loss of Internet, DNS failure, a router restart,
   or SIGIL-server unavailability must not interrupt cache playback.
3. A successful authenticated playlist response restarts the grace period;
   cache promotion alone never does.
4. When day seven is reached, SIGIL must not start another track.  If a track
   is already playing, it is allowed to finish naturally.
5. Immediately after that track boundary (or immediately if no track is
   playing), SIGIL enters `LICENSE_EXPIRED_PURGED`, stops playback, and removes all
   locally cached media.  It must not keep playing an expired generation
   merely because the device is offline.
6. After the purge, SIGIL must not fall back to old local files or streaming.
   Playback can resume only after it contacts the authenticated SIGIL server
   and obtains a fresh validated playlist response; hybrid warm-up may then
   stream while the new local generation is rebuilt.
7. A remote administrative lock/revocation is a separate future server
   contract. It is **not** inferred from cache freshness, a generic HTTP
   error, or `stop_playback`. Until the backend returns an explicit
   authenticated policy field, the client treats only the documented playlist
   denial codes as an authorization denial boundary.

## Authorization contract

The existing playlist contract supports intentional silence through:

```json
{ "stop_playback": true, "tracks": [] }
```

That contract reauthorizes the device but preserves intentional silence.
Documented non-retryable protocol codes (`UNAUTHORIZED`, `FORBIDDEN`,
`DEVICE_NOT_AUTHORIZED`, `DEVICE_NOT_REGISTERED`,
`PLAYLIST_NOT_ASSIGNED`, `PLAYLIST_UNAVAILABLE`) create a terminal denial
boundary. Generic HTTP 404/409 without one of those codes remains transient.
No sensitive reason, token, or playlist content is exposed through panel logs.

## Expiry state flow

```text
Internet unavailable
        ↓
seven-day entitlement countdown
        ↓
days 0–6: normal cache playback
        ↓
day 7: do not start a new song
        ↓
current song ends
        ↓
LICENSE_EXPIRED_PURGED
        ↓
purge active + staging + archive + playlist metadata
        ↓
no playback until authenticated server contact and a validated generation
```

## Required purge transaction

The implementation must use the shared cache-operation lock and be safe across
power loss and concurrent fetch/playback work.  It must:

1. prevent `audio-player` from opening a new track once expiry is reached;
2. wait for the owned decoder to finish the current song, unless no song is
   active;
3. persist an expiry-pending state before deleting media, then publish
   terminal `LICENSE_EXPIRED_PURGED` after the idempotent purge completes;
4. remove active media, staging media, partial downloads, archived media, and
   active/staging playlist metadata;
5. persist the terminal license-expired reason atomically;
6. preserve device identity, API credentials, Bluetooth preference, and
   diagnostic logs;
7. release the lock even if one deletion step fails, with a retryable
   diagnostic state.

## Runtime separation

`CACHE_TTL_DAYS` is freshness metadata only. `CACHE_DELETE_ON_EXPIRE` was
removed because it was ambiguous and unused. Entitlement lives in atomic
`license_state.json`; the dedicated purge removes every media generation while
the maintenance wipe remains a separate SSH operation.

## Required verification before rollout

- cache continues offline on days 0–6;
- no new song starts once day 7 is reached;
- the in-progress song finishes, then cache and playlist metadata are purged;
- cache cannot be replayed after `LICENSE_EXPIRED_PURGED` without Internet;
- a refreshed generation renews the seven-day deadline;
- reboot or power loss during purge cannot revive playable old media;
- Bluetooth output loss and server failure cannot accidentally clear or bypass
  the license block;
- no API key, token, SSID, or media URL is logged by this policy.
