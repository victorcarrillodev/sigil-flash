#!/bin/bash
# Read-only CLI integration tests for radio-fetcher --validate-active.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
FETCHER="${ROOT}/scripts/radio-fetcher.sh"
PASS=0
FAIL=0
CASE_DIR=""
ORIGINAL_PATH="$PATH"

cleanup_case() {
    [ -z "$CASE_DIR" ] || rm -rf "$CASE_DIR"
    CASE_DIR=""
    PATH="$ORIGINAL_PATH"
}
trap cleanup_case EXIT

run_test() {
    local name="$1" fn="$2"
    if "$fn"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$name"
    fi
    cleanup_case
}

setup_valid_cache() {
    cleanup_case
    CASE_DIR=$(mktemp -d /tmp/sigil-validate-cli.XXXXXX)
    mkdir -p "$CASE_DIR/active/tracks" "$CASE_DIR/bin"
    printf 'alpha-data' > "$CASE_DIR/active/tracks/alpha.mp3"
    printf 'beta-data!' > "$CASE_DIR/active/tracks/beta.mp3"
    local alpha_hash beta_hash alpha_size beta_size total
    alpha_hash=$(sha256sum "$CASE_DIR/active/tracks/alpha.mp3" | awk '{print $1}')
    beta_hash=$(sha256sum "$CASE_DIR/active/tracks/beta.mp3" | awk '{print $1}')
    alpha_size=$(stat -c '%s' "$CASE_DIR/active/tracks/alpha.mp3")
    beta_size=$(stat -c '%s' "$CASE_DIR/active/tracks/beta.mp3")
    total=$((alpha_size + beta_size))
    python3 - "$CASE_DIR/active/playlist.json" "$alpha_hash" "$beta_hash" "$alpha_size" "$beta_size" <<'PYEOF'
import json
import sys
path, alpha_hash, beta_hash, alpha_size, beta_size = sys.argv[1:]
document = {"tracks": [
    {"id": "a", "filename": "alpha.mp3", "size_bytes": int(alpha_size), "sha256": alpha_hash},
    {"id": "b", "filename": "beta.mp3", "size_bytes": int(beta_size), "sha256": beta_hash},
]}
json.dump(document, open(path, "w", encoding="utf-8"), indent=2)
PYEOF
    printf '{"active_cache":{"tracks_count":2,"total_size_bytes":%s}}\n' "$total" > "$CASE_DIR/cache_meta.json"
    export SIGIL_CACHE_META_FILE="$CASE_DIR/cache_meta.json"
    export SIGIL_MUSIC_ACTIVE="$CASE_DIR/active"
}

run_validation() {
    bash "$FETCHER" --validate-active
}

cache_fingerprint() {
    (
        cd "$CASE_DIR" || exit 1
        find active cache_meta.json -printf '%P\t%y\t%m\t%s\t%T@\n' | sort
        find active cache_meta.json -type f -exec sha256sum {} + | sort
    )
}

test_validation_is_read_only_and_offline() {
    setup_valid_cache
    local before after
    before=$(cache_fingerprint) || return 1
    cat > "$CASE_DIR/bin/curl" <<'EOF'
#!/bin/bash
printf 'curl-called\n' >> "$VALIDATION_COMMAND_LOG"
exit 99
EOF
    cat > "$CASE_DIR/bin/mkdir" <<'EOF'
#!/bin/bash
printf 'mkdir-called\n' >> "$VALIDATION_COMMAND_LOG"
exit 98
EOF
    chmod +x "$CASE_DIR/bin/curl" "$CASE_DIR/bin/mkdir"
    export VALIDATION_COMMAND_LOG="$CASE_DIR/commands.log"
    PATH="$CASE_DIR/bin:$ORIGINAL_PATH"
    export PATH
    run_validation >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || return 1
    after=$(cache_fingerprint) || return 1
    [ "$before" = "$after" ] || return 1
    [ ! -e "$VALIDATION_COMMAND_LOG" ]
}

test_missing_directory_fails_without_creation() {
    setup_valid_cache
    rm -rf "$CASE_DIR/active"
    ! run_validation >/dev/null 2>"$CASE_DIR/stderr" || return 1
    [ ! -e "$CASE_DIR/active" ]
}

test_authoritative_total_mismatch_fails() {
    setup_valid_cache
    python3 - "$CASE_DIR/cache_meta.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["active_cache"]["total_size_bytes"] += 1
json.dump(data, open(path, "w", encoding="utf-8"))
PYEOF
    ! run_validation >/dev/null 2>"$CASE_DIR/stderr" || return 1
    grep -q 'total_size_bytes mismatch' "$CASE_DIR/stderr"
}

test_per_track_size_mismatch_fails() {
    setup_valid_cache
    python3 - "$CASE_DIR/active/playlist.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["tracks"][0]["size_bytes"] += 1
json.dump(data, open(path, "w", encoding="utf-8"))
PYEOF
    ! run_validation >/dev/null 2>"$CASE_DIR/stderr" || return 1
    grep -q 'size mismatch' "$CASE_DIR/stderr"
}

test_hash_mismatch_fails() {
    setup_valid_cache
    python3 - "$CASE_DIR/active/playlist.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["tracks"][1]["sha256"] = "0" * 64
json.dump(data, open(path, "w", encoding="utf-8"))
PYEOF
    ! run_validation >/dev/null 2>"$CASE_DIR/stderr" || return 1
    grep -q 'sha256 mismatch' "$CASE_DIR/stderr"
}

test_missing_integrity_metadata_is_explicit() {
    setup_valid_cache
    python3 - "$CASE_DIR/active/playlist.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["tracks"][0].pop("size_bytes")
data["tracks"][0].pop("sha256")
json.dump(data, open(path, "w", encoding="utf-8"))
PYEOF
    run_validation >/dev/null 2>"$CASE_DIR/stderr" || return 1
    grep -q '^LIMITATION:.*neither positive size_bytes nor sha256' "$CASE_DIR/stderr"
}

test_valid_cache_passes() {
    setup_valid_cache
    run_validation >/dev/null 2>"$CASE_DIR/stderr"
}

printf '%s\n' '=== radio-fetcher read-only validation CLI tests ==='
run_test '--validate-active performs no mutation or network/init command' test_validation_is_read_only_and_offline
run_test 'missing active directory fails without creation' test_missing_directory_fails_without_creation
run_test 'positive authoritative aggregate mismatch fails' test_authoritative_total_mismatch_fails
run_test 'per-track size mismatch fails' test_per_track_size_mismatch_fails
run_test 'SHA-256 mismatch fails' test_hash_mismatch_fails
run_test 'missing integrity metadata reports explicit limitation' test_missing_integrity_metadata_is_explicit
run_test 'complete valid cache passes' test_valid_cache_passes

printf '\nValidation CLI: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
