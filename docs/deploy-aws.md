# Deploying the relay to AWS Lambda

This is the runbook for the hosted relay: how it is laid out, how to deploy and
redeploy it, and how to operate it. The container deployment in the
[README](../README.md#quick-start-docker) is unaffected and still works.

## What gets deployed

```
JMAP server ──HTTPS──▶ Lambda Function URL ──▶ Lambda (provided.al2023, arm64, 256 MB)
   (Stalwart,               (AWS TLS cert)          │        │            │
    Fastmail…)                                       │        │            └──▶ APNs (api.push.apple.com)
                                                     │        └──▶ SSM Parameter Store: auth token, .p8 key
App ──register / poll──▶ same URL                    └──▶ DynamoDB table (on demand, TTL, PITR)
```

One CloudFormation stack, [`deploy/aws/template.yaml`](../deploy/aws/template.yaml),
owns everything except the secrets and the code bucket:

| Resource | Name | Notes |
|---|---|---|
| DynamoDB table | `jmap-apns-relay-<stage>` | On-demand, SSE, point-in-time recovery, TTL on `expiresAt`, sparse `byEntitlement` index. **Retained** when the stack is deleted. |
| Lambda function | `jmap-apns-relay-<stage>` | arm64, 256 MB, 15 s timeout. Reserved concurrency when the account allows (see [Quotas](#quotas)). |
| Function URL | (output `RelayURL`) | Auth type `NONE`. The relay authenticates registration itself, and the webhook must stay public. |
| Two Lambda permissions | | Public Function URLs need both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` (with `InvokedViaFunctionUrl`) since October 2025. |
| IAM role | | DynamoDB on the table and its index; `ssm:GetParameters` under `/jmap-apns-relay/<stage>/*`; logs. |
| Log group | `/aws/lambda/jmap-apns-relay-<stage>` | 14-day retention. |

Created by `scripts/deploy-lambda.sh`, outside the stack:

| Resource | Name |
|---|---|
| SSM SecureString | `/jmap-apns-relay/<stage>/auth-token` |
| SSM SecureString | `/jmap-apns-relay/<stage>/apns-key` (the `.p8` PEM) |
| S3 bucket | `jmap-apns-relay-code-<account>-<region>`: private, builds expire after 30 days |

Secrets never pass through CloudFormation. The function reads them at cold
start (`*_PARAMETER` environment variables), and a missing one stops the cold
start rather than starting an open relay.

## The OrcaMail production deployment

| | |
|---|---|
| Account | `892334470821` (dedicated), AWS CLI profile `orcamail` |
| Region | `eu-central-1` |
| Stack | `jmap-apns-relay-prod` |
| URL | `https://ugat6u23sayxdah6ejcysp35jq0ttenj.lambda-url.eu-central-1.on.aws/` |
| APNs | production (`api.push.apple.com`), key `M528HRT4VQ`, team `UA5PQ9SVT8`, topic `de.vselas.orcamail` |
| App Store gating | off (no StoreKit product yet) |
| Auth token | SSM `/jmap-apns-relay/prod/auth-token`; maintainer copy in `~/.config/orcamail/relay-auth-token` (mode 600) |

OrcaMail ships this URL as its default relay (`PushRelayConfiguration.hostedURL`
in the app). **Changing the URL breaks every installed app**, so never delete
and recreate the Function URL. Redeploying code does not change it.

## Prerequisites

- An AWS account and a CLI profile with administrator rights (SSO is fine):
  `aws sts get-caller-identity --profile <profile>` must answer.
- Docker, for the Linux build.
- An APNs auth key (`.p8`) from the Apple Developer portal, with its key id and
  team id. Check it before deploying:

  ```bash
  ORCAMAIL_APNS_KEY=path/to/AuthKey_XXXXXXXXXX.p8 swift Tools/apns-push.swift --check              # sandbox
  ORCAMAIL_APNS_KEY=path/to/AuthKey_XXXXXXXXXX.p8 swift Tools/apns-push.swift --check --production # production
  ```

  (`Tools/apns-push.swift` is in the OrcaMail repository.) "Credentials are good"
  means Apple accepted the key and rejected only the deliberately fake token.

## First deploy

```bash
export AWS_PROFILE=orcamail AWS_REGION=eu-central-1

scripts/build-lambda.sh                 # → .build/lambda/relay-lambda.zip (~31 MB)
scripts/test-lambda-local.sh            # optional: the zip in the Lambda emulator
PAID=1 scripts/test-lambda-local.sh     # optional: with App Store gating on

mkdir -p ~/.config/orcamail && chmod 700 ~/.config/orcamail
(umask 077; openssl rand -base64 48 | tr -d '\n' > ~/.config/orcamail/relay-auth-token)

APNS_KEY_FILE=path/to/AuthKey_M528HRT4VQ.p8 \
APNS_KEY_ID=M528HRT4VQ APNS_TEAM_ID=UA5PQ9SVT8 APNS_TOPIC=de.vselas.orcamail \
APNS_ENVIRONMENT=production \
RELAY_AUTH_TOKEN="$(cat ~/.config/orcamail/relay-auth-token)" \
  scripts/deploy-lambda.sh
```

The script stores both secrets (writing them from files, so neither appears in
a process listing), creates the code bucket, uploads the zip under a
content-addressed key, and deploys the stack. It then prints the URL and runs
a smoke test against `/healthz` and `/v1/capabilities`.

Then exercise the whole protocol over the real URL:

```bash
python3 -I scripts/integration/smoke_live.py https://<id>.lambda-url.<region>.on.aws/
```

That covers auth, registration, a verification webhook, an encrypted webhook,
the poll, a real APNs call (expect `BadDeviceToken` in the logs: the token is
fake), and unregistering the test device.

## Redeploying code

```bash
export AWS_PROFILE=orcamail AWS_REGION=eu-central-1
scripts/build-lambda.sh
APNS_KEY_ID=M528HRT4VQ APNS_TEAM_ID=UA5PQ9SVT8 APNS_TOPIC=de.vselas.orcamail \
  scripts/deploy-lambda.sh
python3 -I scripts/integration/smoke_live.py "$(aws cloudformation describe-stacks \
  --stack-name jmap-apns-relay-prod --query "Stacks[0].Outputs[?OutputKey=='RelayURL'].OutputValue" --output text)"
```

Without `APNS_KEY_FILE` / `RELAY_AUTH_TOKEN` the stored secrets are kept. An
unchanged zip is not a stack change. The deploy has no downtime: Lambda swaps
versions between invocations.

Pass every non-default parameter again on each deploy (the script supplies
defaults for the rest), or CloudFormation resets it. The parameters are:

| Variable | Default | Stack parameter |
|---|---|---|
| `STAGE` | `prod` | `Stage` |
| `APNS_ENVIRONMENT` | `production` | `APNsEnvironment` |
| `RESERVED_CONCURRENCY` | `20` (0 when the account cannot spare it) | `ReservedConcurrency` |
| `APPSTORE_PRODUCT_IDS` | empty: gating off | `AppStoreProductIds` |
| `APPSTORE_APP_APPLE_ID` | empty | `AppStoreAppAppleId` |
| `APPSTORE_ENVIRONMENT` | `Production` | `AppStoreEnvironment` |
| `MAX_DEVICES_PER_SUBSCRIPTION` | `10` | `MaxDevicesPerSubscription` |

## APNs environments: which stack serves which build

The APNs environment is fixed by how the installed app was **signed**, not by
anything in code, and a device token works only on its own environment:

| Build | `aps-environment` | APNs host | Stack |
|---|---|---|---|
| TestFlight, App Store, Ad Hoc | `production` | `api.push.apple.com` | `prod` |
| Run from Xcode (any configuration), Simulator | `development` | `api.sandbox.push.apple.com` | `sandbox` (optional) |

A token sent to the wrong host comes back `BadDeviceToken`. The relay then
removes the token, keeps the registration, and the device re-registers its
token on the next launch. So an Xcode build against `prod` registers and
completes the push handshake, but never shows a banner. That is expected.

To get banners on Xcode builds too, deploy a second stack:

```bash
STAGE=sandbox APNS_ENVIRONMENT=sandbox \
APNS_KEY_FILE=path/to/AuthKey_M528HRT4VQ.p8 \
APNS_KEY_ID=M528HRT4VQ APNS_TEAM_ID=UA5PQ9SVT8 APNS_TOPIC=de.vselas.orcamail \
RELAY_AUTH_TOKEN="$(cat ~/.config/orcamail/relay-auth-token)" \
  scripts/deploy-lambda.sh
```

and point the development build at its URL (OrcaMail: Settings → Push
Notifications → Use Custom Relay). The same `.p8` works for both hosts.

## App Store subscription gating

Off in production today. To turn it on once OrcaMail sells a push product:

1. Create the subscription in App Store Connect and note its product id and
   the app's numeric Apple ID (App Information → Apple ID).
2. Redeploy with
   `APPSTORE_PRODUCT_IDS=<id>[,<id>] APPSTORE_APP_APPLE_ID=<apple id>`.
3. In App Store Connect → App Information → App Store Server Notifications,
   set the **Production** URL (Version 2) to the `AppStoreNotificationURL`
   output, `<relay URL>v1/appstore/notifications`. Use "Request a Test
   Notification" and look for it in the logs.

From then on, `/v1/register` needs the StoreKit 2 `signedTransaction`, and the
app must handle the 402/403/503 refusals (see the
[README](../README.md#selling-push-app-store-subscriptions)). **Ship the app
side first**: turning gating on before the app sends a transaction stops push
for every installed copy.

## Secrets and rotation

**Auth token.** The same value is built into the shipped app (OrcaMail's
`Config/Relay.local.xcconfig`, from a CI secret), and the relay accepts exactly
one token. Rotating it therefore stops registration for every installed copy
until it updates to a build with the new token; already-registered devices keep
receiving push, because the webhook needs no token. Rotate only for a reason (a
leak that is being abused), ship the app build with the new token first where
possible, and prefer turning on App Store gating, which makes the token a minor
gate.

```bash
(umask 077; openssl rand -base64 48 | tr -d '\n' > ~/.config/orcamail/relay-auth-token)
RELAY_AUTH_TOKEN="$(cat ~/.config/orcamail/relay-auth-token)" APNS_KEY_ID=… APNS_TEAM_ID=… APNS_TOPIC=… \
  scripts/deploy-lambda.sh
# Running instances keep the old value until they recycle; force it:
aws lambda update-function-configuration --function-name jmap-apns-relay-prod \
  --description "token rotated $(date -u +%FT%TZ)"
```

**APNs key.** Create a new key in the Developer portal, deploy with
`APNS_KEY_FILE=<new.p8> APNS_KEY_ID=<new id>`, force a recycle as above, check
`[push] APNs sender active` in the logs, then revoke the old key. No app change
is needed.

Never commit the `.p8` or the token. `*.p8` is gitignored in both
repositories.

## Quotas

A new AWS account gets **10 concurrent Lambda executions**, and AWS keeps 10
unreserved, so no concurrency can be reserved. The deploy script detects this,
deploys without a reservation, and prints the increase command. The account
quota is then the ceiling. Request the normal quota once:

```bash
aws service-quotas request-service-quota-increase --service-code lambda \
  --quota-code L-B99A9384 --desired-value 1000
aws service-quotas list-requested-service-quota-change-history --service-code lambda \
  --query 'RequestedQuotas[].{Status:Status,Desired:DesiredValue}'
```

Approval usually takes hours to a few days. Afterwards, redeploy with
`RESERVED_CONCURRENCY=20` to cap what a flood of junk webhooks can cost. (The
OrcaMail account requested 1000 on 2026-10-10.)

## Monitoring

```bash
# Live logs
aws logs tail /aws/lambda/jmap-apns-relay-prod --follow

# Only the relay's own lines (registrations refused, APNs outcomes, errors)
aws logs tail /aws/lambda/jmap-apns-relay-prod --since 1h --filter-pattern '"[push]"'

# Errors and invocations, last hour
for m in Errors Invocations Throttles; do
  aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name $m \
    --dimensions Name=FunctionName,Value=jmap-apns-relay-prod \
    --start-time "$(date -u -v-1H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
    --period 3600 --statistics Sum --query 'Datapoints[0].Sum'
done

# How many devices are registered
aws dynamodb scan --table-name jmap-apns-relay-prod --select COUNT \
  --filter-expression "sk = :r" --expression-attribute-values '{":r":{"S":"registration"}}'
```

What normal looks like: a cold start (`Init Duration`) of about 390 ms, most
requests 2–15 ms billed, about 68 MB used, and a real APNs call about 450 ms.
`BadDeviceToken` lines come from devices whose build does not match the stack's
APNs environment (see above).

**An `Errors` count with no `[push]` line means the Lambda event did not decode.**
The adapter hands such failures straight to the runtime, which logs them only at
trace level, and the Function URL answers 502. To see the reason, raise the log
level briefly and **restore it afterwards**. CloudFormation does not manage
`LOG_LEVEL` and will not remove it:

```bash
aws lambda get-function-configuration --function-name jmap-apns-relay-prod \
  --query Environment --output json > /tmp/env.json
python3 -c "import json;e=json.load(open('/tmp/env.json'));e['Variables']['LOG_LEVEL']='trace';json.dump(e,open('/tmp/env-trace.json','w'))"
aws lambda update-function-configuration --function-name jmap-apns-relay-prod --environment file:///tmp/env-trace.json
# reproduce, then look for "Handler error=" in the logs, then:
aws lambda update-function-configuration --function-name jmap-apns-relay-prod --environment file:///tmp/env.json
```

Trace logs include request headers, which hold the auth token. Keep the window short.

## Cost

At 1,000 users (about 3 million webhooks a month) expect about $1–2 a month,
or $5–9 for heavy users: Lambda requests, DynamoDB on demand and logs, mostly
inside the free tiers. The fixed costs are near zero: no load balancer, no NAT,
no public IPv4. Set a billing alarm anyway:

```bash
aws budgets create-budget --account-id 892334470821 --budget '{"BudgetName":"relay","BudgetLimit":{"Amount":"20","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"<you>"}]}]'
```

## Teardown

```bash
aws cloudformation delete-stack --stack-name jmap-apns-relay-prod
aws cloudformation wait stack-delete-complete --stack-name jmap-apns-relay-prod
# Retained on purpose; delete only if the registrations really should go:
aws dynamodb delete-table --table-name jmap-apns-relay-prod
aws ssm delete-parameters --names /jmap-apns-relay/prod/auth-token /jmap-apns-relay/prod/apns-key
aws s3 rb s3://jmap-apns-relay-code-892334470821-eu-central-1 --force
```

Deleting the stack deletes the Function URL. A new stack gets a **different
URL**, and every installed OrcaMail points at the old one.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Stack fails: "decreases account's UnreservedConcurrentExecution below its minimum value of [10]" | New account, quota 10 | The script now handles it; re-run. See [Quotas](#quotas). |
| Stack stuck in `ROLLBACK_COMPLETE` after a failed first create | CloudFormation cannot update such a stack | The script deletes and recreates it. If the table survived (it is retained), check it is empty, then delete it. |
| JMAP server's webhook gets 502, Lambda `Errors` rises, no `[push]` line | The event did not decode. Seen 2026-10-10: Stalwart sends no `User-Agent`, Lambda sets `userAgent: null`, and `AWSLambdaEvents.FunctionURLRequest` requires a string | Fixed by `TolerantFunctionURLRequest`. For a new variant, see [Monitoring](#monitoring). |
| `BadDeviceToken` for every push to a device | Build/stack APNs environment mismatch | Use the matching stack (see [APNs environments](#apns-environments-which-stack-serves-which-build)). |
| `InvalidProviderToken` | Wrong key id or team id, or a revoked key | Check with `Tools/apns-push.swift --check`, redeploy with the right values. |
| Registration 401 | App and relay tokens differ | Compare the app's build setting with SSM; see [Secrets](#secrets-and-rotation). |
| Cold start fails with "missing [...]" | An SSM parameter is gone | Redeploy with `RELAY_AUTH_TOKEN` / `APNS_KEY_FILE`. |
