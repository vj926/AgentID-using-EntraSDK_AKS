# Concepts & Decisions — a reader's guide

This document is a teaching companion to the deploy scripts. Three things every reader should understand before deploying:

1. **[The architecture, in plain English](#1-the-architecture-in-plain-english)** — what's inside the cluster, what each box does, and how they connect.
2. **[Prerequisites — what you bring vs what this repo creates](#2-prerequisites--what-you-bring-vs-what-this-repo-creates)** — the two-phase setup model.
3. **[Choosing AKS vs ACA vs App Service](#3-choosing-aks-vs-aca-vs-app-service)** — when each hosting platform is the right fit.

---

## 1. The architecture, in plain English

Inside the AKS cluster, the workload is three pods. Think of the cluster as an **apartment building** and each pod as an **apartment** — isolated from the others, talking only through Services (the "doorbells").

```
   User's browser
        │  http://<LB-IP>/  (the public door)
        ▼
   ┌──────────────────────── Box 1 ─────────────────────┐
   │   llm-agent container                              │
   │     │                                              │
   │     │  (1) "I need a weather token"                │
   │     ▼                                              │
   │   sidecar container ─── (2) talks to Entra ────────┼──▶ gets token
   │     │                                              │
   │     │  (3) returns Bearer token                    │
   │     ▼                                              │
   │   llm-agent container                              │
   └──────┬───────────────────────────┬─────────────────┘
          │                           │
          │ (4) HTTP w/ token         │ (5) "what should I say?"
          ▼                           ▼
   ┌──── Box 2 ────┐           ┌──── Box 3 ────┐
   │  weather-api  │           │    ollama     │
   │  (port 8080)  │           │  (port 11434) │
   └───────────────┘           └───────────────┘
```

### 📦 Box 1 — Pod `llm-agent` (the brain)

The **only** pod the outside world can reach (a LoadBalancer Service in front gives it a public IP). It holds **two containers** sharing the same network namespace (think: two roommates in the same apartment, sharing the same phone line and front door).

| Container | What it does | Listens on |
|---|---|---|
| `llm-agent` | Your actual agent code — the chat UI, the LangGraph ReAct loop, the prompt logic. **This is the code you replace with your own agent.** | port 3000 (exposed via Service) |
| `sidecar` | Microsoft-published image (`mcr.microsoft.com/entra-sdk/auth-sidecar`). Its only job is to hand out access tokens when your agent asks for one. | `localhost:5000` — **never exposed outside the pod** |

Because the two containers share a pod, they share a `localhost` network. The agent does:

```
GET http://localhost:5000/AuthorizationHeader?api=weather-api
```

and gets back a fully-formed `Authorization: Bearer eyJ...` header. **Your agent code never imports MSAL, never sees a secret.**

### 📦 Box 2 — Pod `weather-api` (the downstream API the agent calls)

A simple Node.js API representing "any business API your agent needs to call." Validates the bearer token and returns weather data.

- Listens on port 8080
- Exposed inside the cluster only via a Service named `weather-api`
- Not reachable from outside the cluster

**Stand-in for any real downstream system** — your CRM API, your billing system, Microsoft Graph, etc.

### 📦 Box 3 — Pod `ollama` (the local LLM)

A self-hosted Ollama server running `qwen2.5:1.5b` (or whatever model you configure). The agent's **brain** — the model it consults to decide what to do.

- Listens on port 11434
- Has a **PVC** (PersistentVolumeClaim) attached — a disk that survives pod restarts so the model file doesn't have to be re-downloaded every time the pod restarts
- Exposed inside the cluster only via a Service named `ollama`

### Step by step — what happens when a user asks "What's the weather in Seattle?"

1. Browser hits `http://<LB-IP>/` → reaches **Box 1** (the agent container)
2. Agent asks **ollama in Box 3**: "user wants weather in Seattle, what tool should I call?" → ollama replies with a `tool_calls` payload pointing to weather-api
3. Agent asks the **sidecar (in the same pod, on localhost:5000)**: "give me a token for weather-api"
4. Sidecar talks to Entra ID, comes back with a Bearer token
5. Agent calls **Box 2 (weather-api)** with the Bearer token attached → gets the weather
6. Agent feeds the weather back to **Box 3 (ollama)**: "the API returned X, summarize it for the user"
7. Agent returns the final answer to the browser

### The identity chain (lives in Entra, NOT in the cluster)

```
KSA agentid/agent-sa  ── FIC ── ▶ Blueprint app
```

This is **how the sidecar in Box 1 proves to Entra ID that it IS the agent**, without any password or secret.

| Thing | Plain-English meaning |
|---|---|
| **KSA `agentid/agent-sa`** | A Kubernetes ServiceAccount. Think of it as Box 1's **employee badge** — issued and signed by the AKS cluster itself. Kubernetes automatically mounts a fresh, signed JWT version of this badge into the sidecar container every hour. |
| **FIC (Federated Identity Credential)** | A rule registered on the Blueprint app that says: *"If anyone shows me a badge signed by THIS AKS cluster's OIDC issuer, AND the badge name is exactly `system:serviceaccount:agentid:agent-sa`, then I trust them to act as me."* |
| **Blueprint app** | The Entra app registration that **is** the agent's identity. Holds all the API permissions (Graph User.Read, weather-api access, etc.). |

When the sidecar wants a token, the sequence is:

1. Sidecar reads the KSA badge from disk (`/var/run/secrets/azure/tokens/azure-identity-token`)
2. Sidecar sends it to Entra ID, saying "here's my badge, give me a token for the Blueprint app"
3. Entra ID checks the FIC rule, sees the badge matches, and issues a real Entra token
4. Sidecar hands that token back to the agent container

**Net effect: zero secrets in the cluster.** The "credential" is a Kubernetes-issued badge that rotates automatically and only the kubelet can mint.

> **One-line summary:** Box 1 is the agent + its identity helper. Box 2 is the API it calls. Box 3 is the brain it thinks with. The arrow at the bottom is how Box 1 proves who it is to Microsoft Entra ID — using a Kubernetes badge instead of a password.

---

## 2. Prerequisites — what you bring vs what this repo creates

The Entra Agent ID workflow has **two phases**. This repo only does Phase 2. Phase 1 is a separate one-time setup.

```
   Phase 1: Identity setup  (run ONCE per agent, per tenant)
   ───────────────────────────────────────────────────────────
   Skill:  entra-agent-id-setup     (PowerShell, ~5 min)
   Creates: Blueprint app + Agent Identity + downstream API perms
            ↓
   Phase 2: Hosting deploy  (run per environment / per cloud)
   ───────────────────────────────────────────────────────────
   Skill:  deploy-agent-aks-dev     (this repo)
   Reuses:  BLUEPRINT_APP_ID, AGENT_CLIENT_ID from Phase 1
   Creates: AKS cluster + ACR + FIC + pods
```

### Why split this way?

Identity is **tenant-scoped** and **long-lived**. Hosting is **environment-scoped** and **disposable**. You may tear down AKS five times during development — you should not tear down the Blueprint each time.

### What you need before running the AKS deploy

| # | Prerequisite | How you get it | What it gives you |
|---|---|---|---|
| 1 | **Entra tenant** with admin who has `Agent ID Developer` role | Your Entra admin grants you the role | Permission to create Blueprints / Agent Identities |
| 2 | **Azure subscription** with `Owner` or `Contributor` | Provisioned by your Azure admin | Permission to create RG / AKS / ACR |
| 3 | **Blueprint app** registered in Entra | Run `Start-EntraAgentIDWorkflow` from the `entra-agent-id-setup` skill | An appId that represents "the agent's role" |
| 4 | **Agent Identity** created from the Blueprint | Same command above (it does both in one shot) | An Entra Agent ID object with its own objectId, viewable in the portal under Agent IDs |
| 5 | **Downstream API permissions** granted to the Blueprint | Same Phase 1 workflow (or manual `az ad app permission grant`) | The Blueprint can request tokens for Graph, your APIs, etc. |
| 6 | **Local tooling**: `az`, `kubectl`, `pwsh`, `envsubst` | `winget install` / `choco install` | The deploy scripts run |

Items 1–5 are produced by the [`entra-agent-id-setup`](https://github.com/microsoft/entra-agentid-samples/tree/main/.claude/skills/entra-agent-id-setup) skill in the upstream Microsoft repo. Item 6 is just your laptop.

### What the AKS deploy skill DOES and does NOT do

| Action | Does this repo do it? |
|---|---|
| Create a tenant or grant you Entra roles | ❌ No — done by your admin upfront |
| Create the Blueprint app | ❌ No — `entra-agent-id-setup` does it |
| Create the Agent Identity | ❌ No — `entra-agent-id-setup` does it |
| Grant Graph / API permissions to the Blueprint | ❌ No — `entra-agent-id-setup` does it |
| Create an Azure resource group | ✅ Yes |
| Create the ACR (container registry) | ✅ Yes |
| Create the AKS cluster (with OIDC + Workload Identity enabled) | ✅ Yes |
| Build and push the agent + weather-api images | ✅ Yes |
| **Add the Federated Identity Credential (FIC) on the existing Blueprint** | ✅ Yes — this is the key wiring step |
| Apply the Kubernetes manifests (Deployment, Service, PVC) | ✅ Yes |
| Set up OBO sign-in (SPA redirect URIs, admin consent) | ✅ Yes — post-deploy scripts |

### Why we deliberately don't auto-create Blueprint + Agent Identity

1. **Permissions are different.** Creating a Blueprint needs the `Agent ID Developer` role in Entra. Creating AKS needs `Owner` on a sub. Most enterprises split these between Identity team and Platform team. Forcing both into one skill blocks adoption.

2. **Identity is shared, hosting is not.** One Blueprint typically powers an agent that gets deployed to dev, test, staging, prod — each with its own AKS cluster. Re-creating the Blueprint per environment would create duplicate identities in Entra, which is exactly what you don't want.

3. **Cross-tenant deployments require it.** The Blueprint can live in Entra tenant A while AKS lives in tenant B's subscription. The split is mandatory — you literally can't create both from one `az login` session.

> **TL;DR:** This repo is **Phase 2 only**. It assumes a working Blueprint + Agent Identity already exist. If a customer has *only* "an agent" (code) but no Blueprint yet, they run `entra-agent-id-setup` first (~5 minutes) and then come here.

---

## 3. Choosing AKS vs ACA vs App Service

The Entra Agent ID **identity pattern is identical across all three** Azure hosting options. The hosting choice is purely an infrastructure decision. Use the matrix below.

### Decision matrix — with the *why* explained

| Scenario | What this actually means | App Service | ACA | AKS |
|---|---|---|---|---|
| **Your team already runs Kubernetes** | You have engineers who already know `kubectl`, write YAML manifests, manage clusters (could be AKS, EKS, GKE, on-prem). Adding another hosting style means a second skillset, two sets of dashboards, two deployment pipelines. | ❌ Second skillset | 🟡 Still a second skillset | ✅ **Reuse what you already know** |
| **You want zero infra to manage** | You don't want to patch node OSes, upgrade Kubernetes versions, size node pools, or get paged at 2 AM because a node went `NotReady`. You just want to push code and trust the platform. | ✅ Pure PaaS — Microsoft owns everything below your code | ✅ Serverless containers — Microsoft owns the cluster | ❌ You own the cluster, the upgrades, the node pools |
| **First-time customer demo / PoC** | You're showing a customer the Entra Agent ID pattern for the first time. The goal is "wow factor" with minimal time spent on plumbing. Cluster bring-up shouldn't eat your demo prep. | 🟡 Works, but feels old-school | ✅ **5-minute deploy, scale-to-zero, demo-ready** | 🟡 20+ min just to provision the cluster |
| **Need identical setup in EKS / GKE / on-prem K8s later** | The customer says "we deploy to AWS EKS today and may move to Azure tomorrow" or "we run our own K8s on-prem." You need manifests that work everywhere with only the identity wiring changing. | ❌ Azure-only | ❌ Azure-only | ✅ **Kubernetes YAML is portable** — same manifests anywhere |
| **Need GPU for the LLM** | You want to run a real model (qwen2.5:7B, Llama 70B, Mistral) with sub-5-second responses. CPU-only inference is too slow and small CPU models can't reliably do tool calling. You need NVIDIA T4 / A10 / A100 hardware. | ❌ No GPU support | 🟡 Limited GPU SKUs, regional | ✅ **GPU node pools with taints/tolerations** — pin Ollama there only |
| **Need fine-grained network policies** | "Pod A can only talk to Pod B on port 443" rules — like a firewall, but inside the cluster. Required for many enterprise compliance teams (PCI, SOC2). Implemented by Calico / Cilium. | ❌ Not the right abstraction | 🟡 Some traffic rules but not pod-level | ✅ **NetworkPolicy is a first-class K8s object** |
| **Need HPA + KEDA-style autoscaling** | Scale based on custom signals: queue depth, Service Bus messages, Prometheus metric, GPU utilization — not just CPU/memory. | 🟡 Basic CPU/mem scaling only | ✅ KEDA built-in, scales on 50+ event sources | ✅ Full KEDA + HPA + Cluster Autoscaler |
| **Need scale-to-zero** | When nobody is using the agent for an hour, you pay $0. First request after idle takes a 1–5 second cold start, which is acceptable. | ❌ Always running, always billed | ✅ **Native — scales to 0 replicas automatically** | 🟡 Possible via KEDA, but node pool still costs money unless you also shrink it |
| **Workload runs 24/7** | This is a production agent serving requests around the clock. Scale-to-zero is irrelevant because you never go idle. Now it's just a "$/hour while always-on" question. | ✅ Cheapest at small constant load | 🟡 Pay-per-second adds up at 100% utilization | ✅ **Cheapest at large constant load** (you commit to nodes) |
| **Need multiple containers in the same unit** | The Entra sidecar pattern is exactly this: agent container + auth-sidecar container sharing localhost. You may also want a log shipper, a service mesh proxy, etc. | 🟡 Sidecar slot exists but limited to 1 | ✅ Multi-container revision is first-class | ✅ Native — pods support any number of containers |
| **Need a service mesh (Istio, Linkerd)** | You want mTLS between every service automatically, traffic shifting (10% to v2, 90% to v1), retries, circuit breakers — all without code changes. | ❌ Not supported | 🟡 Envoy is under the hood but not user-configurable | ✅ **Install Istio/Linkerd freely** |
| **Need complex networking (private endpoints, custom DNS, multi-VNet)** | Customer requires the agent to live inside their corporate VNet, talk to on-prem AD via ExpressRoute, expose internal-only via private endpoint, with custom DNS forwarders. | 🟡 VNet integration exists but constrained | ✅ Good VNet integration | ✅ **Full BYO VNet, CNI choice, private clusters** |
| **Compliance: must control OS image / kernel / hardening** | Auditor requires CIS-hardened nodes, custom kernel modules, specific patch cadence, or air-gapped operations. PaaS hides the OS from you — that's a non-starter for some teams. | ❌ PaaS — Microsoft picks the OS | ❌ PaaS — Microsoft picks the OS | ✅ **You choose AKS node image, run image-cleaner, apply CIS benchmarks** |
| **Multi-region active/active** | Same workload running in East US + West Europe + Southeast Asia for latency, with traffic distribution and failover. | 🟡 One Web App per region + Front Door | 🟡 One Container App per region + Front Door | ✅ **Federated multi-cluster patterns, Argo CD per cluster** |
| **Entra Agent ID + secretless identity** | The whole point of this POC — no client secrets in your hosting platform. | ✅ System MI → FIC → Blueprint | ✅ System MI → FIC → Blueprint | ✅ Workload Identity (KSA) → FIC → Blueprint |
| **Operational complexity tolerance** | How much "platform work" is your team okay doing on top of just shipping the agent? Upgrades, monitoring the control plane, node maintenance, etc. | 🟢 Near zero | 🟢 Near zero | 🔴 Significant — owning a Kubernetes cluster is a job |
| **Time-to-first-deploy** | From "az login" to "the agent answers an HTTP request." | ~5 minutes | ~5 minutes | ~20–30 minutes (cluster creation alone is 8–12 min) |
| **$/month baseline (1 idle workload)** | Cost when there's no traffic. Important for dev/test environments and demos. | ~$13 (B1 plan) | ~$0 with scale-to-zero | ~$70 (one D2s_v5 node + 1 LB IP, always on) |
| **Skill required on the team** | Who can operate it on Day 2? | Web developers comfortable with Azure Portal + GitHub Actions | Cloud-native developers who know containers but not K8s | Kubernetes operators who own clusters and YAML |

Legend: ✅ great fit · 🟡 works but not ideal · ❌ avoid · 🟢 easy · 🔴 hard

### Pick one in 10 seconds

| Question | If **YES** → pick |
|---|---|
| "Does my team already run Kubernetes for everything else?" | **AKS** |
| "Do I need GPU, mesh, or non-Azure K8s portability?" | **AKS** |
| "Is this a customer demo / a small SaaS-style workload that should scale to zero?" | **ACA** |
| "Cloud-native architecture, but I don't want to manage Kubernetes?" | **ACA** |
| "It's a classic web app team, lift-and-shift, .NET / Node / Python web stack?" | **App Service** |
| "I have many existing App Service apps and don't want a second hosting model?" | **App Service** |

### The honest 3-line summary

- **App Service** — for **classic web app teams**. You write Python/.NET/Node web apps and want PaaS to handle the rest. Cheapest at small scale, most opinionated. Don't use it if you need GPU, mesh, or K8s portability.
- **ACA** — **the default modern choice**. Cloud-native, scale-to-zero, multi-container, no cluster ops. If you can't articulate a specific reason to use AKS, you should use ACA.
- **AKS** — for teams that **need** Kubernetes: they already run it elsewhere, they need GPU / service mesh / network policies, or they need the same manifests to work on EKS / GKE / on-prem tomorrow. You pay for that power with cluster operations work.

The Entra Agent ID story is **identical across all three** — same sidecar, same Blueprint, same FIC, same OBO. The hosting platform is purely an infrastructure choice.
