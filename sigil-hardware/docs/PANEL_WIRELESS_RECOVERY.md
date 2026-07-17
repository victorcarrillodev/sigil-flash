# SIGIL panel wireless recovery contract

## WiFi

`SIGIL_WIFI_INTERFACE` is the only interface setting and defaults to `wlan0` in
`/etc/sigil/wifi-fallback.conf`. The panel and systemd service read that file;
privileged scan and power-save operations run through `wifi-fallback.sh`, which
also reads the same root-owned file after `sudo` removes caller environment.

The browser uses a two-request handoff. The first request validates and prepares
the exact credential and returns HTTP 202 without changing radio ownership. A
second CSRF-protected commit proves the browser received that response; only the
commit starts the AP-to-client transition. The browser does not poll the old AP
after commit.

`wifi-fallback.sh` checks state every 30 seconds. Four confirmed link failures
are required before AP recovery. While AP is active, the first known-profile
retry is after 120 seconds; failed retries use persisted exponential backoff up
to 1800 seconds. Two successful external probes stabilize recovered Internet
state. Saved profiles are retained across temporary failures. Only a newly
created, never-successful panel profile is removed when its initial attempt
fails.

## Bluetooth

`preferred_bt.txt` changes only after a selected speaker has connected and its
A2DP route is usable. The daemon checks a healthy preferred connection every 15
seconds. A failed recovery waits 15 seconds, then doubles the delay after each
failed cycle up to 300 seconds. A successful A2DP recovery resets the delay to
15 seconds.

Automatic recovery never blocks, untrusts, removes, adopts, or disconnects an
unrelated device. Selecting a different speaker disconnects only the previous
preferred speaker after the new A2DP route is usable; the previous pairing and
trust remain intact. Only an explicit Remove request performs untrust and BlueZ
removal. Explicit Disconnect clears the preference so the daemon does not
immediately undo the user's action.
