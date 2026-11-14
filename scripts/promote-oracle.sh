#!/usr/bin/env bash
# Promotes a tested commit to the Oracle cluster: fast-forwards the "oracle" branch to it (default: main).
# Argo CD on Oracle follows that branch (envs/oracle/apps). Refuses anything that is not a fast-forward, so the
# Oracle history only ever moves forward through commits that already ran on the local cluster.
# Usage: ./scripts/promote-oracle.sh [commit]
set -euo pipefail
cd "$(dirname "$0")/.."
REF="${1:-main}"
git fetch -q origin
SHA="$(git rev-parse "origin/$REF" 2>/dev/null || git rev-parse "$REF")"
git merge-base --is-ancestor origin/oracle "$SHA" || { echo "refused: $SHA is not ahead of oracle (not a fast-forward)" >&2; exit 1; }
echo "oracle: $(git rev-parse --short origin/oracle) -> $(git rev-parse --short "$SHA")"
git log --oneline "origin/oracle..$SHA"
git push origin "$SHA:refs/heads/oracle"
