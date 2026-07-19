# SIGIL device identity contract

Manufacturing input is strict JSON containing only `_schema_version`,
`serial_number`, `model`, `model_version`, `batch`, and
`capabilities.i2s_dac`. All fields are required; the capability is a JSON
boolean. Tokens and other secret fields are rejected.

First boot atomically persists manufacturing metadata to
`/etc/sigil/device.conf` as `root:sigil` mode `0640`:

```text
SIGIL_SERIAL_NUMBER="SIGIL-000001"
SIGIL_MODEL="Sigil-Streamer"
SIGIL_MODEL_VERSION="v1"
SIGIL_BATCH="2026-01"
```

The declared I2S capability is stored only as
`SIGIL_I2S_DAC_PRESENT=0|1` in `/etc/sigil/audio.conf`. An existing valid value
is preserved when there is no new provision. Otherwise only the confirmed
legacy `Sigil-Streamer`/`v1` mapping can resolve true; invalid or absent values
fail closed to false. ALSA and PulseAudio are never treated as physical
presence detection.

`panel/device_identity.py` is the canonical runtime parser. It returns
`device_id`, `serial_number`, `model`, `model_version`, `batch`, and
`capabilities`. `device_id` is the permanent lowercase `wlan0` MAC, then the
non-zero CPU serial, then the first 16 characters of a non-empty machine-id,
then `sigil-unknown`. Missing
manufacturing metadata, especially `model_version`, fails clearly. There is no
implicit legacy migration.

Manufacturing injects a one-use enrollment key at
`/etc/sigil/secrets/enrollment-key` (root-only, mode `0600`). Firstboot sends
it to `POST /api/devices/provision`, atomically stores the returned permanent
token at `/etc/sigil/secrets/device-api-key` (`root:sigil`, mode `0640`), and
deletes the enrollment key. Registration then uses `POST /api/devices/register`
with `x-api-key`; its body is the full
identity plus `_schema_version: "1.0"`. Playlist and geolocation requests use
the bound `device_id` in their existing path and do not resend or overwrite
manufacturing identity or capabilities.

The flasher injects the per-device enrollment key during physical image
preparation. The permanent API token is never supplied by the operator and is
created only by firstboot after network availability.
