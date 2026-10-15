#!/usr/bin/env bash
# Sends continuous chat completion requests and prints the vLLM version from each response.
# Useful for confirming which pool is serving during a canary rollout.
#
# Usage: set TOKEN, MODEL_NAME, and URL below, then run: bash continuous_inference.sh

TOKEN=""
MODEL_NAME=""
URL=""

while true; do
  TIME=$(date +"%H:%M:%S")
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN}" \
        --data "{
                \"model\": \"${MODEL_NAME}\",
                \"messages\": [
                        {
                                \"role\": \"user\",
                                \"content\": \"Hello, World.\"
                        }
                ]
        }")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | head -n 1)
  if [ "$HTTP_CODE" = "200" ]; then
    VLLM_VERSION=$(echo "$BODY" | jq -r '.system_fingerprint // "null"')
  else
    VLLM_VERSION="null"
  fi
  echo "${TIME} | ${VLLM_VERSION} | ${HTTP_CODE}"
done
