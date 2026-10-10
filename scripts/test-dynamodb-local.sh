#!/usr/bin/env bash
# Runs the store tests that need a real DynamoDB, inside the Linux toolchain,
# against DynamoDB Local with the template's table schema (index included).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NET=relay-ddb-it
stop() {
  docker rm -f relay-ddb-it >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
stop
trap stop EXIT
docker network create "$NET" >/dev/null
docker run -d --name relay-ddb-it --network "$NET" amazon/dynamodb-local:latest -jar DynamoDBLocal.jar -inMemory >/dev/null
AWS=(docker run --rm --network "$NET" -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=eu-central-1 amazon/aws-cli:latest)
for _ in $(seq 1 30); do
  "${AWS[@]}" dynamodb list-tables --endpoint-url http://relay-ddb-it:8000 >/dev/null 2>&1 && break
  sleep 1
done
"${AWS[@]}" dynamodb create-table --endpoint-url http://relay-ddb-it:8000 --table-name relay \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S AttributeName=entitlementId,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --global-secondary-indexes 'IndexName=byEntitlement,KeySchema=[{AttributeName=entitlementId,KeyType=HASH},{AttributeName=pk,KeyType=RANGE}],Projection={ProjectionType=KEYS_ONLY}' \
  --billing-mode PAY_PER_REQUEST >/dev/null
# Built in a scratch copy so the host's macOS .build is left alone.
docker run --rm --network "$NET" -v "$ROOT:/src:ro" -e DYNAMODB_LOCAL_URL=http://relay-ddb-it:8000 \
  -v relay-ddb-it-build:/w/.build swift:6.2 bash -c \
  'mkdir -p /w && cd /src && tar --exclude=.build -cf - . | tar -C /w -xf - && cd /w && swift test --filter DynamoDBLocalTests 2>&1 | grep -E "✔|✘|Test run|error:|passed|failed"'
