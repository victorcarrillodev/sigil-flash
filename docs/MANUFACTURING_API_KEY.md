# Manufacturing enrollment key

SIGIL Flash reads the one-use enrollment key from the local, Git-ignored file:

```text
artifacts/secrets/enrollment-key
```

The file must be owned by the user running SIGIL Flash, be a regular
non-symlink file, use mode `0600`, contain 8–256 printable ASCII characters,
and have at most one final newline. The enrollment key must be unique to the
target device and must never be reused.

During a real flash the value travels inside the mode-`0600` private
manufacturing configuration. The elevated image-preparation process consumes
and removes that temporary configuration, writes the enrollment key into the
mounted image as `/etc/sigil/secrets/enrollment-key` with mode `0600`. Firstboot
exchanges it for the permanent server token, stores that token as
`/etc/sigil/secrets/device-api-key`, and deletes the enrollment key. Neither
credential is included in the SIGIL payload, provision JSON, command-line
arguments, logs, or Git.

`conf/audio.conf` contains only the non-secret server URL and selects protected
`x-api-key` header authentication. `radio-fetcher`, `audio-manager`, and the
audio player create short-lived mode-`0600` curl configuration files so the
credential is not exposed through process arguments or download URLs.

For each clean flash, replace `artifacts/secrets/enrollment-key` with the
server-generated one-use key for that device, restore mode `0600`, validate,
and flash. Never reuse an enrollment key or place a permanent token in this
workspace.
