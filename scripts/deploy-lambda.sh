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
# Own domain (recommended for anything you hand out): DOMAIN_NAME=push.example.com,
# whose public Route 53 zone is in this account. The script deploys a
# certificate stack in us-east-1 (CloudFront requires it there), then serves
# the relay through CloudFront on that name. Once set, later deploys keep it
# without passing it again; DOMAIN_NAME=none removes it.
#
# Selling push (App Store subscription required for APNs delivery):
#   APPSTORE_PRODUCT_IDS=de.vselas.orcamail.pro.yearly,de.vselas.orcamail.pro.monthly
#   APPSTORE_APP_APPLE_ID=1234567890     # App Store Connect → App Information → Apple ID
#   APPSTORE_ENVIRONMENT=Production      # or Sandbox, or Production,Sandbox (App Store + TestFlight)
#   MAX_DEVICES_PER_SUBSCRIPTION=10
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=${STAGE:-prod}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
: "${REGION:?set AWS_REGION}"
: "${APNS_KEY_ID:?set APNS_KEY_ID}" "${APNS_TEAM_ID:?set APNS_TEAM_ID}" "${APNS_TOPIC:?set APNS_TOPIC}"
APNS_ENVIRONMENT=${APNS_ENVIRONMENT:-production}
RESERVED_CONCURRENCY=${RESERVED_CONCURRENCY:-20}
# A new account's whole Lambda quota is 10, all of it unreservable. Reserving
# anything would fail the stack, so fall back to none and say so.
account_quota=$(aws lambda get-account-settings --region "$REGION" --query AccountLimit.ConcurrentExecutions --output text)
if (( RESERVED_CONCURRENCY > 0 && account_quota - RESERVED_CONCURRENCY < 10 )); then
  echo "Account Lambda quota is $account_quota; deploying without reserved concurrency (the quota is the ceiling)."
  echo "Request more: aws service-quotas request-service-quota-increase --service-code lambda --quota-code L-B99A9384 --desired-value 1000"
  RESERVED_CONCURRENCY=0
fi
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

# 3. Own domain: certificate in us-east-1, validated through the zone.
# An unset DOMAIN_NAME keeps whatever the stack already serves, so a plain
# code redeploy can never take the domain away from installed apps.
current_param() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text 2>/dev/null || true
}
if [[ -z "${DOMAIN_NAME:-}" ]]; then
  DOMAIN_NAME=$(current_param DomainName)
  [[ "$DOMAIN_NAME" == None ]] && DOMAIN_NAME=""
  [[ -n "$DOMAIN_NAME" ]] && echo "Keeping domain $DOMAIN_NAME"
fi
[[ "$DOMAIN_NAME" == none ]] && DOMAIN_NAME=""
CERTIFICATE_ARN="" HOSTED_ZONE_ID=""
if [[ -n "$DOMAIN_NAME" ]]; then
  # The longest public zone that is a suffix of the name.
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --output text \
    --query "HostedZones[?Config.PrivateZone==\`false\`].[Name,Id]" |
    awk -v d="$DOMAIN_NAME." '{ n=$1; if ((d == n || substr(d, length(d)-length(n)) == "." n) && length(n) > best) { best=length(n); id=$2 } } END { sub("/hostedzone/", "", id); print id }')
  [[ -n "$HOSTED_ZONE_ID" ]] || { echo "No public Route 53 zone for $DOMAIN_NAME in this account" >&2; exit 1; }
  CERT_STACK="jmap-apns-relay-$STAGE-certificate"
  echo "Certificate for $DOMAIN_NAME (zone $HOSTED_ZONE_ID) in us-east-1; the first one waits for DNS validation"
  aws cloudformation deploy --region us-east-1 --stack-name "$CERT_STACK" \
    --template-file "$ROOT/deploy/aws/certificate.yaml" --no-fail-on-empty-changeset \
    --parameter-overrides DomainName="$DOMAIN_NAME" HostedZoneId="$HOSTED_ZONE_ID"
  CERTIFICATE_ARN=$(aws cloudformation describe-stacks --region us-east-1 --stack-name "$CERT_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text)
fi

# 4. The stack. A first create that failed leaves ROLLBACK_COMPLETE, which can
# only be deleted, not updated.
if [[ "$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" == ROLLBACK_COMPLETE ]]; then
  echo "Removing $STACK left in ROLLBACK_COMPLETE by a failed first create"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
fi
aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file "$ROOT/deploy/aws/template.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    Stage="$STAGE" CodeBucket="$BUCKET" CodeKey="$KEY" \
    APNsKeyId="$APNS_KEY_ID" APNsTeamId="$APNS_TEAM_ID" APNsTopic="$APNS_TOPIC" \
    APNsEnvironment="$APNS_ENVIRONMENT" ReservedConcurrency="$RESERVED_CONCURRENCY" \
    AppStoreProductIds="${APPSTORE_PRODUCT_IDS:-}" AppStoreAppAppleId="${APPSTORE_APP_APPLE_ID:-}" \
    AppStoreEnvironment="${APPSTORE_ENVIRONMENT:-Production}" \
    MaxDevicesPerSubscription="${MAX_DEVICES_PER_SUBSCRIPTION:-10}" \
    DomainName="$DOMAIN_NAME" CertificateArn="$CERTIFICATE_ARN" HostedZoneId="$HOSTED_ZONE_ID"

output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
URL=$(output RelayURL)
FUNCTION_URL=$(output FunctionURL)
echo "Relay URL: $URL"
[[ "$URL" != "$FUNCTION_URL" ]] && echo "Function URL (origin, not for apps): $FUNCTION_URL"
if [[ -n "${APPSTORE_PRODUCT_IDS:-}" ]]; then
  echo "App Store Server Notifications V2 URL: ${URL}v1/appstore/notifications"
fi

# 5. Smoke test: the public endpoints answer, and the cold start loaded secrets.
# Through the domain too; a fresh name can take a minute to resolve everywhere.
for u in "$FUNCTION_URL" "$URL"; do
  curl -fsS --retry 6 --retry-delay 10 --retry-all-errors "${u%/}/healthz" >/dev/null && echo "healthz ok: $u"
done
curl -fsS "${URL%/}/v1/capabilities" && echo
