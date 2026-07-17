# Manufacturing API key

SIGIL Flash reads the device API key from the local, Git-ignored file:

```text
artifacts/secrets/device-api-key
```

The file must be owned by the user running SIGIL Flash, be a regular
non-symlink file, use mode `0600`, contain 8–256 printable ASCII characters,
and have at most one final newline.

During a real flash the value travels inside the mode-`0600` private
manufacturing configuration. The elevated image-preparation process consumes
and removes that temporary configuration, writes the key into the mounted
image as `/etc/sigil/secrets/device-api-key`, and `install.sh` assigns
`root:sigil` ownership and mode `0640`. The key is not included in the SIGIL
payload, provision JSON, command-line arguments, logs, or Git.

`conf/audio.conf` contains only the non-secret server URL and selects protected
`x-api-key` header authentication. `radio-fetcher`, `audio-manager`, and the
audio player create short-lived mode-`0600` curl configuration files so the
credential is not exposed through process arguments or download URLs.

To rotate from a test key to the production key, replace only the contents of
`artifacts/secrets/device-api-key`, restore mode `0600`, validate, and perform a
new clean flash. Existing cards retain the key that was injected into their
image.
