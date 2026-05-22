#!/usr/bin/env bash
# Build & push llm-agent and weather-api to ACR using `az acr build`
# (no local Docker required). Ollama uses the upstream image as-is — the
# 30-ollama.yaml manifest pulls the model into a PVC via initContainer.
set -euo pipefail
: "${ACR_NAME:?}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Locate the sidecar source dirs (`dev/` and `weather-api/`). Two supported layouts:
#   A) Upstream repo layout: <repo>/sidecar/{dev,weather-api,aks}      (when this
#      skill is shipped inside microsoft/entra-agentid-samples)
#   B) Reference-clone layout: <ws>/reference/repo/sidecar/{dev,weather-api}
#      (when developing this skill outside the upstream repo)
find_sidecar_root() {
  local candidate
  for candidate in \
      "$SCRIPT_DIR/../../../../sidecar" \
      "$SCRIPT_DIR/../../../sidecar" \
      "$SCRIPT_DIR/../../../reference/repo/sidecar" ; do
    if [[ -d "$candidate/dev" && -d "$candidate/weather-api" ]]; then
      ( cd "$candidate" && pwd ); return 0
    fi
  done
  return 1
}
SIDECAR_ROOT="$( find_sidecar_root )" || {
  echo "ERROR: could not locate sidecar/{dev,weather-api}. Tried upstream and reference layouts." >&2
  exit 1
}

echo "[1/2] llm-agent  (source: $SIDECAR_ROOT/dev)"
az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/llm-agent:1.0.0 \
  --platform linux/amd64 \
  "$SIDECAR_ROOT/dev"

echo "[2/2] weather-api  (source: $SIDECAR_ROOT/weather-api)"
az acr build --registry "$ACR_NAME" \
  --image agent-id-dev/weather-api:1.0.0 \
  --platform linux/amd64 \
  "$SIDECAR_ROOT/weather-api"
