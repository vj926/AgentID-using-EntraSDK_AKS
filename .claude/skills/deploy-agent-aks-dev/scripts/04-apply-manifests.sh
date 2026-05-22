#!/usr/bin/env bash
# Render manifests with envsubst and apply.
set -euo pipefail

for v in TENANT_ID BLUEPRINT_APP_ID AGENT_CLIENT_ID ACR_NAME OLLAMA_MODEL; do
  if [[ -z "${!v:-}" ]]; then echo "Missing \$$v" >&2; exit 1; fi
done

# CLIENT_SPA_APP_ID is OPTIONAL. The default AKS path is autonomous (app-only)
# auth via Workload Identity — no user MSAL sign-in. Only set it if you also
# want to enable user-OBO mode in the llm-agent UI (mirrors ACA dev skill).
export CLIENT_SPA_APP_ID="${CLIENT_SPA_APP_ID:-not-used}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFESTS="$SCRIPT_DIR/../manifests"
OUT="/tmp/agentid-aks-rendered"
mkdir -p "$OUT"

if ! command -v envsubst >/dev/null; then
  echo "envsubst not found. apt: gettext-base | brew: gettext | choco: gettext" >&2
  exit 1
fi

for f in "$MANIFESTS"/*.yaml; do
  envsubst '$TENANT_ID $BLUEPRINT_APP_ID $AGENT_CLIENT_ID $ACR_NAME $OLLAMA_MODEL $CLIENT_SPA_APP_ID' < "$f" > "$OUT/$(basename "$f")"
done

kubectl apply -f "$OUT/00-namespace.yaml"
kubectl apply -f "$OUT/10-serviceaccount.yaml"
kubectl apply -f "$OUT/20-weather-api.yaml"
kubectl apply -f "$OUT/30-ollama.yaml"
kubectl apply -f "$OUT/40-agent.yaml"
kubectl apply -f "$OUT/50-ingress.yaml"

echo
echo "Waiting for rollouts..."
kubectl -n agentid rollout status deploy/weather-api --timeout=180s
kubectl -n agentid rollout status deploy/ollama       --timeout=600s
kubectl -n agentid rollout status deploy/llm-agent    --timeout=180s

echo
echo "Waiting for LoadBalancer IP..."
for i in $(seq 1 60); do
  IP=$(kubectl -n agentid get svc llm-agent -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$IP" ]] && break
  sleep 5
done
echo "Agent UI: http://${IP:-<pending>}/"
