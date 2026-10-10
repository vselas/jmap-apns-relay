"""Drives the Lambda relay through the runtime interface emulator with
Function URL events: the whole relay protocol, against real DynamoDB Local.
Run by scripts/test-lambda-local.sh."""
import base64, json, sys, urllib.request
import os
URL = os.environ.get("RELAY_INVOKE_URL", "http://localhost:9001/2015-03-31/functions/function/invocations")
def invoke(method, path, headers=None, body=None):
    headers = dict(headers or {})
    event = {
        "version": "2.0", "routeKey": "$default", "rawPath": path, "rawQueryString": "",
        "headers": {"host": "relay.lambda-url.eu-central-1.on.aws", **headers},
        "requestContext": {"accountId": "anonymous", "apiId": "relay", "domainName": "relay.lambda-url.eu-central-1.on.aws",
            "domainPrefix": "relay", "requestId": "r", "routeKey": "$default", "stage": "$default",
            "time": "10/Oct/2026:12:00:00 +0000", "timeEpoch": 1791000000000,
            "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "1.2.3.4", "userAgent": "it"}},
        "isBase64Encoded": body is not None,
    }
    if body is not None:
        event["body"] = base64.b64encode(body).decode()
    req = urllib.request.Request(URL, data=json.dumps(event).encode(), method="POST")
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    raw = out.get("body") or ""
    data = base64.b64decode(raw) if out.get("isBase64Encoded") else raw.encode()
    return out.get("statusCode"), data

failures = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond: failures.append(name)

auth = {"authorization": "Bearer it-token"}
s, d = invoke("GET", "/healthz"); check("healthz", s == 200, f"{s} {d!r}")
s, d = invoke("GET", "/v1/capabilities"); check("capabilities", s == 200 and json.loads(d)["protocol"] == "jmap-apns-relay", f"{s} {d!r}")
s, _ = invoke("POST", "/v1/push/dev-it", body=b'{"@type":"StateChange"}'); check("unknown device webhook is 404", s == 404, s)
s, _ = invoke("POST", "/v1/register", body=b'{"deviceId":"dev-it"}'); check("register without token is 401", s == 401, s)
s, _ = invoke("POST", "/v1/register", {**auth, "authorization": "Bearer nope"}, b'{"deviceId":"dev-it"}'); check("register with wrong token is 401", s == 401, s)
s, d = invoke("POST", "/v1/register", {**auth, "content-type": "application/json"}, b'{"deviceId":"dev-it"}'); check("register", s == 204, f"{s} {d!r}")

verification = b'{"@type":"PushVerification","pushSubscriptionId":"ps1","verificationCode":"code-123"}'
s, d = invoke("POST", "/v1/push/dev-it", body=verification); check("verification webhook", s == 200, f"{s} {d!r}")
cipher = bytes([0x00, 0xFF, 0xFE, 0x80, 0x41, 0x04, 0xC3, 0x28, 0x7B, 0x00]) * 20
s, d = invoke("POST", "/v1/push/dev-it", {"content-encoding": "aes128gcm"}, cipher); check("encrypted webhook", s == 200, f"{s} {d!r}")
s, _ = invoke("GET", "/v1/pending/dev-it"); check("poll without token is 401", s == 401, s)
s, d = invoke("GET", "/v1/pending/dev-it", auth)
items = json.loads(d) if s == 200 else []
check("poll returns both, in order", s == 200 and len(items) == 2, f"{s} {d[:200]!r}")
if len(items) == 2:
    check("verification text intact", b"code-123" in base64.b64decode(items[0]["body"]))
    check("ciphertext byte-for-byte", base64.b64decode(items[1]["body"]) == cipher and items[1].get("contentEncoding") == "aes128gcm")
s, d = invoke("GET", "/v1/pending/dev-it", auth); check("second poll empty", s == 200 and json.loads(d) == [], f"{s} {d!r}")

# 60 pushes: cap at 50 on drain, everything deleted (exercises BatchWriteItem paging).
for i in range(60):
    invoke("POST", "/v1/push/dev-it", body=json.dumps({"@type": "PushVerification", "n": i}).encode())
s, d = invoke("GET", "/v1/pending/dev-it", auth)
items = json.loads(d)
check("queue capped at newest 50", len(items) == 50 and json.loads(base64.b64decode(items[0]["body"]))["n"] == 10, len(items))
s, d = invoke("GET", "/v1/pending/dev-it", auth); check("all 60 deleted", json.loads(d) == [], d[:80])

# A StateChange with an APNs token: the sender really tries APNs sandbox with a
# throwaway key; Apple rejects the token (403/400), and the relay must still 200.
s, _ = invoke("POST", "/v1/register", auth, b'{"deviceId":"dev-it","apnsToken":"' + b"ab" * 32 + b'"}'); check("re-register with APNs token", s == 204, s)
s, d = invoke("POST", "/v1/push/dev-it", body=b'{"@type":"StateChange","changed":{"a":{"Email":"s1"}}}'); check("StateChange accepted despite APNs refusal", s == 200, f"{s} {d!r}")

s, _ = invoke("DELETE", "/v1/register/dev-it"); check("unregister without token is 401", s == 401, s)
s, _ = invoke("DELETE", "/v1/register/dev-it", auth); check("unregister", s == 204, s)
s, _ = invoke("DELETE", "/v1/register/dev-it", auth); check("unregister twice is 404", s == 404, s)
s, _ = invoke("POST", "/v1/push/dev-it", body=b"{}"); check("webhook after unregister is 404", s == 404, s)
print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
