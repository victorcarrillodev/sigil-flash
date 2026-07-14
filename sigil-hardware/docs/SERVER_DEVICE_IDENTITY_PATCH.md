# Required server patch: existing device registration route

The backend repository is not present in this workspace. The client continues
to use the evidenced existing route `POST /api/devices/register`; no endpoint is
invented. Apply the following behavior to that route in the backend, adapting
only the repository's database-access names.

## Database migration

```sql
ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS runtime_device_id varchar(128),
  ADD COLUMN IF NOT EXISTS serial_number varchar(64),
  ADD COLUMN IF NOT EXISTS model varchar(64),
  ADD COLUMN IF NOT EXISTS model_version varchar(32),
  ADD COLUMN IF NOT EXISTS batch varchar(64),
  ADD COLUMN IF NOT EXISTS provision_schema_version varchar(16),
  ADD COLUMN IF NOT EXISTS capabilities jsonb;

CREATE UNIQUE INDEX IF NOT EXISTS devices_runtime_device_id_unique
  ON devices(runtime_device_id) WHERE runtime_device_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS devices_serial_number_unique
  ON devices(serial_number) WHERE serial_number IS NOT NULL;

-- One pre-created credential row belongs to exactly one device record.
-- token_hash contains HMAC-SHA-256(token, server pepper), never plaintext.
CREATE TABLE IF NOT EXISTS device_api_credentials (
  device_id bigint PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  token_hash char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
```

Delete any plaintext-token column only after migrating every credential to a
hash. Never try to hash an unknown existing plaintext token during a request.

## Express/TypeScript handler

```ts
import crypto from "node:crypto";
import type { Request, Response } from "express";
import type { Pool, PoolClient } from "pg";

const SAFE = /^[A-Za-z0-9][A-Za-z0-9 ._+:/-]{0,63}$/;
const SERIAL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ALLOWED_PRODUCTS = new Set(["Sigil-Streamer\u0000v1"]);
const BODY_KEYS = new Set([
  "_schema_version", "device_id", "serial_number", "model",
  "model_version", "batch", "capabilities",
]);

type IdentityBody = {
  _schema_version: "1.0";
  device_id: string;
  serial_number: string;
  model: string;
  model_version: string;
  batch: string;
  capabilities: { i2s_dac: boolean };
};

function tokenHash(raw: string): string {
  const pepper = process.env.DEVICE_TOKEN_PEPPER;
  if (!pepper) throw new Error("DEVICE_TOKEN_PEPPER is not configured");
  return crypto.createHmac("sha256", pepper).update(raw, "utf8").digest("hex");
}

function parseIdentity(value: unknown): IdentityBody | string {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "body must be an object";
  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);
  const unknown = keys.filter((key) => !BODY_KEYS.has(key));
  const missing = [...BODY_KEYS].filter((key) => !(key in body));
  if (unknown.length || missing.length) return `strict schema violation; unknown=${unknown.join(",")}; missing=${missing.join(",")}`;
  if (body._schema_version !== "1.0") return "_schema_version must be 1.0";
  for (const field of ["device_id", "serial_number", "model", "model_version", "batch"] as const) {
    if (typeof body[field] !== "string" || !SAFE.test(body[field] as string)) return `${field} is invalid`;
  }
  if (!SERIAL.test(body.serial_number as string)) return "serial_number is invalid";
  if ((body.model_version as string).length > 32) return "model_version is too long";
  const capabilities = body.capabilities as Record<string, unknown> | null;
  if (!capabilities || Array.isArray(capabilities)
      || Object.keys(capabilities).length !== 1
      || typeof capabilities.i2s_dac !== "boolean") {
    return "capabilities must contain exactly boolean i2s_dac";
  }
  if (!ALLOWED_PRODUCTS.has(`${body.model}\u0000${body.model_version}`)) return "model/model_version is not allowed";
  return body as IdentityBody;
}

export function registerDevice(pool: Pool) {
  return async (req: Request, res: Response): Promise<void> => {
    // Do not log req.headers, req, curl reproductions, or this raw value.
    const rawToken = req.get("x-api-key");
    if (!rawToken) { res.status(401).json({ error: "missing x-api-key" }); return; }
    if (rawToken.length < 32 || rawToken.length > 256) { res.status(401).json({ error: "invalid x-api-key" }); return; }

    const identity = parseIdentity(req.body);
    if (typeof identity === "string") { res.status(400).json({ error: identity }); return; }
    if (req.params.device_id && req.params.device_id !== identity.device_id) {
      res.status(400).json({ error: "path device_id and body device_id differ" }); return;
    }

    let client: PoolClient | undefined;
    try {
      client = await pool.connect();
      await client.query("BEGIN");
      const credential = await client.query(
        `SELECT d.id, d.runtime_device_id, d.serial_number, d.model, d.model_version
           FROM device_api_credentials c JOIN devices d ON d.id = c.device_id
          WHERE c.token_hash = $1 AND c.revoked_at IS NULL FOR UPDATE`,
        [tokenHash(rawToken)],
      );
      if (credential.rowCount !== 1) {
        await client.query("ROLLBACK");
        res.status(401).json({ error: "invalid device credential" }); return;
      }
      const current = credential.rows[0];
      if (current.runtime_device_id && current.runtime_device_id !== identity.device_id) {
        await client.query("ROLLBACK");
        res.status(403).json({ error: "credential belongs to a different runtime device" }); return;
      }
      for (const field of ["serial_number", "model", "model_version"] as const) {
        if (current[field] && current[field] !== identity[field]) {
          await client.query("ROLLBACK");
          res.status(409).json({ error: `${field} conflicts with the bound identity` }); return;
        }
      }
      const duplicate = await client.query(
        "SELECT id FROM devices WHERE serial_number = $1 AND id <> $2",
        [identity.serial_number, current.id],
      );
      if (duplicate.rowCount) {
        await client.query("ROLLBACK");
        res.status(409).json({ error: "serial_number is already registered" }); return;
      }

      // COALESCE prevents later requests from silently changing identity.
      // Capabilities are written only on first binding, never by normal traffic.
      await client.query(
        `UPDATE devices SET
           runtime_device_id = COALESCE(runtime_device_id, $1),
           serial_number = COALESCE(serial_number, $2),
           model = COALESCE(model, $3),
           model_version = COALESCE(model_version, $4),
           batch = COALESCE(batch, $5),
           provision_schema_version = COALESCE(provision_schema_version, $6),
           capabilities = COALESCE(capabilities, $7::jsonb)
         WHERE id = $8`,
        [identity.device_id, identity.serial_number, identity.model,
         identity.model_version, identity.batch, identity._schema_version,
         JSON.stringify(identity.capabilities), current.id],
      );
      await client.query("COMMIT");
      res.status(200).json({ ok: true, registered: true });
    } catch (error: any) {
      if (client) await client.query("ROLLBACK").catch(() => undefined);
      if (error?.code === "23505") {
        res.status(409).json({ error: "device_id or serial_number already registered" });
      } else {
        res.status(500).json({ error: "registration failed" });
      }
    } finally {
      client?.release();
    }
  };
}
```

Wire this handler to the existing router only:

```ts
router.post("/api/devices/register", express.json({ limit: "4kb", strict: true }), registerDevice(pool));
```

Normal playlist, geolocation, heartbeat, and health handlers must authenticate
the same token hash and compare the path `device_id` with the bound
`runtime_device_id`. They must not accept or update manufacturing identity or
capabilities. Missing key is `401`; a valid key bound to another device is
`403`; malformed/path-body disagreement is `400`; uniqueness or immutable
identity conflict is `409`.

## Required backend tests

Add integration tests which pre-create two fake device rows and hashed fake
tokens, then assert:

1. first registration binds all fields and stores only the HMAC hash;
2. missing/invalid `x-api-key` returns `401`;
3. path/body disagreement returns `400` on routes that have both;
4. token bound to another `device_id` returns `403`;
5. duplicate `serial_number` returns `409`;
6. later model or `model_version` mismatch returns `409` and leaves the row unchanged;
7. string `"true"` for `i2s_dac`, unknown fields, or secret fields return `400`;
8. captured application logs never contain the fake token;
9. normal playlist/geolocation/heartbeat requests cannot overwrite capabilities.

These backend tests cannot be executed until the actual server repository and
its schema/test harness are available.
