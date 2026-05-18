#!/usr/bin/env bash
# add-spa-redirect-uri.sh — register browser sign-in URIs on the Client SPA app.
#
# AKS-specific behavior:
#   1. ALWAYS registers `http://localhost:8080/`. The LoadBalancer exposes the
#      agent over plain HTTP, and raw-IP HTTP is NOT a browser "secure context"
#      — so MSAL.js (which relies on Web Crypto / PKCE) refuses to open the
#      sign-in popup. Loopback IS a secure context, so OBO works via
#      `kubectl port-forward svc/llm-agent 8080:80` (see scripts/port-forward.sh).
#   2. If APP_FQDN is set, ALSO registers `${REDIRECT_SCHEME:-http}://$APP_FQDN/`
#      so the LoadBalancer IP works for autonomous-mode browsing (no sign-in).
#   3. If REDIRECT_URI is set, registers that string verbatim instead.
#
# Cross-tenant aware: TENANT_ID is the Entra tenant where the SPA lives. The
# script asks `az` for a Graph token in that tenant explicitly so it works even
# when the active `az account` is in a different (subscription) tenant.
#
# Idempotent — fetches existing spa.redirectUris first, only PATCHes the
# difference.
#
# Required env (from /tmp/deploy-vars.sh):
#   CLIENT_SPA_APP_ID
#   TENANT_ID
# Optional:
#   APP_FQDN          (LoadBalancer IP or DNS; will be wrapped with scheme)
#   REDIRECT_SCHEME   (http|https, default http for AKS)
#   REDIRECT_URI      (overrides APP_FQDN + scheme; verbatim)
#   PORT_FORWARD_URI  (default http://localhost:8080/; set empty to skip)

set -euo pipefail

: "${CLIENT_SPA_APP_ID:?CLIENT_SPA_APP_ID required in env (e.g. /tmp/deploy-vars.sh)}"
: "${TENANT_ID:?TENANT_ID required (Entra tenant where the SPA lives)}"

PORT_FORWARD_URI="${PORT_FORWARD_URI-http://localhost:8080/}"
APP_FQDN="${APP_FQDN:-}"
REDIRECT_SCHEME="${REDIRECT_SCHEME:-http}"
REDIRECT_URI="${REDIRECT_URI:-}"

if [[ -z "$REDIRECT_URI" && -n "$APP_FQDN" ]]; then
  REDIRECT_URI="${REDIRECT_SCHEME}://${APP_FQDN}/"
fi

TOK=$(az account get-access-token --tenant "$TENANT_ID" \
        --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null \
      || az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
[[ -z "$TOK" ]] && { echo "ERROR: failed to acquire Graph token for tenant $TENANT_ID" >&2; exit 1; }

EXISTING=$(curl -sS --fail -H "Authorization: Bearer $TOK" \
  "https://graph.microsoft.com/v1.0/applications(appId='$CLIENT_SPA_APP_ID')?\$select=id,spa")

BODY=$(python3 - <<PY
import json, sys
data = json.loads('''$EXISTING''')
uris = list(data.get("spa", {}).get("redirectUris", []))
want = []
pf  = "$PORT_FORWARD_URI"
red = "$REDIRECT_URI"
if pf:  want.append(pf)
if red: want.append(red)
added = [u for u in want if u and u not in uris]
for u in added:
    uris.append(u)
out = {"_added": added, "_objectId": data["id"], "_patch": {"spa": {"redirectUris": uris}}}
print(json.dumps(out))
PY
)

ADDED=$(echo "$BODY" | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["_added"]))')
OBJID=$(echo "$BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_objectId"])')
PATCH=$(echo "$BODY" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["_patch"]))')

if [[ -z "$ADDED" ]]; then
  echo "All requested redirect URIs already registered. Nothing to do."
  exit 0
fi

curl -sS --fail -X PATCH \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  "https://graph.microsoft.com/v1.0/applications/$OBJID" \
  -d "$PATCH" >/dev/null

echo "Added SPA redirect URIs: $ADDED"
