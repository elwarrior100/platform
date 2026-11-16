#!/usr/bin/env bash
# Resume the platform after the cost kill-switch (ADR-017; envs/oracle/ops/cost-guard.yaml) stopped it. Run BY A
# PERSON from the Mac with their own OCI identity, AFTER finding (and fixing) what cost money (Cost Analysis by
# service). It:
#   1. shows the month's spend and the quota the guard created
#   2. deletes the quota cost-guard-zero (the VM itself may create quotas but never delete them)
#   3. tags the VM cost-guard-ack=<this month>: the guard then only reports for the rest of the month instead of
#      stopping the VM again an hour later (the spend is still over the limit until the month ends)
#   4. starts the VM
# Nothing else changes, and it asks before each step that changes the account. Dry run with --dry-run.
# Usage: ./scripts/cost-guard-resume.sh [--dry-run]
set -euo pipefail
DRY=false; [ "${1:-}" = --dry-run ] && DRY=true
TENANCY=$(awk -F= '/^tenancy/{gsub(/ /,"",$2); print $2; exit}' "${OCI_CONFIG_FILE:-$HOME/.oci/config}")
MONTH=$(date -u +%Y-%m)
ask() { [ "$DRY" = true ] && { echo "  (dry run: skipped)"; return 1; }; printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ]; }

SPEND=$(oci budgets budget budget list --compartment-id "$TENANCY" --all --query 'max_by(data, &"actual-spend")."actual-spend"' --raw-output)
echo "spend this month: EUR $SPEND (the guard trips at EUR 1.00)"

QUOTA=$(oci limits quota list --compartment-id "$TENANCY" --name cost-guard-zero --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -n "$QUOTA" ] && [ "$QUOTA" != null ]; then
  echo "quota cost-guard-zero is present (nothing paid can be created while it is)"
  if ask "delete the quota cost-guard-zero?"; then oci limits quota delete --quota-id "$QUOTA" --force >/dev/null; echo "  quota deleted"; fi
else
  echo "no quota cost-guard-zero"
fi

INSTANCE=$(oci compute instance list --compartment-id "$TENANCY" --display-name "${INSTANCE_NAME:-agente-01}" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output)
[ -n "$INSTANCE" ] && [ "$INSTANCE" != null ] || { echo "VM ${INSTANCE_NAME:-agente-01} not found (set INSTANCE_NAME)" >&2; exit 1; }
STATE=$(oci compute instance get --instance-id "$INSTANCE" --query 'data."lifecycle-state"' --raw-output)
echo "VM state: $STATE"

# freeform tags are replaced as a whole: keep the others and set only cost-guard-ack
TAGS=$(oci compute instance get --instance-id "$INSTANCE" --query 'data."freeform-tags"' --output json \
  | python3 -c 'import json,sys; t=json.load(sys.stdin) or {}; t["cost-guard-ack"]=sys.argv[1]; print(json.dumps(t))' "$MONTH")
if ask "tag the VM cost-guard-ack=$MONTH (the guard only reports until the month ends)?"; then
  oci compute instance update --instance-id "$INSTANCE" --freeform-tags "$TAGS" --force >/dev/null; echo "  tagged"
fi

if [ "$STATE" = STOPPED ] && ask "start the VM?"; then
  oci compute instance action --instance-id "$INSTANCE" --action START >/dev/null
  echo "  START requested; in ~3 minutes: ssh ubuntu@platform-oracle 'sudo k3s kubectl get nodes'"
fi
