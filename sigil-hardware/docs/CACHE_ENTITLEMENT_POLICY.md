# SIGIL cache entitlement and remote-lock policy

## Status

**Product policy approved; implementation pending.**

This document records the intended policy so that future implementation work,
tests, and Graphify queries distinguish it from the currently deployed cache
behaviour.  It does not itself change playback behaviour.

## Purpose

SIGIL may play authenticated media from a validated local cache while the
device is offline, but cached content must not remain usable indefinitely.
The cache is a time-bounded entitlement, not permanent media storage.

## Authoritative policy

1. A fully validated cache generation is usable for **seven calendar days**
   after its last successful authenticated server validation.
2. During those seven days, loss of Internet, DNS failure, a router restart,
   or SIGIL-server unavailability must not interrupt cache playback.
3. A successful authenticated refresh promotes a new validated generation and
   restarts the seven-day period.
4. When day seven is reached, SIGIL must not start another track.  If a track
   is already playing, it is allowed to finish naturally.
5. Immediately after that track boundary (or immediately if no track is
   playing), SIGIL enters `LICENSE_EXPIRED`, stops playback, and removes all
   locally cached media.  It must not keep playing an expired generation
   merely because the device is offline.
6. After the purge, SIGIL must not fall back to old local files or streaming.
   Playback can resume only after it contacts the authenticated SIGIL server
   and obtains a new fully validated playlist generation.
7. An authenticated remote device lock has priority over normal expiry.  When
   the server returns an explicit lock state, SIGIL must stop playback,
   persist `DEVICE_LOCKED`, and purge cached media immediately.  Only an
   explicit authenticated active/unlock response may clear that state.

## Required server contract

The existing playlist contract supports intentional silence through:

```json
{ "stop_playback": true, "tracks": [] }
```

That contract is not a device lock: it does not express entitlement revocation
and it must not be overloaded for it.  The server contract requires an
explicit, authenticated state such as:

```json
{
  "device_status": "locked",
  "lock_reason": "subscription_disabled"
}
```

The precise response shape and compatible server rollout must be agreed before
client implementation.  No sensitive reason, token, or playlist content may
be exposed through normal panel logs.

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
LICENSE_EXPIRED
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
3. publish terminal `LICENSE_EXPIRED` state before deleting media;
4. remove active media, staging media, partial downloads, archived media, and
   active/staging playlist metadata;
5. persist the terminal reason (`LICENSE_EXPIRED` or `DEVICE_LOCKED`)
   atomically;
6. preserve device identity, API credentials, Bluetooth preference, and
   diagnostic logs;
7. release the lock even if one deletion step fails, with a retryable
   diagnostic state.

A remote `DEVICE_LOCKED` command must stop immediately rather than wait for a
track boundary.

## Current implementation gap (commit 5284c71)

Current `CACHE_TTL_DAYS=7` and the runtime counter mark cache state as
`EXPIRED`, but `audio-manager.sh` still permits local playback and retains the
generation until replacement.  `CACHE_DELETE_ON_EXPIRE=true` in `audio.conf`
is not currently consumed by the runtime scripts.

The SSH maintenance cache wipe is also not suitable for this policy: it
preserves archived media and uses a broad `pkill -9 mpg123` fallback.  Expiry
and remote locking need their own narrowly-scoped purge operation.

## Required verification before rollout

- cache continues offline on days 0–6;
- no new song starts once day 7 is reached;
- the in-progress song finishes, then cache and playlist metadata are purged;
- cache cannot be replayed after `LICENSE_EXPIRED` without Internet;
- a refreshed generation renews the seven-day deadline;
- remote lock purges immediately, including archive and partial files;
- reboot or power loss during purge cannot revive playable old media;
- a locked device cannot be reactivated by stale state files;
- Bluetooth output loss and server failure cannot accidentally clear or bypass
  a lock;
- no API key, token, SSID, or media URL is logged by this policy.
