# Domain API

A REST API for managing the domains belonging to a mail server without needing
the web interface. It covers the full lifecycle: onboarding, verification, DNS
checks and DKIM key rotation.

All paths below are relative to the root of your Postal installation
(for example `https://postal.example.com`).

## Authentication

Every request must include the `X-Server-API-Key` header containing an API
credential key. Create a credential of type **API** in the web interface under
*Server → Credentials*.

```
X-Server-API-Key: <your-api-key>
```

The key identifies a **server**, and every domain in this API is scoped to that
server — you can only see and manage domains owned by the server that owns the
key. A missing or invalid key returns `401`; a suspended server (or its
organization) returns `403`.

## Request and response format

- Send parameters as a JSON body with `Content-Type: application/json`. Keys are
  top-level (for example `{"name": "example.com"}`).
- Successful responses are `application/json` and contain the resource under a
  `domain` key (except the list endpoint, which returns a plain array).
- Errors share a common shape:

```json
{
  "error": {
    "code": "DomainNotFound",
    "message": "The requested domain could not be found."
  }
}
```

## The domain object

Every endpoint that returns a domain uses the same representation:

```json
{
  "domain": {
    "uuid": "0c0f0d1e-2b3a-4c5d-8e9f-0a1b2c3d4e5f",
    "name": "example.com",
    "verified": false,
    "verified_at": null,
    "verification_method": "DNS",
    "dns_checked_at": null,
    "dns_ok": null,
    "outgoing": true,
    "incoming": true,
    "verification": {
      "method": "DNS",
      "token": "Vd3k7yQ1mZ9pR4tLb8xNc2WfHy6Js0Aq",
      "dns_txt_name": "example.com",
      "dns_txt_value": "postal-verification Vd3k7yQ1mZ9pR4tLb8xNc2WfHy6Js0Aq"
    },
    "records": {
      "spf": {
        "name": "example.com",
        "type": "TXT",
        "value": "v=spf1 a mx include:spf.postal.example.com ~all"
      },
      "dkim": {
        "name": "postal-ABCDEF._domainkey.example.com",
        "type": "TXT",
        "value": "v=DKIM1; t=s; h=sha256; p=MIIBIjANBg...IDAQAB;"
      },
      "mx": [
        "mx1.postal.example.com",
        "mx2.postal.example.com"
      ],
      "return_path": {
        "name": "psrp.example.com",
        "type": "CNAME",
        "value": "rp.postal.example.com"
      }
    },
    "statuses": {
      "spf": { "status": null, "error": null },
      "dkim": { "status": null, "error": null },
      "mx": { "status": null, "error": null },
      "return_path": { "status": null, "error": null }
    },
    "pending_dkim": null
  }
}
```

Field notes:

| Field | Description |
| --- | --- |
| `verified` / `verified_at` | Whether ownership of the domain has been verified. `verified_at` is a Unix timestamp or `null`. |
| `verification_method` | `DNS` or `Email`. |
| `verification` | Present only while the domain is unverified. Contains the DNS TXT record (`dns_txt_name`/`dns_txt_value`) or email `token` to use. |
| `records` | The DNS records to publish. `records.mx` is a plain array of MX hostnames. |
| `statuses` | Result of the last DNS check. Each `status` is `OK`, `Missing`, `Invalid` or `null` (never checked). |
| `dns_ok` | `true`/`false` once DNS has been checked, otherwise `null`. `true` when SPF and DKIM are `OK` and MX/return-path are `OK` or `Missing`. |
| `pending_dkim` | Present only while a DKIM key rotation is in progress: `{ "name": ..., "value": ... }`. |

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/v1/domains` | List domains |
| `POST` | `/api/v1/domains` | Create (onboard) a domain |
| `GET` | `/api/v1/domains/:uuid` | Get a domain |
| `DELETE` | `/api/v1/domains/:uuid` | Delete a domain |
| `POST` | `/api/v1/domains/:uuid/verify` | Verify ownership (DNS or email) |
| `POST` | `/api/v1/domains/:uuid/check` | Re-check the DNS records |
| `POST` | `/api/v1/domains/:uuid/regenerate_dkim` | Generate a new DKIM key |
| `POST` | `/api/v1/domains/:uuid/cancel_dkim_regeneration` | Discard a pending DKIM key change |

### List domains

```
GET /api/v1/domains
```

Returns `200` with an array of domain objects (ordered by name).

```bash
curl -H "X-Server-API-Key: $KEY" https://postal.example.com/api/v1/domains
```

### Create a domain

```
POST /api/v1/domains
```

| Parameter | Required | Description |
| --- | --- | --- |
| `name` | Yes | The domain name, e.g. `example.com`. |
| `verification_method` | No | `DNS` (default) or `Email`. |

Returns `201` with the new domain. A DKIM key is generated immediately, so the
response already includes every DNS record you need to publish. Returns `422`
with `"code": "ValidationFailed"` and an `errors` array when the name is missing,
malformed, or already added.

```bash
curl -X POST https://postal.example.com/api/v1/domains \
  -H "X-Server-API-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "example.com", "verification_method": "DNS"}'
```

### Get a domain

```
GET /api/v1/domains/:uuid
```

Returns `200` with `{ "domain": { ... } }`, or `404` (`DomainNotFound`).

```bash
curl -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>
```

### Delete a domain

```
DELETE /api/v1/domains/:uuid
```

Returns `204 No Content` on success, or `404` (`DomainNotFound`).

```bash
curl -X DELETE -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>
```

### Verify a domain

```
POST /api/v1/domains/:uuid/verify
```

The parameters depend on the domain's `verification_method`.

**DNS method** — publish the TXT record from `verification.dns_txt_name` /
`verification.dns_txt_value`, then call the endpoint with no body. Returns `200`
with the domain on success, `422` (`VerificationFailed`) if the record can't be
found.

```bash
curl -X POST -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>/verify
```

**Email method** — two steps:

1. Request a code by passing `email_address`. It must be one of the domain's
   verification addresses (`webmaster`, `postmaster`, `admin`, `administrator`
   or `hostmaster`, at the domain or a parent domain). Returns `200` and sends
   the code by email.
2. Submit the code by passing `code` (the 6-digit value from the email). Returns
   `200` on success, `422` (`InvalidVerificationCode`) otherwise.

| Parameter | Description |
| --- | --- |
| `email_address` | Send the verification code to this address. |
| `code` | The code received by email, to complete verification. |

```bash
# 1. send the code
curl -X POST https://postal.example.com/api/v1/domains/<uuid>/verify \
  -H "X-Server-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"email_address": "admin@example.com"}'

# 2. submit the code
curl -X POST https://postal.example.com/api/v1/domains/<uuid>/verify \
  -H "X-Server-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"code": "123456"}'
```

Returns `422` (`AlreadyVerified`) if the domain is already verified, and `400`
(`ParameterError`) if neither parameter is supplied for the email method.

### Check DNS records

```
POST /api/v1/domains/:uuid/check
```

Runs all four DNS checks (SPF, DKIM, MX, return-path) and returns `200` with the
domain and its refreshed `statuses`/`dns_ok`. The status code is always `200` —
inspect `dns_ok` (or the individual `statuses`) to see whether everything is
configured correctly.

```bash
curl -X POST -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>/check
```

### Regenerate DKIM key

```
POST /api/v1/domains/:uuid/regenerate_dkim
```

Generates a new DKIM key. If the current key is already live (`dkim_status` is
`OK`), the new key is returned as a pending key under `pending_dkim` and the
existing key keeps signing until you publish the new record and call
`/check`. Otherwise the active key is replaced immediately.

Returns `200` with the domain, or `422` (`DkimChangeInProgress`) if a rotation
is already underway.

```bash
curl -X POST -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>/regenerate_dkim
```

### Cancel DKIM regeneration

```
POST /api/v1/domains/:uuid/cancel_dkim_regeneration
```

Discards a pending DKIM key, leaving the existing key active. Returns `200` with
the domain.

```bash
curl -X POST -H "X-Server-API-Key: $KEY" \
  https://postal.example.com/api/v1/domains/<uuid>/cancel_dkim_regeneration
```

## Onboarding walkthrough

1. **Create the domain** and capture the `uuid` and `records` from the response:

   ```bash
   curl -X POST https://postal.example.com/api/v1/domains \
     -H "X-Server-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"name": "example.com"}'
   ```

2. **Publish the DNS records** — the SPF, DKIM, MX and return-path records from
   `records`, plus the ownership TXT record from `verification.dns_txt_value`
   (for the DNS method).

3. **Verify ownership**:

   ```bash
   curl -X POST -H "X-Server-API-Key: $KEY" \
     https://postal.example.com/api/v1/domains/<uuid>/verify
   ```

4. **Confirm the DNS records** once they have propagated, and check `dns_ok`:

   ```bash
   curl -X POST -H "X-Server-API-Key: $KEY" \
     https://postal.example.com/api/v1/domains/<uuid>/check
   ```

## Error codes

| HTTP status | `error.code` | Meaning |
| --- | --- | --- |
| `400` | `ParameterError` | A required parameter was missing (for example, no `email_address` or `code`). |
| `401` | `AccessDenied` | No `X-Server-API-Key` header was provided. |
| `401` | `InvalidServerAPIKey` | The API key is not valid. |
| `403` | `ServerSuspended` | The server (or its organization) is suspended. |
| `404` | `DomainNotFound` | No domain with that UUID belongs to this server. |
| `422` | `ValidationFailed` | The domain could not be created. Includes an `errors` array. |
| `422` | `AlreadyVerified` | The domain has already been verified. |
| `422` | `VerificationFailed` | The DNS TXT record could not be verified. |
| `422` | `InvalidVerificationCode` | The email verification code was incorrect. |
| `422` | `InvalidEmailAddress` | The email address is not a valid verification address for the domain. |
| `422` | `DkimChangeInProgress` | A DKIM key change is already in progress. |
