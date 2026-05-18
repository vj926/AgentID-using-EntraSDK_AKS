# Cross-tenant deployment

The default assumption in this skill is that the Azure subscription (where AKS, ACR, the Resource Group live) and the Entra tenant (where the Blueprint, Agent Identity, Client SPA live) are the **same tenant**. But that's not required — this layout supports a common real-world case where:

| Concern | Tenant |
|---|---|
| Entra Agent ID objects (Blueprint, Agent, SPA) | A "demo" or "ISV" tenant (e.g. `M365-*.onmicrosoft.com`) — where you have Agent ID Admin |
| Azure subscription that pays for AKS | A different "corp" tenant — where you have Owner/Contributor on a sub |

This page is the deep-dive. Quick-start is the callout in `SKILL.md` Step 0.

## Why it works

**Workload Identity federation trusts an OIDC issuer URL, not a tenant.** The Federated Identity Credential (FIC) on the Blueprint app is:

```
issuer    = https://eastus2.oic.prod-aks.azure.com/<corp-tenant-id>/<cluster-id>/
subject   = system:serviceaccount:agentid:agent-sa
audiences = [ api://AzureADTokenExchange ]
```

Entra (in the demo tenant) checks: "is this JWT signed by a key listed in the issuer's JWKS, and do `iss`/`sub`/`aud` match a registered FIC on this app?" It does **not** care which tenant the issuer happens to live in. As long as the issuer URL is publicly reachable (AKS OIDC issuers are), the assertion is valid.

The sidecar's `AZURE_TENANT_ID` is set to the **demo tenant** (where the Blueprint lives) — that's the STS that mints the Blueprint token, not the issuer's tenant.

## Variable contract

`deploy-vars.sh` has two tenant variables:

| Variable | Tenant | Used by |
|---|---|---|
| `SUBSCRIPTION_TENANT_ID` | Corp tenant (AKS/ACR/RG) | `az login --tenant`, `az account set`, RG/AKS/ACR ARM calls |
| `TENANT_ID` | Demo tenant (Blueprint, Agent, SPA) | `Connect-MgGraph -TenantId`, FIC create on Blueprint, sidecar `AZURE_TENANT_ID`, manifests' `TENANT_ID` env var |

If `SUBSCRIPTION_TENANT_ID` is unset, scripts assume single-tenant and use `TENANT_ID` for both. **Existing single-tenant deployments don't need to change anything.**

## The two `az login` flows

```bash
# 1. Sub-tenant context for all `az` resource calls
az login --tenant "$SUBSCRIPTION_TENANT_ID"
az account set --subscription "$SUBSCRIPTION_ID"

# 2. Graph context for FIC create / SPA redirect URI patch (interactive, separate browser sign-in)
pwsh -NoProfile -Command "Connect-MgGraph -TenantId '$TENANT_ID' -Scopes 'Application.ReadWrite.All' -NoWelcome"
```

The Graph cache from step (2) persists on disk in `~/.mg/`. Subsequent `pwsh` processes reuse it silently as long as the token hasn't expired.

For `add-spa-redirect-uri.sh` the script calls `az account get-access-token --tenant "$TENANT_ID" --resource graph` — this triggers a one-time interactive sign-in to the demo tenant the first time, then caches.

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `az account set --subscription` fails with `Subscription not found` | Active `az` context is in the wrong tenant | `az login --tenant "$SUBSCRIPTION_TENANT_ID"` |
| `AADSTS50020: User account ... does not exist in tenant` when calling Graph | Token requested without `--tenant` | Pass `--tenant "$TENANT_ID"` to `az account get-access-token` or `Connect-MgGraph -TenantId $TENANT_ID` |
| FIC create fails with `Authorization_RequestDenied` | Connected to Graph in the wrong tenant | `Disconnect-MgGraph; Connect-MgGraph -TenantId $TENANT_ID` |
| Sidecar logs `AADSTS700016: Application not found in directory` | `AzureAd__TenantId` points at the corp tenant, but the Blueprint is in the demo tenant | Set the manifest's `TENANT_ID` env to `$TENANT_ID` (demo); leave `SUBSCRIPTION_TENANT_ID` only for ARM |
| RG / AKS / ACR fail to create with `SubscriptionNotFound` even though `az account show` is correct | First time using this sub — resource providers not registered | `az provider register -n Microsoft.ContainerService; ContainerRegistry; Compute; Network; Storage; OperationalInsights; OperationsManagement` |

## Teardown caveat

The companion `teardown-agent-aks-dev` skill uses the same split: `SUBSCRIPTION_TENANT_ID` for the RG delete, `TENANT_ID` for FIC delete on the Blueprint and (opt-in) Entra-object deletes. Keep both vars in `/tmp/deploy-vars.sh` so teardown can target them correctly.
