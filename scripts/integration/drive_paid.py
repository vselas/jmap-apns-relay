"""Paid-mode checks for the Lambda relay in the runtime emulator.

Genuine App Store proofs need Apple's signature, so this checks what the real
binary must refuse: registration without proof, with a forged one, and a
forged server notification. The verifier itself is tested in Swift against a
chain shaped like Apple's (AppStoreEntitlementVerifierTests)."""
import base64, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from drive import invoke, check, failures  # noqa: E402  (reuses the event builder)

auth = {"authorization": "Bearer it-token", "content-type": "application/json"}
s, d = invoke("GET", "/v1/capabilities")
check("advertises appStoreEntitlement", s == 200 and "appStoreEntitlement" in json.loads(d)["features"], d[:200])
s, d = invoke("POST", "/v1/register", auth, b'{"deviceId":"paid-1"}')
check("no proof is 402 entitlementRequired", s == 402 and b"entitlementRequired" in d, f"{s} {d!r}")

def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")
forged = ".".join([
    b64url(json.dumps({"alg": "ES256", "x5c": ["AAAA", "BBBB", "CCCC"]}).encode()),
    b64url(json.dumps({"originalTransactionId": "1", "productId": "de.vselas.orcamail.pro", "bundleId": "com.example.relay-it",
                       "environment": "Sandbox", "signedDate": 1791000000000, "expiresDate": 4102444800000}).encode()),
    b64url(b"\x00" * 64),
])
body = json.dumps({"deviceId": "paid-1", "signedTransaction": forged}).encode()
s, d = invoke("POST", "/v1/register", auth, body)
check("forged transaction is 402 entitlementInvalid", s == 402 and b"entitlementInvalid" in d, f"{s} {d!r}")

s, d = invoke("POST", "/v1/appstore/notifications", {"content-type": "application/json"},
              json.dumps({"signedPayload": forged}).encode())
check("forged notification is 400", s == 400, f"{s} {d!r}")
s, _ = invoke("POST", "/v1/push/paid-1", body=b'{"@type":"StateChange"}')
check("unregistered device still 404", s == 404, s)
print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
