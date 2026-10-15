#!/usr/bin/env bash
set -euo pipefail

# Usage: set-canary-weight.sh <llmisvc> [canary-llmisvc]
# If canary-llmisvc is omitted, the canary InferencePool is discovered by grepping for "canary".

NAMESPACE="runtime-swap"
LLMISVC="${1:?Usage: $0 <llmisvc> [canary-llmisvc]}"
CANARY_LLMISVC="${2:-}"
HTTPROUTE="${LLMISVC}-kserve-route"

read -rp "Canary weight 0-100 (0 = remove canary, 100 = full cutover): " CANARY_WEIGHT

if ! [[ "$CANARY_WEIGHT" =~ ^[0-9]+$ ]] || [ "$CANARY_WEIGHT" -gt 100 ]; then
  echo "Error: enter a whole number between 0 and 100" >&2
  exit 1
fi

BLUE_WEIGHT=$((100 - CANARY_WEIGHT))

if [ -n "$CANARY_LLMISVC" ]; then
  CANARY_POOL=$(oc get inferencepools -n "$NAMESPACE" --no-headers | grep "$CANARY_LLMISVC" | awk '{print $1}')
else
  CANARY_POOL=$(oc get inferencepools -n "$NAMESPACE" --no-headers | grep canary | awk '{print $1}')
fi

if [ -z "$CANARY_POOL" ]; then
  echo "Error: no canary InferencePool found in namespace $NAMESPACE" >&2
  exit 1
fi

echo "Pool:  blue=$(oc get inferencepools -n "$NAMESPACE" --no-headers | grep -v "$CANARY_POOL" | awk '{print $1}')  canary=$CANARY_POOL"
echo "Split: blue=${BLUE_WEIGHT}%  canary=${CANARY_WEIGHT}%"
echo ""

RULES=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" -o json | \
  jq --arg canary "$CANARY_POOL" \
     --argjson cw "$CANARY_WEIGHT" \
     --argjson bw "$BLUE_WEIGHT" '
  .spec.rules | map(
    if any(.backendRefs[]; .kind == "InferencePool") then
      .backendRefs = (
        (.backendRefs
          | map(select(.name != $canary))
          | map(if .kind == "InferencePool" then .weight = $bw else . end)
        )
        + if $cw > 0 then [{
            "group": "inference.networking.k8s.io",
            "kind": "InferencePool",
            "name": $canary,
            "port": 8000,
            "weight": $cw
          }] else [] end
      )
    else
      .
    end
  )
')

if [ "$CANARY_WEIGHT" -eq 0 ]; then
  # Remove custom route spec entirely — controller reverts HTTPRoute to its defaults
  oc patch llminferenceservice "$LLMISVC" -n "$NAMESPACE" --type=json \
    -p '[{"op": "remove", "path": "/spec/router/route/http"}]'
else
  oc patch llminferenceservice "$LLMISVC" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"router\":{\"route\":{\"http\":{\"spec\":{\"rules\":$RULES}}}}}}"
fi

echo ""
STATUS=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')
echo "HTTPRoute ResolvedRefs: $STATUS"
