# Flujo de Credenciales y Autenticación en SIGIL Flash

```
Keyring del SO del PC de fabricación (secret-tool / libsecret)
  └─ Contraseña de la cuenta de fábrica dedicada
       ├─ POST /api/login  →  token de sesión de vida corta
       ├─ POST /api/admin/enrollment-keys  →  credencial de UN SOLO USO,
       │     opcionalmente LIGADA a la MAC del equipo que se va a fabricar
       └─ Inyección en la imagen montada
            /etc/sigil/secrets/enrollment-key, modo 0600, escritura atómica
            └─ Primer arranque (firstboot.sh): POST /api/devices/bootstrap
                 └─ Canje por un token PERMANENTE de dispositivo
                      └─ Borrado de la credencial de un solo uso + fsync
                           └─ Runtime: el token permanente es la ÚNICA
                              credencial que el dispositivo usa jamás
```

## Dónde se cablea

| Paso | Componente |
|---|---|
| Lectura del keyring | `src-tauri/src/services/credential.rs` |
| Login y solicitud | comandos `login_factory` y `request_enrollment` |
| Interfaz del operario | `src/components/CredentialPanel.tsx` |
| Inyección en la imagen | `write_enrollment_key` en `services/provision.rs` |
| Canje en el dispositivo | `sigil-hardware/scripts/firstboot.sh` |

Sin credencial obtenida, el botón de fabricación permanece deshabilitado: la
solicitud ocurre antes de escribir el primer byte.

## Contrato del backend

```
POST /api/login
  petición  { "username": <str>, "password": <str> }
  respuesta { "token": <str> }

POST /api/admin/enrollment-keys        Authorization: Bearer <token>
  petición  { "device_id": <mac|omitido>, "serial_number": <str|omitido> }
  respuesta { "keys": [ { "enrollment_key": <str> } ] }
  errores   409 el equipo ya tiene una credencial activa
            400 el servidor exige MAC y no se envió
            429 demasiadas solicitudes seguidas

POST /api/devices/bootstrap            (lo llama el dispositivo)
  petición  { "device_id": <str>, "enrollment_key": <str> }
  respuesta { "token": <str> }   32–256 ASCII sin espacios, DETERMINISTA

POST /api/devices/register             header x-api-key: <token permanente>
  respuesta { "ok": true } o { "registered": true }
```

Los rechazos del servidor se traducen a frases accionables por un operario de
fábrica: 409 → «Este equipo ya tiene una credencial activa registrada»,
400 → «El servidor exige la dirección MAC (deviceId) y no fue enviada»,
429 → «Demasiadas solicitudes seguidas, espere unos momentos».

## Invariantes

1. La contraseña de fábrica vive **solo** en el keyring. Nunca en un archivo de
   configuración, en argv, en logs ni en el repositorio.
2. Si el keyring no está disponible se **falla** con un error que nombra el
   paquete a instalar (`libsecret-tools`). Nunca se cae a texto plano ni a una
   variable de entorno.
3. El dispositivo nunca ve la contraseña de fábrica ni el token de sesión.
4. La MAC se normaliza a minúsculas con `:` byte a byte igual en el formulario,
   en el backend y en el servidor; si difiriera, una credencial ligada nunca
   podría consumirse.
5. Ligar la credencial a la MAC hace que una imagen extraviada antes del primer
   arranque no pueda enrolar hardware ajeno.
6. La credencial se escribe con temporal + `fsync` + `rename` atómico + fsync
   del directorio + relectura verificada, con modo 0600.
7. La cuenta de fábrica es de un rol dedicado, no administrativo, y no se
   instala jamás en un dispositivo.
