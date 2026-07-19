#!/bin/bash
# Persistent logging and sanitized HTTP phase diagnostics contract.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/sigil-persistent-diagnostics.XXXXXX)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

check() {
    local label="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$label"
    fi
}

JOURNAL="$ROOT/conf/90-sigil-persistent-journal.conf"
check "journal storage is persistent" grep -qxF 'Storage=persistent' "$JOURNAL"
check "journal is capped at 64 MiB" grep -qxF 'SystemMaxUse=64M' "$JOURNAL"
check "journal keeps free space" grep -qxF 'SystemKeepFree=128M' "$JOURNAL"
check "journal retention is bounded" grep -qxF 'MaxRetentionSec=14day' "$JOURNAL"
check "legacy logs rotate daily and by size" \
    sh -c "grep -qxF '    daily' '$ROOT/conf/sigil-logrotate' && grep -qxF '    size 1M' '$ROOT/conf/sigil-logrotate'"
check "WiFi service logs stdout and stderr to journal" \
    sh -c "grep -qxF 'StandardOutput=journal' '$ROOT/services/sigil-wifi-control.service' && grep -qxF 'StandardError=journal' '$ROOT/services/sigil-wifi-control.service'"
check "payload selects persistent diagnostics files" \
    sh -c "grep -qxF 'conf/90-sigil-persistent-journal.conf' '$ROOT/manifests/flasher-payload-files.txt' && grep -qxF 'conf/sigil-logrotate' '$ROOT/manifests/flasher-payload-files.txt'"
check "WiFi control behavioral diagnostics tests" \
    python3 -m unittest "$ROOT/tests/test_wifi_control.py"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
set -uo pipefail
output=""
while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$MOCK_CURL_ARGS"
    case "$1" in
        --output) shift; output="$1" ;;
        --connect-timeout|--max-time|--write-out|--config|--interface) shift ;;
    esac
    shift
done
if [ "${MOCK_CURL_RC:-0}" -ne 0 ]; then
    exit "$MOCK_CURL_RC"
fi
printf '%s' "${MOCK_CURL_BODY:-fixture}" > "$output"
printf '%s' "${MOCK_HTTP_STATUS:-200}"
EOF
chmod +x "$TMP/bin/curl"

# shellcheck source=../scripts/radio-fetcher.sh
source "$ROOT/scripts/radio-fetcher.sh"
PATH="$TMP/bin:$PATH"
LOG="$TMP/fetcher.log"
OPERATION_ID="synthetic-operation"
SERVER_URL="https://synthetic.invalid"
CONNECT_TIMEOUT_SECONDS=1
PLAYLIST_FETCH_TIMEOUT_SECONDS=1
DOWNLOAD_TIMEOUT_SECONDS=1
CURL_CONFIG="$TMP/curl.conf"
printf '%s\n' 'header = "x-api-key: synthetic-redacted"' > "$CURL_CONFIG"
chmod 600 "$CURL_CONFIG"
export PATH LOG OPERATION_ID MOCK_CURL_ARGS="$TMP/curl.args"

MOCK_CURL_RC=6 MOCK_HTTP_STATUS=000 MOCK_CURL_BODY=""
export MOCK_CURL_RC MOCK_HTTP_STATUS MOCK_CURL_BODY
if ! http_get_to_file playlist_request "$SERVER_URL/playlist" "$TMP/dns.body" 1; then :; fi
check "DNS transport failure has a stable error identifier" \
    grep -q 'error_id=DNS_RESOLUTION_FAILED.*curl_exit=6.*http_status=000' "$LOG"

: > "$LOG"
: > "$MOCK_CURL_ARGS"
MOCK_CURL_RC=0 MOCK_HTTP_STATUS=401 MOCK_CURL_BODY='{"error":"redacted"}'
export MOCK_CURL_RC MOCK_HTTP_STATUS MOCK_CURL_BODY
if ! http_get_to_file playlist_request "$SERVER_URL/playlist" "$TMP/auth.body" 1; then :; fi
check "API authentication failure is distinct from Internet failure" \
    grep -q 'error_id=API_AUTH_FAILED.*http_status=401' "$LOG"

: > "$LOG"
: > "$MOCK_CURL_ARGS"
MOCK_HTTP_STATUS=200 MOCK_CURL_BODY='fixture-audio'
export MOCK_HTTP_STATUS MOCK_CURL_BODY
check "synthetic audio request succeeds" \
    http_get_to_file audio_request "$SERVER_URL/audio" "$TMP/audio.body" 1
check "audio request used protected curl config" \
    grep -qxF -- '--config' "$MOCK_CURL_ARGS"
check "audio response is validated as nonempty fixture" \
    sh -c "test -s '$TMP/audio.body' && test \"\$(cat '$TMP/audio.body')\" = fixture-audio"
check "secret header content is absent from argv and logs" \
    sh -c "! grep -Fq synthetic-redacted '$MOCK_CURL_ARGS' && ! grep -Fq synthetic-redacted '$LOG'"

printf '\nPersistent diagnostics: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
