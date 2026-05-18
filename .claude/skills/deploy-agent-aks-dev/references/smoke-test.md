# Local smoke test on `kind`

**Goal:** validate every manifest and the agent-↔-sidecar wiring on the user's laptop, with no Azure resources, before paying for AKS.

## What's tested

| Concern | Covered? |
|---|---|
| YAML parses & passes k8s API validation | ✅ |
| Container images build and run | ✅ |
| Agent reaches sidecar on `localhost:5000` | ✅ |
| Agent reaches `weather-api` Service | ✅ |
| Agent reaches `ollama` Service and model loads | ✅ |
| Sidecar acquires Blueprint token (ClientSecret mode) | ✅ |
| Workload Identity assertion file flow | ❌ (only works on real AKS — uses `ClientSecret` overlay instead) |
| End-to-end OBO with the Client SPA | ❌ (requires a deployed redirect URI — defer to Azure) |

So the smoke test proves the **kubernetes wiring** is correct. The **secretless credential path** still must be tested on real AKS in Step 7 of the main skill.

## Requirements

- Docker Desktop (or any Docker-compatible engine).
- `kind` ≥ 0.20.
- `kubectl` ≥ 1.28.
- A Blueprint client secret (set `BLUEPRINT_CLIENT_SECRET`). For an isolated smoke test where you don't want to use a real tenant, set it to a junk value — the sidecar will fail to mint tokens but every other component should still come up healthy, and `/status` will return `sidecar_reachable: true, token_acquired: false`.

## Usage

```bash
source /tmp/deploy-vars.sh   # for TENANT_ID, BLUEPRINT_APP_ID, *_CLIENT_ID
export BLUEPRINT_CLIENT_SECRET="<from your Blueprint app>"

bash .claude/skills/deploy-agent-aks-dev/scripts/smoke-test-kind.sh
# ... runs for 5-10 min on first run (mostly Ollama model pull) ...
# Last line: SMOKE PASS  or  SMOKE FAIL: <reason>

# Cleanup:
bash .claude/skills/deploy-agent-aks-dev/scripts/smoke-test-kind.sh --cleanup
```

## How it differs from production manifests

The script generates a temp overlay that replaces only the sidecar's credential block:

```yaml
# overlay applied to 40-agent.yaml only
- name: AzureAd__ClientCredentials__0__SourceType
  value: ClientSecret
- name: AzureAd__ClientCredentials__0__ClientSecret
  valueFrom:
    secretKeyRef: { name: blueprint-secret, key: client-secret }
```

…and drops the `azure.workload.identity/use: "true"` label. Everything else — namespace, KSA, Services, PVC, Deployment shapes — is unchanged.

## Interpreting failures

| `SMOKE FAIL: <…>` | Most likely cause |
|---|---|
| `kind cluster create` | Docker not running |
| `image load` | `docker build` failed — inspect `kind-build.log` |
| `weather-api rollout` | Port 8080 conflict, or weather-api image broken |
| `ollama rollout` | initContainer hit a network timeout pulling the model; rerun |
| `agent rollout` | Sidecar crash — `kubectl logs deploy/llm-agent -c sidecar` |
| `/status non-200` | Agent can't reach Ollama Service; check DNS in pod |
