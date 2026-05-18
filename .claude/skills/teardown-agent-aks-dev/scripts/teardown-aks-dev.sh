#!/usr/bin/env bash
# teardown-aks-dev.sh — orchestrator for teardown-agent-aks-dev.
#
# Safe by default: DRY_RUN=1, DELETE_ENTRA=0.
#
# Usage:
#   bash teardown-aks-dev.sh                              # dry-run, RG + FIC
#   DRY_RUN=0 bash teardown-aks-dev.sh                    # real, RG + FIC
#   DRY_RUN=0 DELETE_ENTRA=1 bash teardown-aks-dev.sh     # full
#   bash teardown-aks-dev.sh --fic-only                   # just the FIC, no RG touch
#
# Env (from /tmp/deploy-vars.sh):
#   SUBSCRIPTION_ID, RG                          (required for RG mode)
#   TENANT_ID, BLUEPRINT_APP_ID                  (required for FIC delete)
#   FIC_NAME                                     (default: aks-agent-sa)
#   SUBSCRIPTION_TENANT_ID                       (cross-tenant; defaults to TENANT_ID)
#   AGENT_CLIENT_ID, CLIENT_SPA_APP_ID           (optional; needed for DELETE_ENTRA=1)
#
# Exit codes:
#   0  — completed (or dry-run completed)
#   1  — missing required env / preflight failed
#   2  — user aborted at confirmation prompt
#   3  — partial failure (RG deleted but FIC remains, etc.)

set -u
set -o pipefail

: "${VARS_FILE:=/tmp/deploy-vars.sh}"
: "${DRY_RUN:=1}"
: "${DELETE_ENTRA:=0}"
: "${FIC_NAME:=aks-agent-sa}"

FIC_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --fic-only) FIC_ONLY=1 ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

if [[ -f "$VARS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$VARS_FILE"
else
  echo "ERROR: $VARS_FILE not found. Re-export at minimum SUBSCRIPTION_ID, RG, TENANT_ID, BLUEPRINT_APP_ID." >&2
  exit 1
fi

: "${SUBSCRIPTION_TENANT_ID:=${TENANT_ID:-}}"
: "${TENANT_ID:?TENANT_ID required in $VARS_FILE}"
: "${BLUEPRINT_APP_ID:?BLUEPRINT_APP_ID required in $VARS_FILE (for FIC delete)}"
if [[ "$FIC_ONLY" -eq 0 ]]; then
  : "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID required in $VARS_FILE}"
  : "${RG:?RG required in $VARS_FILE}"
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would prompt '$prompt' — assuming yes"
    return 0
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

graph_token_for() {
  # $1 = tenant id; echoes a Graph access token in that tenant, or empty on failure.
  az account get-access-token --tenant "$1" --resource https://graph.microsoft.com \
    --query accessToken -o tsv 2>/dev/null || true
}

echo "============================================================"
echo "Teardown plan (AKS / Entra Agent ID)"
if [[ "$FIC_ONLY" -eq 0 ]]; then
  echo "  Subscription tenant: $SUBSCRIPTION_TENANT_ID"
  echo "  Subscription:        $SUBSCRIPTION_ID"
  echo "  Resource group:      $RG               (WILL be deleted)"
fi
echo "  Entra tenant:        $TENANT_ID"
echo "  Blueprint app:       $BLUEPRINT_APP_ID"
echo "    └─ FIC to remove:  $FIC_NAME"
if [[ "$FIC_ONLY" -eq 0 ]]; then
  echo "  Delete Entra apps:   $DELETE_ENTRA"
fi
echo "  Dry run:             $DRY_RUN"
echo "  FIC-only mode:       $FIC_ONLY"
echo "============================================================"
confirm "Proceed?" || { echo "Aborted."; exit 2; }

# ----------------------------------------------------------------------
# FIC-only fast path
# ----------------------------------------------------------------------
if [[ "$FIC_ONLY" -eq 1 ]]; then
  echo ""
  echo "Step F — Delete FIC '$FIC_NAME' from Blueprint $BLUEPRINT_APP_ID"
  GTOK=$(graph_token_for "$TENANT_ID")
  if [[ -z "$GTOK" ]]; then
    echo "  ERROR: no Graph token for tenant $TENANT_ID. az login --tenant $TENANT_ID first." >&2
    exit 1
  fi
  APP_OID=$(curl -sS --fail -H "Authorization: Bearer $GTOK" \
    "https://graph.microsoft.com/v1.0/applications(appId='$BLUEPRINT_APP_ID')?\$select=id" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  if [[ -z "$APP_OID" ]]; then
    echo "  (Blueprint app not found — nothing to do)"; exit 0
  fi
  FIC_ID=$(curl -sS --fail -H "Authorization: Bearer $GTOK" \
    "https://graph.microsoft.com/v1.0/applications/$APP_OID/federatedIdentityCredentials" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((c['id'] for c in d['value'] if c['name']=='$FIC_NAME'),''))")
  if [[ -z "$FIC_ID" ]]; then
    echo "  (FIC '$FIC_NAME' not present — nothing to do)"; exit 0
  fi
  run "curl -sS --fail -X DELETE -H 'Authorization: Bearer $GTOK' 'https://graph.microsoft.com/v1.0/applications/$APP_OID/federatedIdentityCredentials/$FIC_ID'"
  echo "  FIC removed."
  exit 0
fi

# ----------------------------------------------------------------------
# Step 1: revoke OAuth grants on Agent SP
# ----------------------------------------------------------------------
if [[ -n "${AGENT_CLIENT_ID:-}" ]]; then
  echo ""
  echo "Step 1 — Revoke OAuth consent grants on Agent SP ($AGENT_CLIENT_ID)"
  AGENT_SP_OID=$(az ad sp show --id "$AGENT_CLIENT_ID" --query id -o tsv 2>/dev/null || true)
  if [[ -n "$AGENT_SP_OID" ]]; then
    GRANTS=$(az rest --method GET \
      --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$AGENT_SP_OID'" \
      --query 'value[].id' -o tsv 2>/dev/null || true)
    if [[ -n "$GRANTS" ]]; then
      while IFS= read -r g; do
        [[ -n "$g" ]] && run "az rest --method DELETE --uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$g'"
      done <<< "$GRANTS"
    else
      echo "  (no grants found)"
    fi
  else
    echo "  (Agent SP not found — skipping)"
  fi
fi

# ----------------------------------------------------------------------
# Step 2: delete FIC on Blueprint
# ----------------------------------------------------------------------
echo ""
echo "Step 2 — Delete FIC '$FIC_NAME' on Blueprint $BLUEPRINT_APP_ID"
GTOK=$(graph_token_for "$TENANT_ID")
if [[ -z "$GTOK" ]]; then
  echo "  WARN: no Graph token for tenant $TENANT_ID. Skipping FIC delete. (az login --tenant $TENANT_ID and re-run with --fic-only.)"
else
  APP_OID=$(curl -sS --fail -H "Authorization: Bearer $GTOK" \
    "https://graph.microsoft.com/v1.0/applications(appId='$BLUEPRINT_APP_ID')?\$select=id" 2>/dev/null \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  if [[ -n "$APP_OID" ]]; then
    FIC_ID=$(curl -sS --fail -H "Authorization: Bearer $GTOK" \
      "https://graph.microsoft.com/v1.0/applications/$APP_OID/federatedIdentityCredentials" \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((c['id'] for c in d['value'] if c['name']=='$FIC_NAME'),''))" 2>/dev/null || true)
    if [[ -n "$FIC_ID" ]]; then
      run "curl -sS --fail -X DELETE -H 'Authorization: Bearer $GTOK' 'https://graph.microsoft.com/v1.0/applications/$APP_OID/federatedIdentityCredentials/$FIC_ID'"
    else
      echo "  (FIC '$FIC_NAME' not present — skipping)"
    fi
  else
    echo "  (Blueprint app not found — skipping)"
  fi
fi

# ----------------------------------------------------------------------
# Step 3: delete RG
# ----------------------------------------------------------------------
echo ""
echo "Step 3 — Delete resource group $RG (in sub $SUBSCRIPTION_ID)"
run "az account set --subscription '$SUBSCRIPTION_ID'"
if az group show --name "$RG" >/dev/null 2>&1; then
  run "az group delete --name '$RG' --yes --no-wait"
else
  echo "  (RG does not exist — skipping)"
fi

# ----------------------------------------------------------------------
# Step 4: Entra cleanup (opt-in)
# ----------------------------------------------------------------------
if [[ "$DELETE_ENTRA" == "1" ]]; then
  echo ""
  echo "Step 4 — Delete Entra objects (in tenant $TENANT_ID)"
  if [[ -n "${CLIENT_SPA_APP_ID:-}" ]] && confirm "Delete Client SPA ($CLIENT_SPA_APP_ID)?"; then
    run "az ad app delete --id '$CLIENT_SPA_APP_ID' 2>/dev/null || true"
  fi
  if [[ -n "${AGENT_CLIENT_ID:-}" ]] && confirm "Delete Agent Identity ($AGENT_CLIENT_ID)?"; then
    echo "  NOTE: delete the Agent Identity via the Agent ID portal or Graph:"
    echo "    az rest --method DELETE --uri 'https://graph.microsoft.com/beta/agentIdentities/$AGENT_CLIENT_ID'"
  fi
  echo ""
  echo "  *** Blueprint ($BLUEPRINT_APP_ID) is often SHARED across agents. ***"
  if confirm "Are you SURE you want to delete the Blueprint?"; then
    run "az ad app delete --id '$BLUEPRINT_APP_ID' 2>/dev/null || true"
  fi
else
  echo ""
  echo "Step 4 — Skipping Entra cleanup (DELETE_ENTRA=0)"
fi

# ----------------------------------------------------------------------
# Step 5: verify
# ----------------------------------------------------------------------
echo ""
echo "Step 5 — Verify"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN: skipping verification"
else
  echo "  RG exists?       $(az group exists --name "$RG" 2>/dev/null || echo unknown)"
  if [[ -n "${BLUEPRINT_APP_ID:-}" ]]; then
    REMAIN=$(az ad app federated-credential list --id "$BLUEPRINT_APP_ID" --query "[?name=='$FIC_NAME'] | length(@)" -o tsv 2>/dev/null || echo "?")
    echo "  FICs named '$FIC_NAME' remaining on Blueprint: $REMAIN"
  fi
  if [[ "$DELETE_ENTRA" == "1" && -n "${CLIENT_SPA_APP_ID:-}" ]]; then
    echo "  Client SPA:      $(az ad app show --id "$CLIENT_SPA_APP_ID" 2>&1 | head -1)"
  fi
fi

echo ""
echo "Done. If DRY_RUN=1, re-run with DRY_RUN=0 to actually delete."
