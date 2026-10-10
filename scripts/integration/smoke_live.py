"""Smoke-tests a deployed relay over its real URL: auth, registration, the
webhook, the poll, binary bodies, a real APNs call with a throwaway token,
then unregisters the test device.

  python3 -I scripts/integration/smoke_live.py https://<id>.lambda-url.<region>.on.aws/

Reads the bearer token from ~/.config/orcamail/relay-auth-token, or
RELAY_AUTH_TOKEN_FILE."""
import base64, json, os, sys, urllib.request, urllib.error
URL = sys.argv[1].rstrip("/")
TOKEN = open(os.path.expanduser(os.environ.get("RELAY_AUTH_TOKEN_FILE", "~/.config/orcamail/relay-auth-token"))).read().strip()
dev = "orcamail-smoke-" + os.urandom(6).hex()
def call(method, path, headers=None, body=None):
    req = urllib.request.Request(URL + path, data=body, method=method, headers={"user-agent": "relay-smoke", **(headers or {})})
    try:
        r = urllib.request.urlopen(req, timeout=30); return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
fails = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  [{detail}]")); (None if ok else fails.append(name))
auth = {"authorization": "Bearer " + TOKEN, "content-type": "application/json"}
s, d = call("GET", "/readyz"); check("readyz", s == 200, s)
s, _ = call("POST", "/v1/register", {"content-type": "application/json"}, json.dumps({"deviceId": dev}).encode()); check("register without token 401", s == 401, s)
s, _ = call("POST", "/v1/register", {**auth, "authorization": "Bearer wrong"}, json.dumps({"deviceId": dev}).encode()); check("wrong token 401", s == 401, s)
s, _ = call("POST", "/v1/push/" + dev, body=b'{"@type":"StateChange"}'); check("unknown device 404", s == 404, s)
s, d = call("POST", "/v1/register", auth, json.dumps({"deviceId": dev}).encode()); check("register", s == 204, f"{s} {d!r}")
s, d = call("POST", "/v1/push/" + dev, {"content-type": "application/json"}, b'{"@type":"PushVerification","pushSubscriptionId":"x","verificationCode":"smoke-code"}'); check("verification webhook", s == 200, f"{s} {d!r}")
cipher = bytes(range(256))
s, d = call("POST", "/v1/push/" + dev, {"content-encoding": "aes128gcm", "content-type": "application/octet-stream"}, cipher); check("encrypted webhook", s == 200, f"{s} {d!r}")
s, d = call("GET", "/v1/pending/" + dev, auth)
items = json.loads(d) if s == 200 else []
check("poll returns both", s == 200 and len(items) == 2, f"{s} {d[:200]!r}")
if len(items) == 2:
    check("verification intact", b"smoke-code" in base64.b64decode(items[0]["body"]))
    check("ciphertext byte-for-byte through the Function URL", base64.b64decode(items[1]["body"]) == cipher)
s, _ = call("POST", "/v1/register", auth, json.dumps({"deviceId": dev, "apnsToken": "ab" * 32}).encode()); check("register with APNs token", s == 204, s)
s, d = call("POST", "/v1/push/" + dev, {"content-type": "application/json"}, b'{"@type":"StateChange","changed":{}}'); check("StateChange to real APNs", s == 200, f"{s} {d!r}")
s, _ = call("DELETE", "/v1/register/" + dev, auth); check("unregister (cleanup)", s == 204, s)
print(f"\n{len(fails)} failure(s); device {dev}")
sys.exit(1 if fails else 0)
