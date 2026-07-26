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
No database — device registrations and the small pending queue persist to a JSON file.

## Quick start (Docker)

```bash
docker run -d --name jmap-apns-relay -p 8443:8443 \
  -v "$PWD/secrets:/secrets:ro" -v "$PWD/state:/state" \
  -e PORT=8443 \
  -e TLS_CERT=/secrets/tls.crt -e TLS_KEY=/secrets/tls.key \
  -e STATE_PATH=/state/relay.json \
  -e APNS_KEY_PATH=/secrets/AuthKey_ABCDE12345.p8 \
  -e APNS_KEY_ID=ABCDE12345 \
  -e APNS_TEAM_ID=UA5PQ9SVT8 \
  -e APNS_TOPIC=com.example.app \
  -e APNS_ENVIRONMENT=sandbox \
  dvselas/jmap-apns-relay:latest
```

JMAP push URLs must be HTTPS (RFC 8620 §7.2), so the relay serves TLS whenever
`TLS_CERT`/`TLS_KEY` are set — in production put it behind a reverse proxy or
give it a real cert; the JMAP server must be able to reach it and trust that
cert. Without the `APNS_*` variables the relay runs in **dev mode**: it logs
each event and serves a `/v1/pending` poll endpoint instead of calling Apple.

See [`compose.example.yaml`](compose.example.yaml) for a Compose deployment, and
[`scripts/gen-dev-certs.sh`](scripts/gen-dev-certs.sh) to mint a self-signed cert
for local testing.

## Configuration

All configuration is via environment variables.

| Variable           | Required | Default                     | Meaning                                                        |
|--------------------|:--------:|-----------------------------|----------------------------------------------------------------|
| `PORT`             |          | `8090`                      | Listen port                                                    |
| `TLS_CERT`         |          | —                           | PEM cert chain; enables HTTPS (required for real JMAP push)    |
| `TLS_KEY`          |          | —                           | PEM private key                                                |
| `STATE_PATH`       |          | `/tmp/pushrelay-state.json` | Device registry + pending queue (JSON)                         |
| `APNS_KEY_PATH`    |    ✓\*   | —                           | Path to the APNs `.p8` auth key                                |
| `APNS_KEY_ID`      |    ✓\*   | —                           | The key's 10-char Key ID                                       |
| `APNS_TEAM_ID`     |    ✓\*   | —                           | Apple Developer Team ID                                        |
| `APNS_TOPIC`       |    ✓\*   | —                           | The app's bundle id                                            |
| `APNS_ENVIRONMENT` |          | `production`                | `sandbox` for development/TestFlight builds                    |
| `APNS_ALERT_TITLE` |          | `Mail`                      | Fallback alert title (a Notification Service Extension can enrich) |
| `APNS_ALERT_BODY`  |          | `New mail`                  | Fallback alert body                                            |

\* The four `APNS_*` key variables are required **together** to enable real
delivery; set none of them to run in dev/log mode.

## HTTP API

| Method | Path                    | Purpose                                             |
|--------|-------------------------|-----------------------------------------------------|
| `POST` | `/v1/register`          | Register a device — body `{"deviceId": "...", "apnsToken": "..."}` (`apnsToken` optional) |
| `POST` | `/v1/push/:deviceId`    | The JMAP `PushSubscription` webhook target          |
| `GET`  | `/v1/pending/:deviceId` | Dev poll — returns and clears the device's queue    |
| `GET`  | `/healthz`              | Liveness                                            |

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

Only `StateChange` payloads are delivered to APNs; the `PushVerification`
handshake is never turned into a user-visible notification. The alert carries
the raw `StateChange` (with `mutable-content: 1`) so a
[Notification Service Extension](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
can run a targeted sync and rewrite the alert with real sender/subject.

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

## Build & test from source

```bash
swift build
swift test
```

Requires Swift 6.2+. The Docker image is built from the [`Dockerfile`](Dockerfile)
at the repo root.

## Security

- The relay stores only opaque device ids and APNs tokens — never message
  content. `StateChange` payloads carry object *state strings*, not mail bodies.
- Serve it over TLS and keep the `.p8` out of the image and repo.
- The `/v1/pending` poll endpoint is a development aid; it exposes queued
  payloads for a device id to anyone who knows that id — don't rely on it in
  production.

## License

[MIT](LICENSE) © Deno von Selasinsky
