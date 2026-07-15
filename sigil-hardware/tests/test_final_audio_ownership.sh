#!/bin/bash
# Production-behavior regression tests for autonomous audio ownership.
# shellcheck disable=SC2016 # literal production patterns are intentional
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TEST_ROOT=$(mktemp -d /tmp/sigil-audio-ownership.XXXXXX)
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
run_test() {
    local name="$1"
    shift
    if "$@"; then ok "$name"; else not_ok "$name"; fi
}

test_panel_routes_are_non_mutating_and_status_is_canonical() {
    ROOT="$ROOT" TEST_ROOT="$TEST_ROOT" python3 <<'PYEOF'
import importlib.util
import json
import os
import pathlib
import sys
import types

root = pathlib.Path(os.environ["ROOT"])
tmp = pathlib.Path(os.environ["TEST_ROOT"])
os.environ["SIGIL_SECRET_KEY"] = "test-only-secret"

class FakeApp:
    def __init__(self, *_args, **_kwargs):
        self.secret_key = None
        self.logger = types.SimpleNamespace(warning=lambda *_args: None, error=lambda *_args: None)
        self.config = types.SimpleNamespace(update=lambda **_kwargs: None)
    def route(self, *_args, **_kwargs):
        return lambda function: function
    def add_url_rule(self, *_args, **_kwargs):
        return None
    def before_request(self, function):
        return function
    def run(self, *_args, **_kwargs):
        raise AssertionError("runtime start is not expected in tests")

flask = types.ModuleType("flask")
flask.Flask = FakeApp
flask.render_template = lambda *_args, **_kwargs: ""
flask.jsonify = lambda value=None, **kwargs: value if value is not None else kwargs
flask.request = types.SimpleNamespace(args={}, form={}, headers={}, host="localhost", endpoint="", path="/", remote_addr="local", method="GET")
flask.redirect = lambda value, **_kwargs: value
flask.Response = object
flask.session = {}
flask.url_for = lambda endpoint, **_kwargs: "/" + endpoint
sys.modules["flask"] = flask

panel_auth = types.ModuleType("panel_auth")
panel_auth.verify_panel_pin_hash = lambda _path, _pin: False
panel_auth.panel_hash_is_provisioned = lambda _path: False
sys.modules["panel_auth"] = panel_auth

config = types.ModuleType("config")
config.wifi_status = {}
sys.modules["config"] = config

identity = types.ModuleType("device_identity")
identity.load_identity = lambda: {"device_id": "TEST-DEVICE"}
sys.modules["device_identity"] = identity

calls = {"disconnect": 0}
bluetooth = types.ModuleType("bluetooth")
bluetooth.get_known_devices = lambda: []
bluetooth.get_preferred_device = lambda: ""
bluetooth.get_connected_devices = lambda: []
bluetooth.is_device_connected = lambda _mac: False
bluetooth.is_valid_mac = lambda _mac: True
bluetooth._is_mac = lambda _value: False
bluetooth._get_real_name = lambda _mac: ""
bluetooth.stream_bluetooth_scan = lambda: iter(())
bluetooth.pair_device = lambda _mac: (True, "ok")
bluetooth.connect_device = lambda _mac: (True, "ok")
def disconnect_device():
    calls["disconnect"] += 1
    return True, "ok"
bluetooth.disconnect_device = disconnect_device
bluetooth.remove_device = lambda _mac: (True, "ok")
sys.modules["bluetooth"] = bluetooth

wifi = types.ModuleType("wifi")
wifi.scan_wifi_networks = lambda: []
wifi.connect_wifi = lambda _ssid, _password: (True, "ok")
wifi.get_current_wifi = lambda: ""
sys.modules["wifi"] = wifi

spec = importlib.util.spec_from_file_location("sigil_panel_app", root / "panel/app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

playback = tmp / "playback_state.json"
mode = tmp / "audio_mode.json"
legacy = tmp / "now_playing.txt"
module._PLAYBACK_STATE_FILE = str(playback)
module._AUDIO_MODE_FILE = str(mode)
module._LEGACY_NOW_PLAYING_FILE = str(legacy)

playback.write_text(json.dumps({
    "playing": True,
    "local": {"current_track_url": "https://music.invalid/Track%20One.mp3?token=TOP_SECRET"},
    "output": {"available": True, "type": "bluetooth", "sink": "test_sink"},
}), encoding="utf-8")
mode.write_text(json.dumps({"mode": "RADIO", "last_error": None}), encoding="utf-8")
legacy.write_text("stale-legacy.mp3", encoding="utf-8")

body = module.music_status()
assert body["is_playing"] is True
assert body["track_name"] == "Track One"
assert body["track_url"] == "Track One.mp3"
assert body["route"] == "bluetooth" and body["output"] == "test_sink"
assert body["runtime_state"] == "RADIO"
assert "TOP_SECRET" not in json.dumps(body) and "https://" not in json.dumps(body)

next_body, next_status = module.music_next()
assert next_status == 409
assert next_body["success"] is False

disconnect_response = module.api_disconnect_active()
assert disconnect_response["success"] is True
assert calls["disconnect"] == 1

playback.write_text(json.dumps({"playing": False}), encoding="utf-8")
stale = module.music_status()
assert stale["is_playing"] is False

playback.write_text("{malformed", encoding="utf-8")
malformed = module.music_status()
assert malformed["is_playing"] is False
PYEOF
}

test_next_control_absent() {
    ! grep -q 'music-next-btn\|/music/next\|btn-next' \
        "$ROOT/panel/templates/index.html" "$ROOT/panel/static/js/app.js" "$ROOT/panel/static/css/style.css"
}

test_no_panel_playback_commands() {
    ! grep -Eq 'pkill|killall|systemctl.*(audio|radio-stream)|mpg123' "$ROOT/panel/app.py"
}

test_phase2_is_install_default() {
    grep -q 'PHASE2_AUDIO_SERVICES="radio-fetcher audio-manager audio-player"' "$ROOT/install.sh" \
        && grep -q 'disable radio-stream.service' "$ROOT/install.sh" \
        && grep -q 'enable "${svc}.service"' "$ROOT/install.sh" \
        && grep -q 'enable sigil-firstboot.service' "$ROOT/install.sh" \
        && ! grep -q 'systemctl .*--now' "$ROOT/install.sh" \
        && ! grep -q 'SERVICES=.*radio-stream' "$ROOT/install.sh"
}

test_service_manifest_defaults() {
    python3 - "$ROOT/manifests/services.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
assert {"radio-fetcher", "audio-manager", "audio-player"} <= set(doc["enable"])
assert "radio-stream" in doc["disable"]
assert "radio-stream" not in doc["enable"]
PYEOF
}

test_player_is_only_phase2_route_activator() {
    grep -q 'select_audio_route' "$ROOT/scripts/audio-player.sh" \
        && ! grep -q 'select_audio_route\|sigil-audio-route' "$ROOT/scripts/audio-manager.sh" \
        && ! grep -q 'select_audio_route\|sigil-audio-route' "$ROOT/scripts/radio-fetcher.sh"
}

test_manager_consumes_published_output() {
    grep -q 'output.available' "$ROOT/scripts/audio-manager.sh" \
        && grep -q 'output.type' "$ROOT/scripts/audio-manager.sh" \
        && grep -q 'output.sink' "$ROOT/scripts/audio-manager.sh"
}

test_player_publishes_route_atomically() {
    grep -q 'doc\["output"\]' "$ROOT/scripts/audio-player.sh" \
        && grep -q 'os.replace(tmp_path, out_file)' "$ROOT/scripts/audio-player.sh"
}

test_legacy_has_no_global_kill() {
    ! grep -Eq '\b(pkill|killall)\b' \
        "$ROOT/scripts/radio-stream.sh" \
        "$ROOT/services/radio-stream.service" \
        "$ROOT/scripts/sigil-phase2-cutover.sh" \
        "$ROOT/scripts/sigil-phase2-rollback.sh"
}

test_legacy_service_owns_cgroup() {
    grep -qx 'KillMode=control-group' "$ROOT/services/radio-stream.service" \
        && grep -qx 'ExecStart=/usr/local/bin/radio-stream.sh' "$ROOT/services/radio-stream.service"
}

test_player_kills_only_owned_child() {
    ! grep -Eq '\b(pkill|killall)\b' "$ROOT/scripts/audio-player.sh" \
        && grep -q 'kill "\$MPG123_PID"' "$ROOT/scripts/audio-player.sh"
}

test_automatic_progression_remains() {
    grep -q 'track_num=$((track_num + 1))' "$ROOT/scripts/audio-player.sh" \
        && grep -q 'TRACK_INDEX=$track_num' "$ROOT/scripts/audio-player.sh" \
        && grep -q 'while IFS= read -r track_json' "$ROOT/scripts/audio-player.sh"
}

test_no_media_controls_introduced() {
    ! grep -Eqi 'id="music-(play|pause|next|previous|prev|volume)(-btn)?"|/music/(play|pause|next|previous|prev)' \
        "$ROOT/panel/templates/index.html" "$ROOT/panel/static/js/app.js"
}

test_panel_sudoers_has_no_audio_service_control() {
    ! grep -Eq 'radio-stream|audio-manager|audio-player|mpg123' "$ROOT/conf/sigil-network.sudoers"
}

run_test "panel routes are non-mutating and status is canonical" test_panel_routes_are_non_mutating_and_status_is_canonical
run_test "Next control is absent from the technician UI" test_next_control_absent
run_test "panel contains no playback process or service commands" test_no_panel_playback_commands
run_test "image preparation enables Phase 2 without starting chroot services" test_phase2_is_install_default
run_test "service manifest declares Phase 2 production defaults" test_service_manifest_defaults
run_test "audio-player is the only Phase 2 route activator" test_player_is_only_phase2_route_activator
run_test "audio-manager consumes player-published output" test_manager_consumes_published_output
run_test "audio-player publishes route state atomically" test_player_publishes_route_atomically
run_test "legacy rollback contains no global process kill" test_legacy_has_no_global_kill
run_test "legacy rollback process tree is systemd-owned" test_legacy_service_owns_cgroup
run_test "audio-player signals only its owned decoder child" test_player_kills_only_owned_child
run_test "automatic playlist progression remains present" test_automatic_progression_remains
run_test "no end-user media controls are present" test_no_media_controls_introduced
run_test "panel sudoers grants no audio control" test_panel_sudoers_has_no_audio_service_control

printf '\nAudio ownership: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
