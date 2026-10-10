#!/usr/bin/env bash
# Runs the built Lambda (scripts/build-lambda.sh) the way AWS would: inside the
# provided.al2023 image's runtime interface emulator, against DynamoDB Local and a
# Parameter Store stub, with a throwaway APNs key. Then drives the whole relay
# protocol through Function URL events. Leaves nothing running.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP="$ROOT/.build/lambda/bootstrap"
[[ -x "$BOOTSTRAP" ]] || { echo "Build first: scripts/build-lambda.sh" >&2; exit 2; }
ARCH=${ARCH:-arm64}
[[ "$ARCH" == arm64 ]] && PLATFORM=linux/arm64 || PLATFORM=linux/amd64
PORT=${PORT:-9001}
NET=relay-lambda-it

stop_containers() {
  docker rm -f relay-it-fn relay-it-ssm relay-it-ddb >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
stop_containers  # leftovers from an interrupted run
WORK=$(mktemp -d)
trap 'stop_containers; rm -rf "$WORK"' EXIT

openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt > "$WORK/key.p8"
printf 'it-token' > "$WORK/token"
docker network create "$NET" >/dev/null
docker run -d --name relay-it-ddb --network "$NET" amazon/dynamodb-local:latest -jar DynamoDBLocal.jar -inMemory >/dev/null
docker run -d --name relay-it-ssm --network "$NET" -v "$ROOT/scripts/integration:/stub:ro" -v "$WORK:/w:ro" \
  -e SSM_PARAM_1="/jmap-apns-relay/it/auth-token=/w/token" -e SSM_PARAM_2="/jmap-apns-relay/it/apns-key=/w/key.p8" \
  python:3.12-alpine python -u /stub/ssm_stub.py >/dev/null

AWS=(docker run --rm --network "$NET" -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=eu-central-1 amazon/aws-cli:latest)
for _ in $(seq 1 30); do
  "${AWS[@]}" dynamodb list-tables --endpoint-url http://relay-it-ddb:8000 >/dev/null 2>&1 && break
  sleep 1
done
"${AWS[@]}" dynamodb create-table --endpoint-url http://relay-it-ddb:8000 --table-name relay \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST >/dev/null

docker run -d --name relay-it-fn --network "$NET" --platform "$PLATFORM" -p "$PORT:8080" \
  -v "$BOOTSTRAP:/var/runtime/bootstrap:ro" \
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_REGION=eu-central-1 \
  -e AWS_ENDPOINT_URL_DYNAMODB=http://relay-it-ddb:8000 -e AWS_ENDPOINT_URL_SSM=http://relay-it-ssm:4566 \
  -e RELAY_MODE=production -e DYNAMODB_TABLE=relay \
  -e RELAY_AUTH_TOKEN_PARAMETER=/jmap-apns-relay/it/auth-token -e APNS_KEY_PARAMETER=/jmap-apns-relay/it/apns-key \
  -e APNS_KEY_ID=ABCDE12345 -e APNS_TEAM_ID=ABCDE12345 -e APNS_TOPIC=com.example.relay-it -e APNS_ENVIRONMENT=sandbox \
  public.ecr.aws/lambda/provided:al2023 bootstrap >/dev/null
sleep 2

status=0
RELAY_INVOKE_URL="http://localhost:$PORT/2015-03-31/functions/function/invocations" \
  python3 -I "$ROOT/scripts/integration/drive.py" || status=$?
echo "--- relay log"
docker logs relay-it-fn 2>&1 | grep -E '\[push\]|INIT REPORT|error' || true
exit $status
