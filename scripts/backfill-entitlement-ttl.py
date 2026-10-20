#!/usr/bin/env python3
"""Gives entitlements written before the retention change their TTL.

Since entitlements carry `expiresAt` (DynamoDB's TTL attribute) set to the end
of their retention, 90 days after the period ends or Apple revoked them, the
relay keeps no lapsed subscription forever. Items written before that have no
`expiresAt`, and a subscription that has lapsed is never written again, so this
sets it once, by the same rule as `Entitlement.deletableAfter`.

Dry run by default; `--apply` writes. Each write is conditional on the item
still having no `expiresAt`, so a relay writing the item at the same time wins.
An item whose retention is already over gets a past TTL, and DynamoDB deletes
it within a day or two.

    AWS_PROFILE=orcamail AWS_REGION=eu-central-1 \\
      scripts/backfill-entitlement-ttl.py [--stage prod] [--apply]
"""
import argparse
import json
import math
import subprocess
import sys
from datetime import datetime, timezone

RETENTION_SECONDS = 90 * 24 * 3600  # Entitlement.retention


def aws(*args: str) -> dict:
    out = subprocess.run(["aws", "dynamodb", *args, "--output", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        raise subprocess.CalledProcessError(out.returncode, "aws dynamodb " + args[0], out.stdout, out.stderr)
    return json.loads(out.stdout) if out.stdout.strip() else {}


def number(item: dict, name: str) -> float | None:
    value = item.get(name, {}).get("N")
    return float(value) if value is not None else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", default="prod")
    parser.add_argument("--apply", action="store_true", help="write the TTLs (default: only list them)")
    args = parser.parse_args()
    table = f"jmap-apns-relay-{args.stage}"

    items: list[dict] = []
    start: dict | None = None
    while True:
        request = [
            "scan", "--table-name", table,
            "--filter-expression", "begins_with(pk, :prefix) AND attribute_not_exists(expiresAt)",
            "--expression-attribute-values", json.dumps({":prefix": {"S": "entitlement#"}}),
        ]
        if start:
            request += ["--exclusive-start-key", json.dumps(start)]
        try:
            page = aws(*request)
        except subprocess.CalledProcessError as error:
            sys.exit(error.stderr.strip())
        items += page.get("Items", [])
        start = page.get("LastEvaluatedKey")
        if not start:
            break

    now = datetime.now(timezone.utc).timestamp()
    planned = 0
    for item in items:
        pk = item["pk"]["S"]
        end = number(item, "revokedAt") or number(item, "periodEndsAt")
        if end is None:
            print(f"keep  {pk}: non-expiring, no TTL")
            continue
        ttl = math.ceil(end + RETENTION_SECONDS)
        when = datetime.fromtimestamp(ttl, timezone.utc).strftime("%Y-%m-%d")
        state = "already past, DynamoDB deletes it" if ttl <= now else f"deleted after {when}"
        print(f"{'set ' if args.apply else 'would'} {pk}: expiresAt {ttl} ({state})")
        planned += 1
        if args.apply:
            try:
                aws(
                    "update-item", "--table-name", table,
                    "--key", json.dumps({"pk": item["pk"], "sk": item["sk"]}),
                    "--update-expression", "SET expiresAt = :ttl",
                    "--condition-expression", "attribute_not_exists(expiresAt)",
                    "--expression-attribute-values", json.dumps({":ttl": {"N": str(ttl)}}),
                )
            except subprocess.CalledProcessError as error:
                if "ConditionalCheckFailedException" in error.stderr:
                    print(f"      {pk}: the relay wrote it meanwhile, left as is")
                else:
                    sys.exit(error.stderr)

    verb = "set" if args.apply else "to set (run with --apply)"
    print(f"{len(items)} entitlements without a TTL, {planned} {verb}")


if __name__ == "__main__":
    main()
