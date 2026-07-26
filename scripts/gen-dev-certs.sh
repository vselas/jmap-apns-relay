#!/usr/bin/env bash
# Generates a self-signed TLS cert for local testing of the relay.
#
#   ./scripts/gen-dev-certs.sh [hostname ...]
#
# Output (gitignored) in ./secrets:
#   tls.crt / tls.key   server cert + key for the given hostnames
#
# The JMAP server that posts to the relay must trust tls.crt (or its CA). For a
# self-signed cert like this, add it to that server's trust store. In
# production use a real cert (e.g. from your reverse proxy or Let's Encrypt).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/secrets"
mkdir -p "$DIR"

HOSTS=("$@")
[[ ${#HOSTS[@]} -eq 0 ]] && HOSTS=("localhost")

san_parts=()
for h in "${HOSTS[@]}"; do san_parts+=("DNS:$h"); done
san_parts+=("IP:127.0.0.1")
SAN="subjectAltName=$(IFS=,; echo "${san_parts[*]}")"

if [[ -f "$DIR/tls.crt" ]]; then
  echo "cert already exists in $DIR — delete tls.crt/tls.key to regenerate."
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
  -keyout "$DIR/tls.key" -out "$DIR/tls.crt" \
  -subj "/CN=${HOSTS[0]}" \
  -addext "$SAN" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=serverAuth"

echo "Wrote $DIR/tls.crt and $DIR/tls.key for: ${HOSTS[*]}"
