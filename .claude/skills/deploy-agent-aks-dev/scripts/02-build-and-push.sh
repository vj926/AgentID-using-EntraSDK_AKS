#!/usr/bin/env bash
# Build & push llm-agent and weather-api to ACR using `az acr build`
# (no local Docker required). Ollama uses the upstream image as-is — the
# 30-ollama.yaml manifest pulls the model into a PVC via initContainer.
set -euo pipefail
: "${ACR_NAME:?}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../../.." && pwd )"

echo "[1/2] llm-agent"
az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/llm-agent:1.0.0 \
  --platform linux/amd64 \
  "$REPO_ROOT/reference/repo/sidecar/dev"

echo "[2/2] weather-api"
az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/weather-api:1.0.0 \
  --platform linux/amd64 \
  "$REPO_ROOT/reference/repo/sidecar/weather-api"
