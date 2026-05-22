---
name: deploy-agent-aks-dev
description: 'AI-led, end-to-end deployment of an agent that authenticates with Microsoft Entra Agent ID to Azure Kubernetes Service, using Azure Workload Identity instead of client secrets. Use when an engineering team wants to host their own agent (or this repo''s `sidecar/dev` sample) on AKS with the Entra Agent ID auth-sidecar pattern; when promoting an existing docker-compose stack from ClientSecret to secretless federation; or when an organization already standardized on Kubernetes and needs Agent ID to fit alongside their other workloads. Includes a kind-based local smoke test (no Azure cost), a one-shot orchestrator, a port-forward workflow for the OBO sign-in flow, and an explicit "Adapt for your own agent" section. NOT for Azure Container Apps (use `deploy-agent-aca-dev`), App Service (use `deploy-agent-appservice-dev`), or the AWS Bedrock variant (use `deploy-agent-aca-aws`). Chains to `entra-agent-id-setup` for the Blueprint + Agent Identity + Client SPA objects, and pairs with `teardown-agent-aks-dev` for cleanup.'
---

# Deploy an Entra Agent ID Agent to Azure Kubernetes Service (AI-Led)

End-to-end, **secretless** deployment of an agent that uses the Microsoft Entra Agent ID auth-sidecar on AKS. The included `sidecar/dev` sample is the default runnable artifact; the skill also walks an external team through **adapting their own agent** to the same pattern.

One federation chain — Kubernetes ServiceAccount → Blueprint app. **No client secrets in the cluster.** No UAMI in the middle.

**Canonical manifests:** [`manifests/`](./manifests/). Long-form walkthrough tutorial: [`deploy/azure/kubernetes-service/dev/README.md`](../../../deploy/azure/kubernetes-service/dev/README.md).

## When to Use

- An engineering team wants to host their own agent on AKS using the Entra Agent ID sidecar pattern (autonomous app-identity flow + optional On-Behalf-Of user flow).
- The team already has AKS as a platform standard and needs Agent ID to fit alongside other workloads — no new compute service.
- The team wants the **secretless** posture: Workload Identity, projected SA tokens, FIC trust on the Blueprint app — no client secrets stored in the cluster.
- The user has a docker-compose dev stack from `sidecar/dev` and wants to promote it to AKS without rewriting the agent code.
- A non-Azure k8s cluster (EKS, GKE, on-prem) is the eventual target — this skill produces a reference layout that is 95% portable; see [references/non-azure-k8s.md](./references/non-azure-k8s.md).

## Do NOT Use When

- **Azure Container Apps** is the target — use [`deploy-agent-aca-dev`](../deploy-agent-aca-dev/SKILL.md).
- **Azure App Service** is the target — use `deploy-agent-appservice-dev`.
- **AWS Bedrock** is the LLM backend — use [`deploy-agent-aca-aws`](../deploy-agent-aca-aws/SKILL.md).
- **Local laptop docker-compose** is sufficient — use `sidecar/dev/` directly with `docker compose up`. No federation needed.
- The team only needs the agent for a short demo with no Kubernetes plans — ACA is cheaper and simpler.

## Prerequisites (verify BEFORE running anything)

1. **Entra role** on the signing-in user, one of: `Global Administrator`, `Agent ID Administrator`, `Agent ID Developer`. If unsure, run the [`entra-agent-id-setup`](../entra-agent-id-setup/SKILL.md) skill first — it surfaces the role requirement and creates the Blueprint/Agent/SPA objects.
2. **Azure RBAC**: `Owner` or `Contributor` on the subscription where AKS will live, plus `User Access Administrator` if the AKS attach-ACR step needs to grant `AcrPull`.
3. **Tooling**:
   - `az` ≥ 2.60 with `aks-preview` extension (`az extension add --name aks-preview`)
   - `kubectl` ≥ 1.28
   - `pwsh` 7.4+ with `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`)
   - `envsubst` (from the `gettext` package; on Windows comes with Git Bash)
   - Optional for local smoke test: Docker Desktop + `kind` ≥ 0.20
   - Optional for "Adapt for your own agent": a container image of the user's agent in any registry reachable by AKS
4. **Tenant + subscription confirmed with the user.** ALWAYS confirm before any `az` command that mutates resources. Users frequently have multiple tenants; pick the wrong one and you create a half-deployed cluster in the wrong place.
5. **Entra Agent ID base objects exist** — Blueprint, Agent Identity, and (for OBO) a Client SPA. If not, chain `entra-agent-id-setup` first.
6. **Resource providers registered** on first use of a fresh subscription:
   `Microsoft.ContainerService`, `Microsoft.ContainerRegistry`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.OperationsManagement`. `01-create-aks.sh` checks and registers what's missing.

> [!NOTE]
> **Windows / PowerShell users:** the orchestrator and scripts are bash + `pwsh`. Run them from **Git Bash** or **WSL**, not raw PowerShell — `source`, `envsubst`, and curl-style heredocs do not have native PowerShell equivalents.

> [!NOTE]
> **Cross-tenant deployment** (the Azure subscription lives in tenant A while the Entra Agent ID objects live in tenant B) is supported. Set `SUBSCRIPTION_TENANT_ID` in `/tmp/deploy-vars.sh`. Full pattern: [references/cross-tenant-federation.md](./references/cross-tenant-federation.md). Default behavior is single-tenant.

## SKU decisions — ask the user first

Don't silently default to the cheapest tier. The orchestrator requires each SKU variable to be set and fails hard if any is missing. Confirm each value **with the user** before provisioning. Full tradeoff matrix and per-model sizing: [references/sku-sizing.md](./references/sku-sizing.md).

| Variable | Ask | Demo default | Silent-failure mode if chosen wrong |
|---|---|---|---|
| `NODE_VM_SIZE` | demo / GPU / Spot | `Standard_D4s_v5` | `qwen2.5:7b` on `D2` → OOM kill; tokens come out at 1 char/sec on `B2s` |
| `NODE_COUNT` | 1 – 5 | `2` | `1` = no headroom during model pulls; if the node restarts, every pod becomes `Pending` |
| `ACR_SKU` | `Basic` / `Standard` / `Premium` | `Basic` | Basic's 10 GB fills up with ~6 baked-Ollama variants |
| `STORAGE_GB` | PVC size for Ollama models | `20` | 1B model = 1.3 GB; 7B = 4.3 GB; too small → init container hangs on disk-full |
| `OLLAMA_MODEL` | `qwen2.5:1.5b` / `qwen2.5:7b` / `llama3.2:1b` / your own | `qwen2.5:1.5b` | 7B on CPU node = 30 s+ per turn; tool-calling becomes unreliable |
| `INGRESS_TYPE` | `LoadBalancer` / `ingress-nginx` / `appgw` | `LoadBalancer` | `nginx` needs Helm + cert-manager; `appgw` adds ~$240/mo |
| `ENABLE_LOGS` | `none` / `azure-monitor-container-insights` | `none` | `none` hides crash loops; flip on once you hit a "why" moment |

**When invoking this skill, explicitly state the defaults to the user and ask them to confirm or override — do not assume.**

## Procedure

The procedure is built for the included `sidecar/dev` sample. If you're bringing your own agent, do Steps 0–3 unchanged and then jump to the **[Adapt for your own agent](#adapt-for-your-own-agent)** section before Step 4.

### Step 0 — Confirm account and populate variables

```bash
cp .claude/skills/deploy-agent-aks-dev/scripts/deploy-vars.sh.template /tmp/deploy-vars.sh
# Edit /tmp/deploy-vars.sh: fill in TENANT_ID, SUBSCRIPTION_ID, RG, LOCATION, SKUs.
source /tmp/deploy-vars.sh

az login --tenant "${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"
az account set --subscription "$SUBSCRIPTION_ID"
az account show --query '{name:name, id:id, tenantId:tenantId}' -o table
```

Stop and confirm with the user before proceeding. Wrong-tenant deployments are the #1 source of cleanup pain.

### Step 1 — Create Entra Agent ID base objects

Delegate to [`entra-agent-id-setup`](../entra-agent-id-setup/SKILL.md). Capture `BLUEPRINT_APP_ID`, `AGENT_CLIENT_ID`, and (for OBO) `CLIENT_SPA_APP_ID` into `/tmp/deploy-vars.sh`.

Then configure the Blueprint for OBO (sets `identifierUris`, adds the `access_as_user` scope, pre-authorizes the Client SPA, and pre-grants admin consent — all idempotent):

```bash
pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/setup-obo-blueprint-for-aks.ps1 \
  -BlueprintAppId "$BLUEPRINT_APP_ID" \
  -ClientSpaAppId "$CLIENT_SPA_APP_ID" \
  -AgentAppId    "$AGENT_CLIENT_ID" \
  -TenantId      "$TENANT_ID"
```

Skip this script if the deployment is autonomous-only (no user sign-in). It's safe to run twice; subsequent runs are no-ops.

### Step A — Local smoke test on `kind` (RECOMMENDED before Azure)

Validate every manifest against a real Kubernetes API server with no Azure cost. The smoke test uses `ClientSecret` for the sidecar (matches the upstream docker-compose), so no federation is required.

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/smoke-test-kind.sh
```

What it covers and what it doesn't: [references/smoke-test.md](./references/smoke-test.md). Output is one line — `SMOKE PASS` or `SMOKE FAIL: <reason>`. **Do this before Step 2** unless you're already comfortable with the manifests.

### Step 2 — Azure infrastructure (RG + ACR + AKS with OIDC + Workload Identity)

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/01-create-aks.sh
```

Creates:
- Resource group in `$LOCATION`.
- ACR `$ACR_NAME` with `--admin-enabled false`.
- AKS `$AKS_NAME` with `--enable-oidc-issuer --enable-workload-identity` and a system pool of `$NODE_COUNT × $NODE_VM_SIZE`.
- `az aks update --attach-acr` → the kubelet's MI gets `AcrPull` on the ACR (no `imagePullSecrets` needed).
- Appends `OIDC_ISSUER=<URL>` to `/tmp/deploy-vars.sh`.

> [!NOTE]
> If your tenant enforces Azure Policy that blocks public LBs (common in regulated environments), set `INGRESS_TYPE=ingress-nginx` and install the controller manually. The LoadBalancer Service in `50-ingress.yaml` becomes a ClusterIP + Ingress.

### Step 3 — Federate the KSA to the Blueprint app (the only federation chain)

```bash
pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/03-federate-blueprint.ps1 \
  -TenantId       "$TENANT_ID" \
  -BlueprintAppId "$BLUEPRINT_APP_ID" \
  -OidcIssuerUrl  "$OIDC_ISSUER" \
  -FicName        "${FIC_NAME:-aks-agent-sa}"
```

Adds one Federated Identity Credential on the Blueprint app:
- `issuer`   = the AKS OIDC URL captured in Step 2
- `subject`  = `system:serviceaccount:agentid:agent-sa`
- `audience` = `api://AzureADTokenExchange`

**No UAMI is created.** The pod's projected SA token IS the assertion the Blueprint accepts. See [references/workload-identity.md](./references/workload-identity.md) for why this works and what `SignedAssertionFilePath` does.

### Step 4 — Build and push container images

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/02-build-and-push.sh
```

`az acr build` for `llm-agent` and `weather-api`. **No local Docker required.** Ollama uses the upstream `ollama/ollama:latest` image as-is — the model is fetched by an initContainer on first pod start and persisted in a PVC. If your tenant has an Azure Policy blocking public Docker Hub pulls, pre-import: `az acr import --name "$ACR_NAME" --source docker.io/ollama/ollama:latest` and update `30-ollama.yaml` to reference the ACR copy.

### Step 5 — Apply manifests

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/04-apply-manifests.sh
```

Renders `manifests/*.yaml` through `envsubst` (with an **explicit varlist** — `$TENANT_ID $BLUEPRINT_APP_ID $AGENT_CLIENT_ID $ACR_NAME $OLLAMA_MODEL $CLIENT_SPA_APP_ID` — to avoid clobbering shell variables like `$PID` inside init scripts), then `kubectl apply -f -`, then `kubectl rollout status` per Deployment, and finally waits for the LoadBalancer external IP. Captures `APP_FQDN=<LB-IP>` into `/tmp/deploy-vars.sh`.

### Step 6 — Post-deploy wiring (REQUIRED — execute immediately after Step 5)

> [!IMPORTANT]
> AI agent **MUST** execute all three sub-steps. Do NOT skip. Full rationale + portal fallback: [references/post-deploy-manual-steps.md](./references/post-deploy-manual-steps.md).

1. **Add SPA redirect URIs.** Registers `http://localhost:8080/` (required for OBO — see sub-step 3) and, if `APP_FQDN` is set, also `http://$APP_FQDN/`:

   ```bash
   APP_FQDN="$APP_FQDN" \
     bash .claude/skills/deploy-agent-aks-dev/scripts/add-spa-redirect-uri.sh
   ```

2. **Grant Agent → Graph delegated `User.Read`** (fixes `AADSTS65001` on OBO):

   ```bash
   pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/grant-agent-obo-consent.ps1 \
     -AgentAppId "$AGENT_CLIENT_ID" -TenantId "$TENANT_ID"
   ```

3. **Use port-forward for OBO sign-in.** The LoadBalancer is plain HTTP, which browsers refuse to treat as a "secure context" — MSAL's PKCE flow needs `crypto.subtle`, which is gated on secure-context, so the sign-in popup never opens on `http://<LB-IP>`. Loopback is exempt:

   ```bash
   bash .claude/skills/deploy-agent-aks-dev/scripts/port-forward.sh
   # browser:  http://localhost:8080  → click "Sign In"
   ```

   Autonomous (no-sign-in) mode works fine on the raw `http://$APP_FQDN/` without port-forward.

### Step 7 — Verify

```bash
# Sidecar reachable on localhost from the agent container
kubectl -n agentid exec deploy/llm-agent -c llm-agent -- \
  curl -fsS http://localhost:5000/AuthorizationHeader?api=graph-app | head -c 80

# End-to-end autonomous flow
curl -fsS "http://$APP_FQDN/status"      # expect: ollama_available: true, sidecar_reachable: true

# Workload identity wired?
kubectl -n agentid exec deploy/llm-agent -c sidecar -- \
  ls /var/run/secrets/azure/tokens/      # expect: azure-identity-token
kubectl -n agentid exec deploy/llm-agent -c sidecar -- env | grep AZURE_
# expect AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE, AZURE_AUTHORITY_HOST
```

Then open `http://$APP_FQDN/` in a browser. Autonomous mode should return a model-generated answer ("weather in Seattle?" → real Open-Meteo data via the weather-api). Then run the port-forward and sign in via the MSAL popup to exercise OBO.

## Adapt for your own agent

The pattern is: **your agent container + the auth-sidecar container, in one pod, sharing localhost. The KSA federates to your Blueprint app. The sidecar reads the projected SA token from disk and signs Entra assertions on every outbound call.**

To swap in your own agent (instead of `llm-agent`):

1. **Build your agent image** to a registry AKS can pull from (the ACR created in Step 2 works; so does any other registry as long as the kubelet has pull credentials).

2. **Replace the `llm-agent` container spec** in `manifests/40-agent.yaml` with your image. Keep:
   - The pod label `azure.workload.identity/use: "true"` (triggers the webhook to project the SA token).
   - The KSA `agent-sa` (annotated with the Blueprint's `client-id` and the tenant).
   - The `sidecar` container, byte-for-byte unchanged. Image: `mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless`. It listens on `localhost:5000`.

3. **Call the sidecar from your agent code** for every outbound token need:
   ```http
   GET http://localhost:5000/AuthorizationHeader?api=<api-name>
   → 200 OK
   Authorization: Bearer eyJ...
   ```
   The `<api-name>` matches a `DownstreamApis__<name>__*` env var on the sidecar (see `40-agent.yaml`). To add a downstream API, set:
   ```yaml
   - name: AzureAd__ClientCredentials__0__SourceType
     value: SignedAssertionFilePath          # do not change
   - name: DownstreamApis__myapi__BaseUrl
     value: https://api.example.com
   - name: DownstreamApis__myapi__Scopes__0
     value: api://your-api-app-id/.default
   - name: DownstreamApis__myapi__RequestAppToken
     value: "true"                            # app-only; remove for OBO
   ```

4. **Re-issue federation if your namespace / KSA differ** from `agentid` / `agent-sa`. The FIC's `subject` field is exact-match — update Step 3 inputs.

5. **(Optional) Replace `weather-api`** with your downstream API. The sidecar handles token validation on the caller side; the API must validate the JWT (issuer, audience = its own app ID URI, `appid` claim = the Agent ID app ID). See `manifests/20-weather-api.yaml` for a Python reference implementation.

6. **(Optional) Replace `ollama`** with Azure OpenAI or any other completions backend by removing the `ollama` Deployment/Service/PVC and updating your agent's `OLLAMA_URL` (or analogous) env var.

What you do NOT need to change: the FIC, the sidecar image, the KSA annotations, the pod label, the projected-token volume path. Those are the contract between AKS Workload Identity and Entra Agent ID — and the contract is what makes this pattern portable across agents.

## One-Shot Orchestrator

When prereqs are met and SKU variables confirmed:

```bash
source /tmp/deploy-vars.sh
bash .claude/skills/deploy-agent-aks-dev/scripts/deploy-aks-dev.sh
```

Idempotent. Runs Steps 2 → 5 in order. Steps 0, 1, A, 6 require human decisions or interactive sign-in and remain manual.

## Key Artifacts

Persisted in `/tmp/deploy-vars.sh`:

| Variable | Source | Required? |
|---|---|---|
| `TENANT_ID`, `SUBSCRIPTION_ID` | User | always |
| `SUBSCRIPTION_TENANT_ID` | User | only for cross-tenant deployments |
| `RG`, `LOCATION`, `AKS_NAME`, `ACR_NAME`, `NODE_COUNT`, `NODE_VM_SIZE` | User (SKU) | always |
| `OLLAMA_MODEL`, `STORAGE_GB`, `INGRESS_TYPE`, `ENABLE_LOGS` | User (SKU) | always |
| `BLUEPRINT_APP_ID`, `AGENT_CLIENT_ID` | Step 1 (`entra-agent-id-setup`) | always |
| `CLIENT_SPA_APP_ID` | Step 1 | only for OBO |
| `BLUEPRINT_CLIENT_SECRET` | Step 1 | only for `kind` smoke test |
| `OIDC_ISSUER` | Step 2 | autofilled |
| `APP_FQDN` (= LoadBalancer IP) | Step 5 | autofilled |
| `FIC_NAME` | User (optional) | defaults to `aks-agent-sa`; set when redeploying to avoid collision with old FICs |

**No client secrets in the cluster.** The only secret on disk is the projected SA token, rotated automatically by the kubelet ~10 minutes before expiry.

## References

- [Architecture summary](./references/architecture.md) — pod / sidecar / Service / federation diagram
- [SKU and sizing decisions](./references/sku-sizing.md) — node, ACR, Ollama, ingress, logs cost matrix
- [Workload Identity deep-dive](./references/workload-identity.md) — why `SignedAssertionFilePath` works and how the FIC is validated
- [Cross-tenant federation](./references/cross-tenant-federation.md) — Azure sub in tenant A, Entra objects in tenant B
- [Post-deploy manual steps](./references/post-deploy-manual-steps.md) — SPA redirect URI, OBO consent, port-forward rationale
- [Adapting to EKS / GKE / on-prem](./references/non-azure-k8s.md) — the only Azure-specific pieces and what replaces them
- [Local smoke test on `kind`](./references/smoke-test.md) — what's covered, what's not, how to interpret failures
- [Troubleshooting matrix](./references/troubleshooting.md) — symptom → cause → fix tables
- [OBO pre-flight checklist](./references/obo-preflight-checklist.md) — **walk this before enabling OBO**; 12 quick checks that catch the failures we hit in real engagements (Microsoft.Graph module, signed-in role, missing SPs, consentType=AllPrincipals vs Principal, browser cache, etc.)

## Paired skills

- **Setup of Entra objects:** [`entra-agent-id-setup`](../entra-agent-id-setup/SKILL.md) — creates Blueprint + Agent Identity + Client SPA.
- **Teardown:** [`teardown-agent-aks-dev`](../teardown-agent-aks-dev/SKILL.md) — reverses this skill. DRY-RUN by default. Cleans the RG, the FIC on the Blueprint, and (opt-in) the Entra apps.
- **Alternate hosting:** [`deploy-agent-aca-dev`](../deploy-agent-aca-dev/SKILL.md) — same agent, Azure Container Apps instead of AKS. Use when the team is not already on Kubernetes.
