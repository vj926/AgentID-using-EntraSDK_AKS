# Workload Identity deep-dive

## Why this works without a UAMI

The auth-sidecar (`Microsoft.Identity.Web`) supports several `ClientCredentials` sources. Two are relevant:

| `SourceType` | What it does | Where it makes sense |
|---|---|---|
| `SignedAssertionFromManagedIdentity` | Calls IMDS to get a JWT signed by the MI; uses that as the federated client assertion | ACA, App Service, VMs (real MI) |
| `SignedAssertionFilePath` | Reads a JWT directly from a file on disk and uses it as the assertion | **AKS with Workload Identity** |

On AKS with `--enable-workload-identity`, the mutating webhook (triggered by the pod label `azure.workload.identity/use: "true"`) does two things:

1. Injects env vars `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_AUTHORITY_HOST`.
2. Projects a service account token at `/var/run/secrets/azure/tokens/azure-identity-token`, signed by the **AKS cluster's OIDC issuer**, with audience `api://AzureADTokenExchange`.

That projected token IS already a valid federated assertion for any Entra app that trusts that issuer + subject. So we point the sidecar at it directly with `SignedAssertionFilePath` and skip the UAMI hop entirely.

## The FIC contract

The federated identity credential on the Blueprint app says:

```
issuer    = <AKS OIDC issuer URL>            # e.g. https://eastus.oic.prod-aks.azure.com/<tenantId>/<clusterId>/
subject   = system:serviceaccount:agentid:agent-sa
audiences = [ api://AzureADTokenExchange ]
```

The sidecar sends `client_assertion=<that token>` to `login.microsoftonline.com`, Entra validates the signature against the AKS OIDC keys, checks issuer+subject+audience, and mints a Blueprint token. The Blueprint token is then used (via OBO or client-credentials) to mint the **Agent Identity** token for the downstream API.

## Token rotation

| Token | Lifetime | Refreshed by |
|---|---|---|
| Projected SA token (assertion) | ~1 h | Workload identity webhook (re-writes the file ~10 min before expiry) |
| Blueprint access token | ~1 h | Sidecar (Microsoft.Identity.Web cache) |
| Agent Identity token | ~1 h | Sidecar on each `GetAuthorizationHeader` call (cached) |

Because `SignedAssertionFilePath` re-reads the file on every assertion request, rotation is automatic. Nothing to configure.

## Why not just use UAMI + `SignedAssertionFromManagedIdentity`?

It also works:
- KSA federated to UAMI (standard AKS workload identity pattern).
- Blueprint federated to UAMI (FIC subject = UAMI objectId).
- Sidecar with `SignedAssertionFromManagedIdentity`.

But this introduces:
- An extra Azure resource (the UAMI) to provision, manage RBAC on, and clean up.
- A second federation hop (KSA→UAMI→Blueprint instead of KSA→Blueprint).
- An IMDS-style round-trip in the sidecar on every token request.

Direct KSA→Blueprint is one fewer resource, one fewer hop, same security posture. Recommended for new deployments. If your organization standardizes on UAMI-per-workload for IAM auditing, switch the sidecar env to `SignedAssertionFromManagedIdentity` and add the UAMI hop — manifests stay otherwise identical.

## Validating workload identity is wired correctly

```bash
# Token file exists?
kubectl -n agentid exec deploy/llm-agent -c sidecar -- \
  ls -l /var/run/secrets/azure/tokens/

# Env vars injected?
kubectl -n agentid exec deploy/llm-agent -c sidecar -- env | grep AZURE_

# Decode the assertion (audience + iss + sub)
kubectl -n agentid exec deploy/llm-agent -c sidecar -- \
  sh -c 'cat /var/run/secrets/azure/tokens/azure-identity-token' \
  | cut -d. -f2 | base64 -d 2>/dev/null
```

Expected: `iss` = AKS OIDC URL, `sub` = `system:serviceaccount:agentid:agent-sa`, `aud` = `api://AzureADTokenExchange`.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Sidecar logs `AADSTS70021: No matching federated identity record found` | FIC subject doesn't match the projected token's `sub` | Recreate the FIC with `subject = system:serviceaccount:<ns>:<ksa>` exactly |
| `AZURE_FEDERATED_TOKEN_FILE` env not set in sidecar | Pod missing `azure.workload.identity/use: "true"` label | Add the label to **the pod template**, not the Deployment |
| Token file empty / 404 from Entra | KSA missing `azure.workload.identity/client-id` annotation | Annotate the KSA with the Blueprint app's client ID |
| `kubectl get pod` shows no `AZURE_*` env | Workload identity webhook not installed | `az aks update --enable-workload-identity` on the cluster |
