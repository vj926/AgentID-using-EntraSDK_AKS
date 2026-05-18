# SKU and sizing decisions

Demo-cost target: **~$150/mo if left running 24×7**. Tear down between sessions.

## Node pool

| `NODE_VM_SIZE` | vCPU / RAM | ~$/mo (East US, PAYG) | Use case |
|---|---|---|---|
| `Standard_B2s` | 2 / 4 | ~$30 | Smallest possible demo; `qwen2.5:1.5b` works but is slow |
| `Standard_D2s_v5` | 2 / 8 | ~$70 | **Default**. Comfortable for `qwen2.5:1.5b`. |
| `Standard_D4s_v5` | 4 / 16 | ~$140 | Required for `qwen2.5:7b` on CPU |
| `Standard_NC4as_T4_v3` | 4 / 28 + T4 GPU | ~$540 | Required for `qwen2.5:7b` at usable latency |

`NODE_COUNT=2` ensures one node free for rescheduling during model pulls or upgrades. Customer demos can drop to 1.

## Ollama

| `OLLAMA_MODEL` | RAM (peak) | Disk | First-token latency on D2s_v5 |
|---|---|---|---|
| `qwen2.5:0.5b` | ~700 MB | ~400 MB | <1 s |
| **`qwen2.5:1.5b`** | ~1.5 GB | ~1.3 GB | 1–2 s |
| `llama3.2:1b` | ~1.5 GB | ~1.3 GB | 1–2 s |
| `qwen2.5:3b` | ~2.5 GB | ~2 GB | 3–5 s |
| `qwen2.5:7b` (CPU) | ~5.5 GB | ~4.3 GB | 15–30 s (avoid) |
| `qwen2.5:7b` (GPU) | ~5.5 GB | ~4.3 GB | 1–2 s |

**Default `qwen2.5:1.5b`**: best demo experience on the cheapest CPU node.

`STORAGE_GB` for the PVC: at least `model_disk × 2`. 20 Gi covers any single 7B model with room for one alternate.

## LLM tool-calling reliability — the part that surprises everyone

The Entra value-prop is the **token chain**, not the LLM. But the same demo UI also exposes an Ollama-driven tool-calling path, and small CPU-only models do not reliably emit `tool_calls`. Customers see this and assume something is wrong with the auth setup. It isn't.

| Choice | Cost delta | Tool-calling result |
|---|---|---|
| **Default**: `Standard_D2s_v5` + `qwen2.5:1.5b` | $0 | ⚡ Direct works always; 💻 Ollama is "best-effort" — sometimes calls the tool, often skips it and hallucinates |
| Bump nodes to `Standard_D8s_v5` + `qwen2.5:7b` (CPU) | ~+$210/mo | Tool calls reliably, but 15–30 s/turn |
| Add a GPU node pool (`Standard_NC4as_T4_v3`, taint `sku=gpu:NoSchedule`) and pin Ollama there | ~+$500/mo | Reliable AND fast (<5 s/turn) |
| **Recommended for enterprise demos**: replace Ollama with **Azure OpenAI** | ~$10–50/mo pay-per-token | Tool calls reliably; removes the entire Ollama Deployment + PVC; sidecar pattern is unchanged |

**Practical guidance:** to verify the auth chain in any size demo, use ⚡ Direct mode. To showcase end-to-end LLM-driven tool calling, either pay for a GPU node or swap to Azure OpenAI.

## ACR

| `ACR_SKU` | Storage | Geo | When to use |
|---|---|---|---|
| **`Basic`** | 10 GB | single region | Demo, samples, customer adopts → fork |
| `Standard` | 100 GB | single region | If you're storing multiple model-baked images |
| `Premium` | 500 GB | geo-replication | Production multi-region |

## Ingress

| `INGRESS_TYPE` | What gets installed | Cost / complexity |
|---|---|---|
| **`LoadBalancer`** | None — just a public Standard LB on the agent Service | Free (LB rule fee ~$18/mo); zero extra components |
| `ingress-nginx` | NGINX ingress controller via Helm | Adds 1 deployment; needs cert-manager for TLS |
| `appgw` | AKS Application Gateway add-on (AGIC) | App Gateway base ~$240/mo; managed TLS via Key Vault |

Default `LoadBalancer` because the goal is a working demo, not a hardened production gateway.

## Logs

| `ENABLE_LOGS` | What you get | Cost |
|---|---|---|
| **`none`** | `kubectl logs` against pods | Free; lost on pod deletion |
| `azure-monitor-container-insights` | Container Insights with retained logs | ~$2–3/GB ingested |

Default `none` for demo. Flip on once you hit a "why is my pod crashing" moment that requires history.

## Total estimated demo cost (East US, PAYG, default everything)

| Item | $/mo |
|---|---|
| 2 × Standard_D2s_v5 | ~$140 |
| ACR Basic | ~$5 |
| Standard LB rule | ~$18 |
| 20 GB managed-csi PVC | ~$1.5 |
| Public IP | ~$3.5 |
| **Total** | **~$170/mo** |

Stop the cluster (`az aks stop`) when not in use and total drops to ~$30/mo (storage + ACR only).
