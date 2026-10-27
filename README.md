# Canary Deployments and Cutover in RHOAI

A guide to safely rolling out a new model server version in **Red Hat OpenShift AI (RHOAI)** using a canary deployment. Traffic shifts gradually from the old version to the new one, with the ability to roll back instantly at any stage.

---


## How Traffic Control Works

When you create an LLMInferenceService (LLMISVC), the controller automatically creates two things:
- An **InferencePool** — the group of model pods
- An **HTTPRoute** — the routing rule pointing traffic at that pool

By adding a second InferencePool (the canary's) with a weight to `spec.router.route.http.spec.rules`, you can split traffic between old and new without touching the gateway or HTTPRoute directly. Setting the weight to `0` removes the canary from routing — instant rollback. Setting `spec.router.route.http` back to empty (`{}`) returns the HTTPRoute to the controller's defaults: 100% of traffic to the original pool.

---

## Prerequisites

- `oc` CLI, logged in with edit rights on your namespace
- `jq` installed in your shell
- The new model image available and pullable from within the cluster
- Original LLMISVC fully healthy (all conditions `True`)

Check the original is healthy before starting:

```bash
oc get llminferenceservice <your-llmisvc> -n <namespace> \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'
```

---

## Overview

```
[ Deploy canary ] → [ Mirror traffic ] → [ Weighted split ] → [ Cutover ] → [ Clean up ]
                          ↑                      ↑
                    (optional but              gradually
                     recommended)            increase weight
```

---

## Stage 1 — Deploy the Canary

Create a second LLMISVC with:
- A **new name** (e.g. append `-canary`).
- The **same `spec.model.name`** as the original — the canary pod must accept requests for the same model name clients send.
- The new container image.

See [`manifests/canary-llmisvc.yaml`](manifests/canary-llmisvc.yaml) for a full example.

```bash
oc apply -f manifests/canary-llmisvc.yaml

# Wait until Ready = True
oc get llminferenceservice <canary-llmisvc> -n <namespace> -w
```

Note the canary InferencePool name before the next step:

```bash
oc get llminferenceservice <canary-llmisvc> -n <namespace> \
  -o jsonpath='{.status.router.scheduler.inferencePool.name}'
```

Then **remove the canary's gateway reference**. The canary does not need its own HTTPRoute — traffic will reach it through the original's HTTPRoute. Leaving the reference in creates an unnecessary extra route:

```bash
oc patch llminferenceservice <canary-llmisvc> -n <namespace> --type=merge \
  -p '{"spec":{"router":{"gateway":{"refs":null}}}}'
```

Confirm the canary's HTTPRoute is gone:

```bash
oc get httproute -n <namespace> | grep canary
# Should return nothing
```

At this point, the canary pool is running but receives no traffic:

```
  Client requests
        |
     Gateway
        |
   HTTPRoute ──── 100% ──▶  Blue InferencePool
                                    |
                             (original pods)

  Canary InferencePool  ← warmed up, idle, no traffic yet
```

---

## Stage 2 — Mirror Traffic (optional but recommended)

Before routing any real client traffic to the canary, mirror a copy of live requests to it. Clients are still served only by the blue pool. The canary's responses are discarded. This confirms the new pods can handle real inference load at zero client risk.

```bash
bash scripts/set-mirror.sh <original-llmisvc> <canary-llmisvc>
```

```
  Client requests
        |
     Gateway
        |
   HTTPRoute ──── 100% ──▶  Blue InferencePool ──▶ Response to client
        |
        └── mirror ────────▶ Canary InferencePool ──▶ Response discarded
```

Watch the canary pod logs to confirm mirrored requests are arriving:

```bash
oc logs -f -n <namespace> <canary-pod-name> | grep -E "POST|200|error"
```

> **Note:** The Istio gateway used in RHOAI does not support percentage-based mirroring — every request is mirrored. This doubles inference load on the cluster during the soak period, so account for that in capacity planning.

Once satisfied the canary is stable, remove the mirror before moving to the weighted split:

```bash
bash scripts/set-mirror.sh <original-llmisvc> <canary-llmisvc> --revert
```

---

## Stage 3 — Weighted Traffic Split

Run the weight script and enter the desired canary percentage (e.g. `10` for a 90/10 split):

```bash
bash scripts/set-canary-weight.sh <original-llmisvc> <canary-llmisvc>
```

```
  Client requests
        |
     Gateway
        |
   HTTPRoute ──── 90% ──▶  Blue InferencePool
        |
        └────── 10% ──▶  Canary InferencePool
```

Increase the canary weight gradually. Allow at least 10–15 minutes at each stage to observe behaviour:

| Stage | Blue | Canary |
|-------|------|--------|
| Initial | 90% | 10% |
| | 75% | 25% |
| | 50% | 50% |
| | 10% | 90% |
| Full cutover | 0% | 100% |

Use [`scripts/continuous-inference.sh`](scripts/continuous-inference.sh) to send continuous test requests. The `system_fingerprint` field in each response shows which pool served it, making the split visible:

```
10:15:13 | vllm-0.24.0+rhaiv.9-71aa6c0c | 200   ← blue pool
10:15:15 | vllm-0.28.0+rhaiv.7-bdc4464b | 200   ← canary pool
10:15:17 | vllm-0.24.0+rhaiv.9-71aa6c0c | 200
10:15:20 | vllm-0.28.0+rhaiv.7-bdc4464b | 200
```

Watch for crashes or errors between weight increases:

```bash
oc get pods -n <namespace> -w
oc get events -n <namespace> --sort-by='.lastTimestamp' | grep -i "oom\|kill\|crash"
```

---

## Stage 4 — Cutover

Once the canary is handling 100% of traffic stably, update the original LLMISVC to use the new image. This triggers a rolling update — the old pod stays up until the new one is fully ready:

```bash
oc patch llminferenceservice <original-llmisvc> -n <namespace> --type=merge \
  -p '{"spec":{"template":{"containers":[{"name":"main","image":"<new-image>"}]}}}'
```

Wait for both `MainWorkloadReady` and `Ready` to be `True`:

```bash
oc get llminferenceservice <original-llmisvc> -n <namespace> -w
```

---

## Stage 5 — Clean Up

Remove the custom route spec from the original LLMISVC, returning it to default single-pool routing:

```bash
oc patch llminferenceservice <original-llmisvc> -n <namespace> --type=json \
  -p '[{"op": "remove", "path": "/spec/router/route/http"}]'
```

Delete the canary:

```bash
oc delete llminferenceservice <canary-llmisvc> -n <namespace>
```

```
  Client requests
        |
     Gateway
        |
   HTTPRoute ──── 100% ──▶  Blue InferencePool (now running new image)
```

---

## Rollback

**Before Stage 4** — run the weight script and enter `0`. This removes the canary from the HTTPRoute and returns routing to 100% blue, instantly:

```bash
bash scripts/set-canary-weight.sh <original-llmisvc> <canary-llmisvc>
# Enter: 0

oc delete llminferenceservice <canary-llmisvc> -n <namespace>
```

**After Stage 4** — if the new pod fails to become ready, the rolling update stalls and the old pod keeps serving. Patch the image back:

```bash
oc patch llminferenceservice <original-llmisvc> -n <namespace> --type=merge \
  -p '{"spec":{"template":{"containers":[{"name":"main","image":"<previous-image>"}]}}}'
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/set-mirror.sh <llmisvc> [canary-llmisvc]` | Adds a `RequestMirror` filter to the HTTPRoute, sending a copy of every request to the canary pool. Responses are discarded |
| `scripts/set-canary-weight.sh <llmisvc> [canary-llmisvc]` | Sets the canary traffic weight interactively. Enter `0` for instant rollback, `100` for full cutover |
| `scripts/continuous-inference.sh` | Sends continuous chat completion requests and prints the vLLM version from each response — for confirming which pool is serving |

---

## Example Manifests

The [`manifests/`](manifests/) directory contains PHI-4 examples used to validate this guide:

- [`manifests/original-llmisvc.yaml`](manifests/original-llmisvc.yaml) — original LLMISVC (PHI-4 on vLLM v0.24.0)
- [`manifests/canary-llmisvc.yaml`](manifests/canary-llmisvc.yaml) — canary LLMISVC (PHI-4 on vLLM v0.28.0)

---

## Capacity Note

During the canary period, two full model deployments run simultaneously. Ensure your cluster has sufficient node capacity for both before starting. During mirroring, inference load is doubled — every request is processed by both pools.
