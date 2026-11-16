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
# only commits whose CI (validate.yml) passed: 15 commits once reached Oracle with CI red and every later check skipped.
# Public repository: the GitHub API needs no token. Break glass (CI itself broken, fix urgent): PROMOTE_SKIP_CI=1.
if [ "${PROMOTE_SKIP_CI:-0}" = 1 ]; then
  echo "WARNING: PROMOTE_SKIP_CI=1, promoting without a green CI" >&2
else
  CI="$(curl -fsS "https://api.github.com/repos/elwarrior100/platform/actions/workflows/validate.yml/runs?head_sha=$SHA" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["workflow_runs"]
done=[x for x in r if x["status"]=="completed"]
print("success" if any(x["conclusion"]=="success" for x in done) else ("running" if len(done) < len(r) else (done[0]["conclusion"] if done else "none")))')" \
    || { echo "refused: could not read the CI status of $SHA from GitHub" >&2; exit 1; }
  [ "$CI" = success ] || { echo "refused: CI (validate.yml) for $SHA is '$CI', not success (wait for it, or fix it)" >&2; exit 1; }
  echo "CI green for $(git rev-parse --short "$SHA")"
fi
echo "oracle: $(git rev-parse --short origin/oracle) -> $(git rev-parse --short "$SHA")"
git log --oneline "origin/oracle..$SHA"
git push origin "$SHA:refs/heads/oracle"
