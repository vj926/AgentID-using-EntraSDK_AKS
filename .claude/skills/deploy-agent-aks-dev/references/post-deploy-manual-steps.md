# Post-deploy manual steps

Three steps cannot be completed before the cluster + LoadBalancer exist, and none can be done via `az ad app update`. Run them after Step 5 (apply manifests) in the main SKILL procedure.

## 1. Add SPA redirect URIs

The Client SPA app was registered with only `http://localhost:3003`. For browser sign-in to work, you need at least:

| Redirect URI | Why |
|---|---|
| `http://localhost:8080/` | **Required for OBO sign-in.** Browsers refuse to run MSAL's PKCE on raw-IP HTTP because it's not a secure context; loopback is exempt. Used together with `kubectl port-forward`. |
| `http://<LB-IP>/` | Optional. Lets the autonomous-mode UI load directly on the LoadBalancer IP. Sign-in will still fail from this origin — that's normal. |

`az ad app update --web-redirect-uris` does NOT modify SPA URIs — you must PATCH Graph directly:

```bash
APP_FQDN="$APP_FQDN" \
  bash .claude/skills/deploy-agent-aks-dev/scripts/add-spa-redirect-uri.sh
```

The script idempotently appends both `http://localhost:8080/` and `http://$APP_FQDN/` to `spa.redirectUris`.

Portal fallback: **Microsoft Entra ID** → **App registrations** → *Client SPA* → **Authentication** → **Single-page application** → **Add URI** → enter `http://localhost:8080/` → **Save**.

## 2. Grant Agent → Graph delegated `User.Read` admin consent

### Symptom

Browser OBO flow fails with:

```
AADSTS65001: The user or administrator has not consented to use the application
```

### Why

`Start-EntraAgentIDWorkflow` grants **application** Graph permissions (e.g., `User.Read.All`) only. OBO additionally requires a **delegated** permission (`User.Read`) with admin consent at the tenant level, because the exchange happens on behalf of a user.

### Fix

```powershell
pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/grant-agent-obo-consent.ps1 `
  -AgentAppId "$env:AGENT_CLIENT_ID" -TenantId "$env:TENANT_ID"
```

Idempotent — checks for an existing grant first. Creates `oauth2PermissionGrant`: `clientId=<Agent SP>`, `resourceId=<Graph SP>`, `consentType=AllPrincipals`, `scope=User.Read`.

## 3. Open the agent via port-forward to exercise OBO

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/port-forward.sh
# in another shell / browser:
# http://localhost:8080
```

Then click **Sign In** — the MSAL popup should open and you can sign in as any user in `$TENANT_ID`.

For autonomous mode (no sign-in needed), `http://<LB-IP>/` works directly with no port-forward.

## Why these aren't automated inside Step 5

- **SPA URI** depends on the LoadBalancer external IP, which exists only after `kubectl apply` + LB provisioning. Cannot be precomputed.
- **OBO consent** is intentionally separate because autonomous-only deployments don't need it. Bundling it would hide a tenant-level admin consent behind a generic deploy command.
- **Port-forward** is an interactive convenience, not a deploy step. Producing it as a long-running background process inside a deploy script would surprise the user.

Scripts (1) and (2) are byte-identical (modulo filenames/paths) to the ACA skill's `add-spa-redirect-uri.sh` and `grant-agent-obo-consent.ps1` — they're Entra-level operations, not cloud-specific.
