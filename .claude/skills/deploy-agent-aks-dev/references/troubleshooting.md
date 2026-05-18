# Troubleshooting matrix

Match symptom → cause → fix. Most issues fall into 4 buckets: workload identity wiring, image pull, Ollama, post-deploy Entra config.

## Quick reference — actual K8s object names

These names are what the manifests create. Use these in every `kubectl` command:

| Object | Name |
|---|---|
| Namespace | `agentid` |
| ServiceAccount | `agent-sa` |
| Agent Deployment | `llm-agent` (pod label `app=llm-agent`) |
| Agent containers (in same pod) | `llm-agent` and `sidecar` |
| Other Deployments | `weather-api`, `ollama` |
| LoadBalancer Service (UI) | `llm-agent` |

Common commands (use these verbatim — `app=agent` or container `auth-sidecar` will silently match nothing):
```
kubectl get pods -n agentid
kubectl get svc  -n agentid llm-agent                                       # external IP
kubectl logs     -n agentid -l app=llm-agent -c sidecar    --tail=50        # sidecar
kubectl logs     -n agentid -l app=llm-agent -c llm-agent  --tail=50        # web UI
kubectl exec     -n agentid deploy/llm-agent -c sidecar -- env | grep ^AZURE_
```

## Workload Identity / token acquisition

| Symptom | Cause | Fix |
|---|---|---|
| Sidecar logs: `AADSTS70021: No matching federated identity record` | FIC subject mismatch | Recreate FIC: `subject=system:serviceaccount:agentid:agent-sa` exactly. Spaces or wrong namespace = no match. |
| Sidecar logs: `AADSTS700016: Application not found` | `AzureAd__ClientId` is the Agent ID, not the Blueprint | Set `AzureAd__ClientId=$BLUEPRINT_APP_ID` |
| Sidecar logs: `Could not load file or assembly` / restarts | Wrong image tag | Use `mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless` |
| `kubectl exec sidecar -- env \| grep AZURE_` returns nothing | Pod missing label `azure.workload.identity/use: "true"` | Add to pod template, restart deployment |
| `AZURE_FEDERATED_TOKEN_FILE` set but file is empty | KSA missing annotations | Annotate KSA with `azure.workload.identity/client-id` and `tenant-id` |
| Sidecar logs `FileNotFoundException: ...azure-identity-token` | Mutating webhook didn't fire | `az aks update -g $RG -n $AKS --enable-workload-identity`; restart pod |

## Image pull

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on llm-agent or weather-api | ACR not attached to AKS | `az aks update -g $RG -n $AKS --attach-acr $ACR_NAME` |
| `ImagePullBackOff` on `ollama/ollama:latest` | Docker Hub rate limit | Pull-through cache in ACR: `az acr import --source docker.io/ollama/ollama:latest`, change manifest to use ACR copy |

## Ollama

| Symptom | Cause | Fix |
|---|---|---|
| Ollama pod crash-loops, OOMKilled | Model too large for node | Switch `OLLAMA_MODEL` to `qwen2.5:1.5b` or bump `NODE_VM_SIZE` |
| `/status` returns `ollama_available: false` | Init container still pulling model | Wait — first pull is 1–5 min |
| Init container hangs on `ollama pull` | Network egress blocked | Check NSG / firewall allows `registry.ollama.ai` |
| Agent gets 500s when asking questions | Wrong model name in `OLLAMA_MODEL` env vs what initContainer pulled | Make sure they match exactly (`qwen2.5:1.5b` ≠ `qwen2.5`) |

## Post-deploy Entra config

| Symptom | Cause | Fix |
|---|---|---|
| OBO sign-in fails with `AADSTS65001` | Agent → Graph User.Read not admin-consented | Run `grant-agent-obo-consent.ps1` from the ACA skill |
| OBO sign-in fails with `AADSTS50011: redirect URI mismatch` | Agent FQDN not added to SPA app | Run `add-spa-redirect-uri.sh` with `APP_FQDN=<LB IP>` |
| OBO sign-in works but agent can't call Graph as user | Blueprint not configured for OBO | Re-run upstream `setup-obo-blueprint*` script |
| weather-api returns 401 to agent | `TENANT_ID` env on weather-api wrong, or `appid` in token doesn't match Agent ID | Confirm both containers see the same `TENANT_ID`; check `kubectl logs deploy/weather-api` for the validation error |

## Networking

| Symptom | Cause | Fix |
|---|---|---|
| LB IP stays `<pending>` for > 5 min | Subscription LB quota exhausted or policy blocks public IPs | Switch to `INGRESS_TYPE=ingress-nginx` |
| Agent can resolve `weather-api` but gets connection refused | CoreDNS cache stale or pod still starting | `kubectl rollout status deploy/weather-api`; restart agent |
| `kubectl port-forward` works but LB doesn't | NSG on the AKS node subnet blocks 80 | Inspect AKS node subnet NSG rules |

## Smoke test (kind)

| Symptom | Cause | Fix |
|---|---|---|
| `kind create cluster` fails with `cgroup` errors | Docker Desktop cgroup v1 incompatibility | Update Docker Desktop ≥ 4.20 |
| `kind load docker-image` slow / hangs | Large image transfer over Docker socket | Be patient (3–5 min for ollama image); or use a kind config with local registry |
| Sidecar in ClientSecret mode logs `AADSTS7000215: Invalid client secret` | Junk secret used | Replace with real Blueprint secret, or accept this and only verify non-token paths |
