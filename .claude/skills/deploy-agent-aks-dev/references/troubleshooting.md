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
| OBO sign-in fails with `AADSTS65001` | Agent → Graph User.Read not admin-consented | Run `scripts/grant-agent-obo-consent.ps1` (AKS-local copy) |
| OBO sign-in fails with `AADSTS50011: redirect URI mismatch` | Agent FQDN not added to SPA app | Run `scripts/add-spa-redirect-uri.sh` with `APP_FQDN=<LB IP>` |
| OBO sign-in works but agent can't call Graph as user | Blueprint not configured for OBO | Re-run `scripts/setup-obo-blueprint-for-aks.ps1` |
| weather-api returns 401 to agent | `TENANT_ID` env on weather-api wrong, or `appid` in token doesn't match Agent ID | Confirm both containers see the same `TENANT_ID`; check `kubectl logs deploy/weather-api` for the validation error |
| Sign-in popup throws `pkce_not_created: TypeError: Cannot read properties of undefined (reading 'subtle')` | MSAL needs `window.crypto.subtle`, which browsers gate on **secure context**. `http://<raw-IP>` is not a secure context; `http://localhost:*` is exempt. | Run `scripts/port-forward.sh` and use `http://localhost:8080` for sign-in. Production-style fix: front the Service with HTTPS (cert-manager + NGINX, or AGIC + Key Vault). |

## Cross-tenant federation

| Symptom | Cause | Fix |
|---|---|---|
| `03-federate-blueprint.ps1` fails with `Authorization_RequestDenied` | `Connect-MgGraph` ran against the wrong tenant (the Azure-sub tenant, not the Entra tenant where the Blueprint lives) | Re-run with explicit `-TenantId $TENANT_ID` (the Entra/Blueprint tenant), independent of `SUBSCRIPTION_TENANT_ID` |
| `az aks ...` works but Graph calls 401 | Single `az login` only covered one tenant; CLI cached the wrong context for Graph | `az login --tenant $TENANT_ID` once, then `az login --tenant $SUBSCRIPTION_TENANT_ID` and `az account set --subscription $SUBSCRIPTION_ID`. The two tokens live side-by-side. |
| Sidecar logs `AADSTS70021` even though FIC was created | FIC was added on the Blueprint **in the Azure-sub tenant**, not the Entra tenant | Delete the wrong FIC. Recreate it on the Blueprint app in the Entra tenant (`TENANT_ID`). |
| Pod env shows `AZURE_TENANT_ID=$SUBSCRIPTION_TENANT_ID` | `40-agent.yaml` rendered before `TENANT_ID` was the Entra tenant | Re-render manifests with `TENANT_ID` set to the Entra/Blueprint tenant, `kubectl apply`, restart pod |

See [`cross-tenant-federation.md`](./cross-tenant-federation.md) for the full pattern.

## Manifest rendering (`envsubst`)

| Symptom | Cause | Fix |
|---|---|---|
| Rendered YAML still contains `$TENANT_ID` literal | `envsubst` without an explicit var list substitutes **only exported** vars; if you forgot to `source /tmp/deploy-vars.sh` or used `set` (not `export`), nothing happens | `set -a; source /tmp/deploy-vars.sh; set +a` so all assignments are auto-exported |
| Rendered YAML has empty strings where vars should be | Variable was sourced but had a blank value, or shell variable shadowed it | `echo "TENANT_ID=$TENANT_ID"` before rendering. Prefer the explicit-varlist form: `envsubst '$TENANT_ID $BLUEPRINT_APP_ID ...' < file.yaml` to fail loudly on typos |
| `envsubst: command not found` (Windows / Git Bash) | `gettext` not installed | Git Bash ships it under `/usr/bin/envsubst.exe`; otherwise `winget install GnuWin32.Gettext` or `choco install gettext` |

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
