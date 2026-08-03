# SIGIL offline license grace policy

SIGIL may play licensed media for at most **604800 accumulated runtime seconds**
without a new successful authenticated playlist validation.

## Authorization proof

Only a fresh `GET /api/devices/{device_id}/playlist` response resets the
counter, after SIGIL has validated all of:

- HTTP `200`;
- `ok: true`;
- `_schema_version: "1.0"`;
- `source: "server"`;
- valid playlist or the explicit `stop_playback: true, tracks: []` contract.

Health checks, DNS, Internet access, media responses, cached responses and
registration responses never reset entitlement.  A documented non-retryable
playlist protocol code (`UNAUTHORIZED`, `FORBIDDEN`,
`DEVICE_NOT_AUTHORIZED`, `DEVICE_NOT_REGISTERED`,
`PLAYLIST_NOT_ASSIGNED`, `PLAYLIST_UNAVAILABLE`) enters a denial boundary;
unknown 404/409 responses remain transient and consume grace.

## Persistent state and ownership

`audio-manager` is the only normal writer of
`/var/lib/sigil/license_state.json`.  It uses uptime plus `boot_id`, commits
every 60 seconds and on transitions, and records a conservative 60-second
debit after an unclean reboot.  Wall clock is diagnostic only.

`radio-fetcher` owns playlist/cache generations and publishes only a sanitized
authorization event.  `audio-player` owns decoder PID/start ticks/lease and
checks the read-only gate immediately before every decoder.  The panel only
reads state.

The retired `radio-stream` runtime is excluded from production payloads and
the installer removes it on update.  It cannot be used as a rollback route
because it predates this authorization gate and generation validation.

## Expiration and recovery

At the limit SIGIL publishes `LICENSE_EXPIRY_PENDING_TRACK_END`: the existing
decoder finishes naturally, but no new cache, archive or stream track starts.
Once the player is idle, the dedicated purge removes active, staging, archive,
partials and playlist manifests under `cache-operation.lock`.  An interrupted
purge remains fail-closed and resumes at boot; even a recorded terminal state
rechecks and removes any stale media left by a failed filesystem operation.

The resulting `LICENSE_EXPIRED_PURGED` state survives SSH logout, reboot and
generic connectivity recovery.  A fresh post-purge authenticated playlist
validation clears it, then the existing hybrid warm-up streams immediately
while rebuilding verified local cache.  `stop_playback` remains an authorized
administrative silence and does not purge media.

## Test-only limit

Production ignores configuration overrides and always uses 604800 seconds.
Short limits are accepted only when `SIGIL_LICENSE_TEST_MODE=1` is supplied to
a dedicated test image/run; that variable and its accompanying configuration
must never be included in a manufacturing payload.

## Raspberry Pi Zero 2 W rollout checklist

Run this only on a disposable validation image, never by changing the
production grace value:

1. Authorize online, start cache playback, and record the license JSON.
2. Use the explicit test-only limit, disconnect authenticated server access,
   and confirm playback continues before its limit.
3. Cross the limit while a track is playing: confirm that track finishes and
   no next stream, active, staging, or archive track starts.
4. Confirm `LICENSE_EXPIRED_PURGED`, empty generation roots, absent playlist
   manifests, and a panel that remains reachable.
5. Reboot offline; restore only DNS/general Internet; and perform SSH
   login/logout. Each must remain silent and blocked.
6. Restore an authenticated playlist response. Confirm the counter resets,
   streaming begins only if no valid cache exists, and background files are
   size/SHA-256 validated before the next natural cache transition.
7. Repeat the expiry/purge test with power removed during pending expiry and
   during purge; on boot it must remain blocked until purge recovery completes.
8. Observe CPU, RAM, journal growth, free space, decoder count, Wi-Fi packet
   loss, and Bluetooth audio continuity during the tests. There must be one
   player, one fetcher, no retry loop faster than 30 seconds while blocked,
   and no repeated Wi-Fi scanning caused by license recovery.
