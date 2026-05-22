---
title: "Tutorial: Deploy a local-LLM agent with the Microsoft Entra Agent ID sidecar on Azure Kubernetes Service"
description: Deploy a self-contained agent (Ollama local LLM + Microsoft Entra Agent ID sidecar) to Azure Kubernetes Service. Workload Identity federation, no stored secrets, one Kubernetes ServiceAccount as the only thing the cluster trusts.
ms.topic: tutorial
ms.date: 05/22/2026
---

# Tutorial: Deploy a local-LLM agent with the Microsoft Entra Agent ID sidecar on Azure Kubernetes Service

In this tutorial, you deploy a sample AI agent whose model runs **in-cluster on Ollama** and whose identity is brokered by the **Microsoft Entra Agent ID sidecar**. The agent runs as a Kubernetes workload on **Azure Kubernetes Service (AKS)** and authenticates to Microsoft Entra without any long-lived credentials stored in cluster secrets, environment variables, or the container registry.

The model runs locally inside the cluster, so the deployment has **no second cloud** — the entire token chain begins and ends in Microsoft Entra and the workload boundary is a single Kubernetes pod. That makes this variant the right fit for teams that already standardize on Kubernetes, for organizations with hard requirements on workload portability across clusters (AKS, EKS, GKE, on-prem), and for demos in regulated tenants where the LLM must not leave the customer's network.

In this tutorial, you learn how to:

> [!div class="checklist"]
> * Create a Microsoft Entra Agent Identity Blueprint, Agent Identity, and OBO client app.
> * Provision an AKS cluster with the OIDC issuer and Workload Identity webhook enabled, plus a private Azure Container Registry.
> * Federate a Kubernetes ServiceAccount to Microsoft Entra (no managed identity, no client secret, no AWS, no GCP).
> * Build and deploy the agent, sidecar, downstream API, and Ollama as Kubernetes workloads.
> * Verify the autonomous and on-behalf-of (OBO) identity flows end to end.

> [!TIP]
> **Recommended: AI-assisted deployment.** The fastest, least error-prone way to finish this tutorial is to pair an AI assistant with the skill packaged in this repo: [`.claude/skills/deploy-agent-aks-dev/SKILL.md`](../../../.claude/skills/deploy-agent-aks-dev/SKILL.md). The assistant confirms your SKU choices, picks the right Ollama model strategy, handles the cross-tenant federation case if it applies, and surfaces known failure modes in real time — typically cutting deployment time from hours to minutes. Running the tutorial end-to-end by hand is fully supported (every command is documented below); the skill just front-loads the decisions.
>
> The skill works with **Claude Code** (which reads `.claude/skills/` by default) and with **GitHub Copilot Chat** (ask it to read the `SKILL.md` file). If you prefer a manual run, continue reading — the tutorial remains the source of truth.

## 1. Overview

### 1.1 What you build

A single AKS cluster that exposes a browser UI at `http://<load-balancer-ip>`. The cluster runs four workloads under one namespace (`agentid`):

| Workload | Image | Role |
|---|---|---|
| `llm-agent` Pod (container 1) | `agent-id-dev/llm-agent` (your ACR) | Public-facing Flask + LangChain agent. Receives user chat requests on port **3000**, decides when to call a tool, uses the Ollama HTTP API for LLM completions, and calls `weather-api` for downstream data. |
| `llm-agent` Pod (container 2 — sidecar) | `mcr.microsoft.com/entra-sdk/auth-sidecar` (Microsoft) | The **Microsoft Entra Agent ID auth sidecar**. Listens on `localhost:5000` (pod-internal, not exposed by any Service). `llm-agent` calls it to get Agent Identity tokens — app-only (**TR**, autonomous flow) or on-behalf-of a user (**TU**, OBO flow). Authenticates to Entra as the Blueprint app using `SignedAssertionFilePath` against the projected ServiceAccount token — no client secret. |
| `weather-api` Deployment | `agent-id-dev/weather-api` (your ACR) | Sample downstream API on `8080`, exposed inside the cluster as a `ClusterIP` Service. Validates the Agent Identity JWT on every request (JWKS signature check, issuer, audience, `appid`) and returns real Open-Meteo data only if the call is from the expected Agent Identity. |
| `ollama` Deployment | `ollama/ollama:latest` (public) | Local LLM server on `11434`, exposed inside the cluster as a `ClusterIP` Service. Serves Qwen 2.5 (or another small model) from a `PersistentVolumeClaim` so the model is pulled once and survives pod restarts. |

**Why one pod for agent + sidecar, and separate Deployments for weather-api and Ollama.** The Entra Agent ID sidecar must share `localhost` with the agent — pod is the smallest Kubernetes unit that guarantees that. The downstream API and the model server are not security-critical co-tenants of the agent; making them independent Deployments lets you scale, restart, swap models, or replace the LLM server (Ollama → vLLM → Azure OpenAI) without touching the agent pod or its auth path.

**How they're wired:**

```
user ──HTTP──▶ Service: llm-agent (LoadBalancer)
                    │
                    ▼
              Pod: llm-agent
                    │ localhost:5000   ──▶  sidecar         (Agent ID tokens)
                    │ Service:weather-api:8080  ──▶  Pod: weather-api  (validates TR/TU)
                    │ Service:ollama:11434      ──▶  Pod: ollama       (local LLM, PVC-backed)
                    │
                    └── (no external model calls — fully self-contained inside the cluster)
```

Only the `llm-agent` Service is publicly reachable. The `weather-api` and `ollama` Services are `ClusterIP` and the `sidecar` listener is pod-internal `localhost`, in line with the Entra Agent ID SDK security model.

When you're done:

* No `BLUEPRINT_CLIENT_SECRET` exists anywhere in the cluster, in any `Secret`, in any container image, or in the registry. The sidecar authenticates to Entra by reading the projected ServiceAccount token from disk and presenting it as a signed assertion.
* No external model provider credentials exist either — the LLM runs locally inside the cluster.
* Every Entra token rotates automatically (projected ServiceAccount token: 1 hour; Agent Identity tokens: minutes).
* Revocation is a single command: remove the federated credential from the Blueprint app, and the cluster instantly stops being trusted by Entra.

### 1.2 Architecture

#### 1.2.1 High-level overview

```
┌─────────────────────────────────────────┐
│        User's browser (MSAL.js)         │
└─────────────────────┬───────────────────┘
                      │ HTTP (or HTTPS if you add TLS)
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│  AKS cluster — namespace `agentid`                                │
│                                                                   │
│   Service: llm-agent (LoadBalancer)                              │
│                       │                                           │
│   ┌───────────────────▼────────────────────┐                     │
│   │  Pod: llm-agent                         │                     │
│   │   ├── container: llm-agent              │                     │
│   │   └── container: sidecar (Entra SDK)    │                     │
│   │       localhost:5000  (pod-internal)    │                     │
│   │       reads /var/run/secrets/azure/     │                     │
│   │             tokens/azure-identity-token │                     │
│   └───────────────────┬────────────────────┘                     │
│                       │                                           │
│   Service: weather-api ──▶  Pod: weather-api                     │
│   Service: ollama      ──▶  Pod: ollama  ──▶  PVC (model cache)  │
│                                                                   │
│   ServiceAccount: agent-sa                                       │
│   (annotated for Workload Identity)                              │
└─────────────────────────────┬────────────────────────────────────┘
                              │
                              ▼
                       Microsoft Entra ID
                       (Blueprint app — owns the federated credential)
```

#### 1.2.2 Identity and federation — one chain, one direction

There is exactly **one** federation chain in this deployment: the Kubernetes ServiceAccount `agentid/agent-sa` federates to the Blueprint app so the sidecar can sign Entra assertions without a client secret.

```
    ┌─────────────────────────────────────────┐
    │  Kubernetes ServiceAccount              │
    │  agentid/agent-sa                       │
    │  Issuer = AKS OIDC issuer URL           │
    │  Subject = system:serviceaccount:       │
    │              agentid:agent-sa           │
    └─────────────────────┬───────────────────┘
                          │  (sidecar reads the projected token from disk
                          │   and presents it as a client assertion)
                          ▼
    ┌─────────────────────────────────────────┐
    │  Blueprint app                          │
    │  Federated credential:                  │
    │    issuer  = <AKS OIDC URL>             │
    │    subject = system:serviceaccount:     │
    │                agentid:agent-sa         │
    │    audience = api://AzureADTokenExchange│
    └─────────────────────┬───────────────────┘
                          ▼
                   Graph + weather-api
```

This deployment uses **no user-assigned managed identity, no Azure AD application secret, no AWS OIDC provider, no IAM role**. The ServiceAccount is the only identity the cluster needs to trust, and the federation contract on the Blueprint is the only place Entra needs to be configured.

### 1.3 Why not static credentials

A laptop run of this sample uses `BLUEPRINT_CLIENT_SECRET` because it's the simplest pattern for a single developer. On AKS, you promote to `SignedAssertionFilePath`: the **Azure Workload Identity** webhook projects a Kubernetes ServiceAccount token into the pod at `/var/run/secrets/azure/tokens/azure-identity-token`, and the sidecar uses that token as the federated client assertion when calling Entra. The Blueprint client secret disappears from the cluster entirely — there is nothing in any `Secret`, `ConfigMap`, env var, or registry image that can be exfiltrated to obtain a long-lived credential.

Both patterns are valid — the local one optimizes for simplicity, the cluster one optimizes for secretlessness. They differ only in which value of `AzureAd__ClientCredentials__0__SourceType` the sidecar uses; the agent code is unchanged.

### 1.4 Why Azure Kubernetes Service

* **Pod-level sidecar semantics.** Multi-container pods share `localhost` and the same lifecycle, which is exactly what the Entra Agent ID SDK's security model requires.
* **Workload Identity is first-class.** OIDC issuer URL + mutating webhook + projected ServiceAccount tokens are a standard AKS feature flag (`--enable-oidc-issuer --enable-workload-identity`) — no custom controllers, no out-of-band token refresh container.
* **Portable beyond Azure.** The same manifests, with a different OIDC issuer URL, deploy to EKS or GKE. The Entra Agent ID side of the contract is identical because the FIC trusts the issuer URL, not the cloud.
* **Fits existing Kubernetes platforms.** Teams that already operate AKS for other workloads don't need a new compute service. The agent becomes another namespace alongside the rest of the platform.

## 2. Prerequisites

### 2.1 Azure

* A subscription where you can create resource groups, ACR, AKS clusters, public IPs, and (optionally) Log Analytics.
* One of the following Microsoft Entra roles for the signing-in user:
  * **Global Administrator**, or
  * **Agent ID Administrator** (template ID `db506228-d27e-4b7d-95e5-295956d6615f`), or
  * **Agent ID Developer** (template ID `adb2368d-a9be-41b5-8667-d96778e081b0`).
* Application Administrator alone is **not sufficient** — the Blueprint APIs require an Agent ID role.

> [!NOTE]
> **Cross-tenant supported.** The Blueprint and Agent Identity can live in a different tenant than the Azure subscription that hosts AKS. Workload Identity federation is based on the OIDC issuer URL, not the tenant. See [§7.2](#72-cross-tenant-federation) for the variable layout.

### 2.2 Tooling

| Tool | Minimum version | Notes |
|---|---|---|
| `az` CLI | 2.60 | With the `aks-preview` extension: `az extension add --name aks-preview`. |
| `kubectl` | 1.28 | Cluster client. |
| `pwsh` | 7.4 | Required for Agent ID Blueprint Graph operations. |
| `Microsoft.Graph.Authentication` | 2.35 | `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`. |
| `Microsoft.Graph.Beta.Applications` | 2.35 | Same. |
| `envsubst` | any | Ships with GNU `gettext`; comes with Git Bash on Windows. |
| `kind` *(optional)* | 0.22 | Only needed if you want to run the pre-flight smoke test in [§A](#appendix-a--local-smoke-test-with-kind) without paying for AKS. |
| Docker Desktop *(optional)* | 4.30 | Only required for the `kind` smoke test; AKS builds use `az acr build` and need no local Docker. |

### 2.3 Repository

```bash
git clone https://github.com/microsoft/entra-agentid-samples.git
cd entra-agentid-samples
```

## 2.5 Choose your SKUs

Before provisioning anything, pick a SKU for each of the following. The table lists **demo defaults** in bold; the warning blocks describe the silent-failure modes that happen when you accept a default without thinking. All values are set as shell variables in [§4](#4-set-variables).

| Decision | Variable | Demo default | Alternatives | When to change |
|---|---|---|---|---|
| Node VM size | `NODE_VM_SIZE` | **`Standard_D2s_v5`** (2 vCPU / 8 GiB, ~$70/mo) | `Standard_B2s` (~$30, slower), `Standard_D4s_v5` (~$140), `Standard_D8s_v5` (~$280), GPU `Standard_NC4as_T4_v3` (~$540) | 1.5B model on D2s_v5 CPU is comfortable for `⚡ Direct` calls; LLM-driven tool calling reliability improves materially on D8s_v5 or a GPU pool. |
| Node count | `NODE_COUNT` | **`2`** | `1` (cheaper) … `5` | `1` makes upgrades and replica rescheduling brittle; `≥2` keeps one node free during model pulls. |
| ACR SKU | `ACR_SKU` | **`Basic`** (~$5/mo) | `Standard` (~$20), `Premium` (~$50) | Stay on Basic for demos. Move to Standard if you start pushing multiple model-baked variants. |
| Ollama model | `OLLAMA_MODEL` | **`qwen2.5:1.5b`** (~1.3 GB, CPU-friendly) | `qwen2.5:0.5b`, `qwen2.5:3b`, `qwen2.5:7b` (needs ≥ D8s_v5 or GPU) | Larger models need bigger nodes; reliability and latency of LLM-driven tool calling depend heavily on this. |
| PVC size | `STORAGE_GB` | **`20`** | `10` (1.5B model only), `50` (multiple models cached) | At least `model_disk × 2`. 20 GiB covers any single 7B model with headroom. |
| Ingress | `INGRESS_TYPE` | **`LoadBalancer`** (`Standard` LB, ~$18/mo) | `ingress-nginx` (adds NGINX + cert-manager), `appgw` (AGIC, ~$240/mo) | LoadBalancer is the lightest path to a working demo; switch to `ingress-nginx` or AGIC the moment you need TLS, hostnames, or path-based routing. |
| Logs | `ENABLE_LOGS` | **`none`** (free, kubectl logs only) | `azure-monitor-container-insights` (~$2.76/GB) | Stay on `none` for the first deploy. Enable Container Insights once you hit a "why did this pod crash hours ago" question. |

> [!WARNING]
> **`NODE_VM_SIZE=Standard_B2s` + `qwen2.5:1.5b`.** The B-series is burstable. Sustained Ollama inference exhausts CPU credits, and answers that should take 1–2 s start taking 30+ s. Use D-series for any demo you'll show live.

> [!WARNING]
> **`OLLAMA_MODEL=qwen2.5:7b` on D2s_v5.** 7B models on CPU-only 2-vCPU nodes take 15–30 s per turn and often produce hallucinated tool calls under load. Either bump to `D8s_v5`, add a GPU node pool, or accept that LLM-driven tool calling is a stretch goal on small CPU nodes — the **⚡ Direct** mode (which is the authoritative proof of the Entra Agent ID + Workload Identity chain) works on every SKU.

> [!WARNING]
> **`INGRESS_TYPE=LoadBalancer` + browser sign-in.** Browsers gate `crypto.subtle` on **secure context**, and `http://<raw-IP>` is not a secure context. The MSAL.js popup for OBO sign-in throws `pkce_not_created: TypeError: Cannot read properties of undefined (reading 'subtle')`. The workaround is `kubectl port-forward` to `http://localhost:8080` (loopback is exempt). For an end-user-facing demo, switch to `ingress-nginx` with a real TLS certificate.

> [!WARNING]
> **`ENABLE_LOGS=none` + Ollama init container.** The init container does `ollama pull <model>` on first replica start (up to 5 min for a 7B model). Without Container Insights you can only inspect this via live `kubectl logs`; once the pod restarts there is no history. Turn logs on for the first deploy.

For the full decision matrix, see the skill reference: [`sku-sizing.md`](../../../.claude/skills/deploy-agent-aks-dev/references/sku-sizing.md).

## 3. Final object inventory

After you finish this tutorial, the following objects exist:

| Object | Where | Purpose |
|---|---|---|
| Agent Identity Blueprint | Entra | Defines the Agent Identity family. Holds the federated credential that trusts the cluster's ServiceAccount. |
| Agent Identity | Entra | The actual agent principal. Holds Graph app and delegated permissions. |
| Client SPA app | Entra | Browser-side MSAL.js sign-in surface for OBO flows. |
| Resource group | Azure | Container for all Azure resources. |
| Azure Container Registry | Azure | Holds `agent-id-dev/llm-agent` and `agent-id-dev/weather-api`. |
| AKS cluster | Azure | OIDC issuer + Workload Identity webhook enabled; ACR attached for pull. |
| (optional) Log Analytics workspace | Azure | Only if `ENABLE_LOGS=azure-monitor-container-insights`. |
| Kubernetes namespace `agentid` | AKS | Boundary for all in-cluster objects. |
| Kubernetes ServiceAccount `agentid/agent-sa` | AKS | The only thing the cluster needs Entra to trust. |
| Kubernetes Deployments and Services | AKS | `llm-agent`, `weather-api`, `ollama` |
| Kubernetes PersistentVolumeClaim | AKS | Caches the Ollama model across pod restarts. |

The Blueprint, Agent Identity, and Client SPA app are **tenant-level Entra objects** — they survive cluster deletions. The Azure resource group and the cluster are **disposable**.

## 4. Set variables

Run this block once at the start of your shell. Every subsequent command references these variables. The SKU variables come from [§2.5](#25-choose-your-skus) — confirm each choice before you `source` the file.

```bash
# Azure identity
export TENANT_ID="<your-entra-tenant-id>"                # Tenant where the Blueprint & Agent live
export SUBSCRIPTION_TENANT_ID="$TENANT_ID"               # Same as TENANT_ID for single-tenant deploy.
                                                         # Different value enables cross-tenant deploy (see §7.2).
export SUBSCRIPTION_ID="<azure-subscription-id>"
export RG="rg-agentid-aks-dev"
export LOCATION="eastus2"
export AKS_NAME="aks-agentid-dev"
export ACR_NAME="acragentiddev$(openssl rand -hex 3)"    # must be globally unique, lowercase, no hyphens

# SKU decisions (see §2.5 — confirm each one)
export NODE_VM_SIZE="Standard_D2s_v5"
export NODE_COUNT="2"
export ACR_SKU="Basic"
export OLLAMA_MODEL="qwen2.5:1.5b"
export STORAGE_GB="20"
export INGRESS_TYPE="LoadBalancer"                       # LoadBalancer | ingress-nginx | appgw
export ENABLE_LOGS="none"                                # none | azure-monitor-container-insights

# Sign in (two logins for cross-tenant; one for single-tenant)
az login --tenant "$TENANT_ID"                           # Entra tenant — for Blueprint and FIC operations
az login --tenant "$SUBSCRIPTION_TENANT_ID"              # Azure-sub tenant — same as above if single-tenant
az account set --subscription "$SUBSCRIPTION_ID"
```

## 5. Phase 1 — Create the Microsoft Entra Agent ID objects

These Entra objects are independent of the cluster. If you've already created them in a previous tutorial, skip to [§6](#6-phase-2--create-the-azure-infrastructure) and reuse the existing IDs.

### 5.1 Create the Blueprint and Agent Identity

```bash
pwsh -NoProfile -Command "
. ./scripts/EntraAgentID-Functions.ps1
Connect-MgGraph -Scopes `
  'AgentIdentityBlueprint.AddRemoveCreds.All',`
  'AgentIdentityBlueprint.Create',`
  'AgentIdentityBlueprint.DeleteRestore.All',`
  'AgentIdentity.DeleteRestore.All',`
  'DelegatedPermissionGrant.ReadWrite.All',`
  'Application.Read.All',`
  'AgentIdentityBlueprintPrincipal.Create',`
  'AppRoleAssignment.ReadWrite.All',`
  'Directory.Read.All',`
  'User.Read' -TenantId '$TENANT_ID' -NoWelcome
\$r = Start-EntraAgentIDWorkflow ``
  -BlueprintName 'Dev Local-LLM Blueprint' ``
  -AgentName 'Local LLM Weather Agent' ``
  -Permissions @('User.Read.All')
Write-Host \"BLUEPRINT_APP_ID=\$(\$r.Blueprint.BlueprintAppId)\"
Write-Host \"AGENT_CLIENT_ID=\$(\$r.Agent.AgentIdentityAppId)\"
"
```

```bash
export BLUEPRINT_APP_ID="<from-output>"
export AGENT_CLIENT_ID="<from-output>"
```

### 5.2 Register the Client SPA app

```bash
cat > scripts/.env <<EOF
TENANT_ID=${TENANT_ID}
BLUEPRINT_APP_ID=${BLUEPRINT_APP_ID}
AGENT_CLIENT_ID=${AGENT_CLIENT_ID}
EOF

bash scripts/setup-obo-client-app.sh
export CLIENT_SPA_APP_ID=$(grep '^CLIENT_SPA_APP_ID=' scripts/.env | cut -d= -f2)
```

### 5.3 Configure the Blueprint for OBO

```powershell
pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/setup-obo-blueprint-for-aks.ps1 `
  -BlueprintAppId $env:BLUEPRINT_APP_ID `
  -ClientSpaAppId $env:CLIENT_SPA_APP_ID `
  -AgentAppId $env:AGENT_CLIENT_ID `
  -TenantId $env:TENANT_ID
```

### 5.4 Admin-consent the Agent's delegated Graph permission

OBO requires a **delegated** `User.Read` grant in addition to the application permissions `Start-EntraAgentIDWorkflow` already granted. Without this, users hit `AADSTS65001`.

```powershell
pwsh -NoProfile -File .claude/skills/deploy-agent-aks-dev/scripts/grant-agent-obo-consent.ps1 `
  -AgentAppId $env:AGENT_CLIENT_ID -TenantId $env:TENANT_ID
```

> [!div class="checklist"]
> * Blueprint app ID: `$BLUEPRINT_APP_ID`
> * Agent Identity app ID: `$AGENT_CLIENT_ID`
> * Client SPA app ID: `$CLIENT_SPA_APP_ID`

## 6. Phase 2 — Create the Azure infrastructure

All commands use the SKU variables set in [§4](#4-set-variables).

### 6.1 Resource group, ACR, AKS cluster

```bash
az group create --name "$RG" --location "$LOCATION" -o none

az acr create --resource-group "$RG" --name "$ACR_NAME" --sku "$ACR_SKU" --admin-enabled false -o none

# Required resource providers
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait

# AKS with OIDC issuer + Workload Identity webhook enabled
CREATE_ARGS=(--resource-group "$RG" --name "$AKS_NAME" --location "$LOCATION"
  --node-count "$NODE_COUNT" --node-vm-size "$NODE_VM_SIZE"
  --enable-oidc-issuer --enable-workload-identity
  --enable-managed-identity
  --generate-ssh-keys)

if [[ "$ENABLE_LOGS" == "azure-monitor-container-insights" ]]; then
  az monitor log-analytics workspace create -g "$RG" -n "${AKS_NAME}-logs" -l "$LOCATION" -o none
  WS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "${AKS_NAME}-logs" --query id -o tsv)
  CREATE_ARGS+=(--enable-addons monitoring --workspace-resource-id "$WS_ID")
fi

az aks create "${CREATE_ARGS[@]}" -o none
```

### 6.2 Attach ACR to AKS

The kubelet pulls images from ACR using AKS's managed identity. Attaching the registry to the cluster grants the right RBAC automatically.

```bash
az aks update --resource-group "$RG" --name "$AKS_NAME" --attach-acr "$ACR_NAME" -o none
```

### 6.3 Capture the cluster's OIDC issuer URL

This URL is the trust anchor for the federated credential in [§7](#7-phase-3--federate-the-serviceaccount-to-the-blueprint).

```bash
export OIDC_ISSUER=$(az aks show -g "$RG" -n "$AKS_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)
echo "$OIDC_ISSUER"
```

### 6.4 Get cluster credentials

```bash
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing
kubectl get nodes
```

## 7. Phase 3 — Federate the ServiceAccount to the Blueprint

The sidecar authenticates to Entra as the Blueprint app using `SignedAssertionFilePath`. Add a federated credential on the Blueprint that trusts the cluster's OIDC issuer and the exact ServiceAccount the agent pod runs under.

### 7.1 Add the federated credential

```powershell
pwsh -NoProfile -Command "
Connect-MgGraph -Scopes 'AgentIdentityBlueprint.AddRemoveCreds.All' -TenantId '$env:TENANT_ID' -NoWelcome
\$body = @{
  name        = 'aks-agent-sa'
  issuer      = '$env:OIDC_ISSUER'
  subject     = 'system:serviceaccount:agentid:agent-sa'
  audiences   = @('api://AzureADTokenExchange')
  description = 'AKS Workload Identity for the local-LLM agent'
} | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest POST \"https://graph.microsoft.com/beta/applications(appId='$env:BLUEPRINT_APP_ID')/federatedIdentityCredentials\" -Body \$body -ContentType 'application/json'
"
```

The sidecar activates this credential by setting `AzureAd__ClientCredentials__0__SourceType=SignedAssertionFilePath` and pointing it at the projected token in [Phase 5](#9-phase-5--deploy-the-kubernetes-workloads).

**This is the only federation chain in the deployment.** There is no managed identity, no AWS, no GCP, no intermediary app.

### 7.2 Cross-tenant federation

Workload Identity federation is **OIDC-URL based**, not tenant-bound — so the Blueprint can live in one tenant while AKS and ACR live in a different tenant's subscription. Common case: an Entra demo tenant holds the Blueprint and Agent Identity, while a corporate billing tenant holds the Azure subscription that runs the cluster.

Set the two tenant variables independently in [§4](#4-set-variables):

```bash
export TENANT_ID="<entra-tenant — Blueprint & Agent live here>"
export SUBSCRIPTION_TENANT_ID="<azure-sub tenant — AKS/ACR live here>"
```

Run `az login` once per tenant; the CLI tracks the two contexts side by side. The federation Graph call always uses `$TENANT_ID` (Blueprint tenant); the cluster commands always use `$SUBSCRIPTION_TENANT_ID` (Azure tenant). Full pattern, variable contract, and common errors: [`cross-tenant-federation.md`](../../../.claude/skills/deploy-agent-aks-dev/references/cross-tenant-federation.md).

## 8. Phase 4 — Build and push container images

Two images go to your ACR: `llm-agent` and `weather-api`. The sidecar image is pulled from MCR at runtime. Ollama uses the upstream image as-is (the model is pulled into the PVC by an `initContainer`, not baked into the image).

`az acr build` runs the build inside ACR — no local Docker daemon is required.

```bash
az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/llm-agent:1.0.0 \
  --platform linux/amd64 \
  sidecar/dev

az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/weather-api:1.0.0 \
  --platform linux/amd64 \
  sidecar/weather-api
```

## 9. Phase 5 — Deploy the Kubernetes workloads

The full manifest set lives in [`.claude/skills/deploy-agent-aks-dev/manifests/`](../../../.claude/skills/deploy-agent-aks-dev/manifests/) and uses `${VAR}` placeholders that `envsubst` substitutes at apply time.

### 9.1 Render and apply

```bash
set -a; source /tmp/deploy-vars.sh; set +a    # auto-export every variable

MANIFEST_DIR=".claude/skills/deploy-agent-aks-dev/manifests"

# Render with explicit varlist so typos fail loudly instead of producing empty strings
VARLIST='$TENANT_ID $BLUEPRINT_APP_ID $AGENT_CLIENT_ID $CLIENT_SPA_APP_ID $ACR_NAME $OLLAMA_MODEL $STORAGE_GB'

for f in "$MANIFEST_DIR"/*.yaml; do
  envsubst "$VARLIST" < "$f"
done | kubectl apply -f -
```

The manifests create, in order:

| File | What it creates |
|---|---|
| `00-namespace.yaml` | Namespace `agentid` |
| `10-serviceaccount.yaml` | ServiceAccount `agent-sa` annotated with `azure.workload.identity/client-id=${BLUEPRINT_APP_ID}` and `tenant-id=${TENANT_ID}` |
| `20-weather-api.yaml` | Deployment + ClusterIP Service for `weather-api` |
| `30-ollama.yaml` | PVC (`${STORAGE_GB}Gi`), `initContainer` that runs `ollama pull ${OLLAMA_MODEL}`, Deployment, ClusterIP Service |
| `40-agent.yaml` | Deployment for the `llm-agent` pod (agent container + sidecar container); pod labelled `azure.workload.identity/use: "true"`; sidecar reads token from `/var/run/secrets/azure/tokens/azure-identity-token` and sets `AzureAd__ClientCredentials__0__SourceType=SignedAssertionFilePath` |
| `50-ingress.yaml` | LoadBalancer Service exposing `llm-agent` on port 80 |

### 9.2 Wait for the LoadBalancer IP

```bash
kubectl -n agentid wait deploy/llm-agent --for=condition=available --timeout=10m

export APP_FQDN=$(kubectl -n agentid get svc llm-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "http://${APP_FQDN}"
```

> [!IMPORTANT]
> The pod label `azure.workload.identity/use: "true"` is what triggers the mutating webhook to project the token into the sidecar's filesystem. If you remove the label, the file `/var/run/secrets/azure/tokens/azure-identity-token` will not exist and the sidecar will log `FileNotFoundException` on every token request.

## 10. Phase 6 — Post-deployment wiring

Two manual steps that can't be done before the cluster exists.

### 10.1 Add the LoadBalancer IP to the Client SPA redirect URIs

```bash
bash .claude/skills/deploy-agent-aks-dev/scripts/add-spa-redirect-uri.sh
```

The script PATCHes `spa.redirectUris` on the Client SPA app directly via Graph. It always adds `http://localhost:8080/` (used for the port-forward sign-in path in [§11.4](#114-obo-flow-via-port-forward)) and additionally adds `http://${APP_FQDN}/` if `APP_FQDN` is set. `az ad app update --web-redirect-uris` does **not** affect SPA redirect URIs — that's why this is a Graph PATCH.

### 10.2 Agent → Graph delegated `User.Read` consent

Already done in [§5.4](#54-admin-consent-the-agents-delegated-graph-permission). If you skipped it, do it now — you'll hit `AADSTS65001` on the OBO flow otherwise.

## 11. Phase 7 — Verify

### 11.1 Confirm pod and Workload Identity wiring

```bash
kubectl -n agentid get pods
# Expect llm-agent, weather-api, ollama all Running.

# The sidecar should have the AZURE_* env vars injected by the webhook
kubectl -n agentid exec deploy/llm-agent -c sidecar -- env | grep '^AZURE_'
# Expect: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE, AZURE_AUTHORITY_HOST

# The projected token file must exist
kubectl -n agentid exec deploy/llm-agent -c sidecar -- \
  ls -l /var/run/secrets/azure/tokens/
```

### 11.2 Status check

```bash
curl -sS "http://${APP_FQDN}/api/status" | python3 -m json.tool
# Expected:
# "ollama_available": true
# "ollama_model": "qwen2.5:1.5b"
# "sidecar_url": "http://localhost:5000"
```

### 11.3 Autonomous flow (⚡ Direct)

```bash
curl -sS -X POST "http://${APP_FQDN}/api/chat" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Weather in Dallas?","token_flow":"autonomous","use_langchain":false}' \
  | python3 -m json.tool
```

The response includes the weather from `weather-api` and Qwen's natural-language explanation. This call exercises the full chain: sidecar → projected token → Entra → Agent Identity token → `weather-api` → Open-Meteo. **This is the authoritative proof that the Entra Agent ID + Workload Identity wiring works.**

### 11.4 OBO flow (via port-forward)

Browsers refuse to compute the PKCE challenge over plain HTTP unless the page is loaded from a secure context. `http://<LB-IP>` is not a secure context; `http://localhost:*` is. Port-forward to localhost:

```bash
kubectl -n agentid port-forward svc/llm-agent 8080:80
```

In a browser, open <http://localhost:8080/>, click **Sign In**, complete MSAL, then chat with **Identity Flow = OBO**.

For a production-style sign-in URL, terminate TLS in front of the Service (NGINX Ingress + cert-manager, or AGIC + Key Vault).

### 11.5 Ollama health

```bash
kubectl -n agentid logs deploy/ollama --tail 30
kubectl -n agentid exec deploy/ollama -- ollama list
```

On first pod start, the `initContainer` runs `ollama pull qwen2.5:1.5b` and writes the model to the PVC. Subsequent restarts skip the pull because the volume persists.

## 12. Rotate

Workload Identity rotates its projected ServiceAccount tokens automatically (~1 hour). If you redeploy the cluster, or move tenants:

1. Capture the new OIDC issuer URL: `az aks show ... --query oidcIssuerProfile.issuerUrl -o tsv`.
2. Delete the Blueprint's federated credential and re-add it with the new `issuer` (and unchanged `subject = system:serviceaccount:agentid:agent-sa`).
3. Update `TENANT_ID` and `BLUEPRINT_APP_ID` annotations on the ServiceAccount if those changed:
   ```bash
   kubectl -n agentid annotate sa agent-sa azure.workload.identity/client-id=$BLUEPRINT_APP_ID --overwrite
   kubectl -n agentid annotate sa agent-sa azure.workload.identity/tenant-id=$TENANT_ID --overwrite
   kubectl -n agentid rollout restart deploy/llm-agent
   ```

There is no AWS or GCP rotation — because there is no AWS or GCP.

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Sidecar logs `AADSTS70021: No matching federated identity record` | FIC subject mismatch | Recreate the FIC with subject `system:serviceaccount:agentid:agent-sa` — exact characters, no spaces, lowercase. |
| Sidecar logs `AADSTS700016: Application not found` | `AzureAd__ClientId` is the Agent ID, not the Blueprint | Set `AzureAd__ClientId=$BLUEPRINT_APP_ID` in the sidecar env (it's the federated identity holder). |
| `kubectl exec sidecar -- env \| grep AZURE_` returns nothing | Pod missing label `azure.workload.identity/use: "true"` | Add the label to the pod template, redeploy. |
| `AZURE_FEDERATED_TOKEN_FILE` is set but the file doesn't exist | KSA missing the required annotations | Annotate KSA with `azure.workload.identity/client-id=$BLUEPRINT_APP_ID` and `azure.workload.identity/tenant-id=$TENANT_ID`. |
| Sidecar logs `FileNotFoundException: ...azure-identity-token` | Mutating webhook didn't fire (or AKS feature not enabled) | `az aks update -g $RG -n $AKS_NAME --enable-workload-identity`; restart pod. |
| `ollama_available: false` in `/api/status` | initContainer still pulling model | First pull is 1–5 min for `qwen2.5:1.5b`. Tail `kubectl logs deploy/ollama -c init-pull-model`. |
| Ollama pod OOMKilled | Model too large for node | Drop to `qwen2.5:1.5b` or bump `NODE_VM_SIZE`. |
| Agent answers ignore the tool ("here's a generic forecast") | LLM-driven tool calling on small CPU node — small models hallucinate tool decisions | Use **⚡ Direct** mode to verify the auth chain; bump to D8s_v5 + 7B, GPU pool, or Azure OpenAI for reliable Ollama tool calling. |
| OBO sign-in popup throws `pkce_not_created: TypeError: Cannot read properties of undefined (reading 'subtle')` | Browser refuses `crypto.subtle` on non-secure context | Use `kubectl port-forward` and load `http://localhost:8080`. |
| `AADSTS65001` on browser OBO sign-in | Missing delegated `User.Read` admin consent | Run `grant-agent-obo-consent.ps1` (see [§5.4](#54-admin-consent-the-agents-delegated-graph-permission)). |
| `AADSTS50011: redirect URI mismatch` | Deployed URL (or `http://localhost:8080`) not in SPA `redirectUris` | Run `add-spa-redirect-uri.sh` (see [§10.1](#101-add-the-loadbalancer-ip-to-the-client-spa-redirect-uris)). |
| Graph `$filter=appId eq` returns empty for Blueprint | Agent Identity Blueprint types invisible to `$filter` | Use key-lookup form `/beta/applications(appId='<id>')` — the scripts in this skill already do this. |
| `403 Authorization_RequestDenied` on Blueprint create | Signing-in user has only `Application Administrator`, not an Agent ID role | Assign `Agent ID Developer` or `Agent ID Administrator`. |
| Cross-tenant: FIC was added but sidecar still hits `AADSTS70021` | FIC accidentally added to a Blueprint **in the wrong tenant** | Run `Connect-MgGraph -TenantId $TENANT_ID` explicitly before the Graph PATCH. Delete the wrong FIC, recreate in the Blueprint tenant. |
| LB IP stays `<pending>` for >5 min | Subscription LB quota exhausted or policy blocks public IPs | Switch `INGRESS_TYPE` to `ingress-nginx` and use an internal LB or an Application Gateway. |
| Pod `ImagePullBackOff` | ACR not attached to AKS, or wrong image name | `az aks update --attach-acr $ACR_NAME`; double-check the manifest image refs match `$ACR_NAME.azurecr.io/agent-id-dev/...:1.0.0`. |
| Rendered manifest still contains `$TENANT_ID` literal | `envsubst` ran without exported vars | `set -a; source /tmp/deploy-vars.sh; set +a` before rendering, or use the explicit varlist form shown in [§9.1](#91-render-and-apply). |

### 13.1 Diagnostic one-liners

```bash
# Cluster basics
kubectl -n agentid get pods,svc,sa

# OIDC issuer (must match the FIC issuer URL on the Blueprint)
az aks show -g "$RG" -n "$AKS_NAME" --query oidcIssuerProfile.issuerUrl -o tsv

# FIC on the Blueprint
az rest --method GET --url "https://graph.microsoft.com/beta/applications(appId='$BLUEPRINT_APP_ID')/federatedIdentityCredentials"

# Sidecar env (Workload Identity wiring)
kubectl -n agentid exec deploy/llm-agent -c sidecar -- env | grep '^AZURE_'

# Sidecar logs (Entra auth errors)
kubectl -n agentid logs deploy/llm-agent -c sidecar --tail 50

# Ollama pull progress and served models
kubectl -n agentid logs deploy/ollama --tail 50
kubectl -n agentid exec deploy/ollama -- ollama list
```

## 14. Cost (demo profile, ~24/7)

| Line item | Approx USD/month |
|---|---|
| AKS — 2 × Standard_D2s_v5 nodes | ~$140 |
| Standard Load Balancer rule + public IP | ~$22 |
| Azure Container Registry Basic | ~$5 |
| `${STORAGE_GB}` GiB managed-csi PVC (default `20`) | ~$1.50 |
| Log Analytics *(only if enabled)* | ~$2 |
| **Total Azure** | **~$170** |
| Per-token model cost | **$0** (Ollama local) |

`az aks stop --resource-group $RG --name $AKS_NAME` drops the node bill to $0 while preserving the cluster and PVC; total at-rest is ~$30/mo (ACR + LB + PVC + public IP). `az aks start` brings the cluster back in 2–3 min.

## 15. Clean teardown

> **TIP — AI-assisted teardown.** If you use Claude Code or GitHub Copilot, invoke the [`teardown-agent-aks-dev`](../../../.claude/skills/teardown-agent-aks-dev/SKILL.md) skill. It runs the same commands below with dry-run by default and prompts at each destructive step.
>
> ```bash
> # Dry run (default — prints commands, deletes nothing)
> bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh
>
> # Azure only
> DRY_RUN=0 bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh
>
> # Full teardown (Azure + FIC + opt-in Entra apps)
> DRY_RUN=0 DELETE_ENTRA=1 \
>   bash .claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh
> ```

### 15.1 Order of operations

1. **Revoke OAuth consent** on the Agent SP so a future redeploy starts from a clean state.
2. **Delete the federated credential** on the Blueprint. The Blueprint itself is usually shared across deployments — do not delete it by accident.
3. **Delete the Azure resource group** — removes the AKS cluster, ACR (with the built images), Log Analytics workspace, public IP, and PVC in one call.
4. **Delete Entra objects** *(opt-in)* — Client SPA, Agent Identity, Blueprint. Blueprints are often shared — **re-confirm before deleting**.

### 15.2 Manual commands

```bash
# 0. Load the deployment variables
source /tmp/deploy-vars.sh

# 1. Revoke OAuth consent on the Agent SP
AGENT_SP_OID=$(az ad sp show --id "$AGENT_CLIENT_ID" --query id -o tsv)
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$AGENT_SP_OID'" \
  --query 'value[].id' -o tsv | while read -r g; do
    az rest --method DELETE --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$g"
  done

# 2. Delete the FIC on the Blueprint (does NOT delete the Blueprint app itself)
FIC_ID=$(az rest --method GET \
  --uri "https://graph.microsoft.com/beta/applications(appId='$BLUEPRINT_APP_ID')/federatedIdentityCredentials?\$select=id,name" \
  --query "value[?name=='aks-agent-sa'].id | [0]" -o tsv)
[[ -n "$FIC_ID" ]] && az rest --method DELETE \
  --uri "https://graph.microsoft.com/beta/applications(appId='$BLUEPRINT_APP_ID')/federatedIdentityCredentials/$FIC_ID"

# 3. Azure — deletes AKS, ACR, public IP, PVC, Log Analytics in one call
az group delete --name "$RG" --yes --no-wait

# 4. Entra (opt-in)
az ad app delete --id "$CLIENT_SPA_APP_ID"
az rest --method DELETE --uri "https://graph.microsoft.com/beta/agentIdentities/$AGENT_CLIENT_ID"
# Blueprint — re-confirm, this may be shared:
az ad app delete --id "$BLUEPRINT_APP_ID"
```

### 15.3 Verify

```bash
az group exists --name "$RG"                              # expect: false
az rest --method GET --url "https://graph.microsoft.com/beta/applications(appId='$BLUEPRINT_APP_ID')/federatedIdentityCredentials" \
  --query "value[?name=='aks-agent-sa']" -o tsv           # expect: empty
```

## Appendix A — Local smoke test with kind

Before paying for AKS, you can validate the manifest wiring on a local `kind` cluster. The smoke test substitutes `SignedAssertionFilePath` (which needs an Entra-trusted OIDC issuer) with `ClientSecret`, so it does not exercise the federation chain — but it catches typos in the manifests, image build problems, and pod startup issues.

```bash
source /tmp/deploy-vars.sh
export BLUEPRINT_CLIENT_SECRET="<one-shot secret minted only for the smoke test>"
bash .claude/skills/deploy-agent-aks-dev/scripts/smoke-test-kind.sh

# Cleanup
bash .claude/skills/deploy-agent-aks-dev/scripts/smoke-test-kind.sh --cleanup
```

Full details: [`smoke-test.md`](../../../.claude/skills/deploy-agent-aks-dev/references/smoke-test.md).

## Appendix B — Secretless migration from docker-compose

| Setting | docker-compose (`sidecar/dev`) | This tutorial (AKS) |
|---|---|---|
| `AzureAd__ClientCredentials__0__SourceType` | `ClientSecret` | `SignedAssertionFilePath` |
| `AzureAd__ClientCredentials__0__SignedAssertionFileDiskPath` | n/a | `/var/run/secrets/azure/tokens/azure-identity-token` |
| `BLUEPRINT_CLIENT_SECRET` | In `.env` | **Deleted** |
| Sidecar network access | Docker bridge | Pod-internal `localhost` |
| FIC on Blueprint | Not required | Required (added in [§7](#7-phase-3--federate-the-serviceaccount-to-the-blueprint)) |
| Identity rotation | Manual secret rotation | Automatic (~1 h projected token rotation) |

Both configurations are valid: local docker-compose optimizes for setup simplicity; AKS optimizes for secretlessness.
