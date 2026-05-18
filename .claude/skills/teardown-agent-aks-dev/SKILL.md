---
name: teardown-agent-aks-dev
description: 'AI-led teardown of an Entra Agent ID agent deployed to Azure Kubernetes Service by deploy-agent-aks-dev. Use when an engineering team wants to delete the AKS cluster, the resource group (which removes AKS + ACR + Log Analytics + PVCs in one shot), the Federated Identity Credential added to their Blueprint app, and optionally the Entra apps themselves (Client SPA, Agent Identity, Blueprint). Defaults to DRY-RUN so the operator sees exactly what will be deleted before anything is destroyed. Entra-object deletion is opt-in because Blueprints are often shared. Cross-tenant aware (SUBSCRIPTION_TENANT_ID for the RG delete, TENANT_ID for the FIC delete and Entra object cleanup). NOT for ACA deployments (use teardown-agent-aca-dev), NOT for the AWS variant (use teardown-agent-aca-aws), NOT for local docker-compose stacks (use `docker compose down -v`).'
---

# Teardown — Entra Agent ID Agent on AKS (AI-Led)

Reverses the [`deploy-agent-aks-dev`](../deploy-agent-aks-dev/SKILL.md) skill. Deletes the resource group (AKS, ACR, Log Analytics, PVCs), removes the Federated Identity Credential the deploy added to the Blueprint app, and — opt-in — deletes the Entra apps (Client SPA, Agent Identity, Blueprint).

**Paired with:** [`deploy-agent-aks-dev`](../deploy-agent-aks-dev/SKILL.md). Uses the same `/tmp/deploy-vars.sh`.

## When to Use

- "Tear down the AKS demo", "delete the agent cluster", "clean up the RG".
- Ending a demo / sales engagement and removing billable resources before they accrue ($140+/mo for a small node pool, plus $18/mo for the public LB).
- Re-running the deploy skill from a clean state (e.g. after a misconfigured `NODE_VM_SIZE`).
- Rotating to a different region or subscription — full teardown is cleaner than mutating the cluster.

## Do NOT Use When

- **Local docker-compose** — `cd sidecar/dev && docker compose down -v` is enough.
- **ACA variant** — use [`teardown-agent-aca-dev`](../teardown-agent-aca-dev/SKILL.md).
- **AWS variant** — use [`teardown-agent-aca-aws`](../teardown-agent-aca-aws/SKILL.md) (handles IAM role, OIDC provider, intermediary app).
- **Shared / long-lived Blueprint** — confirm with the user that the Blueprint isn't used by other agents before opting into `DELETE_ENTRA=1`. Deleting a shared Blueprint will break every other agent that federates against it.

## Safety posture

1. **Dry-run by default** (`DRY_RUN=1`). User must set `DRY_RUN=0` to actually delete anything.
2. **Entra objects are opt-in** (`DELETE_ENTRA=1`). Default keeps the Blueprint, Agent Identity, and Client SPA in the tenant.
3. **Re-confirms before deleting the Blueprint** — even with `DELETE_ENTRA=1`, the orchestrator prompts again, because Blueprints are routinely shared.
4. **FIC delete is automatic** even with `DELETE_ENTRA=0`. The FIC is the only Blueprint-scoped artifact the deploy created, and leaving it behind orphans state without protecting any shared concern.
5. **Confirm tenant + subscription + RG** with the user first. Users frequently have multiple Azure accounts; misfiring an RG delete on the wrong sub is unrecoverable.

## Prerequisites

1. `/tmp/deploy-vars.sh` from the original deployment (at minimum `SUBSCRIPTION_ID`, `RG`, `TENANT_ID`, `BLUEPRINT_APP_ID`; `FIC_NAME`, `AGENT_CLIENT_ID`, `CLIENT_SPA_APP_ID` if cleaning those).
2. `az` logged in to **both** tenants if this was a cross-tenant deploy:
   ```bash
   az login --tenant "${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"   # for RG delete
   az login --tenant "$TENANT_ID"                              # for FIC delete + Entra cleanup
   ```
   Single-tenant deploys need only one login.
3. **Graph role**:
   - FIC delete needs `Application.ReadWrite.OwnedBy` (own the Blueprint) or `Application.ReadWrite.All`.
   - `DELETE_ENTRA=1` additionally needs `Application Administrator` or higher on the apps you're deleting.
4. `pwsh` 7.4+ if running the FIC delete via the `Microsoft.Graph.Authentication` PowerShell path (the orchestrator falls back to `az rest` when `pwsh` isn't available).

## Procedure

### Step 0 — Confirm scope with the user

The orchestrator prints this banner and prompts for confirmation. Reproduce in your message to the user verbatim:

```
Teardown plan (AKS / Entra Agent ID):
  Subscription:        $SUBSCRIPTION_ID
  Resource group:      $RG               (WILL be deleted — removes AKS, ACR, LB, PVCs, logs)
  Blueprint app:       $BLUEPRINT_APP_ID
    └─ FIC to remove:  $FIC_NAME         (always removed when found)
  Delete Entra apps:   $DELETE_ENTRA     (Client SPA, Agent Identity, Blueprint — opt-in)
  Dry run:             $DRY_RUN
Proceed? [y/N]
```

### Step 1 — Revoke OAuth consent grants on the Agent SP

Even if you keep the Agent Identity, revoke any user-consent grants so a redeploy starts clean (and so a stale `User.Read` admin-consent isn't left behind on a destroyed cluster).

```bash
AGENT_SP_OID=$(az ad sp show --id "$AGENT_CLIENT_ID" --query id -o tsv 2>/dev/null || true)
if [[ -n "$AGENT_SP_OID" ]]; then
  az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$AGENT_SP_OID'" \
    --query 'value[].id' -o tsv | while read -r g; do
      az rest --method DELETE --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$g"
  done
fi
```

### Step 2 — Delete the Federated Identity Credential on the Blueprint

The deploy added one FIC to the Blueprint (`name = $FIC_NAME`, `subject = system:serviceaccount:agentid:agent-sa`). Remove it so the Blueprint isn't left trusting an OIDC issuer that no longer exists:

```bash
TENANT_ID="$TENANT_ID" BLUEPRINT_APP_ID="$BLUEPRINT_APP_ID" FIC_NAME="${FIC_NAME:-aks-agent-sa}" \
  bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh --fic-only
```

The orchestrator does this automatically in Step 2; the standalone invocation above is for manual triage.

### Step 3 — Delete the resource group

```bash
az group delete --name "$RG" --yes --no-wait
```

This removes, in one shot:
- The AKS cluster (`$AKS_NAME`)
- The ACR (`$ACR_NAME`) and every image in it
- The system-assigned managed identity AKS provisioned for the kubelet
- Any PVCs (Ollama models) and their backing disks
- The Log Analytics workspace if `ENABLE_LOGS=azure-monitor-container-insights` and it was created in `$RG`
- The Standard LB and its public IP

> [!NOTE]
> Log Analytics workspaces are sometimes pinned to a different RG by tenant policy. If `az group delete` succeeds but `az monitor log-analytics workspace show` still finds yours, delete it manually.

### Step 4 — Delete Entra objects (opt-in: `DELETE_ENTRA=1`)

Asked **per object**, in order, lowest-blast-radius first:

1. **Client SPA** (`CLIENT_SPA_APP_ID`) — usually safe; created per-deployment.
2. **Agent Identity** — delete via the Agent ID portal or Graph (`DELETE /agentIdentities/{id}`).
3. **Blueprint** (`BLUEPRINT_APP_ID`) — **PROMPT AGAIN.** Often shared across agents. Deleting a shared Blueprint breaks every other agent that federates against it.

```bash
az ad app delete --id "$CLIENT_SPA_APP_ID" 2>/dev/null || true
# Agent + Blueprint: prompt explicitly first, then call Graph
```

### Step 5 — Verify

```bash
az group exists --name "$RG"                                      # expect: false
az ad app federated-credential list --id "$BLUEPRINT_APP_ID" \
  --query "[?name=='$FIC_NAME']" -o tsv                           # expect: empty
az ad app show --id "$CLIENT_SPA_APP_ID" 2>&1 | head -1           # expect: "not found" (if DELETE_ENTRA=1)
```

## One-Shot Orchestrator

Single-entry-point script: [`scripts/teardown-aks-dev.sh`](./scripts/teardown-aks-dev.sh).

```bash
# Dry run (default) — Azure + FIC, no Entra app deletes
bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh

# Real teardown — RG + FIC, keep Entra apps
DRY_RUN=0 bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh

# Full teardown — RG + FIC + Entra apps (Client SPA, Agent, Blueprint — each prompted)
DRY_RUN=0 DELETE_ENTRA=1 \
  bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh

# Just remove the FIC and exit (no RG touch)
bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh --fic-only
```

## Cross-tenant teardown

If the deploy was cross-tenant (Azure sub in tenant A, Entra objects in tenant B), the orchestrator switches `az` context per step:

| Step | Uses | Tenant |
|---|---|---|
| Revoke OAuth grants | `az rest` against Graph | `$TENANT_ID` (B) |
| Delete FIC | `az rest` / `pwsh + Connect-MgGraph` | `$TENANT_ID` (B) |
| Delete RG | `az group delete` | `$SUBSCRIPTION_TENANT_ID` (A) |
| Delete Entra apps | `az ad app delete` | `$TENANT_ID` (B) |

You must be signed in to both before running. The orchestrator fails early with a clear message if either context is missing.

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `az group delete` hangs > 10 min | ACR has soft-delete retention enabled, or a KV with purge protection is in the RG | `az resource list -g "$RG"` to find the stuck resource; purge it manually |
| `Authorization_RequestDenied` on `az ad app delete` | Signing-in user lacks `Application Administrator` on the app | Elevate via PIM or have the app owner run it |
| FIC delete returns 404 | Already deleted, or `FIC_NAME` mismatch | `az ad app federated-credential list --id "$BLUEPRINT_APP_ID"` to enumerate actual names |
| `Subscription not found` on `az account set` | Wrong-tenant `az` context (cross-tenant deploy) | `az login --tenant "$SUBSCRIPTION_TENANT_ID"` |
| RG deleted but ACR images still billing | ACR was in a different RG | Find it: `az acr list --query "[?name=='$ACR_NAME']"`; delete: `az acr delete --name "$ACR_NAME" --yes` |
| Baked-in Ollama image still billing after `az group delete` | ACR soft-delete retention window | `az acr list --query "[].{n:name,p:properties.policies.softDeletePolicy.status}"`; purge if present |
| Workload identity webhook errors on next deploy | Old FIC still present with conflicting subject | `--fic-only` mode of the orchestrator, or `az ad app federated-credential delete` by ID |

## References

- [Azure — delete resource group](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/delete-resource-group)
- [Microsoft Graph — federatedIdentityCredentials](https://learn.microsoft.com/en-us/graph/api/application-delete-federatedidentitycredentials)
- [Microsoft Graph — oauth2PermissionGrant delete](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-delete)
- [`deploy-agent-aks-dev`](../deploy-agent-aks-dev/SKILL.md) — the deploy skill this reverses
- [`deploy-agent-aks-dev/references/cross-tenant-federation.md`](../deploy-agent-aks-dev/references/cross-tenant-federation.md) — the two-tenant pattern this teardown supports
