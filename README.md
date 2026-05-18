# AgentID using EntraSDK — AKS

Production-quality reference for deploying an AI agent secured by **Microsoft Entra Agent ID** on **Azure Kubernetes Service (AKS)**, using Azure Workload Identity and a Microsoft-published auth-sidecar.

This is the AKS counterpart to the ACA / App Service samples in [microsoft/entra-agentid-samples](https://github.com/microsoft/entra-agentid-samples). Same identity pattern, same sidecar — different hosting platform.

## What's in this repo

```
.
├── .claude/skills/
│   ├── deploy-agent-aks-dev/      ← publication-grade deploy skill
│   │   ├── SKILL.md
│   │   ├── scripts/               ← orchestrator + post-deploy scripts
│   │   └── references/            ← 8 deep-dive reference docs
│   └── teardown-agent-aks-dev/    ← safe teardown skill (DRY_RUN=1 by default)
│       ├── SKILL.md
│       └── scripts/
└── sidecar/aks/
    ├── README.md                  ← architecture + quick-start
    ├── manifests/                 ← Kubernetes YAML (Deployment, Service, PVC, SA)
    └── scripts/                   ← bash + pwsh scripts (cluster, ACR, FIC, manifests)
```

## What this gives you

- **Zero secrets in the cluster.** Identity flows from a Kubernetes ServiceAccount → Azure Workload Identity federation → an Entra Agent ID Blueprint app. No client secrets stored anywhere.
- **Sidecar pattern.** Your agent code never imports MSAL. It calls `GET http://localhost:5000/AuthorizationHeader` against a sidecar container in the same pod, and gets a fully-formed `Authorization: Bearer …` header back.
- **Two identity modes supported out of the box:**
  - **Autonomous (app-only)** — agent acts as itself for background workloads.
  - **On-Behalf-Of (OBO)** — agent acts on behalf of a signed-in user; both identities appear in the Entra audit log.
- **Cross-tenant ready.** The Blueprint and Agent Identity can live in one Entra tenant while AKS lives in another tenant's subscription — Workload Identity federation is OIDC-issuer based, not tenant-bound.

## Quick start

```bash
# Phase 1 (one-time, separate skill): create Blueprint + Agent Identity in Entra
#   → use the upstream `entra-agent-id-setup` skill, or run Start-EntraAgentIDWorkflow

# Phase 2 (this repo): deploy to AKS
cp sidecar/aks/scripts/deploy-vars.sh.template /tmp/deploy-vars.sh
# Edit /tmp/deploy-vars.sh — fill in TENANT_ID, SUBSCRIPTION_ID, RG, AKS_NAME, ACR_NAME,
# BLUEPRINT_APP_ID, AGENT_CLIENT_ID, (optional) CLIENT_SPA_APP_ID.

source /tmp/deploy-vars.sh
az login --tenant "${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"
az account set --subscription "$SUBSCRIPTION_ID"

bash sidecar/aks/scripts/deploy-aks-dev.sh
```

For the full walkthrough (including "how to adapt this for your own agent"), read [`.claude/skills/deploy-agent-aks-dev/SKILL.md`](./.claude/skills/deploy-agent-aks-dev/SKILL.md).

## Architecture (one-liner)

```
LoadBalancer ─▶ Pod: llm-agent (agent container + auth-sidecar on localhost:5000)
                Pod: weather-api  (downstream API)
                Pod: ollama       (local LLM, on PVC)

                KSA agentid/agent-sa ── FIC ──▶ Blueprint app (Entra)
```

## Choosing AKS vs ACA vs App Service

The Entra Agent ID **identity pattern is identical across all three** Microsoft-hosted options. The hosting choice depends on whether you need Kubernetes-specific capabilities (GPU node pools, service mesh, network policies, multi-cluster portability to EKS/GKE/on-prem). If you don't, ACA is usually the simpler choice.

## Status

- ✅ End-to-end deployment validated in cross-tenant mode (Entra demo tenant + corporate Azure subscription).
- ✅ Both autonomous and OBO modes working.
- ✅ Publication-grade skills authored for both deploy and teardown.
- 🟡 Upstream PRs to `microsoft/entra-agentid-samples` pending.

## License

MIT — see [LICENSE](./LICENSE).

## Acknowledgements

Built on top of the [microsoft/entra-agentid-samples](https://github.com/microsoft/entra-agentid-samples) reference patterns. The auth-sidecar image (`mcr.microsoft.com/entra-sdk/auth-sidecar`) is published and maintained by Microsoft.
