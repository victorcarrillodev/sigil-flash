#!/bin/bash
# Focused deterministic tests for the persistent seven-day entitlement state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/sigil-license-state.py"
PURGE="$ROOT/scripts/sigil-license-purge.sh"
TMP="$(mktemp -d /tmp/sigil-license-grace.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state/license_state.json"
MARKER="$TMP/run/license-blocked"
MUSIC="$TMP/music"
PLAYBACK="$TMP/state/playback_state.json"
META="$TMP/state/cache_meta.json"
MEDIA="$TMP/state/media_sync_state.json"
ACTIVE="$TMP/state/playlist.active.json"
STAGING="$TMP/state/playlist.staging.json"
REBOOT_STATE="$TMP/reboot/license_state.json"
REBOOT_MARKER="$TMP/reboot/license-blocked"

run_state() {
  SIGIL_LICENSE_STATE_FILE="$STATE" SIGIL_LICENSE_BLOCK_MARKER="$MARKER" \
    SIGIL_LICENSE_TEST_MODE=1 SIGIL_LICENSE_TEST_GRACE_SECONDS=5 \
    python3 "$HELPER" "$@"
}

run_reboot_state() {
  local boot_id="$1" uptime="$2"
  shift 2
  SIGIL_LICENSE_STATE_FILE="$REBOOT_STATE" SIGIL_LICENSE_BLOCK_MARKER="$REBOOT_MARKER" \
    SIGIL_LICENSE_TEST_MODE=1 SIGIL_LICENSE_TEST_GRACE_SECONDS=500 \
    SIGIL_LICENSE_TEST_BOOT_ID="$boot_id" SIGIL_LICENSE_TEST_UPTIME_SECONDS="$uptime" \
    python3 "$HELPER" "$@"
}

assert_json() {
  local expression="$1"
  python3 - "$STATE" "$expression" <<'PYEOF'
import json, sys
document = json.load(open(sys.argv[1], encoding='utf-8'))
raise SystemExit(0 if eval(sys.argv[2], {}, {'d': document}) else 1)
PYEOF
}

run_state init >/dev/null
if run_state gate >/dev/null 2>&1; then
  echo "FAIL: first install must be blocked before authenticated validation" >&2; exit 1
fi
run_state authorize --event-id first-auth >/dev/null
run_state gate >/dev/null
assert_json "d['phase'] == 'LICENSE_AUTHORIZED' and d['offline_accumulated_seconds'] == 0"

# The only state transition to expiry is monotonic runtime, never wall clock.
python3 - "$STATE" <<'PYEOF'
import json, pathlib
path = pathlib.Path(__import__('sys').argv[1])
d = json.loads(path.read_text())
uptime = int(float(pathlib.Path('/proc/uptime').read_text().split()[0]))
d['last_monotonic_checkpoint'] = max(0, uptime - 5)
path.write_text(json.dumps(d))
PYEOF
run_state tick --force >/dev/null || test $? -eq 2
assert_json "d['phase'] == 'LICENSE_EXPIRY_PENDING_TRACK_END' and d['expiry_pending'] is True"
if run_state gate >/dev/null 2>&1; then
  echo "FAIL: pending expiry may not start another track" >&2; exit 1
fi

# A successful playlist response that arrived after the boundary is observed
# must be consumed, but it cannot unlock media which is now pending purge.
CURRENT_BOOT=$(cat /proc/sys/kernel/random/boot_id)
cat > "$MEDIA" <<EOF
{"_schema_version":"1.0","phase":"STREAM_WARMUP","authorization_event":{"operation_id":"pre-purge-proof","boot_id":"$CURRENT_BOOT","result":"AUTHENTICATED_PLAYLIST_OK","protocol_code":null,"http_status":200}}
EOF
source "$ROOT/scripts/audio-manager.sh"
LOG="$TMP/audio-manager.log"
LICENSE_STATE_FILE="$STATE"
MEDIA_SYNC_FILE="$MEDIA"
LICENSE_HELPER="$HELPER"
export SIGIL_LICENSE_BLOCK_MARKER="$MARKER"
license_initialize >/dev/null
consume_authorization_event
assert_json "d['phase'] == 'LICENSE_EXPIRY_PENDING_TRACK_END' and d['last_authorization_event_id'] == 'pre-purge-proof'"

# The dedicated purge removes every generation and stale manifest, but only
# after the player is known idle.
mkdir -p "$MUSIC/active/tracks" "$MUSIC/staging/tracks" "$MUSIC/archive/g/tracks" "$TMP/state"
printf a > "$MUSIC/active/tracks/a.mp3"
printf b > "$MUSIC/staging/tracks/b.partial"
printf c > "$MUSIC/archive/g/tracks/c.mp3"
printf '{}' > "$ACTIVE"
printf '{}' > "$STAGING"
run_state request-purge >/dev/null

# An owned live decoder is the natural-boundary guard: the purge must wait and
# leave all licensed media untouched until it has actually exited.
sleep 30 &
DECODER_PID=$!
DECODER_TICKS=$(awk '{print $22}' "/proc/${DECODER_PID}/stat")
printf '{"playing":true,"process":{"pid":%s,"start_ticks":%s}}\n' \
  "$DECODER_PID" "$DECODER_TICKS" > "$PLAYBACK"
if SIGIL_STATE_DIR="$TMP/state" SIGIL_MUSIC_ROOT="$MUSIC" \
  SIGIL_CACHE_OP_LOCK="$TMP/run/cache-operation.lock" SIGIL_LICENSE_STATE_FILE="$STATE" \
  SIGIL_PLAYBACK_STATE_FILE="$PLAYBACK" SIGIL_CACHE_META_FILE="$META" \
  SIGIL_MEDIA_SYNC_FILE="$MEDIA" SIGIL_PLAYLIST_ACTIVE_FILE="$ACTIVE" \
  SIGIL_PLAYLIST_STAGING_FILE="$STAGING" bash "$PURGE" >/dev/null 2>&1; then
  echo "FAIL: purge ran while its owned decoder was live" >&2; exit 1
fi
test -e "$MUSIC/active/tracks/a.mp3"
kill "$DECODER_PID" 2>/dev/null || true
wait "$DECODER_PID" 2>/dev/null || true
printf '{}' > "$PLAYBACK"
SIGIL_STATE_DIR="$TMP/state" SIGIL_MUSIC_ROOT="$MUSIC" \
SIGIL_CACHE_OP_LOCK="$TMP/run/cache-operation.lock" SIGIL_LICENSE_STATE_FILE="$STATE" \
SIGIL_PLAYBACK_STATE_FILE="$PLAYBACK" SIGIL_CACHE_META_FILE="$META" \
SIGIL_MEDIA_SYNC_FILE="$MEDIA" SIGIL_PLAYLIST_ACTIVE_FILE="$ACTIVE" \
SIGIL_PLAYLIST_STAGING_FILE="$STAGING" bash "$PURGE"
run_state purge-complete >/dev/null
test ! -e "$MUSIC/active/tracks/a.mp3"
test ! -e "$MUSIC/staging/tracks/b.partial"
test ! -e "$MUSIC/archive/g/tracks/c.mp3"
test ! -e "$ACTIVE" && test ! -e "$STAGING"
assert_json "d['phase'] == 'LICENSE_EXPIRED_PURGED' and d['purged'] is True"
# Recovery may retry the dedicated transaction after state has reached its
# terminal result; that must be harmless and successful.
SIGIL_STATE_DIR="$TMP/state" SIGIL_MUSIC_ROOT="$MUSIC" \
SIGIL_CACHE_OP_LOCK="$TMP/run/cache-operation.lock" SIGIL_LICENSE_STATE_FILE="$STATE" \
SIGIL_PLAYBACK_STATE_FILE="$PLAYBACK" SIGIL_CACHE_META_FILE="$META" \
SIGIL_MEDIA_SYNC_FILE="$MEDIA" SIGIL_PLAYLIST_ACTIVE_FILE="$ACTIVE" \
SIGIL_PLAYLIST_STAGING_FILE="$STAGING" bash "$PURGE"
if run_state gate >/dev/null 2>&1; then
  echo "FAIL: terminal purge must survive generic recovery" >&2; exit 1
fi

# A post-purge proof is the only unlock path; an old event id or cache cannot
# be replayed by the purge operation itself.
cat > "$MEDIA" <<EOF
{"_schema_version":"1.0","phase":"LICENSE_PURGED","authorization_event":{"operation_id":"post-purge-auth","boot_id":"$CURRENT_BOOT","result":"AUTHENTICATED_PLAYLIST_OK","protocol_code":null,"http_status":200}}
EOF
license_initialize >/dev/null
consume_authorization_event
run_state gate >/dev/null
assert_json "d['phase'] == 'LICENSE_AUTHORIZED' and d['purged'] is False and d['last_authorization_event_id'] == 'post-purge-auth'"

# DNS/transport recovery never becomes authorization, and stale or malformed
# success-shaped events are consumed once rather than creating a 10-second
# log/retry storm after a reboot.
license_initialize >/dev/null
cat > "$MEDIA" <<EOF
{"_schema_version":"1.0","phase":"WAITING_NETWORK","authorization_event":{"operation_id":"dns-only","boot_id":"$CURRENT_BOOT","result":"TRANSIENT_FAILURE","protocol_code":"DNS_FAILURE","http_status":0}}
EOF
consume_authorization_event
assert_json "d['phase'] == 'LICENSE_GRACE_OFFLINE' and d['last_authorization_event_id'] == 'dns-only' and d['last_authorization_result'] == 'DNS_FAILURE'"
cat > "$MEDIA" <<'EOF'
{"_schema_version":"1.0","phase":"WAITING_NETWORK","authorization_event":{"operation_id":"stale-success","boot_id":"not-this-boot","result":"AUTHENTICATED_PLAYLIST_OK","protocol_code":null,"http_status":200}}
EOF
consume_authorization_event
assert_json "d['phase'] == 'LICENSE_GRACE_OFFLINE' and d['last_authorization_event_id'] == 'stale-success'"

# The persisted monotonic checkpoints, boot ID and conservative unclean-boot
# debit ensure that service restarts, power loss and wall-clock edits cannot
# give an offline device free grace time.
run_reboot_state boot-a 100 init >/dev/null
run_reboot_state boot-a 100 authorize --event-id reboot-auth >/dev/null
run_reboot_state boot-a 130 tick --force >/dev/null
python3 - "$REBOOT_STATE" <<'PYEOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document['updated_at'] = '2099-01-01T00:00:00Z'  # wall clock is diagnostic only
path.write_text(json.dumps(document))
PYEOF
run_reboot_state boot-b 0 tick --force >/dev/null
python3 - "$REBOOT_STATE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['offline_accumulated_seconds'] >= 90, d
assert d['phase'] == 'LICENSE_AUTHORIZED', d
PYEOF
run_reboot_state boot-b 50 tick --force >/dev/null
run_reboot_state boot-c 0 tick --force >/dev/null
python3 - "$REBOOT_STATE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
# 30 seconds on boot-a, two conservative 60-second unclean boot reserves,
# and 50 seconds on boot-b survive a wall-clock rollback.
assert d['offline_accumulated_seconds'] >= 200, d
PYEOF

# A raw 404/409 must never be treated as revocation. Only the server's
# documented protocol codes may create an immediate authorization denial.
source "$ROOT/scripts/radio-fetcher.sh"
LOG="$TMP/radio-fetcher.log"
is_authoritative_license_denial DEVICE_NOT_AUTHORIZED
is_authoritative_license_denial PLAYLIST_UNAVAILABLE
! is_authoritative_license_denial ""
! is_authoritative_license_denial "GENERIC_HTTP_404"
! is_authoritative_license_denial "GENERIC_HTTP_409"

# A long download may finish after the manager has crossed the license
# boundary.  The final move is serialized with the cache lock and must fail
# closed rather than leave a validated-looking staging file behind.
COMMIT_TRACK="$TMP/music/staging/tracks/late.mp3"
mkdir -p "$(dirname "$COMMIT_TRACK")"
CACHE_OP_LOCK="$TMP/run/cache-operation.lock"
http_get_to_file() { printf 'late-media' > "$3"; return 0; }
license_allows_media() { return 1; }
LATE_HASH=$(printf 'late-media' | sha256sum | awk '{print $1}')
if download_track '/media/late.mp3' "$COMMIT_TRACK" "$LATE_HASH" 10 >/dev/null 2>&1; then
  echo "FAIL: expired license committed a downloaded track" >&2; exit 1
fi
test ! -e "$COMMIT_TRACK" && test ! -e "${COMMIT_TRACK}.partial"
license_allows_media() { return 0; }

# Every track, not only track zero, is part of the authorization proof.
GOOD_TRACK_HASH=$(printf 'x' | sha256sum | awk '{print $1}')
validate_remote_playlist "{\"ok\":true,\"_schema_version\":\"1.0\",\"source\":\"server\",\"playlist_id\":\"p\",\"version_hash\":\"v\",\"stop_playback\":false,\"tracks\":[{\"url\":\"/media/a.mp3\",\"filename\":\"a.mp3\",\"sha256\":\"$GOOD_TRACK_HASH\",\"size_bytes\":1},{\"url\":\"/media/b.mp3\",\"filename\":\"b.mp3\",\"sha256\":\"bad\",\"size_bytes\":1}]}" && {
  echo "FAIL: malformed later playlist track was accepted" >&2; exit 1;
}

# Existing field units do not rerun firstboot. The cache owner therefore
# atomically removes only the obsolete clock/config fields on its first cycle.
LEGACY_META="$TMP/state/legacy-cache-meta.json"
cat > "$LEGACY_META" <<'EOF'
{"cache_policy":{"max_ttl_days":7,"auto_renew":true,"delete_on_expire":false},"runtime":{"runtime_seconds":123}}
EOF
CACHE_META_FILE="$LEGACY_META"
DRY_RUN=false
ensure_cache_meta
python3 - "$LEGACY_META" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert 'runtime' not in d, d
assert 'delete_on_expire' not in d['cache_policy'], d
PYEOF

# Regression guards for natural-boundary and process ownership contracts.
rg -q 'wait_for_license_gate' "$ROOT/scripts/audio-player.sh"
rg -q 'LICENSE_EXPIRY_PENDING_TRACK_END' "$ROOT/scripts/audio-manager.sh"
rg -q 'AUTH_IGNORED_DURING_PURGE' "$ROOT/scripts/audio-manager.sh"
! rg -q '\bpkill\b' "$ROOT/scripts/sigil-license-purge.sh"
! rg -q '\bpkill\b' "$ROOT/scripts/sigil-cache-wipe.sh"
rg -q -- '--event-id "\$event_id"' "$ROOT/scripts/audio-manager.sh"
rg -q 'gate.*read-only\|intentionally read-only' "$ROOT/scripts/sigil-license-state.py"
rg -q 'Cache operation lock busy while committing download' "$ROOT/scripts/radio-fetcher.sh"
rg -q 'PLAYLIST_NOT_ASSIGNED' "$ROOT/scripts/radio-fetcher.sh"
rg -q 'DEVICE_NOT_REGISTERED' "$ROOT/scripts/radio-fetcher.sh"

echo "PASS: license grace state, boundary gate and purge policy"
