#!/usr/bin/env bash
set -euo pipefail

# Usage: set-mirror.sh <llmisvc> [canary-llmisvc] [--revert]
# Adds a RequestMirror filter to all InferencePool-backed HTTPRoute rules, sending a copy of
# every request to the canary InferencePool. Existing mirror filters are replaced (not stacked).
# If canary-llmisvc is omitted, the canary InferencePool is discovered by grepping for "canary".
# Pass --revert to remove all mirroring and restore the HTTPRoute to controller defaults.

NAMESPACE="runtime-swap"

REVERT=false
POSITIONAL=()
for arg in "$@"; do
  if [ "$arg" = "--revert" ]; then REVERT=true; else POSITIONAL+=("$arg"); fi
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

LLMISVC="${1:?Usage: $0 <llmisvc> [canary-llmisvc] [--revert]}"
CANARY_LLMISVC="${2:-}"

HTTPROUTE="${LLMISVC}-kserve-route"

if $REVERT; then
  echo "Removing mirror from $LLMISVC..."
  # The llmisvc controller does not reconcile the HTTPRoute when mirror filters are removed
  # from spec.router.route.http — only when they are added. So we patch the HTTPRoute directly.
  RULES=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" -o json | \
    jq '.spec.rules | map(
      if any(.backendRefs[]; .kind == "InferencePool") then
        .filters = ((.filters // []) | map(select(.type != "RequestMirror")))
      else
        .
      end
    )')
  oc patch llminferenceservice "$LLMISVC" -n "$NAMESPACE" --type=json \
    -p '[{"op": "remove", "path": "/spec/router/route/http"}]'
  oc patch httproute "$HTTPROUTE" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"rules\":$RULES}}"
  echo ""
  STATUS=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')
  echo "HTTPRoute ResolvedRefs: $STATUS"
  echo "Mirror removed."
  exit 0
fi

if [ -n "$CANARY_LLMISVC" ]; then
  CANARY_POOL=$(oc get inferencepools -n "$NAMESPACE" --no-headers | grep "$CANARY_LLMISVC" | awk '{print $1}')
else
  CANARY_POOL=$(oc get inferencepools -n "$NAMESPACE" --no-headers | grep canary | awk '{print $1}')
fi

if [ -z "$CANARY_POOL" ]; then
  echo "Error: no canary InferencePool found in namespace $NAMESPACE" >&2
  exit 1
fi

echo "Mirroring to canary pool: $CANARY_POOL"
echo ""

RULES=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" -o json | \
  jq --arg canary "$CANARY_POOL" '
  .spec.rules | map(
    if any(.backendRefs[]; .kind == "InferencePool") then
      .filters = (
        ((.filters // []) | map(select(.type != "RequestMirror")))
        + [{
          "type": "RequestMirror",
          "requestMirror": {
            "backendRef": {
              "group": "inference.networking.k8s.io",
              "kind": "InferencePool",
              "name": $canary,
              "port": 8000
            }
          }
        }]
      )
    else
      .
    end
  )
')

oc patch llminferenceservice "$LLMISVC" -n "$NAMESPACE" --type=merge \
  -p "{\"spec\":{\"router\":{\"route\":{\"http\":{\"spec\":{\"rules\":$RULES}}}}}}"

echo ""
STATUS=$(oc get httproute "$HTTPROUTE" -n "$NAMESPACE" \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')
echo "HTTPRoute ResolvedRefs: $STATUS"
echo ""
echo "Note: Istio does not support the 'percent' field on RequestMirror — every request is mirrored."
echo "To remove mirroring, run: $0 $LLMISVC --revert"
