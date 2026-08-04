#!/bin/bash
# Behavioral tests for the SSE wake path: radio-fetcher's FIFO-based
# sleep_or_wake and sigil-event-listener's SSE line handling. Production
# functions are sourced and invoked directly by this harness.
# shellcheck disable=SC1091,SC2034,SC2317

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
    local name="$1"
    local fn="$2"
    if ( "$fn" ); then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL %s\n' "$name"
    fi
}

test_sleep_or_wake_returns_early_on_fifo_write() {
    local tmp elapsed_start elapsed_end
    tmp=$(mktemp -d /tmp/sigil-wake.XXXXXX)
    ( source "${ROOT}/scripts/radio-fetcher.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/playlist-wake"
      LOG="$tmp/fetcher.log"
      LOG_DIR="$tmp/log"
      MUSIC_STAGING="$tmp/staging"
      MUSIC_ARCHIVE="$tmp/archive"
      ensure_dirs

      # Un escritor de fondo simula sigil-event-listener.sh anunciando el evento
      # poco después de que radio-fetcher empiece a esperar.
      ( sleep 0.2; printf 'playlist_changed\n' > "$WAKE_FIFO" ) &
      local writer_pid=$!

      elapsed_start=$(date +%s%N)
      sleep_or_wake 30
      elapsed_end=$(date +%s%N)
      wait "$writer_pid" 2>/dev/null || true

      elapsed_ms=$(( (elapsed_end - elapsed_start) / 1000000 ))
      # Debe cortar bien antes del timeout de 30s configurado.
      [ "$elapsed_ms" -lt 5000 ]
      grep -q 'Sincronización adelantada.*playlist_changed' "$LOG"
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_sleep_or_wake_honors_timeout_without_a_writer() {
    local tmp elapsed_start elapsed_end
    tmp=$(mktemp -d /tmp/sigil-wake.XXXXXX)
    ( source "${ROOT}/scripts/radio-fetcher.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/playlist-wake"
      LOG="$tmp/fetcher.log"
      LOG_DIR="$tmp/log"
      MUSIC_STAGING="$tmp/staging"
      MUSIC_ARCHIVE="$tmp/archive"
      ensure_dirs

      elapsed_start=$(date +%s%N)
      sleep_or_wake 1
      elapsed_end=$(date +%s%N)

      elapsed_ms=$(( (elapsed_end - elapsed_start) / 1000000 ))
      # Sin escritor, debe agotar el timeout completo (con margen de scheduler).
      [ "$elapsed_ms" -ge 900 ]
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_sleep_or_wake_falls_back_to_plain_sleep_without_fifo() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-wake.XXXXXX)
    ( source "${ROOT}/scripts/radio-fetcher.sh"
      WAKE_FIFO="$tmp/does-not-exist"
      LOG="$tmp/fetcher.log"
      touch "$LOG"

      local start end
      start=$(date +%s%N)
      sleep_or_wake 1
      end=$(date +%s%N)
      elapsed_ms=$(( (end - start) / 1000000 ))
      [ "$elapsed_ms" -ge 900 ]
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_ensure_dirs_creates_the_fifo() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-wake.XXXXXX)
    ( source "${ROOT}/scripts/radio-fetcher.sh"
      RUN_SIGIL_DIR="$tmp/run"
      WAKE_FIFO="$tmp/run/playlist-wake"
      LOG="$tmp/fetcher.log"
      LOG_DIR="$tmp/log"
      MUSIC_STAGING="$tmp/staging"
      MUSIC_ARCHIVE="$tmp/archive"
      ensure_dirs
      [ -p "$WAKE_FIFO" ]
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_ensure_dirs_is_idempotent_when_fifo_already_exists() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-wake.XXXXXX)
    ( source "${ROOT}/scripts/radio-fetcher.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/playlist-wake"
      LOG="$tmp/fetcher.log"
      LOG_DIR="$tmp/log"
      MUSIC_STAGING="$tmp/staging"
      MUSIC_ARCHIVE="$tmp/archive"
      ensure_dirs
      ensure_dirs
      [ -p "$WAKE_FIFO" ]
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_listener_wakes_fetcher_on_playlist_changed_event() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-listener.XXXXXX)
    ( source "${ROOT}/scripts/sigil-event-listener.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/playlist-wake"
      LOG="$tmp/listener.log"
      touch "$LOG"
      mkfifo -m 0660 "$WAKE_FIFO"

      # El lector va en segundo plano: escribir en un FIFO sin lector bloquearía.
      ( exec 9<"$WAKE_FIFO"; read -r -t 2 -u 9 line; printf '%s' "$line" > "$tmp/received" ) &
      local reader_pid=$!
      sleep 0.1

      handle_sse_line 'event: playlist_changed'
      wait "$reader_pid"

      [ "$(cat "$tmp/received")" = "playlist_changed" ]
      grep -q 'anuncia un cambio de playlist' "$LOG"
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_listener_ignores_heartbeat_and_unknown_lines() {
    local tmp
    tmp=$(mktemp -d /tmp/sigil-listener.XXXXXX)
    ( source "${ROOT}/scripts/sigil-event-listener.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/playlist-wake"
      LOG="$tmp/listener.log"
      touch "$LOG"
      mkfifo -m 0660 "$WAKE_FIFO"
      # Lectura-escritura (`<>`), no sólo lectura (`<`): abrir un FIFO sólo para
      # lectura bloquea hasta que aparezca un escritor, y este test no tiene
      # ninguno. `<>` no bloquea y de paso deja el extremo de lectura abierto
      # sin consumir — si el latido o una línea desconocida escribieran al
      # FIFO, quedarían pendientes en el buffer en vez de perderse en silencio.
      exec 9<>"$WAKE_FIFO"

      handle_sse_line 'event: heartbeat'
      handle_sse_line 'data: {"unrelated":true}'
      handle_sse_line ''
      timeout 2 true

      grep -q 'Latido recibido' "$LOG"
      ! grep -q 'anuncia un cambio' "$LOG"
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

test_listener_wake_is_a_noop_without_a_reader() {
    # wake_fetcher no debe colgar el listener si radio-fetcher no está
    # escuchando (p. ej. durante un reinicio del servicio).
    local tmp
    tmp=$(mktemp -d /tmp/sigil-listener.XXXXXX)
    ( source "${ROOT}/scripts/sigil-event-listener.sh"
      RUN_SIGIL_DIR="$tmp"
      WAKE_FIFO="$tmp/does-not-exist"
      LOG="$tmp/listener.log"
      touch "$LOG"

      timeout 2 bash -c "$(declare -f wake_fetcher log); WAKE_FIFO='$WAKE_FIFO' LOG='$LOG' wake_fetcher playlist_changed"
    )
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

printf '%s\n' '=== Final event wake tests ==='
run_test "sleep_or_wake returns early when the listener writes to the FIFO" test_sleep_or_wake_returns_early_on_fifo_write
run_test "sleep_or_wake honors the full timeout without a writer" test_sleep_or_wake_honors_timeout_without_a_writer
run_test "sleep_or_wake falls back to plain sleep when the FIFO is missing" test_sleep_or_wake_falls_back_to_plain_sleep_without_fifo
run_test "ensure_dirs creates the wake FIFO" test_ensure_dirs_creates_the_fifo
run_test "ensure_dirs is idempotent when the FIFO already exists" test_ensure_dirs_is_idempotent_when_fifo_already_exists
run_test "listener wakes the fetcher on a playlist_changed SSE event" test_listener_wakes_fetcher_on_playlist_changed_event
run_test "listener ignores heartbeat and unrelated SSE lines" test_listener_ignores_heartbeat_and_unknown_lines
run_test "listener's wake is a no-op when no one is listening" test_listener_wake_is_a_noop_without_a_reader

printf '\nEvent wake: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' 'Failed tests:'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
