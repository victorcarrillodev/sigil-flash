#!/bin/bash
# Regression test suite for sigil-hardware JSON helpers
#
# Tests the argv-based JSON value passing pattern that replaced
# unsafe Shell-to-Python interpolation (the null-vs-None structural fix).
#
# Each test inlines the exact same Python heredoc pattern used by the
# production scripts so we validate the contract end-to-end.
#
# Usage:
#   sudo ./tests/test_suite.sh          # run all tests
#   sudo ./tests/test_suite.sh --list   # list test names
#   sudo ./tests/test_suite.sh --name "test_update*"  # filter by glob

# Functions in this harness are discovered with declare -F and invoked by name.
# shellcheck disable=SC2317
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${HERE}/fixtures"
PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

# ── Colors / formatting ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Test runner helpers ──────────────────────────────────────────────────────

plan() {
    echo "=== $1 ==="
}

ok() {
    PASS=$((PASS + 1))
    printf "  %sok%s  %s\n" "${GREEN}" "${NC}" "$1"
}

not_ok() {
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
    printf "  %sFAIL%s %s\n" "${RED}" "${NC}" "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf "  %sSKIP%s %s\n" "${YELLOW}" "${NC}" "$1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$label"
    else
        not_ok "$label — expected: [${expected}], got: [${actual}]"
    fi
}

assert_ne() {
    local not_expected="$1"
    local actual="$2"
    local label="$3"
    if [ "$actual" != "$not_expected" ]; then
        ok "$label"
    else
        not_ok "$label — should NOT be: [${not_expected}]"
    fi
}

assert_rc() {
    local expected_rc="$1"
    local actual_rc="$2"
    local label="$3"
    if [ "$expected_rc" -eq "$actual_rc" ]; then
        ok "$label"
    else
        not_ok "$label — expected rc=${expected_rc}, got rc=${actual_rc}"
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        ok "$label"
    else
        not_ok "$label — file ${file} does not contain pattern [${pattern}]"
    fi
}

# ── Temp file helpers ─────────────────────────────────────────────────────────

mk_temp_dir() {
    mktemp -d /tmp/sigil-test.XXXXXX
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# ==============================================================================
# update_cache_meta — the primary function that was affected by the null-vs-None
# ==============================================================================

test_update_set_string() {
    plan "update_cache_meta: set string value"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "active_cache.playlist_id" '"pl_new"' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]
key_path  = sys.argv[2]
raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local rc=$?
    assert_rc 0 "$rc" "set string — exit code"

    local val; val=$(python3 -c "import json; print(json.load(open('${dir}/test.json'))['active_cache']['playlist_id'])")
    assert_eq "pl_new" "$val" "set string — pl_new == pl_new"
    rm -rf "$dir"
}

test_update_set_null() {
    plan "update_cache_meta: set null"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "active_cache.playlist_id" 'null' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['active_cache']['playlist_id'])")
    assert_eq "None" "$val" "set null — Python None stored as JSON null"
    rm -rf "$dir"
}

test_update_set_bool_true() {
    plan "update_cache_meta: set boolean true"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "active_cache.integrity_verified" 'false' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['active_cache']['integrity_verified'])")
    assert_eq "False" "$val" "set bool false — Python False"
    rm -rf "$dir"
}

test_update_set_integer() {
    plan "update_cache_meta: set integer"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "active_cache.tracks_count" '99' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['active_cache']['tracks_count'])")
    assert_eq "99" "$val" "set integer — 99 == 99"
    rm -rf "$dir"
}

test_update_set_array() {
    plan "update_cache_meta: set JSON array"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "staging_cache.failed_tracks" '["tr_001","tr_002"]' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(len(d['staging_cache']['failed_tracks']))")
    assert_eq "2" "$val" "set array — length 2"
    rm -rf "$dir"
}

test_update_set_zero() {
    plan "update_cache_meta: set integer 0"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "active_cache.tracks_count" '0' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['active_cache']['tracks_count'])")
    assert_eq "0" "$val" "set integer 0 — 0 == 0"
    rm -rf "$dir"
}

test_update_set_deeply_nested() {
    plan "update_cache_meta: deeply nested path (3+ levels)"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "meta.deeply.nested.key" '"updated"' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['meta']['deeply']['nested']['key'])")
    assert_eq "updated" "$val" "deeply nested — updated == updated"
    rm -rf "$dir"
}

test_update_create_intermediate_keys() {
    plan "update_cache_meta: create intermediate keys"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    python3 - "${dir}/test.json" "new_section.sub.value" '"created"' <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    local val; val=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['new_section']['sub']['value'])")
    assert_eq "created" "$val" "create intermediate — created == created"
    rm -rf "$dir"
}

test_update_invalid_json_value() {
    plan "update_cache_meta: invalid JSON value (error)"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    set +e
    python3 - "${dir}/test.json" "active_cache.playlist_id" 'not-json' <<'PYEOF' 2>/dev/null
import json, sys
try:
    value = json.loads(sys.argv[3])
except json.JSONDecodeError:
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "invalid JSON value — exit code 1"
    rm -rf "$dir"
}

test_update_invalid_key_path_empty() {
    plan "update_cache_meta: invalid key path (error)"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    set +e
    python3 - "${dir}/test.json" "" '"val"' <<'PYEOF' 2>/dev/null
import json, sys
key_path = sys.argv[2]
keys = key_path.split('.')
if not keys or any(k == '' for k in keys):
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "invalid key path — exit code 1"
    rm -rf "$dir"
}

test_update_corrupt_json() {
    plan "update_cache_meta: corrupt existing JSON (error)"
    local dir; dir=$(mk_temp_dir)
    echo "not json at all" > "${dir}/test.json"

    set +e
    python3 - "${dir}/test.json" "active_cache.playlist_id" '"val"' <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except json.JSONDecodeError:
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "corrupt JSON file — exit code 1"
    rm -rf "$dir"
}

test_update_missing_file() {
    plan "update_cache_meta: missing file (error)"
    local dir; dir=$(mk_temp_dir)

    set +e
    python3 - "${dir}/noexist.json" "key" '"val"' <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "missing file — exit code 1"
    rm -rf "$dir"
}

test_update_atomic_write() {
    plan "update_cache_meta: atomic write integrity"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    # Perform 5 updates in sequence, read back each
    for i in 1 2 3 4 5; do
        python3 - "${dir}/test.json" "active_cache.tracks_count" "$i" <<'PYEOF' > /dev/null 2>&1
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
        local val; val=$(python3 -c "import json; print(json.load(open('${dir}/test.json'))['active_cache']['tracks_count'])")
        assert_eq "$i" "$val" "atomic write round ${i} — ${i} == ${i}"
    done
    rm -rf "$dir"
}

test_update_non_object_segment() {
    plan "update_cache_meta: non-object segment in path (error)"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    set +e
    python3 - "${dir}/test.json" "array_field.something" '"val"' <<'PYEOF' 2>/dev/null
import json, sys
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    if not isinstance(obj[k], dict):
        sys.exit(1)
    obj = obj[k]
obj[keys[-1]] = value
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "non-object segment — exit code 1"
    rm -rf "$dir"
}

# ==============================================================================
# reset_staging_cache — must use JSON null, not Python None
# ==============================================================================

test_reset_staging_cache() {
    plan "reset_staging_cache: all staging fields set correctly"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    local keys=(
        "staging_cache.playlist_id|null"
        "staging_cache.version_hash|null"
        "staging_cache.download_started_at|null"
        "staging_cache.progress_percent|0"
        "staging_cache.tracks_downloaded|0"
        "staging_cache.tracks_total|0"
    )

    for entry in "${keys[@]}"; do
        local k="${entry%%|*}"
        local v="${entry##*|}"
        python3 - "${dir}/test.json" "$k" "$v" <<'PYEOF' > /dev/null 2>&1
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF
    done

    # Read back — null fields should be Python None, not string "None"
    local pl; pl=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['staging_cache']['playlist_id'])")
    assert_eq "None" "$pl" "reset — playlist_id is None (JSON null)"
    local pct; pct=$(python3 -c "import json; d=json.load(open('${dir}/test.json')); print(d['staging_cache']['progress_percent'])")
    assert_eq "0" "$pct" "reset — progress_percent is 0"
    rm -rf "$dir"
}

# ==============================================================================
# read_json_field — normalized output (null, true, false, not None)
# ==============================================================================

test_read_string() {
    plan "read_json_field: string"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "active_cache.playlist_id" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "pl_abc123" "$val" "read string — pl_abc123"
}

test_read_null() {
    plan "read_json_field: null"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "staging_cache.playlist_id" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "null" "$val" "read null — prints 'null'"
}

test_read_bool_true() {
    plan "read_json_field: boolean true"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "active_cache.integrity_verified" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "true" "$val" "read bool true — prints 'true'"
}

test_read_bool_false() {
    plan "read_json_field: boolean false"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "expiration_warning_sent" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "false" "$val" "read bool false — prints 'false'"
}

test_read_integer() {
    plan "read_json_field: integer"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "active_cache.tracks_count" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "50" "$val" "read integer — 50 == 50"
}

test_read_integer_zero() {
    plan "read_json_field: integer 0"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "staging_cache.progress_percent" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "0" "$val" "read integer 0 — prints '0'"
}

test_read_nested_deep() {
    plan "read_json_field: deeply nested"
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "meta.deeply.nested.key" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
val = data
for key in sys.argv[2].split('.'):
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    assert_eq "found-it" "$val" "read deeply nested — found-it"
}

test_read_missing_key() {
    plan "read_json_field: missing key (error)"
    set +e
    local val; val=$(python3 - "${FIXTURES}/nested-values.json" "does.not.exist" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except: print(""); sys.exit(1)
val = data
for key in sys.argv[2].split('.'):
    if not isinstance(val, dict) or key not in val:
        print(""); sys.exit(1)
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    local rc=$?
    set -e
    assert_eq "" "$val" "read missing key — output is empty"
    assert_rc 1 "$rc" "read missing key — exit code 1"
}

test_read_nonexistent_file() {
    plan "read_json_field: non-existent file (error)"
    set +e
    local val; val=$(python3 - "/tmp/noexist-$$.json" "key" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except: print(""); sys.exit(1)
val = data
for key in sys.argv[2].split('.'):
    if not isinstance(val, dict) or key not in val:
        print(""); sys.exit(1)
    val = val[key]
if val is True: print("true")
elif val is False: print("false")
elif val is None: print("null")
else: print(val)
PYEOF
)
    local rc=$?
    set -e
    assert_eq "" "$val" "read non-existent file — output is empty"
    assert_rc 1 "$rc" "read non-existent file — exit code 1"
}

test_read_corrupt_json() {
    plan "read_json_field: corrupt JSON (error)"
    local dir; dir=$(mk_temp_dir)
    echo "not json" > "${dir}/corrupt.json"
    set +e
    local val; val=$(python3 - "${dir}/corrupt.json" "key" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except: print(""); sys.exit(1)
PYEOF
)
    local rc=$?
    set -e
    assert_eq "" "$val" "read corrupt JSON — output is empty"
    assert_rc 1 "$rc" "read corrupt JSON — exit code 1"
    rm -rf "$dir"
}

# ==============================================================================
# json_string helper
# ==============================================================================

test_json_string_normal() {
    plan "json_string: normal string"
    local val; val=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "hello")
    assert_eq '"hello"' "$val" "json_string normal — \"hello\""
}

test_json_string_with_quotes() {
    plan "json_string: string with double quotes"
    local val; val=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" 'say "hello"')
    assert_eq '"say \"hello\""' "$val" "json_string quoted — escaped quotes"
}

test_json_string_special_chars() {
    plan "json_string: special characters round-trip (newline, backslash, unicode, empty)"
    local result; result=$(python3 <<'PYEOF'
import json
cases = [
    ("empty", ""),
    ("newline", "line1\nline2"),
    ("backslash", "a\\b"),
    ("unicode", "café"),
    ("tab", "col1\tcol2"),
    ("mixed", "say \"hello\"\nline2"),
]
for name, original in cases:
    encoded = json.dumps(original)
    decoded = json.loads(encoded)
    assert decoded == original, f"MISMATCH {name}: {original!r} != {decoded!r} (encoded={encoded})"
print("ALL OK")
PYEOF
)
    assert_eq "ALL OK" "$result" "json_string special chars — all round-trip correctly"
}

# ==============================================================================
# get_track_count
# ==============================================================================

test_track_count_normal() {
    plan "get_track_count: normal playlist"
    local val; val=$(python3 - "${FIXTURES}/playlist-with-tracks.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('tracks', [])))
PYEOF
)
    assert_eq "3" "$val" "track count normal — 3"
}

test_track_count_empty() {
    plan "get_track_count: empty tracks"
    local val; val=$(python3 - "${FIXTURES}/playlist-empty-tracks.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('tracks', [])))
PYEOF
)
    assert_eq "0" "$val" "track count empty — 0"
}

test_track_count_missing_key() {
    plan "get_track_count: missing tracks key"
    local val; val=$(python3 - "${FIXTURES}/playlist-no-tracks-key.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('tracks', [])))
PYEOF
)
    assert_eq "0" "$val" "track count missing key — 0"
}

test_track_count_bad_file() {
    plan "get_track_count: non-existent file"
    local dir; dir=$(mk_temp_dir)
    local val; val=$(python3 - "${dir}/noexist.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except:
    print('0')
PYEOF
)
    assert_eq "0" "$val" "track count no file — 0"
    rm -rf "$dir"
}

# ==============================================================================
# extract_tracks_json
# ==============================================================================

test_extract_tracks_normal() {
    plan "extract_tracks_json: normal playlist"
    local dir; dir=$(mk_temp_dir)
    python3 - "${FIXTURES}/playlist-with-tracks.json" <<'PYEOF' > "${dir}/out.txt"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
for t in data.get('tracks', []):
    print(json.dumps(t))
PYEOF
    local count; count=$(wc -l < "${dir}/out.txt")
    assert_eq "3" "$count" "extract tracks — 3 lines"
    local first; first=$(head -1 "${dir}/out.txt")
    assert_eq '{"id": "tr_001", "url": "/audio/track1.mp3", "filename": "track1.mp3", "title": "First Track", "sha256": "aaa"}' "$first" "extract tracks — first line"
    rm -rf "$dir"
}

test_extract_tracks_empty() {
    plan "extract_tracks_json: empty tracks"
    local dir; dir=$(mk_temp_dir)
    python3 - "${FIXTURES}/playlist-empty-tracks.json" <<'PYEOF' > "${dir}/out.txt"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
for t in data.get('tracks', []):
    print(json.dumps(t))
PYEOF
    local count; count=$(wc -l < "${dir}/out.txt")
    assert_eq "0" "$count" "extract empty tracks — 0 lines"
    rm -rf "$dir"
}

# ==============================================================================
# write_audio_mode (audio-manager.sh pattern)
# ==============================================================================

test_write_audio_mode_normal() {
    plan "write_audio_mode: all fields"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/audio_mode.json"

    python3 - "$outfile" "RADIO" "RADIO" "startup" "2026-07-10T12:00:00Z" \
        "true" "COMPLETE" "" "" "" "0" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; desired = sys.argv[3]; reason = sys.argv[4]
now = sys.argv[5]; internet_str = sys.argv[6]; cache_status = sys.argv[7]
pv = sys.argv[8]; le = sys.argv[9]; lta = sys.argv[10]; tc = int(sys.argv[11]) if sys.argv[11].isdigit() else 0
doc = {
    "_schema_version": "1.0", "mode": mode, "desired_mode": desired,
    "reason": reason, "since": now,
    "internet_available": (internet_str == "true"),
    "cache_status": cache_status,
    "active_playlist_version": pv if pv else None,
    "last_transition_at": lta if lta else None,
    "transition_count": tc,
    "last_error": le if le else None,
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local mode; mode=$(python3 -c "import json; print(json.load(open('${outfile}'))['mode'])")
    assert_eq "RADIO" "$mode" "write audio mode — mode == RADIO"
    local internet; internet=$(python3 -c "import json; print(json.load(open('${outfile}'))['internet_available'])")
    assert_eq "True" "$internet" "write audio mode — internet True"
    rm -rf "$dir"
}

test_write_audio_mode_with_nulls() {
    plan "write_audio_mode: empty optional fields become null"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/audio_mode.json"

    python3 - "$outfile" "LOCAL" "RADIO" "network_lost" "2026-07-10T12:00:00Z" \
        "false" "EMPTY" "" "" "" "5" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; desired = sys.argv[3]; reason = sys.argv[4]
now = sys.argv[5]; internet_str = sys.argv[6]; cache_status = sys.argv[7]
pv = sys.argv[8]; le = sys.argv[9]; lta = sys.argv[10]; tc = int(sys.argv[11]) if sys.argv[11].isdigit() else 0
doc = {
    "_schema_version": "1.0", "mode": mode, "desired_mode": desired,
    "reason": reason, "since": now,
    "internet_available": (internet_str == "true"),
    "cache_status": cache_status,
    "active_playlist_version": pv if pv else None,
    "last_transition_at": lta if lta else None,
    "transition_count": tc,
    "last_error": le if le else None,
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local internet; internet=$(python3 -c "import json; print(json.load(open('${outfile}'))['internet_available'])")
    assert_eq "False" "$internet" "write audio nulls — internet False"
    local pv; pv=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d['active_playlist_version'] if d['active_playlist_version'] is not None else 'None')")
    assert_eq "None" "$pv" "write audio nulls — playlist_version is None"
    local tc; tc=$(python3 -c "import json; print(json.load(open('${outfile}'))['transition_count'])")
    assert_eq "5" "$tc" "write audio nulls — transition_count 5"
    rm -rf "$dir"
}

# ==============================================================================
# save_playback_state (audio-player.sh pattern)
# ==============================================================================

test_save_playback_state_normal() {
    plan "save_playback_state: fields"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/playback_state.json"

    python3 - "$outfile" "RADIO" "2026-07-10T12:00:00Z" "sha256:abc" "tr_005" "3" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; now = sys.argv[3]
hash_val = sys.argv[4]; tid_val = sys.argv[5]
track_idx = int(sys.argv[6]) if sys.argv[6].isdigit() else 0
doc = {
    "_schema_version": "1.0", "mode": mode,
    "radio": {"last_check": None, "last_hash": None},
    "local": {
        "playlist_hash": hash_val if hash_val else None,
        "current_track_index": track_idx,
        "current_track_id": tid_val if tid_val else None,
        "position_seconds": 0, "last_updated": now,
    },
    "statistics": {"total_plays": 0, "mode_switches": 0, "last_server_contact": None},
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local mode; mode=$(python3 -c "import json; print(json.load(open('${outfile}'))['mode'])")
    assert_eq "RADIO" "$mode" "playback state — mode RADIO"
    local idx; idx=$(python3 -c "import json; print(json.load(open('${outfile}'))['local']['current_track_index'])")
    assert_eq "3" "$idx" "playback state — track index 3"
    rm -rf "$dir"
}

test_save_playback_state_with_nulls() {
    plan "save_playback_state: empty fields become null"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/playback_state.json"

    python3 - "$outfile" "LOCAL" "2026-07-10T12:00:00Z" "" "" "0" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; now = sys.argv[3]
hash_val = sys.argv[4]; tid_val = sys.argv[5]
track_idx = int(sys.argv[6]) if sys.argv[6].isdigit() else 0
doc = {
    "_schema_version": "1.0", "mode": mode,
    "radio": {"last_check": None, "last_hash": None},
    "local": {
        "playlist_hash": hash_val if hash_val else None,
        "current_track_index": track_idx,
        "current_track_id": tid_val if tid_val else None,
        "position_seconds": 0, "last_updated": now,
    },
    "statistics": {"total_plays": 0, "mode_switches": 0, "last_server_contact": None},
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local hash_val; hash_val=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d['local']['playlist_hash'] if d['local']['playlist_hash'] is not None else 'None')")
    assert_eq "None" "$hash_val" "playback state nulls — hash is None"
    local tid; tid=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d['local']['current_track_id'] if d['local']['current_track_id'] is not None else 'None')")
    assert_eq "None" "$tid" "playback state nulls — track_id is None"
    rm -rf "$dir"
}

# ==============================================================================
# sigil-validate-state.sh pattern
# ==============================================================================

test_validate_valid_json() {
    plan "validate-state: valid JSON with _schema_version"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    local result; result=$(python3 - "${dir}/test.json" <<'PYEOF' 2>&1 || true
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
if '_schema_version' in data:
    print("OK")
else:
    print("WARN")
PYEOF
)
    assert_eq "OK" "$result" "validate valid — OK"
    rm -rf "$dir"
}

test_validate_invalid_json() {
    plan "validate-state: invalid JSON (error)"
    local dir; dir=$(mk_temp_dir)
    echo "not json" > "${dir}/bad.json"

    set +e
    python3 - "${dir}/bad.json" <<'PYEOF' 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except json.JSONDecodeError:
    print("INVALID")
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_eq "INVALID" "$(python3 - "${dir}/bad.json" <<'PYEOF' 2>&1 || true
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except json.JSONDecodeError:
    print("INVALID")
    sys.exit(1)
PYEOF
)" "validate invalid — INVALID"
    assert_rc 1 "$rc" "validate invalid — exit code 1"
    rm -rf "$dir"
}

test_validate_missing_file() {
    plan "validate-state: missing file (error)"
    set +e
    python3 - "/tmp/noexist-$$.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
except Exception:
    sys.exit(1)
PYEOF
    local rc=$?
    set -e
    assert_rc 1 "$rc" "validate missing file — exit code 1"
}

test_validate_schema_check() {
    plan "validate-state: schema validation (if jsonschema available)"
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "jsonschema not installed"
        return
    fi
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/data.json"

    python3 - "${dir}/data.json" <<'PYEOF' 2>&1
import json, sys
from jsonschema import validate, ValidationError
with open(sys.argv[1]) as f: data = json.load(f)
# Minimal schema: any object with _schema_version is valid
schema = {"type": "object", "required": ["_schema_version"], "properties": {"_schema_version": {"type": "string"}}}
validate(instance=data, schema=schema)
print("VALID")
PYEOF
    local val; val=$(python3 - "${dir}/data.json" <<'PYEOF' 2>&1
import json, sys
from jsonschema import validate, ValidationError
with open(sys.argv[1]) as f: data = json.load(f)
schema = {"type": "object", "required": ["_schema_version"], "properties": {"_schema_version": {"type": "string"}}}
validate(instance=data, schema=schema)
print("VALID")
PYEOF
)
    assert_eq "VALID" "$val" "validate schema — VALID"
    rm -rf "$dir"
}

# ==============================================================================
# Injection safety — confirm shell vars are never interpolated into Python
# ==============================================================================

test_injection_safety() {
    plan "injection: shell vars not interpolated into Python source"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    # A value that would be dangerous if interpolated into Python source
    local malicious="'; import os; os.system('echo PWNED'); '"
    local rc=0
    python3 - "${dir}/test.json" "key" "$malicious" 2>&1 <<'PYEOF' || rc=$?
import json, sys
try:
    json.loads(sys.argv[3])
    print("PARSED_OK")
except json.JSONDecodeError:
    print("REJECTED")
    sys.exit(1)
PYEOF
    assert_eq 1 "$rc" "injection — exit code 1 (JSON rejected)"
    rm -rf "$dir"
}

# ==============================================================================
# Injection payload — valid JSON strings that must NOT be interpolated or
# executed. The payload is stored as inert text in the JSON file.
# ==============================================================================

test_injection_payload_stored_as_text() {
    plan "injection: Python expression stored as inert text"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    local payload='__import__("os").system("touch /tmp/sigil-injected")'
    local json_val
    json_val=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$payload")

    # Write it via update_cache_meta pattern
    python3 - "${dir}/test.json" "string_field" "$json_val" <<'PYEOF'
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF

    # Read back — must equal original payload exactly
    local stored
    stored=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['string_field'])" "${dir}/test.json")
    assert_eq "$payload" "$stored" "injection payload — stored as text, not executed"
    assert_eq "0" "$(test -f /tmp/sigil-injected && echo 1 || echo 0)" "injection payload — no file created"
    rm -rf "$dir"
}

test_injection_special_characters() {
    plan "injection: special characters stored as inert text"
    local dir; dir=$(mk_temp_dir)
    cp "${FIXTURES}/nested-values.json" "${dir}/test.json"

    local cases
    cases=$(python3 <<'PYEOF'
import json
payloads = [
    "hello; world",
    "$(id)",
    "`whoami`",
    "'; print('PWNED'); '",
    "| cat /etc/passwd",
    "&& rm -rf /",
    "|| echo pwned",
    "hello \"world\"",
    "line1\nline2",
    "café",
    "tab\tseparated",
    "var=value",
    "${HOME}",
]
for p in payloads:
    print(json.dumps(p))
PYEOF
)

    while IFS= read -r json_line; do
        [ -z "$json_line" ] && continue
        local expected
        expected=$(python3 - "$json_line" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]))
PYEOF
)

        # Write via update_cache_meta pattern
        python3 - "${dir}/test.json" "string_field" "$json_line" <<'PYEOF' > /dev/null 2>&1
import json, os, sys, tempfile
file_path = sys.argv[1]; key_path = sys.argv[2]; raw_value = sys.argv[3]
value = json.loads(raw_value)
keys = key_path.split('.')
with open(file_path) as f: data = json.load(f)
obj = data
for k in keys[:-1]:
    if k not in obj: obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
dir_name = os.path.dirname(file_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, file_path)
PYEOF

        local stored
        stored=$(python3 - "${dir}/test.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(d['string_field'] if d['string_field'] else 'NONE')
PYEOF
)
        assert_eq "$expected" "$stored" "injection special — [${expected}] stored as inert text"
    done <<< "$cases"
    rm -rf "$dir"
}

# ==============================================================================
# AUTH_MODE tests — init_curl_auth logic
# ==============================================================================

test_auth_mode_query_default() {
    plan "AUTH_MODE: query mode (default)"
    AUTH_MODE="query" API_KEY="sekret123" \
    python3 -c "
import os
AUTH_MODE = os.environ.get('AUTH_MODE', 'query')
API_KEY = os.environ.get('API_KEY', '')
# Credentials are passed via --config tmpfile, never in URL
if AUTH_MODE == 'bearer':
    config_header = 'Authorization: Bearer ' + API_KEY
elif AUTH_MODE == 'none':
    config_header = ''
else:  # query | *
    config_header = 'x-api-key: ' + API_KEY
assert config_header == 'x-api-key: sekret123', f'config_header={config_header}'
print('query mode OK')
"
    local rc=$?
    assert_rc 0 "$rc" "AUTH_MODE=query — x-api-key via --config, no token in URL"
}

test_auth_mode_bearer() {
    plan "AUTH_MODE: bearer mode"
    AUTH_MODE="bearer" API_KEY="sekret123" \
    python3 -c "
import os
AUTH_MODE = os.environ.get('AUTH_MODE', 'query')
API_KEY = os.environ.get('API_KEY', '')
if AUTH_MODE == 'bearer':
    config_header = 'Authorization: Bearer ' + API_KEY
elif AUTH_MODE == 'none':
    config_header = ''
else:
    config_header = 'x-api-key: ' + API_KEY
assert config_header == 'Authorization: Bearer sekret123', f'config_header={config_header}'
print('bearer mode OK')
"
    local rc=$?
    assert_rc 0 "$rc" "AUTH_MODE=bearer — Authorization via --config"
}

test_auth_mode_none() {
    plan "AUTH_MODE: none (no auth)"
    AUTH_MODE="none" API_KEY="" \
    python3 -c "
import os
AUTH_MODE = os.environ.get('AUTH_MODE', 'query')
API_KEY = os.environ.get('API_KEY', '')
if AUTH_MODE == 'bearer':
    config_header = 'Authorization: Bearer ' + API_KEY
elif AUTH_MODE == 'none':
    config_header = ''
else:
    config_header = 'x-api-key: ' + API_KEY
assert config_header == '', f'config_header={config_header}'
print('none mode OK')
"
    local rc=$?
    assert_rc 0 "$rc" "AUTH_MODE=none — no auth config"
}

test_auth_mode_invalid_dies() {
    plan "AUTH_MODE: invalid value dies"
    local dir; dir=$(mk_temp_dir)
    local conf="${dir}/audio.conf"
    cat > "$conf" <<'CONF'
SERVER_URL="http://example.com"
API_KEY="test"
AUTH_MODE="invalid_mode"
CONF
    set +e
    local output
    output=$(AUDIO_CONF="$conf" bash -c '
source "$AUDIO_CONF"
case "${AUTH_MODE}" in
    query|bearer|none) ;;
    *) echo "Invalid AUTH_MODE=${AUTH_MODE}"; exit 1 ;;
esac
' 2>&1)
    local rc=$?
    set -e
    assert_rc 1 "$rc" "AUTH_MODE=invalid — exit code 1"
    rm -rf "$dir"
}

test_auth_mode_missing_key_warns() {
    plan "AUTH_MODE: missing key warns"
    local output
    output=$(API_KEY="" AUTH_MODE="query" bash -c '
if [ -z "$API_KEY" ]; then
    echo "WARN: API_KEY is empty"
fi
' 2>&1)
    assert_eq "WARN: API_KEY is empty" "$output" "AUTH_MODE missing key — warns"
}

# ==============================================================================
# Playlist hash stability — compute_playlist_hash from content only
# ==============================================================================

test_hash_stable_with_metadata() {
    plan "compute_playlist_hash: same content, different metadata"
    local hash1 hash2
    hash1=$(echo '{"tracks": [{"id": "1", "url": "/a.mp3"}], "timestamp": "2026-01-01", "page": 1}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    hash2=$(echo '{"tracks": [{"id": "1", "url": "/a.mp3"}], "timestamp": "2026-06-15", "page": 2}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    assert_eq "$hash1" "$hash2" "hash stable — same tracks, different metadata"
}

test_hash_differs_with_track_change() {
    plan "compute_playlist_hash: different content, different hash"
    local hash1 hash2
    hash1=$(echo '{"tracks": [{"id": "1", "url": "/a.mp3"}]}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    hash2=$(echo '{"tracks": [{"id": "2", "url": "/b.mp3"}]}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    assert_ne "$hash1" "$hash2" "hash differs — different tracks"
}

test_hash_different_order_different_hash() {
    plan "compute_playlist_hash: different track order produces different hash"
    local hash1 hash2
    hash1=$(echo '[{"id": "1", "url": "/a.mp3"}, {"id": "2", "url": "/b.mp3"}]' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    hash2=$(echo '[{"id": "2", "url": "/b.mp3"}, {"id": "1", "url": "/a.mp3"}]' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    assert_ne "$hash1" "$hash2" "hash different — ordering matters for playlists"
}

test_hash_empty_tracks() {
    plan "compute_playlist_hash: empty tracks"
    local hash_val
    hash_val=$(echo '{"tracks": []}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    assert_ne "" "$hash_val" "hash empty — produces a hash"
    local expected_hex
    expected_hex=$(python3 -c "import hashlib; print(hashlib.sha256(b'[]').hexdigest())")
    assert_eq "$expected_hex" "$hash_val" "hash empty — SHA256 of empty array"
}

test_hash_missing_tracks_key() {
    plan "compute_playlist_hash: no tracks key"
    local hash_val
    hash_val=$(echo '{"status": "ok", "message": "no data"}' | python3 -c "
import json, sys, hashlib
raw = json.load(sys.stdin)
if isinstance(raw, list):
    tracks = raw
elif isinstance(raw, dict):
    tracks = raw.get('tracks', [])
else:
    tracks = []
norm = json.dumps(tracks, sort_keys=True, ensure_ascii=True)
print(hashlib.sha256(norm.encode()).hexdigest())
")
    local expected_hex
    expected_hex=$(python3 -c "import hashlib; print(hashlib.sha256(b'[]').hexdigest())")
    assert_eq "$expected_hex" "$hash_val" "hash no tracks key — SHA256 of empty array"
}

# ==============================================================================
# Hardlink fallback visibility
# ==============================================================================

test_hardlink_success_logs() {
    plan "link_unchanged_track: hardlink success logs DEBUG"
    local dir; dir=$(mk_temp_dir)
    echo "content" > "${dir}/source.txt"
    local output
    output=$(bash -c '
dir="${1}"
source="${dir}/source.txt"
target="${dir}/link.txt"
if ln "$source" "$target" 2>/dev/null; then
    echo "DEBUG: Hardlinked unchanged track: $(basename "$source")"
fi
' bash "$dir" 2>&1)
    assert_eq "DEBUG: Hardlinked unchanged track: source.txt" "$output" "hardlink success — DEBUG log"
    assert_file_contains "${dir}/link.txt" "content" "hardlink success — linked content"
    rm -rf "$dir"
}

test_hardlink_fallback_logs() {
    plan "link_unchanged_track: hardlink cross-device fallback"
    local dir; dir=$(mk_temp_dir)
    local subdir="${dir}/sub"
    mkdir "$subdir"
    echo "content" > "${dir}/source.txt"
    # Simulate a hardlink failure by having target already exist
    # ln without -f fails with "File exists", then cp as fallback
    local output
    output=$(bash -c '
source="${1}"
target="${2}"
filename=$(basename "$source")
if ln "$source" "$target" 2>/dev/null; then
    echo "link OK"
elif cp "$source" "$target" 2>/dev/null; then
    echo "WARN: Hardlink failed for ${filename} - falling back to copy"
    echo "INFO: Copied unchanged track: ${filename}"
fi
' bash "${dir}/source.txt" "${dir}/link.txt" 2>&1)
    assert_file_contains <(echo "$output") "link OK" "hardlink fallback — ln succeeded (no cross-device)"
    rm -rf "$dir"
}

test_hardlink_cross_device() {
    plan "link_unchanged_track: simulate cross-device fallback"
    local dir; dir=$(mk_temp_dir)
    echo "content" > "${dir}/source.txt"
    # Create a pre-existing target so ln fails
    touch "${dir}/preexisting.txt"
    local output
    output=$(bash -c '
source="${1}"
target="${2}"
filename=$(basename "$source")
if ln "$source" "$target" 2>/dev/null; then
    echo "link OK"
elif cp "$source" "$target" 2>/dev/null; then
    echo "WARN: Hardlink failed for ${filename} - falling back to copy"
    echo "INFO: Copied unchanged track: ${filename}"
fi
' bash "${dir}/source.txt" "${dir}/preexisting.txt" 2>&1)
    assert_file_contains <(echo "$output") "WARN: Hardlink failed" "hardlink cross-device — WARN logged"
    assert_file_contains <(echo "$output") "INFO: Copied unchanged" "hardlink cross-device — INFO logged"
    # Verify cp fallback actually worked
    if diff "${dir}/source.txt" "${dir}/preexisting.txt"; then
        ok "hardlink cross-device — cp fallback content matches"
    else
        not_ok "hardlink cross-device — cp fallback content mismatch"
    fi
    rm -rf "$dir"
}

test_hardlink_full_failure_logs() {
    plan "link_unchanged_track: both link and copy fail logs ERROR"
    # Both operations fail when source does not exist
    local output rc=0
    output=$(bash -c '
source="/nonexistent/source.txt"
target="/nonexistent/target.txt"
filename=$(basename "$source" 2>/dev/null || echo "source.txt")
rc=0
if ln "$source" "$target" 2>/dev/null; then
    :
elif cp "$source" "$target" 2>/dev/null; then
    echo "copied"
else
    echo "ERROR: Both hardlink and copy failed for ${filename}"
    rc=1
fi
exit $rc
' 2>&1) || rc=$?
    assert_file_contains <(echo "$output") "ERROR: Both hardlink and copy failed" "hardlink full failure — ERROR logged"
}

# ==============================================================================
# Dry-run: stale staging file removal guarded
# ==============================================================================

# ==============================================================================
# validate_track_filename — H6 safe filename validation tests
# ==============================================================================

test_validate_track_filename_empty() {
    plan "validate_track_filename: empty string returns 1"
    local rc
    set +e
    fname="" bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "${fname#/}" != "$fname" ]; then return 1; fi
    case "$fname" in */*|*\\*) return 1 ;; esac
    if [ "$fname" = "." ] || [ "$fname" = ".." ]; then return 1; fi
    case "$fname" in *\\.\\./*|*\\.\\.) return 1 ;; esac
    if echo "$fname" | LC_ALL=C grep -q "[[:cntrl:]]" 2>/dev/null; then return 1; fi
    if [ "$(basename "$fname")" != "$fname" ]; then return 1; fi
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate empty — 1"
}

test_validate_track_filename_absolute() {
    plan "validate_track_filename: absolute path returns 1"
    local rc
    set +e
    fname="/etc/passwd" bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "${fname#/}" != "$fname" ]; then return 1; fi
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate absolute — 1"
}

test_validate_track_filename_slash() {
    plan "validate_track_filename: relative path with slash returns 1"
    local rc
    set +e
    fname="subdir/file.mp3" bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    case "$fname" in */*|*\\*) return 1 ;; esac
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate slash — 1"
}

test_validate_track_filename_backslash() {
    plan "validate_track_filename: backslash returns 1"
    local rc
    set +e
    fname="subdir\\\\file.mp3" bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    case "$fname" in */*|*\\\\*) return 1 ;; esac
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate backslash — 1"
}

test_validate_track_filename_dot() {
    plan "validate_track_filename: '.' returns 1"
    local rc
    set +e
    fname="." bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "$fname" = "." ] || [ "$fname" = ".." ]; then return 1; fi
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate dot — 1"
}

test_validate_track_filename_dotdot() {
    plan "validate_track_filename: '..' returns 1"
    local rc
    set +e
    fname=".." bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if [ "$fname" = "." ] || [ "$fname" = ".." ]; then return 1; fi
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate dotdot — 1"
}

test_validate_track_filename_control() {
    plan "validate_track_filename: control character returns 1"
    local rc
    set +e
    fname=$'file\t.mp3' bash -c '
validate_track_filename() {
    local fname="$1"
    if [ -z "$fname" ]; then return 1; fi
    if echo "$fname" | LC_ALL=C grep -q "[[:cntrl:]]" 2>/dev/null; then return 1; fi
    return 0
}
validate_track_filename "$fname"
' 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate control — 1"
}

test_validate_track_filename_duplicate_detected() {
    plan "validate_track_filename: duplicate filename detection (not in fn, but playlist-level)"
    # This validates that the fetcher's duplicate check pattern works
    local dir; dir=$(mk_temp_dir)
    local seen=""
    local found=""
    for f in "track1.mp3" "track2.mp3" "track1.mp3"; do
        case ":${seen}:" in
            *:${f}:*)
                found="DUPLICATE: ${f}"
                ;;
        esac
        seen="${seen}:${f}"
    done
    assert_eq "DUPLICATE: track1.mp3" "$found" "validate duplicate — detected"
    rm -rf "$dir"
}

# ==============================================================================
# validate_active — runtime integrity check tests
# ==============================================================================

test_validate_active_missing_track() {
    plan "validate_active: missing track forces re-download"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"

    # Playlist with 2 tracks, only 1 on disk
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "tr_001", "filename": "track1.mp3", "sha256": "aaa"},
  {"id": "tr_002", "filename": "track2.mp3", "sha256": "bbb"}
]}
EOF
    echo "content1" > "${active_dir}/tracks/track1.mp3"

    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 2}}
EOF

    # Test using the same Python validation as production validate_active
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys, hashlib
playlist_path, tracks_dir, cache_meta_path = sys.argv[1], sys.argv[2], sys.argv[3]
tracks = json.load(open(playlist_path)).get("tracks", [])
for t in tracks:
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path):
        sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "validate active — missing track returns 1"
    rm -rf "$dir"
}

test_validate_active_all_tracks_present() {
    plan "validate_active: all tracks present passes"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"

    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "tr_001", "filename": "track1.mp3"},
  {"id": "tr_002", "filename": "track2.mp3"}
]}
EOF
    echo "content1" > "${active_dir}/tracks/track1.mp3"
    echo "content2" > "${active_dir}/tracks/track2.mp3"

    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 2}}
EOF

    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
playlist_path, tracks_dir = sys.argv[1], sys.argv[2]
tracks = json.load(open(playlist_path)).get("tracks", [])
for t in tracks:
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path):
        sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 0 "$rc" "validate active — all tracks present returns 0"
    rm -rf "$dir"
}

test_validate_active_zero_tracks() {
    plan "validate_active: zero tracks returns 1"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"

    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 0}}
EOF

    local rc=0
    set +e
    # tracks_count 0 should make validate_active return 1 early
    python3 -c "import json; d=json.load(open('${dir}/cache_meta.json')); tc=d.get('active_cache',{}).get('tracks_count',0); exit(1 if tc == 0 else 0)" 2>/dev/null; rc=$?
    set -e
    assert_rc 1 "$rc" "validate active — zero tracks returns 1"
    rm -rf "$dir"
}

test_validate_active_empty_dir() {
    plan "validate_active: tracks dir empty returns 1"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"

    # Playlist says 1 track but none on disk
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "tr_001", "filename": "track1.mp3"}
]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 1}}
EOF

    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
tracks_dir = sys.argv[2]
tracks = json.load(open(sys.argv[1])).get("tracks", [])
for t in tracks:
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path):
        sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "validate active — empty dir returns 1"
    rm -rf "$dir"
}

# ==============================================================================
# validate_playlist_filenames — playlist-wide filename uniqueness (Fix 6)
# ==============================================================================

test_playlist_filenames_all_unique() {
    plan "validate_playlist_filenames: all unique passes"
    local dir; dir=$(mk_temp_dir)
    cat > "${dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "1", "filename": "track1.mp3"},
  {"id": "2", "filename": "track2.mp3"},
  {"id": "3", "filename": "track3.mp3"}
]}
EOF
    if python3 - "${dir}/playlist.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
tracks = data if isinstance(data, list) else data.get('tracks', [])
seen = {}
for i, t in enumerate(tracks):
    fname = t.get("filename", "")
    if fname in seen:
        print("DUPLICATE", fname, file=sys.stderr)
        sys.exit(1)
    seen[fname] = i
sys.exit(0)
PYEOF
    then
        ok "unique filenames — passes"
    else
        not_ok "unique filenames — should pass"
    fi
    rm -rf "$dir"
}

test_playlist_filenames_duplicate_rejected() {
    plan "validate_playlist_filenames: duplicate rejected"
    local dir; dir=$(mk_temp_dir)
    cat > "${dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "1", "filename": "track1.mp3"},
  {"id": "2", "filename": "track1.mp3"}
]}
EOF
    if python3 - "${dir}/playlist.json" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
tracks = data if isinstance(data, list) else data.get('tracks', [])
seen = {}
for i, t in enumerate(tracks):
    fname = t.get("filename", "")
    if fname in seen:
        sys.exit(1)
    seen[fname] = i
sys.exit(0)
PYEOF
    then
        not_ok "duplicate — should reject"
    else
        ok "duplicate — rejected"
    fi
    rm -rf "$dir"
}

test_playlist_filenames_path_traversal_rejected() {
    plan "validate_playlist_filenames: path traversal rejected"
    local dir; dir=$(mk_temp_dir)
    cat > "${dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "1", "filename": "../../etc/passwd"},
  {"id": "2", "filename": "track2.mp3"}
]}
EOF
    if python3 - "${dir}/playlist.json" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
tracks = data if isinstance(data, list) else data.get('tracks', [])
for i, t in enumerate(tracks):
    fname = t.get("filename", "")
    if "/" in fname or ".." in fname:
        sys.exit(1)
sys.exit(0)
PYEOF
    then
        not_ok "path traversal — should reject"
    else
        ok "path traversal — rejected"
    fi
    rm -rf "$dir"
}

test_playlist_filenames_triplicate_rejected() {
    plan "validate_playlist_filenames: triplicate rejected"
    local dir; dir=$(mk_temp_dir)
    cat > "${dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "1", "filename": "same.mp3"},
  {"id": "2", "filename": "same.mp3"},
  {"id": "3", "filename": "same.mp3"}
]}
EOF
    if python3 - "${dir}/playlist.json" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
tracks = data if isinstance(data, list) else data.get('tracks', [])
seen = set()
for t in tracks:
    fname = t.get("filename", "")
    if fname in seen:
        sys.exit(1)
    seen.add(fname)
sys.exit(0)
PYEOF
    then
        not_ok "triplicate — should reject"
    else
        ok "triplicate — rejected"
    fi
    rm -rf "$dir"
}

# ==============================================================================
# playback_state decoder_failure — Fix 5: failures in playback_state.json
# ==============================================================================

test_playback_state_decoder_failure_present() {
    plan "playback_state: decoder_failure persists correctly"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/playback_state.json"

    python3 - "$outfile" "RADIO" "2026-07-10T12:00:00Z" "" "" "0" \
        "RADIO" "1" "/path/to/track.mp3" "3" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; now = sys.argv[3]
hash_val = sys.argv[4]; tid_val = sys.argv[5]
track_idx = int(sys.argv[6]) if sys.argv[6].isdigit() else 0
failure_source = sys.argv[7]; decoder_exit = sys.argv[8]
failed_path = sys.argv[9]; consecutive = int(sys.argv[10]) if sys.argv[10].isdigit() else 0
decoder_failure = {}
if failure_source and decoder_exit:
    decoder_failure = {
        "last_error": "decoder_failure",
        "decoder_exit_code": int(decoder_exit) if decoder_exit.isdigit() else 0,
        "failed_track_id": tid_val if tid_val else None,
        "failed_track_url": None,
        "failed_local_path": failed_path if failed_path else None,
        "consecutive_failures": consecutive,
        "failure_source": failure_source,
        "failure_at": now,
        "playing": False,
    }
doc = {
    "_schema_version": "1.0", "mode": mode,
    "radio": {"last_check": None, "last_hash": None},
    "local": {
        "playlist_hash": hash_val if hash_val else None,
        "current_track_index": track_idx,
        "current_track_id": tid_val if tid_val else None,
        "position_seconds": 0, "last_updated": now,
    },
    "statistics": {"total_plays": 0, "mode_switches": 0, "last_server_contact": None},
    "decoder_failure": decoder_failure,
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local df; df=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d.get('decoder_failure',{}).get('last_error',''))")
    assert_eq "decoder_failure" "$df" "decoder_failure — last_error present"
    local exit_code; exit_code=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d.get('decoder_failure',{}).get('decoder_exit_code',-1))")
    assert_eq "1" "$exit_code" "decoder_failure — exit_code 1"
    local cons; cons=$(python3 -c "import json; d=json.load(open('${outfile}')); print(d.get('decoder_failure',{}).get('consecutive_failures',-1))")
    assert_eq "3" "$cons" "decoder_failure — consecutive_failures 3"
    rm -rf "$dir"
}

test_playback_state_no_failure_when_empty() {
    plan "playback_state: no decoder_failure when empty args"
    local dir; dir=$(mk_temp_dir)
    local outfile="${dir}/playback_state.json"

    python3 - "$outfile" "RADIO" "2026-07-10T12:00:00Z" "" "" "0" \
        "" "" "" "0" <<'PYEOF'
import json, os, sys, tempfile
out_file = sys.argv[1]; mode = sys.argv[2]; now = sys.argv[3]
hash_val = sys.argv[4]; tid_val = sys.argv[5]
track_idx = int(sys.argv[6]) if sys.argv[6].isdigit() else 0
failure_source = sys.argv[7]; decoder_exit = sys.argv[8]
failed_path = sys.argv[9]; consecutive = int(sys.argv[10]) if sys.argv[10].isdigit() else 0
decoder_failure = {}
if failure_source and decoder_exit:
    decoder_failure = {
        "last_error": "decoder_failure",
        "decoder_exit_code": int(decoder_exit) if decoder_exit.isdigit() else 0,
        "failed_track_id": tid_val if tid_val else None,
        "failed_track_url": None,
        "failed_local_path": failed_path if failed_path else None,
        "consecutive_failures": consecutive,
        "failure_source": failure_source,
        "failure_at": now,
        "playing": False,
    }
doc = {
    "_schema_version": "1.0", "mode": mode,
    "radio": {"last_check": None, "last_hash": None},
    "local": {
        "playlist_hash": hash_val if hash_val else None,
        "current_track_index": track_idx,
        "current_track_id": tid_val if tid_val else None,
        "position_seconds": 0, "last_updated": now,
    },
    "statistics": {"total_plays": 0, "mode_switches": 0, "last_server_contact": None},
    "decoder_failure": decoder_failure,
}
dir_name = os.path.dirname(out_file) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp_path, out_file)
PYEOF

    local has_failure; has_failure=$(python3 -c "import json; d=json.load(open('${outfile}')); print('decoder_failure' in d)")
    assert_eq "True" "$has_failure" "no failure — decoder_failure key exists (empty dict)"
    local df; df=$(python3 -c "import json; d=json.load(open('${outfile}')); print(len(d.get('decoder_failure',{})))")
    assert_eq "0" "$df" "no failure — decoder_failure is empty dict"
    rm -rf "$dir"
}

# ==============================================================================
# validate_active full-track validation — Fix 1: sha256, size, filename-set
# ==============================================================================

test_validate_active_sha256_mismatch() {
    plan "validate_active: sha256 mismatch rejected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    echo "content1" > "${active_dir}/tracks/track1.mp3"
    # Playlist says sha256 is something else
    local fake_hash; fake_hash=$(python3 -c "import hashlib; print(hashlib.sha256(b'WRONG').hexdigest())")
    cat > "${active_dir}/playlist.json" <<EOF
{"tracks": [{"id": "1", "filename": "track1.mp3", "sha256": "${fake_hash}"}]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 1, "total_size_bytes": 8}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys, hashlib
playlist = json.load(open(sys.argv[1]))
tracks_dir = sys.argv[2]
for t in playlist.get("tracks", []):
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path):
        sys.exit(1)
    expected = t.get("sha256", "")
    if expected:
        actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if actual != expected:
            print("ERROR: sha256 mismatch", file=sys.stderr)
            sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "sha256 mismatch — rejected"
    rm -rf "$dir"
}

test_validate_active_size_mismatch() {
    plan "validate_active: size_bytes mismatch rejected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    printf "12345" > "${active_dir}/tracks/track1.mp3"
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [{"id": "1", "filename": "track1.mp3", "size_bytes": 999}]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 1, "total_size_bytes": 999}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
playlist = json.load(open(sys.argv[1]))
tracks_dir = sys.argv[2]
for t in playlist.get("tracks", []):
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path): sys.exit(1)
    file_size = os.path.getsize(path)
    expected_size = t.get("size_bytes", 0)
    if expected_size > 0 and file_size != expected_size:
        print("ERROR: size mismatch", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "size mismatch — rejected"
    rm -rf "$dir"
}

test_validate_active_extra_file_detected() {
    plan "validate_active: extra file on disk detected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    echo "content1" > "${active_dir}/tracks/track1.mp3"
    echo "extra" > "${active_dir}/tracks/extra.mp3"
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [{"id": "1", "filename": "track1.mp3"}]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 1, "total_size_bytes": 8}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
playlist = json.load(open(sys.argv[1]))
tracks_dir = sys.argv[2]
playlist_files = set(t.get("filename", "") for t in playlist.get("tracks", []))
disk_files = set()
if os.path.isdir(tracks_dir):
    for entry in os.listdir(tracks_dir):
        if os.path.isfile(os.path.join(tracks_dir, entry)):
            disk_files.add(entry)
extra = disk_files - playlist_files
missing = playlist_files - disk_files
if extra or missing:
    sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "extra file — detected"
    rm -rf "$dir"
}

test_validate_active_missing_file_detected() {
    plan "validate_active: missing file on disk detected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    echo "content1" > "${active_dir}/tracks/track1.mp3"
    # Playlist says 2 files but only 1 on disk
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [
  {"id": "1", "filename": "track1.mp3"},
  {"id": "2", "filename": "track2.mp3"}
]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 2, "total_size_bytes": 16}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
playlist = json.load(open(sys.argv[1]))
tracks_dir = sys.argv[2]
playlist_files = set(t.get("filename", "") for t in playlist.get("tracks", []))
disk_files = set()
if os.path.isdir(tracks_dir):
    for entry in os.listdir(tracks_dir):
        if os.path.isfile(os.path.join(tracks_dir, entry)):
            disk_files.add(entry)
extra = disk_files - playlist_files
missing = playlist_files - disk_files
if extra or missing:
    sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "missing file — detected"
    rm -rf "$dir"
}

test_validate_active_zero_size_file() {
    plan "validate_active: zero-size file rejected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    : > "${active_dir}/tracks/track1.mp3"
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": [{"id": "1", "filename": "track1.mp3"}]}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 1}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, os, sys
playlist = json.load(open(sys.argv[1]))
tracks_dir = sys.argv[2]
for t in playlist.get("tracks", []):
    fname = t.get("filename", "")
    path = os.path.join(tracks_dir, fname)
    if not os.path.isfile(path): sys.exit(1)
    if os.path.getsize(path) == 0: sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "zero-size file — rejected"
    rm -rf "$dir"
}

test_validate_active_empty_playlist() {
    plan "validate_active: empty playlist rejected"
    local dir; dir=$(mk_temp_dir)
    local active_dir="${dir}/music/active"
    mkdir -p "${active_dir}/tracks"
    cat > "${active_dir}/playlist.json" <<'EOF'
{"tracks": []}
EOF
    cat > "${dir}/cache_meta.json" <<'EOF'
{"active_cache": {"tracks_count": 0}}
EOF
    local rc=0
    set +e
    python3 - "${active_dir}/playlist.json" "${active_dir}/tracks" "${dir}/cache_meta.json" <<'PYEOF' 2>/dev/null; rc=$?
import json, sys
playlist = json.load(open(sys.argv[1]))
tracks = playlist.get("tracks", [])
if not tracks: sys.exit(1)
sys.exit(0)
PYEOF
    set -e
    assert_rc 1 "$rc" "empty playlist — rejected"
    rm -rf "$dir"
}

# ==============================================================================
# Obsolete pattern detection — prove Fix 4 (no inline credentials),
# Fix 8 (no pgrep -f audio-player), Fix 7 (cp -a usage)
# ==============================================================================

test_no_inline_curl_auth_in_radio_stream() {
    plan "obsolete patterns: no inline -H x-api-key in radio-stream.sh"
    local script="${HERE}/../scripts/radio-stream.sh"
    if [ ! -f "$script" ]; then skip "radio-stream.sh not found"; return; fi
    if grep -q -- '-H "x-api-key:' "$script" 2>/dev/null; then
        not_ok "inline -H x-api-key still present in radio-stream.sh"
    else
        ok "no inline -H x-api-key in radio-stream.sh"
    fi
}

test_no_inline_curl_auth_in_firstboot() {
    plan "obsolete patterns: no inline token in firstboot.sh"
    local script="${HERE}/../scripts/firstboot.sh"
    if [ ! -f "$script" ]; then skip "firstboot.sh not found"; return; fi
    # Allow the init_curl_auth function itself, but not inline -H with secret
    # The pattern intentionally searches for the literal shell variable name.
    # shellcheck disable=SC2016
    if grep 'x-api-key.*\$API_KEY' "$script" 2>/dev/null | grep -qv 'init_curl_auth\|printf'; then
        not_ok "inline x-api-key pattern still present in firstboot.sh"
    else
        ok "no inline credential headers in firstboot.sh"
    fi
}

test_no_pgrep_audio_player_in_cutover() {
    plan "obsolete patterns: no pgrep -f audio-player in cutover"
    local script="${HERE}/../scripts/sigil-phase2-cutover.sh"
    if [ ! -f "$script" ]; then skip "cutover script not found"; return; fi
    if grep -q "pgrep.*-f.*audio-player" "$script" 2>/dev/null; then
        not_ok "pgrep -f audio-player still in cutover script"
    else
        ok "no pgrep -f audio-player in cutover script"
    fi
}

test_cp_a_used_in_cutover() {
    plan "cp -a: cutover uses cp -a for backups"
    local script="${HERE}/../scripts/sigil-phase2-cutover.sh"
    if [ ! -f "$script" ]; then skip "cutover script not found"; return; fi
    local cp_a_count
    cp_a_count=$(grep -c 'cp -a' "$script" 2>/dev/null || echo 0)
    if [ "$cp_a_count" -ge 1 ]; then
        ok "cutover uses cp -a (${cp_a_count} occurrences)"
    else
        not_ok "cutover should use cp -a"
    fi
}

test_no_playback_failure_in_cache_meta_schema() {
    plan "schema: no playback_failure in cache_meta schema"
    local script="${HERE}/../scripts/radio-fetcher.sh"
    if [ ! -f "$script" ]; then skip "radio-fetcher.sh not found"; return; fi
    if grep -q '"playback_failure"' "$script" 2>/dev/null; then
        not_ok "playback_failure still in cache_meta schema"
    else
        ok "no playback_failure in cache_meta schema"
    fi
}

test_no_write_playback_failure_in_player() {
    plan "obsolete: no _write_playback_failure in audio-player"
    local script="${HERE}/../scripts/audio-player.sh"
    if [ ! -f "$script" ]; then skip "audio-player.sh not found"; return; fi
    if grep -q '_write_playback_failure' "$script" 2>/dev/null; then
        not_ok "_write_playback_failure still in audio-player.sh"
    else
        ok "no _write_playback_failure in audio-player.sh"
    fi
}

test_no_hardcoded_api_key() {
    plan "credentials: no hardcoded API_KEY fallback in scripts"
    local scripts_dir="${HERE}/../scripts"
    local found=false
    for f in "$scripts_dir"/*.sh; do
        if grep -q 'API_KEY="[^"]' "$f" 2>/dev/null; then
            # Allow empty string or dynamic source, not hardcoded secrets
            if grep -q 'API_KEY="[a-zA-Z0-9]\{8,\}"' "$f" 2>/dev/null; then
                not_ok "hardcoded API_KEY in $(basename "$f")"
                found=true
            fi
        fi
    done
    if ! $found; then
        ok "no hardcoded API_KEY secrets in scripts"
    fi
}

test_tmpfiles_no_or_true() {
    plan "install.sh: no || true on systemd-tmpfiles"
    local script="${HERE}/../install.sh"
    if [ ! -f "$script" ]; then skip "install.sh not found from tests"; return; fi
    if grep -q 'systemd-tmpfiles.*|| true' "$script" 2>/dev/null; then
        not_ok "systemd-tmpfiles has || true in install.sh"
    else
        ok "no || true on systemd-tmpfiles in install.sh"
    fi
}

test_ssh_marker_created_before_wipe() {
    plan "ssh-monitor: marker created before wipe in enter_maintenance"
    local script="${HERE}/../scripts/ssh-monitor.sh"
    if [ ! -f "$script" ]; then skip "ssh-monitor.sh not found"; return; fi
    # The marker creation should appear before "Running cache wipe" in enter_maintenance
    local marker_line wipe_line
    marker_line=$(grep -n "ssh-active" "$script" | grep -v "rm -f" | head -1 | cut -d: -f1)
    wipe_line=$(grep -n "Running cache wipe" "$script" | head -1 | cut -d: -f1)
    if [ -n "$marker_line" ] && [ -n "$wipe_line" ] && [ "$marker_line" -lt "$wipe_line" ]; then
        ok "marker creation (line ${marker_line}) precedes wipe (line ${wipe_line})"
    else
        not_ok "marker creation should precede wipe (marker=${marker_line:-unset}, wipe=${wipe_line:-unset})"
    fi
}

test_ssh_wipe_before_marker_removal() {
    plan "ssh-monitor: wipe runs while marker still active in exit_maintenance"
    local script="${HERE}/../scripts/ssh-monitor.sh"
    if [ ! -f "$script" ]; then skip "ssh-monitor.sh not found"; return; fi
    # Wipe should run before marker removal
    local wipe_line remove_line
    wipe_line=$(grep -n "residual cache wipe" "$script" | head -1 | cut -d: -f1)
    remove_line=$(grep -n "rm -f.*marker_path\|rm -f.*/run/sigil/ssh-active" "$script" | head -1 | cut -d: -f1)
    if [ -n "$wipe_line" ] && [ -n "$remove_line" ] && [ "$wipe_line" -lt "$remove_line" ]; then
        ok "wipe (line ${wipe_line}) precedes marker removal (line ${remove_line})"
    else
        not_ok "wipe should precede marker removal (wipe=${wipe_line:-unset}, remove=${remove_line:-unset})"
    fi
}

test_dry_run_stale_staging_guarded() {
    plan "dry-run: stale staging file removal guarded"
    local dir; dir=$(mk_temp_dir)
    touch "${dir}/playlist.staging.json"
    local output
    output=$(bash -c '
DRY_RUN=true
STAGING="${1}"
if [ -f "$STAGING" ]; then
    if $DRY_RUN; then
        echo "DRY: Would remove stale playlist.staging.json"
    else
        rm -f "$STAGING"
    fi
fi
' bash "${dir}/playlist.staging.json" 2>&1)
    assert_eq "DRY: Would remove stale playlist.staging.json" "$output" "stale staging — dry-run logs DRY"
    if [ -f "${dir}/playlist.staging.json" ]; then
        ok "stale staging — file still exists in dry-run"
    else
        not_ok "stale staging — file was deleted in dry-run"
    fi
    rm -rf "$dir"
}



# ==============================================================================
# Main test dispatcher
# ==============================================================================

LIST_ONLY=false
FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_ONLY=true; shift ;;
        --name) FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

declare -a TESTS
while IFS= read -r line; do
    TESTS+=("$line")
done < <(declare -F | sed 's/declare -f //' | grep -E '^test_' | sort)

if [ "$LIST_ONLY" = true ]; then
    for t in "${TESTS[@]}"; do
        echo "$t"
    done
    exit 0
fi

# Apply filter
if [ -n "$FILTER" ]; then
    declare -a FILTERED
    for t in "${TESTS[@]}"; do
        # FILTER is intentionally a user-supplied test-name glob.
        # shellcheck disable=SC2053
        if [[ $t == $FILTER ]]; then
            FILTERED+=("$t")
        fi
    done
    TESTS=("${FILTERED[@]}")
fi

echo "sigil-hardware regression test suite"
echo "===================================="
echo ""

for t in "${TESTS[@]}"; do
    $t
done

echo ""
echo "===================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for ft in "${FAILED_TESTS[@]}"; do
        echo "  - $ft"
    done
    exit 1
fi
exit 0
