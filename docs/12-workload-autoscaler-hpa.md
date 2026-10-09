# 12 — Workload Autoscaler with an HPA
**Time:** 20 min · **Goal:** Show that vertical rightsizing and a CPU-based HPA can run on the same Deployment without fighting, and why plain VPA cannot.

## What you'll show
- The classic conflict: CPU HPA (target % of request) + VPA (changes the request) on the same Deployment.
- `recommender` (resource-consumer) with a native `autoscaling/v2` HPA on CPU 70 %, 2–5 replicas, and its `loadgen` (`workloads/hpa.yaml`).
- CAST AI vertical scaling enabled on that Deployment, with the **HPA converter**: the HPA target is rewritten from `Utilization 70 %` to an absolute `AverageValue` computed from the original request.
- A burst Job (`manifests/12-hpa/burst-job.yaml`) drives a scale-out; per-pod requests and replica count move independently and predictably.
- Where CAST AI shows the HPA-aware calibration ("Calibrating for HPA" in the event log).

## Prep
- Module 11 done: policy `shop-rightsizing` exists (`enable_workload_autoscaler=true`).
- `recommender` is not part of the baseline, so it has little history when this module starts. The HPA converter and the scale-out work immediately; a calibrated CPU **recommendation** may need up to 30 min (regeneration cycle). <!-- VERIFY: first recommendation latency for a ~5 min old workload -->
- Optional, for a richer event log: apply `workloads/hpa.yaml` at T-4h too. Then `castai-rightsized` in module 11 includes `recommender` (2 x 200m baseline); say so when comparing to `karpenter-baseline`.

## Concepts

### Why HPA + VPA on CPU loops
```text
HPA:  desiredReplicas = ceil(replicas * currentUsage / (target% * request))
VPA:  request := f(usage per pod)

load up   -> HPA adds pods -> usage per pod falls -> VPA lowers request
          -> utilization % rises again          -> HPA adds more pods ...
```
- The upstream VPA README says VPA "should not be used with the HPA on the same resource metric (CPU or memory)". People then exclude CPU from VPA or move the HPA to custom metrics.

### What CAST AI does instead (three separate mechanisms)
| Mechanism | When | What it does |
|---|---|---|
| **Coordinated CPU recommendation** | Vertical on + any HPA (native, CAST AI managed or KEDA) | Simulates past load against HPA behavior for several CPU candidates (cost, CPU delay, max-replica saturation, scaling churn) and picks one. User CPU percentile and CPU overhead are **ignored**; memory settings still apply. Automatic, cannot be turned off. |
| **HPA converter** (`hpa_converters` / `hpaConverters`) | Your own HPA with `Utilization` targets, CAST AI does vertical only | Rewrites `Utilization` to `AverageValue = original_request x target%`. The same real millicores trigger scaling no matter how CAST AI resizes the pod. Reverts if disabled or the HPA is deleted. |
| **CAST AI managed HPA** (`horizontal.optimization: on`, `takeOwnership`) | You want CAST AI to own replicas too | Creates/owns a native `autoscaling/v2` HPA from policy or annotations. Converter steps aside. |

- This module uses the first two: keep the team's own HPA, add vertical + converter.
- Memory-based HPAs get a separate correction: memory requests are kept so typical usage stays below the HPA threshold.

### The numbers for `recommender`
- Request 200m, HPA target 70 % → scale point **140m per pod**.
- With the converter: `averageValue = 200m x 0.70 = 140m`, fixed. If CAST AI lowers the request to ~100m, the HPA still scales at 140m per pod instead of at 70m.
- Without the converter, the same 70 % of a 100m request means scaling at 70m: twice as many replicas for the same load.

## Demo

### Step 1 — Deploy the HPA workload
`recommender` + Service + HPA + `loadgen` (12 min cycle: 6 quiet, 6 burst).
```bash
source scripts/env.sh
kubectl apply -f workloads/hpa.yaml
kubectl rollout status deploy/recommender -n shop --timeout=180s
kubectl get hpa -n shop
```
Expected:
```text
deployment.apps/recommender created
service/recommender created
horizontalpodautoscaler.autoscaling/recommender created
deployment.apps/loadgen created
deployment "recommender" successfully rolled out
NAME          REFERENCE                TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
recommender   Deployment/recommender   cpu: <unknown>/70%   2         5         2          10s
```
`<unknown>` turns into a percentage after ~30–60 s (metrics-server). Capacity: 5 x 200m + 20m fits next to the rightsized `shop`.

### Step 2 — Show the HPA target before CAST AI touches it
```bash
kubectl get hpa recommender -n shop -o jsonpath='{.spec.metrics}' | jq .
```
Expected:
```json
[
  {
    "resource": {
      "name": "cpu",
      "target": { "averageUtilization": 70, "type": "Utilization" }
    },
    "type": "Resource"
  }
]
```

### Step 3 — Enable vertical scaling with the HPA converter
Annotation only; Deployment template untouched.
```bash
cat manifests/12-hpa/enable-vertical-patch.yaml
kubectl patch deploy recommender -n shop --type merge --patch-file manifests/12-hpa/enable-vertical-patch.yaml
```
Expected: `deployment.apps/recommender patched`.

Policy-level equivalent: Console → Workload Autoscaler → Scaling policies → `shop-rightsizing` → Vertical rightsizing → **Enable HPA converter**; in Terraform `hpa_converters { type = "AVERAGE_VALUE_FROM_ORIGINAL_REQUESTS" }`. We keep it on the one workload that has an HPA.

### Step 4 — The HPA target is now absolute
```bash
kubectl get hpa recommender -n shop -o jsonpath='{.spec.metrics}' | jq .
kubectl get hpa -n shop
```
Expected (within ~1–2 min):
```json
[
  {
    "resource": {
      "name": "cpu",
      "target": { "averageValue": "140m", "type": "AverageValue" }
    },
    "type": "Resource"
  }
]
```
and `TARGETS` shows `cpu: <n>m/140m`.
<!-- VERIFY: conversion happens before the first recommendation; exact rendering 140m -->
API view:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workloads?namespaces=shop&workloadNames=recommender" | jq '.workloads[0] | {name, scalingPolicyName, managedBy, hasNativeHpa, recommendationStatus}'
```
Expected: `"hasNativeHpa": true`, `"managedBy": "ANNOTATIONS"`, policy `shop-rightsizing`. <!-- VERIFY: recommendationStatus shape -->

### Step 5 — Burst and watch both dimensions
One 4-minute burst on top of `loadgen` (~1.2 vCPU of extra demand).
```bash
kubectl apply -f manifests/12-hpa/burst-job.yaml
kubectl get hpa recommender -n shop -w
```
Expected: TARGETS climbs above 140m, REPLICAS goes 2 → 3 … 5 (max) within ~1–3 min, then back to 2 about 60 s after the burst ends (`stabilizationWindowSeconds: 60`). Ctrl-C.

Per-pod requests while it scales (second terminal):
```bash
while true; do kubectl get pods -n shop -l app=recommender -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,NODE:.spec.nodeName'; echo; sleep 20; done
```
Expected: new replicas start with the request the webhook gives them (200m until a recommendation exists, the calibrated value after). Replica count follows load; request per pod does not chase it. Ctrl-C.

If a new replica stays `Pending`, CAST AI adds a spot node (≤4 vCPU, template cap 8 vCPU). `kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type` shows it.

### Step 6 — Where the HPA calibration is visible
Console → **Workload Autoscaler → Workloads → recommender → Event log** → a **Recommendation generated** event → JSON view → step `"message": "Calibrating for HPA"`. Compare `statsCalibrated` (chosen), `statsOriginal` (raw percentile) and `statsLowestCost`: `cpu`, `replicas.avg/max`, `scaling.cycles`, `score`.

API equivalent (events list):
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workload-events?workloadNamespace=shop&workloadName=recommender&page.limit=5" | jq '[.items[] | {type, createdAt}]'
```
<!-- VERIFY: event item field names (type, createdAt) -->
If no recommendation exists yet (young workload), say so and come back to it after module 13; it regenerates every 30 min. The calibrated CPU can be **higher** than the plain p80: CAST AI optimizes cost *and* scaling stability, not the smallest request.

### Step 7 — Clean the burst
```bash
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found
kubectl get pods -n shop -l app=burst
```
Expected: `job.batch "burst" deleted`, then `No resources found in shop namespace.`

## Talking points
- Plain VPA + CPU HPA is a documented anti-pattern; most teams pick one dimension. CAST AI lets you keep both on one Deployment.
- The converter keeps the team's HPA as the source of truth (Helm/GitOps still own it) and only rewrites the target type. Do not `kubectl edit` a converted HPA: CAST AI then treats your edit as the new original.
- With vertical + HPA, CAST AI ignores the policy's CPU percentile and overhead. Surprising the first time; it is in the docs.
- Karpenter is unaffected either way: it just sees pods with requests.
- Karpenter-only fair answer: keep VPA off CPU for HPA workloads, or switch HPA to `AverageValue` by hand. That works; it is manual and per workload.

## Reset
Keeps module 11 state; removes the HPA workload and the burst.
```bash
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found
kubectl annotate deploy recommender -n shop workloads.cast.ai/configuration-
kubectl delete -f workloads/hpa.yaml --ignore-not-found
```
Expected: the annotation removed (the converter reverts the HPA target), then the Deployments, Service and HPA deleted.
Full reset to the CAST AI active baseline: `scripts/reset.sh`.

## Q&A prep
- **Does CAST AI replace my HPA?** Not here. It rewrites the target type only. With `horizontal.optimization` + `takeOwnership` it would own the HPA.
- **KEDA?** Supported. With custom metrics mixed in, the calibration moves less far from the configured percentile; the converter skips HPAs with external/object/pods metrics.
- **Predictive scaling + HPA?** Predictive vertical scaling is disabled automatically when horizontal autoscaling is on.
- **What if the converted target is too low?** HPA maxes out. Check `kubectl get hpa` TARGETS against real per-pod usage and adjust the HPA's utilization in its source.
- **Can I see the HPA simulation inputs?** Only the summary in the event log JSON; the algorithm is not configurable.
