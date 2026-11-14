#!/usr/bin/env bash
# Compares the OCI service ranges allowed in the backup and ops egress policies with the list Oracle publishes
# (tags OSN or OBJECT_STORAGE, region eu-madrid-1). Exits 1 with the difference if they no longer match, so the policies can be updated
# before the nightly jobs start failing. Runs weekly in CI (validate.yml) and by hand.
# Usage: ./scripts/check-oci-cidrs.sh [region]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${1:-eu-madrid-1}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json -o "$TMP/ranges.json"
python3 -I - "$TMP/ranges.json" "$REGION" <<'PY' | sort > "$TMP/want"
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["regions"]:
    if r["region"] == sys.argv[2]:
        for c in (c["cidr"] for c in r["cidrs"] if {"OSN", "OBJECT_STORAGE"} & set(c["tags"])):
            print(c)
PY
[ -s "$TMP/want" ] || { echo "no OSN ranges found for $REGION" >&2; exit 1; }
rc=0
for p in envs/oracle/backup/networkpolicy.yaml envs/oracle/ops/networkpolicy.yaml; do
  sed -n '/oci-osn-cidrs:begin/,/oci-osn-cidrs:end/p' "$ROOT/$p" | grep -o 'cidr: [0-9./]*' | cut -d' ' -f2 | sort > "$TMP/have"
  if diff -u "$TMP/have" "$TMP/want" > "$TMP/diff"; then echo "$p: up to date ($(wc -l < "$TMP/have" | tr -d ' ') ranges)"
  else echo "$p: Oracle's list changed (- in the policy, + published):"; cat "$TMP/diff"; rc=1; fi
done
exit $rc
