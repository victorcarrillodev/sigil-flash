# Provisioning account for SIGIL Flash

This document defines the production manufacturing flow for SIGIL Flash. It
uses a dedicated `FACTORY` account only to mint one-use enrollment keys. It is
not a dashboard user and it is never installed on a Raspberry Pi.

## Security model

```text
GNOME Keyring on the manufacturing workstation
  -> FACTORY password
  -> POST /api/login as "fabrica"
  -> POST /api/admin/enrollment-keys
  -> one enrollment key, for one image only
  -> Raspberry first boot: POST /api/devices/bootstrap
  -> permanent token bound to that device
```

The enrollment key is temporary and single-use. The permanent device token is
different for every Raspberry and is the only credential the device uses for
playlist, media, health, registration, and geolocation requests.

Never place the FACTORY password, an enrollment key, or a permanent device
token in Git, the reusable public payload, the base manufacturing image, shell
command arguments, logs, screenshots, or support chats. SIGIL Flash may inject
one newly issued enrollment key into an individualized output image through its
private mode-0600 manufacturing configuration.

## Backend prerequisite

Deploy the `sigil-system` change that introduces the `FACTORY` Prisma role and
the `20260730230000_factory_role` migration. The deployment environment must
set these non-secret values:

```text
FACTORY_USERNAME=fabrica
FACTORY_USER_EMAIL=<dedicated non-human factory email>
```

`FACTORY_USER_EMAIL` must not refer to an existing person or an `ADMIN` account.
The server starts with `prisma migrate deploy`, so a normal `docker compose up
-d --build` applies the role migration before the API serves requests.
Enrollment keys expire after one hour by default (`ENROLLMENT_TTL_HOURS=1`);
only extend that value deliberately for an exceptional manufacturing workflow.

## Create or repair the dedicated account

The backend contains `factory:provision`. It creates the configured account as
active `FACTORY`, resets a pre-existing `FACTORY` password, and refuses to
convert an existing account of any other role.

Generate the password once on the manufacturing workstation, store it in the
local Keyring, and send it to the server through SSH standard input. Do not use
a literal password in these commands:

```bash
factory_password="$(openssl rand -base64 48 | tr -d '\n')"
printf %s "$factory_password" | secret-tool store \
  --label='SIGIL Factory Provisioning' \
  service sigil-flash username fabrica
printf %s "$factory_password" | ssh <deployment-host> \
  'cd <sigil-system-dir> && docker compose exec -T backend bun dist/scripts/provision-factory-user.js'
unset factory_password
```

The command accepts the password only on standard input, requires 24--512
printable ASCII characters, stores only an scrypt hash and salt in PostgreSQL,
and prints no credential. Run it only after the deployment has started
successfully.

If the keyring operation succeeds but the server command fails, delete the
Keyring item or repeat the server command with the same secret before flashing
any device. Do not silently create a second password.

## Install the Keyring command

SIGIL Flash invokes `secret-tool`; it does not keep the FACTORY password in a
configuration file. On Debian or Ubuntu workstations install it once:

```bash
sudo apt-get update
sudo apt-get install -y libsecret-tools gnome-keyring
```

The graphical login session of the user running SIGIL Flash must have an
unlocked GNOME Keyring. Verify presence without printing the secret:

```bash
secret-tool lookup service sigil-flash username fabrica >/dev/null \
  && echo 'Factory credential present' \
  || echo 'Factory credential missing'
```

Do not replace the Keyring with a plaintext `.env`, `config.toml`, shell
history entry, or repository file. If `secret-tool` is unavailable, SIGIL Flash
must fail with its explicit dependency error; install the package instead of
falling back to a file.

## Configure SIGIL Flash

Set only the non-secret server URL in either location:

```text
SIGIL_SERVER_URL=https://<sigil-api-host>
```

or:

```toml
# ~/.config/sigil-flash/config.toml
server_url = "https://<sigil-api-host>"
```

At flash time SIGIL Flash reads the Keyring item using exactly:

```text
service=sigil-flash
username=fabrica
```

It logs in, receives a short-lived JWT, requests exactly one enrollment key,
and injects that key through its private mode-0600 manufacturing configuration.
The key is not part of the public payload or command arguments.

The same `server_url` is injected into the individualized image as the
`SERVER_URL` value in `/etc/sigil/audio.conf`. It is therefore the single API
base for enrollment, registration, playlist, protected media, state, and Wi-Fi
geolocation. Do not rely on the reusable payload's default URL or configure a
terminal/web-console hostname unless it proxies `/api/` to the SIGIL backend.

## Raspberry lifecycle

1. The image contains the one-use enrollment key at
   `/etc/sigil/secrets/enrollment-key` with mode `0600`.
2. First boot exchanges it at `/api/devices/bootstrap` for a permanent device
   token. The server stores only HMACs, marks the enrollment record with
   `usedAt` and `usedByDeviceId`, and rejects use by a different device.
3. First boot writes the token to a temporary restricted file, fsyncs it,
   atomically renames it into place, fsyncs the secrets directory, and verifies
   that it can be read back.
4. Only then does first boot remove the enrollment key and fsync the secrets
   directory again.
5. If power fails after the server commits but before the local write completes,
   the same device can retry bootstrap with the same enrollment key and receive
   the same deterministic permanent token. If power fails after the token is
   durable but before cleanup, the next boot removes the leftover enrollment key
   without changing the device token.
6. The permanent token is stored locally with restricted permissions.
7. The Raspberry uses `x-api-key` with that permanent token only for its own
   device protocol: registration, playlist, protected media, state, and Wi-Fi
   geolocation.

The Raspberry never receives the FACTORY password or JWT. A map/geolocation
report is therefore authorized by the device token, not by manufacturing
credentials.

## Pre-flight checklist

- The server runs the migration and has a dedicated active `FACTORY` account.
- `FACTORY_USER_EMAIL` targets that account, not a human account.
- The manufacturing workstation has `secret-tool` and an unlocked Keyring.
- The Keyring lookup succeeds without printing its value.
- `SIGIL_SERVER_URL` points to the intended HTTPS API.
- The first boot can reach `/api/devices/bootstrap`.
- Each flash requests a new enrollment key; never reuse a key or permanent
  device token.
- A failed image write never authorizes another Raspberry: discard the output
  image and let the unused enrollment key expire instead of reusing it.

## Legacy manual flow

`MANUFACTURING_API_KEY.md` documents the older manual file-injection path.
For the current production flow use this document and let SIGIL Flash obtain a
fresh enrollment key automatically. Do not combine the two flows.
