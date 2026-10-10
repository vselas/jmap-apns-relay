# jmap-apns-relay

[![CI](https://github.com/dvselas/jmap-apns-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/dvselas/jmap-apns-relay/actions/workflows/ci.yml)
[![Docker Hub](https://img.shields.io/docker/v/dvselas/jmap-apns-relay?logo=docker&label=docker%20hub&sort=semver)](https://hub.docker.com/r/dvselas/jmap-apns-relay)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A tiny bridge that turns a [JMAP](https://jmap.io) server's **`PushSubscription`
webhooks** into **Apple Push Notifications**, so an iOS/macOS app can be woken
for new mail (or calendar/contact changes) while it is closed.

JMAP servers such as [Stalwart](https://stalw.art) can POST `StateChange`
events to a webhook URL, but they can't speak APNs. This relay is that missing
piece: a client registers its device, creates a JMAP push subscription pointing
at the relay, and the relay forwards each `StateChange` to Apple as an alert
push addressed to the right device.

```
                    ┌──────────┐   PushSubscription      ┌──────────────┐   APNs    ┌─────────┐
   change  ────────▶│  JMAP    │ ──── webhook POST ─────▶│  this relay  │ ────────▶ │ device  │
                    │  server  │   /v1/push/<deviceId>   │              │           │ (app)   │
                    └──────────┘                         └──────┬───────┘           └─────────┘
                                                                │ maps deviceId → APNs token
   app ── POST /v1/register (deviceId, apnsToken) ──────────────┘
```

Written in Swift with [Hummingbird](https://github.com/hummingbird-project/hummingbird);
ES256 provider tokens via [swift-crypto](https://github.com/apple/swift-crypto),
HTTP/2 to Apple via [async-http-client](https://github.com/swift-server/async-http-client).
Two deployments from one codebase: a **container** that keeps device registrations
and the small pending queue in a JSON file, and an **AWS Lambda** that keeps them
in DynamoDB (see [Deploy to AWS Lambda](#deploy-to-aws-lambda)).

## Quick start (Docker)

```bash
docker run -d --name jmap-apns-relay -p 8443:8443 \
  -v "$PWD/secrets:/secrets:ro" -v "$PWD/state:/state" \
  -e PORT=8443 \
  -e TLS_CERT=/secrets/tls.crt -e TLS_KEY=/secrets/tls.key \
  -e STATE_PATH=/state/relay.json \
  -e RELAY_MODE=production \
  -e RELAY_AUTH_TOKEN='replace-with-a-long-random-secret' \
  -e APNS_KEY_PATH=/secrets/AuthKey_ABCDE12345.p8 \
  -e APNS_KEY_ID=ABCDE12345 \
  -e APNS_TEAM_ID=UA5PQ9SVT8 \
  -e APNS_TOPIC=com.example.app \
  -e APNS_ENVIRONMENT=sandbox \
  dvselas/jmap-apns-relay:0.3.0
```

JMAP push URLs must be HTTPS (RFC 8620 §7.2), so the relay serves TLS whenever
`TLS_CERT`/`TLS_KEY` are set — in production put it behind a reverse proxy or
give it a real cert; the JMAP server must be able to reach it and trust that
cert. In `RELAY_MODE=development`, omitting the `APNS_*` variables selects the
log/poll sender. Production mode requires APNs credentials and an auth token and
fails startup rather than silently degrading to the log sender.

See [`compose.example.yaml`](compose.example.yaml) for a Compose deployment, and
[`scripts/gen-dev-certs.sh`](scripts/gen-dev-certs.sh) to mint a self-signed cert
for local testing.

Sigill can build this checkout through its optional Compose override by setting
`JMAP_APNS_RELAY_PATH` to this repository. No absolute checkout path needs to be
committed.

## Configuration

All configuration is via environment variables.

| Variable           | Required | Default                     | Meaning                                                        |
|--------------------|:--------:|-----------------------------|----------------------------------------------------------------|
| `PORT`             |          | `8090`                      | Listen port                                                    |
| `TLS_CERT`         |          | —                           | PEM cert chain; enables HTTPS (required for real JMAP push)    |
| `TLS_KEY`          |          | —                           | PEM private key                                                |
| `STATE_PATH`       |          | `/tmp/pushrelay-state.json` | Device registry + pending queue (JSON)                         |
| `RELAY_MODE`       |          | `development`               | `development` or fail-closed `production`                     |
| `RELAY_AUTH_TOKEN` | ✓ prod   | —                           | Bearer token for register, unregister, and pending endpoints   |
| `APNS_KEY_PATH`    | ✓ prod\* | —                           | Path to the APNs `.p8` auth key                                |
| `APNS_KEY_ID`      |    ✓\*   | —                           | The key's 10-char Key ID                                       |
| `APNS_TEAM_ID`     |    ✓\*   | —                           | Apple Developer Team ID                                        |
| `APNS_TOPIC`       |    ✓\*   | —                           | The app's bundle id                                            |
| `APNS_ENVIRONMENT` |          | `production`                | `sandbox` for development/TestFlight builds                    |
| `APNS_ALERT_TITLE` |          | `Mail`                      | Fallback alert title (a Notification Service Extension can enrich) |
| `APNS_ALERT_BODY`  |          | `New mail`                  | Fallback alert body                                            |

\* The four APNs credential variables must be set together. Partial APNs
configuration is rejected in every mode.

## HTTP API

| Method | Path                    | Purpose                                             |
|--------|-------------------------|-----------------------------------------------------|
| `POST` | `/v1/register`          | Register a device — body `{"deviceId": "...", "apnsToken": "..."}` (`apnsToken` optional). Requires the bearer token. |
| `DELETE` | `/v1/register/:deviceId` | Unregister a device and discard its pending queue. Requires the current bearer token. |
| `POST` | `/v1/push/:deviceId`    | The JMAP `PushSubscription` webhook target. Unauthenticated — the server sends what it sends; the unguessable device id is the capability. |
| `GET`  | `/v1/pending/:deviceId` | Dev poll — returns and clears the device's queue. Requires the bearer token. |
| `GET`  | `/v1/capabilities`      | Public protocol, feature, and limit discovery                    |
| `GET`  | `/healthz`              | Liveness                                            |
| `GET`  | `/readyz`               | Readiness; fails after a state persistence error    |

## Encrypted payloads

When a JMAP `PushSubscription` carries RFC 8291 keys, the server encrypts what
it sends and the relay cannot read it. That is the intended shape: the relay's
job is to carry a message to a device, not to know what is in it.

The relay handles both:

* **Encrypted** (`Content-Encoding: aes128gcm`) — the body is forwarded verbatim,
  base64-encoded, as `sigill.encrypted` in the APNs payload. The alert text stays
  generic, and `mutable-content: 1` lets the app's notification service extension
  replace it after decrypting. Routing needs nothing from the body: the device id
  is already in the URL.
* **Plaintext** — the old `stateChange` field is still sent, so a client built
  before encryption keeps working. The payload additionally carries
  `sigill.deviceId` and `sigill.protocolVersion` for newer clients.

The final JSON sent to APNs is limited to 4096 bytes. Oversized payloads are
rejected and diagnosed rather than relying on APNs to reject them. APNs invalid
token responses clear only the stale token (the registration remains available
for a later re-registration); transient and permanent failures are classified
in logs.

Two consequences worth knowing:

* The body is handled as **bytes**, not text. An encrypted payload is binary and
  reading it as a `String` yields nothing.
* With encryption on, the relay cannot tell a `PushVerification` from a
  `StateChange`, so it forwards both. Expect one generic notification during
  subscription setup.

## Authentication

`RELAY_AUTH_TOKEN` protects register, unregister, and `/v1/pending` with a bearer
token, compared in constant time. Development mode still runs without one but
warns at startup; production mode refuses to start. An open registry means
anyone who can reach the relay can claim a device id, or re-point an existing
one at their own APNs token and receive that device's notifications. Encryption
stops them *reading* anything; only the token stops them redirecting it.

`/v1/push/:deviceId` stays open deliberately: it is the URL handed to the JMAP
server, which sends what it sends. Someone who guesses a device id can enqueue
noise, which an encrypting client discards as undecryptable.

## How a client integrates

1. **Register** the device: `POST /v1/register` with a stable `deviceId` and,
   once the OS issues one, the APNs device token.
2. **Create a JMAP `PushSubscription`** whose `url` is
   `https://<relay-host>/v1/push/<deviceId>` and whose `types` include the
   objects you care about (e.g. `Email`, `Mailbox`).
3. The JMAP server sends a **`PushVerification`** to that URL (RFC 8620 §7.2);
   read the `verificationCode` back (from your device via APNs, or in dev mode
   from `GET /v1/pending/<deviceId>`) and confirm the subscription.
4. From then on the server POSTs a `StateChange` on every change; the relay
   delivers it to the device as an alert push.

Plaintext `PushVerification` payloads stay in the pending queue and are not sent
to APNs. An encrypted verification is indistinguishable from an encrypted
`StateChange`, so it is forwarded and can produce one generic setup alert; the
device must decrypt and discard it. State changes use an alert push with
`mutable-content: 1`, allowing a
[Notification Service Extension](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
to decrypt (when needed), run a targeted sync, and replace the generic text.

Clients can probe `GET /v1/capabilities`. Protocol version 1 advertises
`encryptedForwarding`, `plaintextMetadata`, `pendingPoll`, and `unregister`, plus
the webhook, APNs-payload, and pending-queue limits. Older relays may not expose
this endpoint, so clients should treat a 404/405 as an unknown legacy relay.
The machine-readable contract is
[`docs/fixtures/relay-protocol-v1.json`](docs/fixtures/relay-protocol-v1.json).
`scripts/check-protocol-fixture.sh` validates it; set `SIGILL_PATH` to a Sigill
checkout to additionally require both repositories' copies to match.

## APNs setup

1. In the Apple Developer portal, enable **Push Notifications** on your App ID
   and create an **APNs Auth Key** (`.p8`); note the **Key ID** and **Team ID**.
2. Mount the `.p8` into the relay and set `APNS_KEY_PATH`/`APNS_KEY_ID`/
   `APNS_TEAM_ID`/`APNS_TOPIC`.
3. Set `APNS_ENVIRONMENT=sandbox` for development and TestFlight builds (whose
   `aps-environment` entitlement is `development`); omit it for App Store builds.
   A mismatch yields `BadDeviceToken` from Apple.

**Never commit the `.p8`** — it can send push to every user of your app. Mount
it as a secret.

## Deploy to AWS Lambda

The same router runs as an ARM64 Lambda behind a
[Function URL](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html),
which supplies HTTPS with a publicly trusted certificate — nothing to configure,
and every JMAP server trusts it. State moves to an on-demand DynamoDB table,
secrets to Parameter Store. At small scale this stays inside AWS's free tiers.

```
JMAP server ──▶ Function URL (HTTPS) ──▶ Lambda (provided.al2023, arm64) ──▶ APNs
                                              │
                          DynamoDB (pk/sk, TTL) · SSM SecureString ×2
```

Everything is in [`deploy/aws/template.yaml`](deploy/aws/template.yaml) (one
CloudFormation stack) and two scripts:

```bash
export AWS_PROFILE=relay AWS_REGION=eu-central-1

scripts/build-lambda.sh                 # Docker → .build/lambda/relay-lambda.zip
scripts/test-lambda-local.sh            # optional: the zip in the Lambda emulator vs DynamoDB Local

# First deploy stores both secrets; later deploys can omit them.
APNS_KEY_FILE=~/keys/AuthKey_ABCDE12345.p8 \
APNS_KEY_ID=ABCDE12345 APNS_TEAM_ID=UA5PQ9SVT8 APNS_TOPIC=com.example.app \
RELAY_AUTH_TOKEN="$(openssl rand -base64 48)" \
  scripts/deploy-lambda.sh
```

The script prints the relay URL (`https://<id>.lambda-url.<region>.on.aws/`);
clients use it for both the app-facing and the server-facing relay address. Keep
the auth token: clients need it to register.

What differs from the container:

| | Container | Lambda |
|---|---|---|
| State | `STATE_PATH` JSON file | `DYNAMODB_TABLE` |
| `.p8` key | `APNS_KEY_PATH` (mounted file) | `APNS_KEY_PARAMETER` → `APNS_KEY` (PEM text) |
| Auth token | `RELAY_AUTH_TOKEN` | `RELAY_AUTH_TOKEN_PARAMETER` → `RELAY_AUTH_TOKEN` |
| TLS | `TLS_CERT` / `TLS_KEY` | the Function URL's |

Any `<NAME>_PARAMETER` variable is resolved from Parameter Store (decrypted) at
cold start into `<NAME>`; a plain `<NAME>` wins, which keeps local runs AWS-free.
A missing parameter stops the cold start rather than starting an open relay.

**Table layout.** One item per registration (`pk = device#<id>`,
`sk = registration`) and one item per queued push (`sk = push#<time>#<nonce>`),
so concurrent instances never overwrite each other's queue. Queued pushes carry
an `expiresAt` TTL of one day — the queue exists for the client's verification
poll, which comes within minutes — and a drain returns at most the newest 50.

**Cost control.** The webhook is unauthenticated by design, so the function has
a reserved concurrency (`RESERVED_CONCURRENCY`, default 20) that caps what a
flood can cost; a request for an unknown device costs one DynamoDB read and
returns 404. Logs are kept 14 days.

**APNs environment.** One stack talks to one APNs host, and it must match the
`aps-environment` the installed build was *signed* with; a mismatch answers
`BadDeviceToken`. Run a second stack (`STAGE=sandbox APNS_ENVIRONMENT=sandbox`)
when both kinds of build need push at once.

## Selling push: App Store subscriptions

A relay can require an active App Store subscription before it delivers to
APNs. Set `APPSTORE_PRODUCT_IDS` and it does; leave it unset and nothing changes.

| Variable | Meaning |
|---|---|
| `APPSTORE_PRODUCT_IDS` | Comma-separated product ids that grant push. Turns the feature on. |
| `APPSTORE_BUNDLE_ID` | Defaults to `APNS_TOPIC`. |
| `APPSTORE_APP_APPLE_ID` | The app's numeric App Store id; required for `Production`. |
| `APPSTORE_ENVIRONMENT` | `Production` (default; App Store and TestFlight) or `Sandbox`. `Xcode` and `LocalTesting` are refused: Apple's library skips signature checks for them. |
| `APPSTORE_MAX_DEVICES` | Registrations one subscription may hold (default 10; each account on each device is one). |

**How a client proves it paid.** `POST /v1/register` gains an optional
`signedTransaction`: the StoreKit 2 `Transaction.jwsRepresentation` for the
subscription. The relay verifies it with Apple's
[App Store Server Library](https://github.com/apple/app-store-server-library-swift):
the ES256 signature, the `x5c` chain to **Apple Root CA - G3** (embedded and
fingerprint-checked), Apple's receipt-signing OIDs, online revocation, bundle id,
environment and product. It then records the subscription under its
`originalTransactionId` and links the device to it. Later registrations from
the same device (a new APNs token, every launch) need no proof.

Refusals carry a JSON `error` the app can act on:

| Status | `error` | Meaning |
|---|---|---|
| 402 | `entitlementRequired` | No proof, and none on file for this device. |
| 402 | `entitlementInvalid` | Not signed by Apple, or not for this app or product. |
| 402 | `entitlementExpired` | Genuine, but the period has ended or it was refunded. |
| 403 | `deviceLimitReached` | The subscription already holds `maxDevices` registrations. |
| 503 | `entitlementUnavailable` | Apple's revocation check did not answer; retry. |

The shared `RELAY_AUTH_TOKEN` is still required on top: the subscription is what
pays, the token keeps scripted clients away from registration.

**What stays free.** The webhook still queues every message, so the JMAP
subscription's verification code reaches `/v1/pending` before anyone pays. Only
the APNs leg is gated: an unpaid device's webhooks answer 200 and send nothing.

**Keeping current.** Point App Store Connect's *App Store Server Notifications*
(Version 2) at `https://<relay>/v1/appstore/notifications`; the deploy script
prints the URL. Renewals, billing-grace periods, expiries, refunds and refund
reversals then update the subscription without the app. Each notification is
verified like a transaction, and an older one arriving after a newer one is
ignored. Pushes keep flowing for an hour past a period's end, so a renewal
racing its notification never drops one.

## Build & test from source

```bash
swift build
swift test
swift build -c release
scripts/check-protocol-fixture.sh --self
scripts/build-lambda.sh && scripts/test-lambda-local.sh   # Lambda, needs Docker
PAID=1 scripts/test-lambda-local.sh                       # …with entitlements on
scripts/test-dynamodb-local.sh                            # DynamoDB store vs DynamoDB Local
```

Requires Swift 6.2+ (the Lambda zip builds in the `swift:6.3.3-amazonlinux2023` image). The Docker image is built from the [`Dockerfile`](Dockerfile)
at the repo root. The example Compose file pins release `0.3.0`; use `:edge`
deliberately when testing unreleased `main` behavior.

## Security

- The relay stores opaque device ids, APNs tokens, and its bounded pending push
  queues. Plaintext `StateChange` payloads contain object state strings, not mail
  bodies; encrypted payloads remain opaque bytes.
- Serve it over TLS and keep the `.p8` out of the image and repo.
- The `/v1/pending` poll endpoint is a development aid. It exposes and drains a
  device's queued payloads to callers holding the shared bearer token; production
  deployments should not treat it as a general delivery API.

## State format

`STATE_PATH` is an atomically replaced, versioned JSON snapshot. Its parent
directories are created at startup. Existing unversioned snapshots are read and
migrated in place; malformed data, unsupported versions, and startup I/O errors
fail startup rather than silently starting with an empty registry. Runtime write
errors make `/readyz` return 503 and are returned by the mutating request.

## License

[MIT](LICENSE) © Deno von Selasinsky
