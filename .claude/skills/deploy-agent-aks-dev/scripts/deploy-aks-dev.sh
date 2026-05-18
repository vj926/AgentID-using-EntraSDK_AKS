#!/usr/bin/env bash
# One-shot orchestrator. Source /tmp/deploy-vars.sh first.
#
#   cp scripts/deploy-vars.sh.template /tmp/deploy-vars.sh
#   # edit /tmp/deploy-vars.sh
#   source /tmp/deploy-vars.sh
#   bash scripts/deploy-aks-dev.sh
#
# Prerequisite: Entra Agent ID Blueprint + Agent already exist. Set BLUEPRINT_APP_ID
# and AGENT_CLIENT_ID in deploy-vars.sh. CLIENT_SPA_APP_ID is OPTIONAL (autonomous
# path doesn't need it).
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export VARS_FILE="${VARS_FILE:-/tmp/deploy-vars.sh}"

for v in TENANT_ID SUBSCRIPTION_ID RG LOCATION AKS_NAME ACR_NAME \
         NODE_COUNT NODE_VM_SIZE BLUEPRINT_APP_ID AGENT_CLIENT_ID \
         OLLAMA_MODEL; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: \$$v unset. Source $VARS_FILE." >&2; exit 1
  fi
done
export CLIENT_SPA_APP_ID="${CLIENT_SPA_APP_ID:-not-used}"
# Defaults to TENANT_ID (single-tenant deploy). Override only for cross-tenant.
export SUBSCRIPTION_TENANT_ID="${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"

echo "============================================================"
echo " AKS deploy plan"
if [[ "$SUBSCRIPTION_TENANT_ID" != "$TENANT_ID" ]]; then
  echo "   *** CROSS-TENANT DEPLOY ***"
  echo "   Entra tenant (Blueprint/Agent) : $TENANT_ID"
  echo "   Azure sub tenant (AKS/ACR)     : $SUBSCRIPTION_TENANT_ID"
  echo "   Subscription                   : $SUBSCRIPTION_ID"
else
  echo "   Tenant/Sub : $TENANT_ID / $SUBSCRIPTION_ID"
fi
echo "   RG/Location: $RG / $LOCATION"
echo "   AKS / ACR  : $AKS_NAME / $ACR_NAME"
echo "   Nodes      : $NODE_COUNT × $NODE_VM_SIZE"
echo "   Model      : $OLLAMA_MODEL"
echo "============================================================"

bash "$SCRIPT_DIR/01-create-aks.sh"
# 01 appends OIDC_ISSUER to VARS_FILE — pick it up.
# shellcheck disable=SC1090
source "$VARS_FILE"

bash "$SCRIPT_DIR/02-build-and-push.sh"

pwsh -NoProfile -File "$SCRIPT_DIR/03-federate-blueprint.ps1" \
  -TenantId       "$TENANT_ID" \
  -BlueprintAppId "$BLUEPRINT_APP_ID" \
  -OidcIssuerUrl  "$OIDC_ISSUER" \
  -FicName        "${FIC_NAME:-aks-agent-sa}"

bash "$SCRIPT_DIR/04-apply-manifests.sh"

echo
echo "============================================================"
LB_IP=$(kubectl get svc -n agentid llm-agent -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
echo " Done. Agent UI:  http://${LB_IP:-<pending>}"
echo
echo " Verify:"
echo "   kubectl get pods -n agentid"
echo "   kubectl logs -n agentid -l app=llm-agent -c sidecar --tail=50"
echo
echo " Autonomous (app-only) path is ready as-is — no Entra config needed."
echo " Open the URL above and chat; the agent acquires its own Agent Identity"
echo " token via the Blueprint FIC."
echo
echo " For user On-Behalf-Of (sign-in) mode (REQUIRED for the 'Sign In' button):"
echo "   1) Register SPA redirect URIs (localhost:8080 for OBO + LB-IP for autonomous):"
echo "        APP_FQDN=\"\$LB_IP\" bash \"\$SCRIPT_DIR/add-spa-redirect-uri.sh\""
echo "   2) Grant Agent -> Graph delegated User.Read admin consent:"
echo "        pwsh -NoProfile -File \"\$SCRIPT_DIR/grant-agent-obo-consent.ps1\" \\"
echo "          -AgentAppId \"$AGENT_CLIENT_ID\" -TenantId \"$TENANT_ID\""
echo "   3) Port-forward to localhost (PKCE needs a secure context — raw HTTP IPs"
echo "      are not secure-context; loopback is exempt):"
echo "        bash \"\$SCRIPT_DIR/port-forward.sh\""
echo "      Then open http://localhost:8080 and click Sign In."
echo "============================================================"
