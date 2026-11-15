#!/usr/bin/env bash
# Scaffolds a new project on the platform (ADR-010): one Argo CD project, one namespace per component, closed network
# policies and a manifests folder per component, which the "projects" ApplicationSet picks up on its own.
#   1. platform/argocd/projects/<project>.yaml (+ kustomization): only its namespaces, no cluster-wide resources
#   2. platform/k8s/00-namespaces.yaml: each namespace with Pod Security labels and platform/network-reviewed
#   3. platform/k8s/network-policies/egress-allowlists.yaml: each namespace may reach DNS and itself, nothing else
#      (no internet, no other namespace, no cloud metadata endpoint): open what it needs, on purpose, later
#   4. projects/<project>/k8s/<component>/00-about.yaml: a placeholder so the ApplicationSet creates the application
# Nothing is committed: review the diff (git diff), then commit, test on the local cluster, promote.
# Usage: ./scripts/new-project.sh <project> <component> [component ...]     e.g.  ./scripts/new-project.sh energy meters
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROJECT="${1:?project name}"; shift
[ "$#" -ge 1 ] || { echo "at least one component (it becomes a namespace and an application)" >&2; exit 1; }
NAME_RE='^[a-z][a-z0-9-]{1,30}[a-z0-9]$'
[[ "$PROJECT" =~ $NAME_RE ]] || { echo "invalid project name: $PROJECT (lowercase letters, digits, dashes)" >&2; exit 1; }
[ ! -e "platform/argocd/projects/$PROJECT.yaml" ] && [ ! -e "projects/$PROJECT" ] || { echo "project $PROJECT already exists" >&2; exit 1; }
for c in "$@"; do
  [[ "$c" =~ $NAME_RE ]] || { echo "invalid component name: $c" >&2; exit 1; }
  taken=false
  grep -qE "^  name: $c\$" platform/k8s/00-namespaces.yaml && taken=true
  grep -rqE "^  name: $c\$" envs/oracle/backup envs/oracle/ops 2>/dev/null && taken=true
  for d in projects/*/k8s/"$c"; do [ -d "$d" ] && taken=true; done
  [ "$taken" = false ] || { echo "namespace/component $c already exists" >&2; exit 1; }
done

# 1. the Argo CD project
{
  cat <<EOF
# Argo CD project for $PROJECT (scaffolded by scripts/new-project.sh): its applications may deploy only into its own
# namespaces, only from this repository, and nothing cluster-wide. Widen namespaceResourceWhitelist on purpose.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $PROJECT
  namespace: argocd
spec:
  description: "$PROJECT - TODO one line on what it does and its repository"
  sourceRepos:
    - https://github.com/elwarrior100/platform.git
  destinations:
EOF
  for c in "$@"; do echo "    - {server: https://kubernetes.default.svc, namespace: $c}"; done
  cat <<'EOF'
  clusterResourceWhitelist: []          # no cluster-wide resources (no namespaces, CRDs, ClusterRoles)
  namespaceResourceWhitelist:
    - {group: "", kind: "*"}
    - {group: apps, kind: "*"}
    - {group: batch, kind: "*"}
    - {group: external-secrets.io, kind: ExternalSecret}
EOF
} > "platform/argocd/projects/$PROJECT.yaml"
python3 - "$PROJECT" <<'PY'
import sys
p = "platform/argocd/projects/kustomization.yaml"; s = open(p).read()
s = s.replace("resources:\n", f"resources:\n  - {sys.argv[1]}.yaml\n", 1)
open(p, "w").write(s)
PY

for c in "$@"; do
  # 2. the namespace
  cat >> platform/k8s/00-namespaces.yaml <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $c
  labels:
    pod-security.kubernetes.io/enforce: baseline
    platform/network-reviewed: "true"   # egress-allowlist: DNS and itself only ($PROJECT, scripts/new-project.sh)
    pod-security.kubernetes.io/warn: restricted
EOF
  # 3. its network policy: closed by default
  cat >> platform/k8s/network-policies/egress-allowlists.yaml <<EOF
---
# $c ($PROJECT): scaffolded closed. It may reach DNS and its own pods only; add what it needs (e.g. lakeFS in data on
# 8000, Postgres on 5432) as explicit rules here, and the matching ingress rule in data-ingress.yaml.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-allowlist
  namespace: $c
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:   # DNS (CoreDNS)
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to:   # pods of this namespace
        - podSelector: {}
EOF
  # 4. the manifests folder
  mkdir -p "projects/$PROJECT/k8s/$c"
  cat > "projects/$PROJECT/k8s/$c/00-about.yaml" <<EOF
# Component $c of project $PROJECT. Every manifest in this folder is applied by the application "$c" (namespace $c),
# created by the "projects" ApplicationSet. Replace this placeholder with the real manifests (Deployments, Jobs...).
apiVersion: v1
kind: ConfigMap
metadata:
  name: about
  namespace: $c
data:
  project: $PROJECT
  component: $c
EOF
done

echo "Scaffolded project $PROJECT with component(s): $*"
git status --short
cat <<EOF

Next, on purpose (not automated):
  - secrets: put them in the vault as <namespace>-<name> (scripts/vault-seed.sh pattern), add the namespace(s) to the
    ClusterSecretStore conditions in envs/local/secret-store and envs/oracle/secret-store, and write ExternalSecrets
  - network: open only what it needs in platform/k8s/network-policies (egress here, ingress in data-ingress.yaml)
  - lake: ./scripts/lakefs-repo.sh <repository> <bucket>   (protected main, GC rules)
  - DAGs: one more entry in dag_bundle_config_list and the image env in platform/airflow/values.yaml
  - then: git diff, commit, check the local cluster, ./scripts/promote-oracle.sh
EOF
