#!/usr/bin/env bash
# Builds the Lambda deployment zip: .build/lambda/relay-lambda.zip
#
#   scripts/build-lambda.sh            # arm64 (the template's default)
#   ARCH=x86_64 scripts/build-lambda.sh
#
# Needs Docker. Cross-building with swift-sdk would also work, but the
# Amazon Linux 2023 image is what provided.al2023 runs, so its glibc is the right one.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-arm64}
case "$ARCH" in
  arm64) PLATFORM=linux/arm64 ;;
  x86_64) PLATFORM=linux/amd64 ;;
  *) echo "ARCH must be arm64 or x86_64" >&2; exit 2 ;;
esac
OUT="$ROOT/.build/lambda"
rm -rf "$OUT"
docker build --platform "$PLATFORM" -f "$ROOT/Dockerfile.lambda" --output "type=local,dest=$OUT" "$ROOT"
(cd "$OUT" && rm -f relay-lambda.zip && zip -q -9 relay-lambda.zip bootstrap)
echo "Built $OUT/relay-lambda.zip ($(du -h "$OUT/relay-lambda.zip" | cut -f1), $ARCH)"
