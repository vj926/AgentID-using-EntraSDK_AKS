# OBO pre-flight checklist

Walk through this **before** running any OBO-enablement script
(`setup-obo-blueprint-for-aks.ps1`, `grant-agent-obo-consent.ps1`,
`add-spa-redirect-uri.sh`). Each row is a 30-second check that prevents
a known-painful failure mode we've hit in real customer engagements.

The agentic CLI **must** verify each item and report status to the user
before proceeding to OBO. If any item is ❌, fix it first.

| # | Check | How to verify | Why it matters |
|---|---|---|---|
| 1 | `Microsoft.Graph` PowerShell module is installed | `pwsh -Command "Get-Module -ListAvailable Microsoft.Graph.Authentication"` returns a row | All OBO scripts call `Connect-MgGraph`. Missing module → `The term 'Connect-MgGraph' is not recognized`. Install with `Install-Module Microsoft.Graph -Scope CurrentUser -Force`. |
| 2 | Signed in to the **Entra** tenant (not the Azure-sub tenant) | `az account show --query tenantId -o tsv` matches `$TENANT_ID` | Federation lives on the Blueprint app in the Entra tenant. Wrong tenant = silent no-op or `Authorization_RequestDenied`. |
| 3 | Signed-in identity has role to write `oauth2PermissionGrants` and modify app registrations | One of: **Cloud Application Administrator**, **Application Administrator**, **Privileged Role Administrator**, **Global Administrator** | Lower roles let the script run but Entra silently rejects the PATCH/POST. |
| 4 | All four GUIDs known: `TENANT_ID`, `BLUEPRINT_APP_ID`, `AGENT_APP_ID`, `CLIENT_SPA_APP_ID` | Echo each; none should be empty | Wrong/swapped IDs are the #1 cause of `AADSTS500011` later. The OBO audience must be the **Blueprint**, never the Agent. |
| 5 | Blueprint app's Service Principal exists in the tenant | `az ad sp show --id $BLUEPRINT_APP_ID --query id` returns an objectId | `AADSTS500011` says "resource **principal** not found" — App Registration alone isn't enough. If missing: `az ad sp create --id $BLUEPRINT_APP_ID`. |
| 6 | SPA app's Service Principal exists | `az ad sp show --id $CLIENT_SPA_APP_ID --query id` returns an objectId | Required for the `oauth2PermissionGrant` (SPA → Blueprint) and for sign-in. |
| 7 | Agent app's Service Principal exists | `az ad sp show --id $AGENT_APP_ID --query id` returns an objectId | Required for the `oauth2PermissionGrant` (Agent → Graph User.Read). |
| 8 | The agent's actual URL is registered as an SPA redirect URI on the SPA app | `az ad app show --id $CLIENT_SPA_APP_ID --query spa.redirectUris` includes the exact URL the browser will hit (LoadBalancer IP, port-forward `http://localhost:8080`, or HTTPS FQDN) | Mismatch = `AADSTS50011: redirect URI mismatch`. Use `add-spa-redirect-uri.sh` to add. |
| 9 | The browser will hit the SPA over a **secure context** (`https://`) **or** `http://localhost:*` | URL begins with `https://` or `http://localhost` | MSAL.js needs `window.crypto.subtle`. Bare `http://<IP>` triggers `pkce_not_created`. Use `scripts/port-forward.sh` for demo. |
| 10 | Consent decision is made up-front: tenant-wide vs per-user | Decide with the user: **AllPrincipals** (everyone in tenant can use, simplest) or **Principal** (per-user grants, brittle) | The default `grant-agent-obo-consent.ps1` ships `AllPrincipals`. If only a subset of users should access the agent, prefer `AllPrincipals` + enable **Assignment required** on the Agent SP (see Row 11). |
| 11 | If only some users should access the agent: `appRoleAssignmentRequired=true` on the Agent SP + users/groups assigned | `az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/<agentSpId>?\$select=appRoleAssignmentRequired"` returns `true`; `appRoleAssignedTo` lists the intended principals | Without this, tenant-wide consent = anyone in the tenant can use the agent. Assignment-required gates *who* can sign in, independent of consent. |
| 12 | Browser session is clean for testing | Use private/incognito window, or clear site data | MSAL caches the **failed** token request. Without this, a successful fix appears to do nothing because the browser replays the cached failure. |

## After running the OBO scripts — verification

These checks confirm the platform actually persisted the writes
(Entra sometimes returns HTTP 204 then silently rolls back changes on
platform-managed Blueprint apps).

| # | Check | How to verify | If failed |
|---|---|---|---|
| V1 | Blueprint has the OBO Application ID URI | `az ad app show --id $BLUEPRINT_APP_ID --query identifierUris` returns `["api://$BLUEPRINT_APP_ID"]` | PATCH was silently rejected. Try setting it in the Entra portal (Expose an API → Application ID URI). If the portal also refuses or reverts, open a support ticket — Blueprint is platform-locked. See [troubleshooting.md](./troubleshooting.md). |
| V2 | Blueprint exposes `access_as_user` scope | `az ad app show --id $BLUEPRINT_APP_ID --query "api.oauth2PermissionScopes[].value"` includes `access_as_user` | Same as V1 — portal fallback or support ticket. |
| V3 | SPA → Blueprint `access_as_user` grant exists with `consentType=AllPrincipals` | Query `oauth2PermissionGrants` filtered by `clientId=<spaSpId>` and `resourceId=<bpSpId>` — at least one row with `consentType=AllPrincipals` and `scope` containing `access_as_user` | Re-run with admin role. If a `Principal`-typed grant exists, it does **not** satisfy other users — add an `AllPrincipals` grant. |
| V4 | Agent → Graph `User.Read` grant exists with `consentType=AllPrincipals` | Query `oauth2PermissionGrants` filtered by `clientId=<agentSpId>` and `resourceId=<graphSpId>` — at least one row with `consentType=AllPrincipals` and `scope` containing `User.Read` | `grant-agent-obo-consent.ps1` may have short-circuited on a pre-existing `Principal` grant. Use the `AllPrincipals` one-liner in [troubleshooting.md](./troubleshooting.md) (`AADSTS65001` row). |

## One-shot pre-flight script (optional helper)

If the agent wants a single command to print pass/fail for rows 1–7,
this snippet does it:

```bash
TENANT_ID="..."; BLUEPRINT_APP_ID="..."; AGENT_APP_ID="..."; CLIENT_SPA_APP_ID="..."

echo "1) Microsoft.Graph module:";   pwsh -Command "Get-Module -ListAvailable Microsoft.Graph.Authentication" | head -2
echo "2) Current tenant:";           az account show --query tenantId -o tsv
echo "3) Current identity:";         az ad signed-in-user show --query userPrincipalName -o tsv
echo "4) GUIDs:";                    echo "  TENANT=$TENANT_ID  BP=$BLUEPRINT_APP_ID  AGENT=$AGENT_APP_ID  SPA=$CLIENT_SPA_APP_ID"
for v in BLUEPRINT_APP_ID AGENT_APP_ID CLIENT_SPA_APP_ID; do
  id=$(eval echo \$$v)
  printf "5/6/7) SP for %s: " "$v"
  az ad sp show --id "$id" --query id -o tsv 2>/dev/null || echo "MISSING — run: az ad sp create --id $id"
done
```
