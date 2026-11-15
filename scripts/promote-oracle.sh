#!/usr/bin/env bash
# Promotes a tested commit to the Oracle cluster: fast-forwards the "oracle" branch to it (default: main).
# Argo CD on Oracle follows that branch (envs/oracle/apps). Refuses anything that is not a fast-forward, so the
# Oracle history only ever moves forward through commits that already ran on the local cluster.
# Usage: ./scripts/promote-oracle.sh [commit]
set -euo pipefail
cd "$(dirname "$0")/.."
REF="${1:-main}"
git fetch -q origin
# a branch name resolves on origin; a commit SHA resolves as itself (--verify: no output when it does not resolve)
SHA="$(git rev-parse -q --verify "origin/$REF^{commit}" || git rev-parse --verify "$REF^{commit}")"
git merge-base --is-ancestor origin/oracle "$SHA" || { echo "refused: $SHA is not ahead of oracle (not a fast-forward)" >&2; exit 1; }
# only commits that are on main, i.e. that the local cluster (which follows main) has already run
git merge-base --is-ancestor "$SHA" origin/main || { echo "refused: $SHA is not on main (it never ran on the local cluster)" >&2; exit 1; }
echo "oracle: $(git rev-parse --short origin/oracle) -> $(git rev-parse --short "$SHA")"
git log --oneline "origin/oracle..$SHA"
git push origin "$SHA:refs/heads/oracle"
