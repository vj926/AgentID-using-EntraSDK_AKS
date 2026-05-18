#!/usr/bin/env bash
# port-forward.sh — open a loopback tunnel to the llm-agent Service so the
# browser-based OBO sign-in flow works.
#
# Why this exists (AKS-specific):
#   The LoadBalancer Service in 50-ingress.yaml exposes the agent over plain
#   HTTP on a public IP. Browsers do NOT treat http://<raw-IP> as a "secure
#   context", so MSAL.js's PKCE flow (which needs Web Crypto's
#   `crypto.subtle`) is blocked and the sign-in popup never opens. Loopback
#   addresses (localhost, 127.0.0.1) ARE secure-context exempt, so port-
#   forwarding the same Service to localhost makes OBO work without setting
#   up TLS / cert-manager / DNS.
#
# Direct (autonomous) mode does NOT require OBO and works fine on the raw
# LB IP. This script is only needed to exercise the "Sign In" button.
#
# Companion: scripts/add-spa-redirect-uri.sh registers `http://localhost:8080/`
# as a SPA redirect URI by default for exactly this flow.
#
# Usage:
#   bash port-forward.sh                # foreground, Ctrl-C to stop
#   LOCAL_PORT=9090 bash port-forward.sh
#
# Env (optional):
#   NAMESPACE   default: agentid
#   SERVICE     default: llm-agent
#   LOCAL_PORT  default: 8080
#   REMOTE_PORT default: 80

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentid}"
SERVICE="${SERVICE:-llm-agent}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
REMOTE_PORT="${REMOTE_PORT:-80}"

echo "Port-forward: http://localhost:${LOCAL_PORT}  ->  svc/${SERVICE}:${REMOTE_PORT} (ns ${NAMESPACE})"
echo "Open this URL in a browser to use OBO sign-in. Ctrl-C to stop."
echo ""

kubectl -n "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}"
