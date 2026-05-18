# Architecture summary

One pod runs the **agent + sidecar** on shared `localhost`. Everything else is a separate Service.

```
                    ┌──────────────────────── AKS cluster ────────────────────────┐
   user ──https──▶  │  Service/LB ─▶ Pod: llm-agent                                │
                    │                 ├─ llm-agent  (Flask, port 3000)             │
                    │                 └─ auth-sidecar (port 5000, localhost only)  │
                    │                         │                                    │
                    │                         ▼                                    │
                    │   reads /var/run/secrets/azure/tokens/azure-identity-token   │
                    │   via SignedAssertionFilePath credential source              │
                    │                                                              │
                    │  Service: weather-api ─▶ Pod: weather-api (8080)             │
                    │  Service: ollama       ─▶ Pod: ollama (11434) + PVC          │
                    └──────────────────────────────────────────────────────────────┘
                                                  │
                                                  ▼
        KSA agentid/agent-sa ──FIC (audience api://AzureADTokenExchange)──▶  Blueprint app
                                                  │
                                                  ▼
                                       Graph / weather-api
```

| Container | Role | Port |
|---|---|---|
| `llm-agent` | Flask + LangChain; calls Ollama Service for completions | 3000 |
| `auth-sidecar` | `mcr.microsoft.com/entra-sdk/auth-sidecar`; reads SA token, signs Entra assertions | 5000 (localhost) |
| `weather-api` | Validates Agent Identity JWT (JWKS, iss, aud, appid) on every request | 8080 |
| `ollama` | Local LLM server, model on PVC | 11434 |

**One federation chain, one direction:**
```
KSA → Blueprint → Graph / weather-api
```
- `KSA → Blueprint` audience: `api://AzureADTokenExchange` (workload-identity standard)
- `Blueprint → downstream` audience: `https://graph.microsoft.com` or the weather-api app ID URI

**What's NOT in this deployment** (compared to the AWS variant):
- No UAMI / intermediary Entra app
- No external cloud OIDC IdP
- No token refresher container
- No `AWS_*` / `BEDROCK_*` env vars
- No shared `EmptyDir` for JWT passing — the workload identity webhook handles projection

**What rotates:** Agent Identity tokens (minutes), projected SA tokens (~1 h). **What's permanent:** the FIC on the Blueprint app. **What's local:** Ollama weights on a PVC.

## Why the agent + sidecar are in the same pod

Microsoft security guidance for the auth-sidecar: it MUST be reachable only inside the same trust boundary. A k8s pod shares a network namespace, so `localhost:5000` is reachable from the agent container but not from any other pod, node process, or off-cluster client. This is the k8s equivalent of "no host port" in compose / "shared revision" in ACA.

## Why weather-api and ollama are separate Deployments

Unlike ACA (one container app = one process group), k8s lets each workload scale and store independently:
- **weather-api** demonstrates real cross-pod token validation. The agent calls a different Service IP, the request crosses the pod boundary, and the API independently validates the JWT.
- **ollama** has a PVC and may grow to a GPU node pool. Coupling it to the agent pod would force a model reload on every agent restart and make GPU scheduling awkward.
