#!/bin/bash
# Production regression tests for root-invoked cache metadata replacement.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WIPE="${ROOT}/scripts/sigil-cache-wipe.sh"
TMP_DIR=$(mktemp -d /tmp/sigil-cache-wipe-metadata.XXXXXX)
ORIGINAL_PATH="$PATH"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert() {
    local description="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$description"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$description"
    fi
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/music/active/tracks" \
    "$TMP_DIR/music/staging/tracks" "$TMP_DIR/music/archive" "$TMP_DIR/run"
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$TMP_DIR/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$TMP_DIR/bin/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/pgrep" "$TMP_DIR/bin/pkill"

CACHE_META="$TMP_DIR/cache_meta.json"
cat > "$CACHE_META" <<'EOF'
{
  "_schema_version": "1.0",
  "active_cache": {"tracks_count": 2, "playlist_id": "old"},
  "staging_cache": {"tracks_downloaded": 1},
  "statistics": {"sentinel": 77},
  "runtime": {"runtime_seconds": 123}
}
EOF
chmod 0640 "$CACHE_META"

if [ "$(id -u)" -eq 0 ]; then
    if ! getent passwd sigil >/dev/null || ! getent group sigil >/dev/null; then
        printf '  FAIL root execution requires the canonical sigil account\n'
        exit 1
    fi
    chown sigil:sigil "$CACHE_META"
fi

EXPECTED_UID=$(stat -c '%u' "$CACHE_META")
EXPECTED_GID=$(stat -c '%g' "$CACHE_META")
EXPECTED_MODE=$(stat -c '%a' "$CACHE_META")
printf 'active\n' > "$TMP_DIR/music/active/tracks/one.mp3"
printf 'staging\n' > "$TMP_DIR/music/staging/tracks/two.mp3"
printf 'archive\n' > "$TMP_DIR/music/archive/keep.mp3"

PATH="$TMP_DIR/bin:$ORIGINAL_PATH" \
SIGIL_MUSIC_DIR="$TMP_DIR/music" \
SIGIL_CACHE_META_FILE="$CACHE_META" \
SIGIL_CACHE_OP_LOCK="$TMP_DIR/run/cache-operation.lock" \
    bash "$WIPE" >"$TMP_DIR/wipe.stdout" 2>"$TMP_DIR/wipe.stderr"
WIPE_RC=$?

assert "production cache wipe exits successfully" test "$WIPE_RC" -eq 0
assert "cache metadata owner is preserved" test "$(stat -c '%u' "$CACHE_META")" -eq "$EXPECTED_UID"
assert "cache metadata group is preserved" test "$(stat -c '%g' "$CACHE_META")" -eq "$EXPECTED_GID"
assert "cache metadata mode is preserved" test "$(stat -c '%a' "$CACHE_META")" = "$EXPECTED_MODE"
assert "cache metadata does not regress to 0600" test "$(stat -c '%a' "$CACHE_META")" != "600"
assert "active tracks are wiped" test -z "$(find "$TMP_DIR/music/active/tracks" -type f -print -quit)"
assert "staging tracks are wiped" test -z "$(find "$TMP_DIR/music/staging/tracks" -type f -print -quit)"
assert "archive is preserved" test -f "$TMP_DIR/music/archive/keep.mp3"
assert "temporary metadata files are removed" test -z "$(find "$TMP_DIR" -maxdepth 1 -name '*.tmp' -print -quit)"
assert "metadata content is reset and unrelated state preserved" \
    python3 - "$CACHE_META" <<'PYEOF'
import json
import sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
valid = (
    document["active_cache"]["tracks_count"] == 0
    and document["staging_cache"]["tracks_downloaded"] == 0
    and document["statistics"]["sentinel"] == 77
    and document["runtime"]["runtime_seconds"] == 123
)
raise SystemExit(0 if valid else 1)
PYEOF

printf '\nCache wipe metadata: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
