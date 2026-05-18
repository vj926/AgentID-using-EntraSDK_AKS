#!/usr/bin/env bash
# smoke-test-kind.sh — validate the AKS manifests on a local `kind` cluster
# without any Azure resources. Uses the ClientSecret credential source
# instead of workload identity (since kind has no Entra-trusted OIDC).
#
# Usage:
#   source /tmp/deploy-vars.sh
#   export BLUEPRINT_CLIENT_SECRET="<secret>"
#   bash smoke-test-kind.sh
#   bash smoke-test-kind.sh --cleanup
set -euo pipefail

CLUSTER="agentid-smoke"
NS="agentid"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Manifests live in sidecar/aks/manifests/ relative to repo root.
# Resolve: skill scripts are at .claude/skills/deploy-agent-aks-dev/scripts/
# so repo root is 4 up.
REPO_ROOT="$( cd "$SCRIPT_DIR/../../../.." && pwd )"
MANIFESTS="$REPO_ROOT/sidecar/aks/manifests"

if [[ "${1:-}" == "--cleanup" ]]; then
  kind delete cluster --name "$CLUSTER" || true
  echo "Cleanup complete."
  exit 0
fi

fail() { echo "SMOKE FAIL: $1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

have docker
have kind
have kubectl
have envsubst

for v in TENANT_ID BLUEPRINT_APP_ID AGENT_CLIENT_ID CLIENT_SPA_APP_ID OLLAMA_MODEL; do
  [[ -n "${!v:-}" ]] || fail "$v not set (source /tmp/deploy-vars.sh)"
done

if [[ -z "${BLUEPRINT_CLIENT_SECRET:-}" ]]; then
  echo "WARN: BLUEPRINT_CLIENT_SECRET unset — sidecar won't acquire tokens,"
  echo "      but the rest of the wiring will still be validated."
  BLUEPRINT_CLIENT_SECRET="placeholder-for-smoke-only"
fi

echo "==> [1/7] Create kind cluster"
if ! kind get clusters | grep -q "^$CLUSTER$"; then
  kind create cluster --name "$CLUSTER" --wait 60s
fi
kubectl cluster-info --context "kind-$CLUSTER"

echo "==> [2/7] Build images locally"
docker build -t agent-id-dev/llm-agent:smoke   "$REPO_ROOT/reference/repo/sidecar/dev"        > /tmp/kind-build-agent.log 2>&1 \
  || { tail -50 /tmp/kind-build-agent.log; fail "image build (llm-agent) — see /tmp/kind-build-agent.log"; }
docker build -t agent-id-dev/weather-api:smoke "$REPO_ROOT/reference/repo/sidecar/weather-api" > /tmp/kind-build-weather.log 2>&1 \
  || { tail -50 /tmp/kind-build-weather.log; fail "image build (weather-api) — see /tmp/kind-build-weather.log"; }

echo "==> [3/7] Load images into kind"
kind load docker-image agent-id-dev/llm-agent:smoke   --name "$CLUSTER"
kind load docker-image agent-id-dev/weather-api:smoke --name "$CLUSTER"

echo "==> [4/7] Render manifests (smoke overlay)"
OUT=$(mktemp -d)
ACR_NAME_PROD="${ACR_NAME:-acr-placeholder}"
# Render with envsubst, then rewrite ACR image refs to the locally-loaded tag.
export TENANT_ID BLUEPRINT_APP_ID AGENT_CLIENT_ID CLIENT_SPA_APP_ID OLLAMA_MODEL ACR_NAME="$ACR_NAME_PROD"
for f in "$MANIFESTS"/*.yaml; do
  envsubst < "$f" \
    | sed -E "s|${ACR_NAME_PROD}\.azurecr\.io/agent-id-dev/llm-agent:1\.0\.0|agent-id-dev/llm-agent:smoke|g" \
    | sed -E "s|${ACR_NAME_PROD}\.azurecr\.io/agent-id-dev/weather-api:1\.0\.0|agent-id-dev/weather-api:smoke|g" \
    > "$OUT/$(basename "$f")"
done

# Strip workload-identity bits and inject ClientSecret credential source.
# - Remove "azure.workload.identity/use: true" pod label
# - Replace SignedAssertionFilePath block with ClientSecret block in the sidecar
python3 - "$OUT/40-agent.yaml" "$OUT/10-serviceaccount.yaml" <<'PY' || fail "python3 not found"
import sys, re
agent_f, sa_f = sys.argv[1], sys.argv[2]

with open(agent_f) as fh: a = fh.read()
a = a.replace('azure.workload.identity/use: "true"', '# (workload-identity disabled in smoke test)')
a = re.sub(
    r'- \{ name: AzureAd__ClientCredentials__0__SourceType,[^}]*\}\s*\n'
    r'\s*- \{ name: AzureAd__ClientCredentials__0__SignedAssertionFileDiskPath,[^}]*\}',
    """- { name: AzureAd__ClientCredentials__0__SourceType, value: "ClientSecret" }
            - name: AzureAd__ClientCredentials__0__ClientSecret
              valueFrom:
                secretKeyRef: { name: blueprint-secret, key: client-secret }""",
    a,
)
with open(agent_f, 'w') as fh: fh.write(a)

with open(sa_f) as fh: s = fh.read()
s = re.sub(r'\n\s+azure\.workload\.identity/[^\n]*', '', s)
with open(sa_f, 'w') as fh: fh.write(s)
PY

echo "==> [5/7] Apply"
kubectl apply -f "$OUT/00-namespace.yaml"
kubectl -n "$NS" create secret generic blueprint-secret \
  --from-literal=client-secret="$BLUEPRINT_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$OUT/10-serviceaccount.yaml"
kubectl apply -f "$OUT/20-weather-api.yaml"
kubectl apply -f "$OUT/30-ollama.yaml"
kubectl apply -f "$OUT/40-agent.yaml"
# Skip 50-ingress.yaml: kind doesn't have a cloud LB. Use port-forward instead.

echo "==> [6/7] Wait for rollouts"
kubectl -n "$NS" rollout status deploy/weather-api --timeout=180s || fail "weather-api rollout"
kubectl -n "$NS" rollout status deploy/ollama       --timeout=600s || fail "ollama rollout (model pull is slow on first run)"
kubectl -n "$NS" rollout status deploy/llm-agent    --timeout=180s || fail "llm-agent rollout"

echo "==> [7/7] Hit /status"
kubectl -n "$NS" port-forward deploy/llm-agent 3000:3000 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 3
STATUS=$(curl -fsS "http://127.0.0.1:3000/status" || true)
echo "  /status -> $STATUS"
[[ "$STATUS" == *"ollama_available"* ]] || fail "agent /status did not include ollama_available; got: $STATUS"
[[ "$STATUS" == *'"ollama_available":true'* || "$STATUS" == *"ollama_available: true"* ]] \
  || fail "ollama_available is not true"

echo
echo "SMOKE PASS — manifests apply, all rollouts succeed, agent reaches Ollama."
echo "Run 'bash $0 --cleanup' to tear down the kind cluster."
