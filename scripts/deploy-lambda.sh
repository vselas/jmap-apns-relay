#!/usr/bin/env bash
# Deploys the relay to AWS Lambda: S3 code bucket, secrets, CloudFormation stack.
# Safe to re-run; every step is idempotent, and secrets are only written when
# you pass them.
#
# First deploy:
#   export AWS_PROFILE=relay AWS_REGION=eu-central-1
#   scripts/build-lambda.sh
#   APNS_KEY_FILE=~/keys/AuthKey_ABCDE12345.p8 \
#   APNS_KEY_ID=ABCDE12345 APNS_TEAM_ID=UA5PQ9SVT8 APNS_TOPIC=de.vselas.orcamail \
#   RELAY_AUTH_TOKEN="$(openssl rand -base64 48)" \
#     scripts/deploy-lambda.sh
#
# Code-only redeploy (secrets kept as they are):
#   scripts/build-lambda.sh && APNS_KEY_ID=… APNS_TEAM_ID=… APNS_TOPIC=… scripts/deploy-lambda.sh
#
# Optional: STAGE (prod), APNS_ENVIRONMENT (production | sandbox),
# RESERVED_CONCURRENCY (20).
#
# Selling push (App Store subscription required for APNs delivery):
#   APPSTORE_PRODUCT_IDS=de.vselas.orcamail.pro.yearly,de.vselas.orcamail.pro.monthly
#   APPSTORE_APP_APPLE_ID=1234567890     # App Store Connect → App Information → Apple ID
#   APPSTORE_ENVIRONMENT=Production      # or Sandbox
#   MAX_DEVICES_PER_SUBSCRIPTION=10
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=${STAGE:-prod}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
: "${REGION:?set AWS_REGION}"
: "${APNS_KEY_ID:?set APNS_KEY_ID}" "${APNS_TEAM_ID:?set APNS_TEAM_ID}" "${APNS_TOPIC:?set APNS_TOPIC}"
APNS_ENVIRONMENT=${APNS_ENVIRONMENT:-production}
RESERVED_CONCURRENCY=${RESERVED_CONCURRENCY:-20}
ZIP="$ROOT/.build/lambda/relay-lambda.zip"
[[ -f "$ZIP" ]] || { echo "Build first: scripts/build-lambda.sh" >&2; exit 2; }

STACK="jmap-apns-relay-$STAGE"
PARAM_PREFIX="/jmap-apns-relay/$STAGE"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="jmap-apns-relay-code-$ACCOUNT-$REGION"
echo "Account $ACCOUNT, region $REGION, stack $STACK"

# 1. Secrets. SecureString under the AWS-managed key; never in the template.
# Values go in by file (file://), so neither secret appears in a process
# listing on this machine.
put_secret() {  # name, file
  aws ssm put-parameter --region "$REGION" --name "$PARAM_PREFIX/$1" --type SecureString \
    --value "file://$2" --overwrite >/dev/null
  echo "Stored $PARAM_PREFIX/$1"
}
if [[ -n "${RELAY_AUTH_TOKEN:-}" ]]; then
  token_file=$(mktemp)
  trap 'rm -f "$token_file"' EXIT
  printf '%s' "$RELAY_AUTH_TOKEN" > "$token_file"
  put_secret auth-token "$token_file"
fi
if [[ -n "${APNS_KEY_FILE:-}" ]]; then
  grep -q "BEGIN PRIVATE KEY" "$APNS_KEY_FILE" || { echo "$APNS_KEY_FILE is not a .p8 key" >&2; exit 1; }
  put_secret apns-key "$APNS_KEY_FILE"
fi
for name in auth-token apns-key; do
  aws ssm get-parameter --region "$REGION" --name "$PARAM_PREFIX/$name" --query Parameter.Name --output text >/dev/null 2>&1 || {
    echo "Missing $PARAM_PREFIX/$name. Pass RELAY_AUTH_TOKEN / APNS_KEY_FILE on the first deploy." >&2
    exit 1
  }
done

# 2. Code bucket: private, encrypted, old builds expire after 30 days.
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [[ "$REGION" == us-east-1 ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
    '{"Rules":[{"ID":"expire-old-builds","Status":"Enabled","Filter":{"Prefix":"builds/"},"Expiration":{"Days":30}}]}'
  echo "Created bucket $BUCKET"
fi
# A content-addressed key: an unchanged build is not a stack change, a new one is.
KEY="builds/$(shasum -a 256 "$ZIP" | cut -c1-16).zip"
aws s3 cp --region "$REGION" --only-show-errors "$ZIP" "s3://$BUCKET/$KEY"

# 3. The stack.
aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file "$ROOT/deploy/aws/template.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    Stage="$STAGE" CodeBucket="$BUCKET" CodeKey="$KEY" \
    APNsKeyId="$APNS_KEY_ID" APNsTeamId="$APNS_TEAM_ID" APNsTopic="$APNS_TOPIC" \
    APNsEnvironment="$APNS_ENVIRONMENT" ReservedConcurrency="$RESERVED_CONCURRENCY" \
    AppStoreProductIds="${APPSTORE_PRODUCT_IDS:-}" AppStoreAppAppleId="${APPSTORE_APP_APPLE_ID:-}" \
    AppStoreEnvironment="${APPSTORE_ENVIRONMENT:-Production}" \
    MaxDevicesPerSubscription="${MAX_DEVICES_PER_SUBSCRIPTION:-10}"

URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RelayURL'].OutputValue" --output text)
echo "Relay URL: $URL"
if [[ -n "${APPSTORE_PRODUCT_IDS:-}" ]]; then
  echo "App Store Server Notifications V2 URL: ${URL}v1/appstore/notifications"
fi

# 4. Smoke test: the public endpoints answer, and the cold start loaded secrets.
curl -fsS "${URL%/}/healthz" >/dev/null && echo "healthz ok"
curl -fsS "${URL%/}/v1/capabilities" && echo
