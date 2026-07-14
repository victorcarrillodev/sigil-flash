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
`capabilities`. `device_id` is the non-zero CPU serial, then the first 16
characters of a non-empty machine-id, then `sigil-unknown`. Missing
manufacturing metadata, especially `model_version`, fails clearly. There is no
implicit legacy migration.

The unique API token is separate at
`/etc/sigil/secrets/device-api-key` (`root:sigil`, mode `0640`). Registration
uses `POST /api/devices/register` with `x-api-key`; its body is the full
identity plus `_schema_version: "1.0"`. Playlist and geolocation requests use
the bound `device_id` in their existing path and do not resend or overwrite
manufacturing identity or capabilities.

The current flasher and Tauri integration remain validation/dry-run only. They
prove provision transfer to flasher-rs but cannot inject `device.conf` into a
physical microSD until privileged image writing, partition mounting, and image
injection are implemented.
