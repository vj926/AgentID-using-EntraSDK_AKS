# `sidecar/aks/` — Entra Agent ID auth-sidecar on Azure Kubernetes Service

Secretless deployment of the local-LLM sample agent (`llm-agent` + Microsoft Entra Agent ID auth-sidecar, plus downstream `weather-api` and Ollama) to AKS using **Azure Workload Identity**.

This directory contains the production-quality manifests and a one-shot orchestrator. For the **comprehensive, AI-led walkthrough** (including how to adapt the pattern for **your own agent**), see the skill:

> 📘 [`.claude/skills/deploy-agent-aks-dev/SKILL.md`](../../.claude/skills/deploy-agent-aks-dev/SKILL.md)

## Architecture

```
                     ┌───────────────────────────────── AKS cluster ──────────────────────────────┐
 user ── http  ──▶   │  Service/LB ─▶ Pod: llm-agent  (3000)                                       │
                     │                 ├── llm-agent       (your agent code)                       │
                     │                 └── sidecar         (mcr.microsoft.com/entra-sdk/...)       │
                     │                      localhost:5000 — never exposed                         │
                     │                      SignedAssertionFilePath = projected SA token           │
                     │                                                                              │
                     │            Service: weather-api  ─▶ Pod: weather-api (8080)                 │
                     │            Service: ollama       ─▶ Pod: ollama (11434) + PVC               │
                     └──────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
                       KSA `agentid/agent-sa` ──FIC──▶ Blueprint app ──▶ Graph / weather-api
                            (issuer = AKS OIDC, subject = system:serviceaccount:agentid:agent-sa)
```

**One federation chain. No UAMI. No client secrets in the cluster.** The Workload Identity webhook projects a Kubernetes SA token into the pod; the auth-sidecar reads it via `SignedAssertionFilePath` and uses it as the federated client assertion for the Blueprint app.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| `az` | ≥ 2.60 | Plus `aks-preview` extension |
| `kubectl` | ≥ 1.28 | |
| `pwsh` | ≥ 7.4 | With `Microsoft.Graph.Authentication` module |
| `envsubst` | any | From `gettext`; comes with Git Bash on Windows |

Plus: an Entra `Agent ID Developer` (or higher) role, `Owner`/`Contributor` on the target Azure subscription, and a Blueprint + Agent Identity already created via `Start-EntraAgentIDWorkflow`.

## Quick start (one shot)

```bash
cp scripts/deploy-vars.sh.template /tmp/deploy-vars.sh
# Edit /tmp/deploy-vars.sh: TENANT_ID, SUBSCRIPTION_ID, RG, LOCATION, AKS_NAME, ACR_NAME,
# BLUEPRINT_APP_ID, AGENT_CLIENT_ID, (optional) CLIENT_SPA_APP_ID.

source /tmp/deploy-vars.sh
az login --tenant "${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"
az account set --subscription "$SUBSCRIPTION_ID"

bash scripts/deploy-aks-dev.sh
```

This provisions the RG, ACR, AKS (OIDC + Workload Identity enabled), builds the images, federates the KSA → Blueprint, applies all manifests, and prints the LoadBalancer IP.

### Steps the orchestrator runs

| Step | Script | What it does |
|---|---|---|
| 1 | `01-create-aks.sh` | RG + ACR + AKS (OIDC + Workload Identity) + ACR attach |
| 2 | `02-build-and-push.sh` | `az acr build` for `llm-agent` and `weather-api` — no local Docker |
| 3 | `03-federate-blueprint.ps1` | Adds FIC on Blueprint: issuer = AKS OIDC, subject = `system:serviceaccount:agentid:agent-sa` |
| 4 | `04-apply-manifests.sh` | `envsubst` → `kubectl apply -f manifests/` → wait for LB IP |

## Cross-tenant deployment

Workload-Identity federation is **OIDC-issuer-URL based**, not tenant-bound — so you can host AKS in one tenant's subscription while the Blueprint app lives in a different tenant (common when the Entra Agent ID demo tenant differs from the corporate Azure billing tenant).

```bash
export TENANT_ID="<entra-tenant — Blueprint & Agent live here>"
export SUBSCRIPTION_TENANT_ID="<azure-sub tenant>"
export SUBSCRIPTION_ID="<sub id inside SUBSCRIPTION_TENANT_ID>"
```

Full pattern, gotchas, and the two `az login` flows: see [skill reference — cross-tenant federation](../../.claude/skills/deploy-agent-aks-dev/references/cross-tenant-federation.md).

## Post-deploy (required only for user On-Behalf-Of mode)

The **autonomous** path (no sign-in) works as soon as `deploy-aks-dev.sh` finishes — open `http://<LB-IP>/`, leave **Identity = Autonomous** and **Mode = ⚡ Direct**, and it works.

To exercise **user-OBO** mode (the **Sign In** button in the UI), do all three:

```bash
# 1. Register SPA redirect URIs (localhost:8080 + LB-IP)
APP_FQDN="$APP_FQDN" bash scripts/add-spa-redirect-uri.sh

# 2. Admin-consent the Agent's delegated User.Read (fixes AADSTS65001)
pwsh -NoProfile -File scripts/grant-agent-obo-consent.ps1 \
  -AgentAppId "$AGENT_CLIENT_ID" -TenantId "$TENANT_ID"

# 3. Port-forward (browsers refuse MSAL/PKCE on raw HTTP IPs; loopback is exempt)
bash scripts/port-forward.sh
# In a browser: http://localhost:8080 → Sign In
```

Rationale: [skill reference — post-deploy manual steps](../../.claude/skills/deploy-agent-aks-dev/references/post-deploy-manual-steps.md).

## Verify

```bash
# Sidecar reachable from agent container?
kubectl -n agentid exec deploy/llm-agent -c llm-agent -- \
  curl -fsS http://localhost:5000/AuthorizationHeader?api=graph-app | head -c 80

# End-to-end autonomous flow
curl -fsS "http://$APP_FQDN/status"

# Workload identity wired?
kubectl -n agentid exec deploy/llm-agent -c sidecar -- \
  ls /var/run/secrets/azure/tokens/        # azure-identity-token
kubectl -n agentid exec deploy/llm-agent -c sidecar -- env | grep AZURE_

# Ollama model loaded?
kubectl -n agentid exec deploy/ollama -- ollama list
```

## Execution modes & LLM tool-calling reliability (important)

The agent UI exposes two execution modes:

| Mode | What it proves | Reliability |
|---|---|---|
| **⚡ Direct** | Skip the LLM, call `weather-api` directly with a real Agent Identity token. **This is the authoritative proof of the Entra Agent ID + Workload Identity chain.** | 100% — works for every city, every time |
| **💻 Ollama** | LLM-driven tool calling via LangGraph ReAct. Demonstrates a local model making its own decisions to invoke the tool. | Depends on node SKU & model — see below |

With the default `qwen2.5:1.5b` on `Standard_D2s_v5` (2 vCPU, CPU-only inference), tool-calling is **unreliable** — the small model frequently skips the tool and hallucinates a response. For deterministic LLM-driven tool calling you need one of:

| Choice | Cost delta | Tool-calling result |
|---|---|---|
| Stay on D2s_v5 + qwen2.5:1.5b | $0 | Direct works always; Ollama is "best-effort" |
| Bump nodes to `Standard_D8s_v5` and switch to `qwen2.5:7b` (CPU) | ~+$210/mo | Reliable but slow (15–30 s/turn) |
| Add a GPU node pool (`Standard_NC4as_T4_v3`, taint `sku=gpu:NoSchedule`) and pin Ollama there | ~+$500/mo | Reliable and fast (<5 s/turn) |
| Replace Ollama with **Azure OpenAI** as the agent's LLM backend | ~$10–50/mo pay-per-token | Most realistic enterprise pattern; deletes the Ollama PVC + Deployment |

> The Entra value-prop is independent of which LLM the agent uses. Customers picking AKS for the *identity* story can pair it with any LLM backend they prefer; this sample defaults to Ollama only because the upstream `sidecar/dev` does.

## What differs from the ACA variant

| Concern | ACA | AKS (this) |
|---|---|---|
| Pod boundary | 1 container app, 4 containers on `localhost` | 1 pod (agent + sidecar) + 2 standalone Deployments |
| Identity | System-assigned MI → FIC subject = MI `principalId` | KSA → FIC subject = `system:serviceaccount:agentid:agent-sa` (no UAMI) |
| Sidecar credential source | `SignedAssertionFromManagedIdentity` | `SignedAssertionFilePath` |
| Ingress | Managed ACA ingress (HTTPS by default) | `Service type: LoadBalancer` (HTTP) — TLS via NGINX/AGIC if needed |
| Model storage | Baked into Ollama image or runtime-pulled into ephemeral disk | PVC; pulled once by initContainer, persists across restarts |
| OBO sign-in URL | `https://<APP_FQDN>` (managed cert) | `http://localhost:8080` via port-forward (raw HTTP IP isn't a secure context) |

## Cleanup

For a single-RG delete (keeps Entra apps, removes only the FIC):

```bash
bash ../../.claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh        # dry-run
DRY_RUN=0 bash ../../.claude/skills/teardown-agent-aks-dev/scripts/teardown-aks-dev.sh
```

Full teardown (RG + FIC + opt-in Entra apps): see [`teardown-agent-aks-dev`](../../.claude/skills/teardown-agent-aks-dev/SKILL.md).

## Layout

```
sidecar/aks/
├── README.md                       (this file)
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-serviceaccount.yaml      (KSA annotated for Workload Identity)
│   ├── 20-weather-api.yaml         (Deployment + Service)
│   ├── 30-ollama.yaml              (PVC + Deployment + Service, init pulls model)
│   ├── 40-agent.yaml               (Deployment: llm-agent + auth-sidecar)
│   └── 50-ingress.yaml             (LoadBalancer Service for llm-agent)
└── scripts/
    ├── deploy-vars.sh.template
    ├── 01-create-aks.sh
    ├── 02-build-and-push.sh
    ├── 03-federate-blueprint.ps1
    ├── 04-apply-manifests.sh
    ├── deploy-aks-dev.sh           (one-shot orchestrator)
    │
    ├── setup-obo-blueprint-for-aks.ps1   (post-deploy OBO: scope + pre-auth + admin consent)
    ├── add-spa-redirect-uri.sh           (post-deploy: localhost:8080 + LB-IP on Client SPA)
    ├── grant-agent-obo-consent.ps1       (post-deploy: User.Read admin consent for Agent SP)
    └── port-forward.sh                   (open http://localhost:8080 → svc/llm-agent)
```

## Adapting for your own agent

Replace the `llm-agent` container in `manifests/40-agent.yaml` with your image; keep the sidecar container, the KSA, the pod label `azure.workload.identity/use: "true"`, and the projected-token mount path. Call the sidecar for every outbound token need:

```http
GET http://localhost:5000/AuthorizationHeader?api=<api-name>
→ Authorization: Bearer eyJ...
```

Full walkthrough: see the skill's [Adapt for your own agent](../../.claude/skills/deploy-agent-aks-dev/SKILL.md#adapt-for-your-own-agent) section.
