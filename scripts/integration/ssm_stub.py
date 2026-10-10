"""A Parameter Store stand-in for the Lambda integration run.

LocalStack's free image no longer runs without a licence, and the relay needs
exactly one SSM call (GetParameters, WithDecryption). This answers it, and
refuses anything not SigV4-signed for `ssm`, so a signing regression fails here.
Values come from the environment: SSM_PARAM_<n>=<name>=<file path>.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PARAMS = {}
for key, spec in os.environ.items():
    if key.startswith("SSM_PARAM_"):
        name, path = spec.split("=", 1)
        with open(path) as handle:
            PARAMS[name] = handle.read()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        auth = self.headers.get("authorization", "")
        signed = auth.startswith("AWS4-HMAC-SHA256 Credential=") and "/ssm/aws4_request" in auth
        if self.headers.get("x-amz-target") != "AmazonSSM.GetParameters" or not signed or body.get("WithDecryption") is not True:
            sys.stderr.write(f"ssm stub: rejected target={self.headers.get('x-amz-target')} signed={signed}\n")
            self.send_response(400)
            self.end_headers()
            return
        names = body["Names"]
        out = json.dumps({
            "Parameters": [{"Name": n, "Value": PARAMS[n]} for n in names if n in PARAMS],
            "InvalidParameters": [n for n in names if n not in PARAMS],
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/x-amz-json-1.1")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


HTTPServer(("0.0.0.0", 4566), Handler).serve_forever()
