# 13 — Head-to-head: where the savings came from
**Time:** 25 min · **Goal:** Put every snapshot side by side, split the saving into node-level vs rightsizing, and price the "Karpenter + VPA" alternative honestly.

## What you'll show
- Final snapshot `castai-final` and pairwise comparisons of `karpenter-baseline`, `castai-autoscaler`, `castai-rightsized`, `castai-final`.
- CAST AI's own view: efficiency (provisioned / requested / used), cost, node count history and estimated savings from the API.
- Grafana/Prometheus node count and CPU requests over the session, independent of both vendors.
- The attribution: **node-level** (Karpenter vs CAST AI autoscaler, same requests) vs **rightsizing** (same autoscaler, smaller requests).
- Optional: VPA in recommendation-only mode next to CAST AI's recommendations (`manifests/13-vpa/`).

## Concepts

### The three snapshots and what each isolates
| Snapshot | Autoscaler | Requests | Taken in |
|---|---|---|---|
| `karpenter-baseline` | Karpenter (tuned NodePool) | original (6.0 vCPU) | Karpenter phase |
| `castai-autoscaler` | CAST AI node autoscaler + evictor | original (6.0 vCPU) | after `switch-to-castai.sh` |
| `castai-rightsized` | CAST AI | rightsized (~1.7–2.2 vCPU) | module 11 |
| `castai-final` | CAST AI | rightsized, settled | this module |

```text
node-level effect   = castai-autoscaler  - karpenter-baseline   (same requests, different autoscaler)
rightsizing effect  = castai-rightsized  - castai-autoscaler    (same autoscaler, different requests)
```
- Expect the node-level effect to be **small or zero**, sometimes negative: both pick cheap spot instances for the same requests. The CAST AI template here is spot-only; Karpenter's pool allows on-demand too, so check `spot workers` before crediting either side.
- Expect the rightsizing effect to dominate. Karpenter would get most of it too, **if** something shrank the requests.
- Node granularity: the smallest allowed node is 2 vCPU, and the system node + EKS control plane ($0.10/h) are fixed. On a tiny cluster the **all-in** % is much smaller than the **workers** %. Real fleets scale more linearly.

### "Karpenter + VPA" counterfactual
| Need | Karpenter + VPA (OSS) | CAST AI |
|---|---|---|
| Recommender | VPA recommender (p90 + 15 % margin, 8-day decaying histogram) | Policy (percentile, overhead, look-back 3 h–7 d, confidence) |
| Apply in place | VPA updater + admission controller, `updateMode: InPlaceOrRecreate` (GA in VPA 1.6) | Built in, IMMEDIATE/DEFERRED |
| Scope | One VPA object per workload (or Goldilocks) | Namespace/label assignment rules |
| HPA on CPU/memory | Not supported on the same metric; exclude CPU or rewrite HPA by hand | Coordinated recommendation + HPA converter |
| Nodes after rightsizing | Karpenter consolidation (`WhenEmptyOrUnderutilized`), no preview | Evictor + Rebalancer with plan preview and savings figure |
| OOM handling | `oom-bump-up-ratio` 1.2, min 100Mi | +20 % / ≥100 Mi, cap 2.5x, auto-disable |
| Savings accounting | None (add OpenCost) | Console reports |
| Cost | Engineering time; no license | Premium plan per CPU (module 14) |

Fair summary: Karpenter + VPA reproduces most of **this** demo's saving for the non-HPA workloads. CAST AI's edge is operating it at scale: policies, HPA coexistence, previews, reports, one vendor.

## Demo

### Step 1 — Settle and take the final snapshot
Load generators off so the snapshot is comparable to the others.
```bash
source scripts/env.sh
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found
kubectl annotate deploy recommender -n shop workloads.cast.ai/configuration- 2>/dev/null; kubectl delete -f workloads/hpa.yaml --ignore-not-found
kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,scheduling.cast.ai/spot
kubectl get pods -n shop --field-selector=status.phase!=Running
```
Expected: the `recommender`/`loadgen` objects deleted (or "not found" lines), 1–2 CAST AI nodes plus the system node, and `No resources found in shop namespace.` Wait until the node list has been stable for ~5 min (evictor cycle + empty-node delay).
```bash
scripts/measure.sh castai-final
ls results/
```
Expected: the measurement table, `saved results/castai-final.json`, and `ls` listing at least `karpenter-baseline.json castai-autoscaler.json castai-rightsized.json castai-final.json` (plus `price-cache.json`).

### Step 2 — Node-level effect (same requests)
```bash
scripts/compare.sh karpenter-baseline castai-autoscaler
```
Expected (shape):
```text
METRIC                      A       B       DELTA   CHANGE
worker nodes                3       3       0       0%
requested vCPU (shop)       6       6       0       0%
$/h workers                 ...     ...     small   ~0..-15%
...
Node types:
  karpenter-baseline:    1x c6a.xlarge/on-demand, 2x c6a.large/spot ...
  castai-autoscaler:     ...x .../spot
```
Say what you see. If B is cheaper, check whether it is just more spot (policy difference, reproducible in Karpenter by allowing only spot) or genuinely cheaper types.

### Step 3 — Rightsizing effect (same autoscaler)
```bash
scripts/compare.sh castai-autoscaler castai-rightsized
scripts/compare.sh castai-rightsized castai-final
```
Expected: `requested vCPU (shop)` 6 → ~2, worker nodes and `$/h workers` down sharply (for example -50 to -65 %); `used vCPU (shop)` unchanged. The second comparison should be close to zero (settling only).

### Step 4 — End to end
```bash
scripts/compare.sh karpenter-baseline castai-final
```
Expected: the headline number. Read both `$/h workers` and `$/h all-in` out loud; the all-in % is smaller because of the system node and EKS fee.

### Step 5 — CAST AI's own view (API)
Same window for every call: the last 6 h.
```bash
T1=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); T0=$(date -u -v-6H '+%Y-%m-%dT%H:%M:%SZ'); echo "$T0 -> $T1"
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/efficiency?startTime=${T0}&endTime=${T1}&stepSeconds=3600" | jq '.current'
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/node-count-history?startTime=${T0}&endTime=${T1}&stepSeconds=1800" | jq -c '.items[]?' | tail -12
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/cost?startTime=${T0}&endTime=${T1}&stepSeconds=3600" | jq '.summary'
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/estimated-savings" | jq '{lastUpdatedAt, isRebalancingRecommended, currentConfiguration}'
```
Expected:
- `efficiency.current`: provisioned vs requested vs used CPU/memory; requested now close to used.
- node count history: higher counts in the Karpenter/CAST AI autoscaler hours, lower after rightsizing.
- cost summary: hourly cost trending down over the window.
- estimated savings: the remaining "available savings" is now small; compare with the figure recorded in the read-only module.
<!-- VERIFY: response field names (.current, .items, .summary, currentConfiguration) and that ISO times work unencoded -->
Console → Cost → **Cluster efficiency** and **Available savings** show the same numbers. Do not open "Realized savings": it needs 14+ days of history.

### Step 6 — Independent view: Prometheus/Grafana
Neither vendor's numbers; kube-state-metrics in `monitoring`.
Terminal 2 (leave running):
```bash
source scripts/env.sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```
Terminal 1:
```bash
curl -s 'http://localhost:9090/api/v1/query?query=count(kube_node_info)' | jq -r '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/query?query=sum(kube_pod_container_resource_requests{namespace="shop",resource="cpu"})' | jq -r '.data.result[0].value[1]'
```
Expected: total nodes including the system node (for example `2` or `3`), and shop CPU requests ~1.7–2.2.
<!-- VERIFY: kube-state-metrics reports resized (in-place) requests -->
Grafana: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`, open http://localhost:3000 (admin / karpenter-demo) → Explore → Prometheus, time range "Last 6 hours", queries:
```text
count(kube_node_info)
sum(kube_node_status_capacity{resource="cpu"})
sum(kube_pod_container_resource_requests{namespace="shop",resource="cpu"})
```
Expected: a step down in node count at the switch (drain/refill) and another after rightsizing; the requests line drops from ~6 to ~2 at module 11. Stop port-forwards with Ctrl-C.

### Step 7 (optional, 8 min) — VPA recommendation-only, side by side
Recommender only (no updater, no admission controller): nothing is changed. It lands on a CAST AI worker, not the system node (no CriticalAddonsOnly toleration). 50m / 500Mi.
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/vpa-rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/recommender-deployment.yaml
kubectl -n kube-system rollout status deploy/vpa-recommender --timeout=180s
for d in cart catalog checkout frontend payments worker; do DEPLOY=$d envsubst < manifests/13-vpa/vpa-off.yaml.tpl | kubectl apply -f -; done
```
Expected: CRDs, RBAC objects and `deployment.apps/vpa-recommender created`, `successfully rolled out`, then 6 lines `verticalpodautoscaler.autoscaling.k8s.io/<name> created`.

After ~2–3 min:
```bash
kubectl get vpa -n shop
kubectl get vpa -n shop -o custom-columns='VPA:.metadata.name,TARGET_CPU:.status.recommendation.containerRecommendations[0].target.cpu,TARGET_MEM:.status.recommendation.containerRecommendations[0].target.memory'
```
Expected: `MODE Off`, `PROVIDED True`, targets in the same range as CAST AI's (CPU tens to low hundreds of millicores). VPA starts from zero history here, so its values are provisional; it also floors CPU at 25m. Compare with module 11 Step 3.
<!-- VERIFY: time to first VPA recommendation without history -->
Remove it right away (also in Reset):
```bash
kubectl delete vpa -n shop --all
kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/recommender-deployment.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/vpa-rbac.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml --ignore-not-found
```

## Talking points
- "The autoscaler swap alone was worth about X %. Rightsizing was worth Y %." Use the measured numbers, not the brochure.
- Karpenter did not lose on node selection. It lost because nothing in a Karpenter-only stack fixes requests.
- Karpenter + VPA would close most of the gap for workloads without CPU HPAs. You would build and run: VPA (3 components), one object per workload, HPA exclusions, Prometheus dashboards for savings, and no preview before consolidation.
- Small clusters understate everything: fixed costs dominate and the 2 vCPU node floor rounds savings away.
- Estimates (Available savings) vs measurements (our snapshots): show both, trust the measurements.

## Reset
```bash
kubectl delete vpa -n shop --all 2>/dev/null; kubectl -n kube-system delete deploy vpa-recommender --ignore-not-found
scripts/reset.sh
```
Expected: `reset.sh` ends with `CAST AI ACTIVE BASELINE reached`. It also removes VPA CRDs/RBAC if present.

## Q&A prep
- **Is the comparison fair to Karpenter?** Same cluster, same workloads, same quota, same measurement script, tuned NodePool disclosed. The rightsizing step is the part Karpenter does not attempt.
- **Would `SpotToSpotConsolidation` or `Balanced` change the node-level number?** Possibly a little; both already pick cheap spot. It cannot change requests.
- **Why not show Karpenter + VPA fully?** It needs updater + admission controller and its own 3 h+ of history; on this quota you cannot run both stacks side by side. The recommendation-only view shows the numbers are similar.
- **Are CAST AI's dollars the same as ours?** CAST AI uses its own price feed (and spot history); `measure.sh` uses AWS list/spot prices. Expect a few % difference.
- **What about the savings report?** Needs 14 days under management; out of scope for a same-day demo.
