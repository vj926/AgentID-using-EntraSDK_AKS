#!/usr/bin/env bash
# Create resource group, ACR, and an AKS cluster with OIDC issuer +
# Azure Workload Identity enabled, then attach ACR.
set -euo pipefail

: "${TENANT_ID:?}"; : "${SUBSCRIPTION_ID:?}"; : "${RG:?}"; : "${LOCATION:?}"
: "${AKS_NAME:?}"; : "${ACR_NAME:?}"; : "${NODE_COUNT:?}"; : "${NODE_VM_SIZE:?}"
export SUBSCRIPTION_TENANT_ID="${SUBSCRIPTION_TENANT_ID:-$TENANT_ID}"

# Verify az CLI is authenticated to the tenant that owns the subscription.
CURRENT_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null || true)
if [[ "$CURRENT_TENANT" != "$SUBSCRIPTION_TENANT_ID" ]]; then
  echo "ERROR: az CLI is signed into tenant '$CURRENT_TENANT' but the target"
  echo "       subscription lives in tenant '$SUBSCRIPTION_TENANT_ID'."
  echo "       Run:  az login --tenant $SUBSCRIPTION_TENANT_ID" >&2
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

echo "[1/4] Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "[2/4] ACR ($ACR_NAME)"
az acr create -g "$RG" -n "$ACR_NAME" --sku Basic --admin-enabled false -o none 2>/dev/null || true

echo "[3/4] AKS cluster ($AKS_NAME) — OIDC + Workload Identity"
az aks create \
  -g "$RG" -n "$AKS_NAME" \
  --location "$LOCATION" \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_VM_SIZE" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-managed-identity \
  --generate-ssh-keys \
  -o none

echo "[4/4] Attach ACR to AKS (grants kubelet AcrPull)"
az aks update -g "$RG" -n "$AKS_NAME" --attach-acr "$ACR_NAME" -o none

OIDC_ISSUER=$(az aks show -g "$RG" -n "$AKS_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "export OIDC_ISSUER=\"$OIDC_ISSUER\"" >> "${VARS_FILE:-/tmp/deploy-vars.sh}"
echo "OIDC issuer: $OIDC_ISSUER"

az aks get-credentials -g "$RG" -n "$AKS_NAME" --overwrite-existing
kubectl get nodes
