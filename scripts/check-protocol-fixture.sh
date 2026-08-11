#!/usr/bin/env bash
# Validates protocol v1 and optionally compares Sigill's committed fixture.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE="$ROOT/docs/fixtures/relay-protocol-v1.json"

python3 - "$FIXTURE" <<'PY'
import base64, json, pathlib, sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text())
caps = contract["capabilities"]
required = {"encryptedForwarding", "plaintextMetadata", "pendingPoll", "unregister"}
assert caps["protocol"] == "jmap-apns-relay"
assert caps["protocolVersion"] == 1
assert required <= set(caps["features"])
assert caps["limits"]["maxAPNsPayloadBytes"] == 4096
plain = contract["plaintextAPNs"]
assert plain["aps"]["mutable-content"] == 1
assert plain["sigill"]["protocolVersion"] == 1
assert plain["stateChange"]["@type"] == "StateChange"
encrypted = contract["encryptedAPNs"]
assert encrypted["aps"]["mutable-content"] == 1
assert base64.b64decode(encrypted["sigill"]["encrypted"], validate=True)
assert "stateChange" not in encrypted
print("relay protocol v1 fixture is valid")
PY

if [[ "${1:-}" == "--self" ]]; then
  exit 0
fi

SIGILL_PATH=${SIGILL_PATH:-}
if [[ -z "$SIGILL_PATH" ]]; then
  echo "Set SIGILL_PATH to compare Sigill's fixture (or pass --self)." >&2
  exit 2
fi

sigill_fixture="$SIGILL_PATH/docs/fixtures/relay-protocol-v1.json"
if [[ ! -f "$sigill_fixture" ]]; then
  echo "Sigill fixture not found: $sigill_fixture" >&2
  exit 1
fi
cmp "$FIXTURE" "$sigill_fixture"
echo "Relay and Sigill protocol fixtures match."
