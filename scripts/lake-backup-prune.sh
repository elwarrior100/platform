#!/usr/bin/env bash
# Monthly prune of the lake copy (Object Storage bucket platform-lake-backup), run BY A PERSON from the Mac with their
# own OCI identity: the VM may create and read there but never delete (ADR-013), and that stays so.
# The copy is in bundles (ADR-016): bundles/<time>-full.tar.gz on the 1st of the month, <time>-incr.tar.gz nightly,
# and catalog/<time>.txt.gz. What can go:
#   - bundles and catalogs older than the SECOND newest full bundle (the last two monthly cycles stay: a restore
#     needs the newest full and what came after it; the previous cycle is the spare)
#   - the legacy object-by-object copy (anything outside bundles/ and catalog/), once a full bundle is at least 7 days
#     old, i.e. the daily drill has restored from bundles for a week
# Every deletion is one Object Storage request (50,000 a month are free): it prints how many it would use, refuses more
# than --max at once, and is best run early in a month. Dry run by default; --apply asks you to type the count.
# Usage: ./scripts/lake-backup-prune.sh [--apply] [--max N]      (default N = 20000)
set -euo pipefail
APPLY=false; MAX=20000
while [ $# -gt 0 ]; do
  case "$1" in --apply) APPLY=true ;; --max) MAX="${2:?number}"; shift ;; *) echo "unknown option $1" >&2; exit 1 ;; esac
  shift
done
BUCKET=platform-lake-backup
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
NS=$(oci os ns get --query data --raw-output)
echo "listing $BUCKET (about one request per 1000 objects)..."
oci os object list -ns "$NS" -bn "$BUCKET" --all --fields name,timeCreated,size \
  --query 'data[].[name,"time-created",size]' --output json > "$TMP/all.json"
python3 - "$TMP/all.json" "$TMP/candidates.txt" "$MAX" <<'PY'
import datetime, json, sys
objs = json.load(open(sys.argv[1])); out, cap = sys.argv[2], int(sys.argv[3])
now = datetime.datetime.now(datetime.timezone.utc)
when = lambda t: datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
fulls = sorted((n, when(t)) for n, t, s in objs if n.startswith("bundles/") and n.endswith("-full.tar.gz"))
stamp = lambda n: n.split("/")[1][:15]                     # 20261201T030000
cand, reasons = [], {}
if len(fulls) >= 2:                                        # keep from the second newest full onwards
    keep_from = stamp(fulls[-2][0])
    for n, t, s in objs:
        if (n.startswith("bundles/") or n.startswith("catalog/")) and stamp(n) < keep_from:
            cand.append((n, s)); reasons[n] = "older than the previous full cycle"
legacy = [(n, s) for n, t, s in objs if not n.startswith(("bundles/", "catalog/"))]
if legacy:
    if fulls and (now - fulls[-1][1]).days >= 7:
        cand += legacy; reasons.update({n: "legacy object-by-object copy" for n, _ in legacy})
    else:
        print(f"legacy object-by-object copy: {len(legacy)} objects kept until a full bundle is 7 days old")
size = sum(s for _, s in cand) / 1e6
print(f"bucket: {len(objs)} objects, {sum(s for *_, s in objs) / 1e6:.0f} MB | full bundles: {len(fulls)}")
print(f"candidates: {len(cand)} objects, {size:.0f} MB -> about {len(cand)} delete requests (50,000 free a month)")
for r in sorted(set(reasons.values())):
    print(f"  {sum(1 for v in reasons.values() if v == r)}: {r}")
if len(cand) > cap:
    print(f"REFUSED: more than --max {cap} deletions in one run (raise --max, ideally early in a month)"); sys.exit(2)
open(out, "w").write("".join(n + "\n" for n, _ in cand))
PY
N=$(wc -l < "$TMP/candidates.txt" | tr -d ' ')
[ "$N" -gt 0 ] || { echo "nothing to prune"; exit 0; }
head -3 "$TMP/candidates.txt" | sed 's/^/  e.g. /'
[ "$APPLY" = true ] || { echo "dry run: run again with --apply to delete these $N objects"; exit 0; }
printf 'Delete %s objects from %s? Type the number to confirm: ' "$N" "$BUCKET"; read -r answer
[ "$answer" = "$N" ] || { echo "not confirmed; nothing deleted"; exit 1; }
deleted=0
while read -r name; do
  oci os object delete -ns "$NS" -bn "$BUCKET" --object-name "$name" --force >/dev/null && deleted=$((deleted + 1))
done < "$TMP/candidates.txt"
echo "deleted $deleted of $N objects"
