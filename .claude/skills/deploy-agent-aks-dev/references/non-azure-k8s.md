# Adapting to non-Azure Kubernetes

The manifests in [`../manifests/`](../manifests/) are 95% portable. Only the credential injection differs by platform.

## What stays the same on EKS / GKE / on-prem

- `00-namespace.yaml`
- `20-weather-api.yaml`
- `30-ollama.yaml`
- `40-agent.yaml` (the two containers and their env, except the sidecar's credential source)
- `50-ingress.yaml` (swap Service type for your platform's idiom)
- The federation Graph call in `03-federate-blueprint.ps1` — only `OidcIssuerUrl` and `subject` change.

## What you change per platform

### Amazon EKS (IRSA)

EKS Pod Identity / IRSA exposes the SA token at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`. Different path, same shape (signed by the cluster's OIDC issuer).

1. Get your EKS OIDC issuer URL: `aws eks describe-cluster --name <name> --query 'cluster.identity.oidc.issuer' --output text`.
2. Federate the Blueprint app with `issuer=<that URL>`, `subject=system:serviceaccount:agentid:agent-sa`.
3. Override the sidecar credential source:
   ```yaml
   - name: AzureAd__ClientCredentials__0__SourceType
     value: SignedAssertionFilePath
   - name: AzureAd__ClientCredentials__0__SignedAssertionFileDiskPath
     value: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
   ```
4. Drop the `azure.workload.identity/*` annotations / labels — EKS doesn't use them.
5. If you want IAM Roles for Service Accounts to also work for AWS-side calls, add the `eks.amazonaws.com/role-arn` annotation on the KSA. Not needed for the Entra side.

### Google GKE (Workload Identity)

GKE projects a token at `/var/run/service-account/token` (or the standard SA path, depending on Workload Identity version).

1. Get the issuer: `gcloud container clusters describe <name> --format='value(workloadIdentityConfig.workloadPool)'` — this gives the pool; the issuer URL is `https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/<name>`.
2. Federate the Blueprint with `issuer=<that URL>`, `subject=system:serviceaccount:agentid:agent-sa`.
3. Same sidecar override as EKS, pointing at GKE's token path.

### On-prem with self-managed OIDC

Standard k8s ≥ 1.21 with `--service-account-issuer` and `--service-account-jwks-uri` flags configured. You must:
1. Expose `<issuer>/.well-known/openid-configuration` and the JWKS publicly (Entra needs to fetch keys).
2. Make sure the issuer in the JWT matches what Entra will see.
3. Federate as above.

## Why this works at all

Entra Agent ID federation is **OIDC-standard, not Azure-specific**. Any token that:
1. Is signed by a key in a JWKS Entra can fetch.
2. Has `iss` matching what you put in the FIC.
3. Has `sub` matching what you put in the FIC.
4. Has `aud=api://AzureADTokenExchange`.

…will be accepted. Workload identity on AKS, IRSA on EKS, Workload Identity on GKE, self-managed on-prem — they all produce conformant tokens.

## What customers can copy as-is

- The auth-sidecar container spec (just change the credential source values).
- `weather-api` and `ollama` Deployments + Services.
- The agent container spec.
- The federation script (only 3 inputs change).

What they MUST author per platform:
- Cluster provisioning (already platform-specific).
- The pod-level annotation / label that triggers projection (Azure: webhook label; AWS: SA annotation; GCP: KSA annotation).
- Ingress.
- Image registry pull config (`imagePullSecrets` or platform equivalent).
