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
| `castai-rightsized` | CAST AI | rightsized (4.5 vCPU on a 3 h old install; ~1.8 after 24 h) | module 11 |
| `castai-final` | CAST AI | rightsized, settled | this module |

```text
node-level effect   = castai-autoscaler  - karpenter-baseline   (same requests, different autoscaler)
rightsizing effect  = castai-rightsized  - castai-autoscaler    (same autoscaler, different requests)
```
- The node-level effect is **offering luck, not intelligence**. Real run: both sides ran 8 spot vCPU for 6 vCPU of requests; CAST AI happened to land 4x c8i-flex.large in ap-south-1c at $0.0163/h each, Karpenter a c6a.xlarge + c8i-flex.xlarge at ~$0.052/h each: -37.7 % on workers. Per vCPU that is the price gap of one spot pool. Rerun it another day and it can be zero or negative. Say so.
- The rightsizing effect is the structural one. Karpenter would get it too, **if** something shrank the requests. In the real run it was capped at -25 % by the cluster-age cap (module 11), and the evictor kept a c6a.xlarge, so `castai-autoscaler` → `castai-rightsized` was +4.4 % on `$/h workers` despite half the nodes and 2 vCPU fewer. Attribution by subtraction is noisy on a 2-node cluster; read vCPU and requests first, dollars second.
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
Expected: `deployment.apps/recommender annotated`, then four `... deleted from shop namespace` lines (or "not found"), 2–3 CAST AI nodes plus the system node. Right after the delete the two `recommender` pods may show `Error` while terminating; repeat the last command until it prints `No resources found in shop namespace.` The node added for the HPA burst is removed ~2.5 min later. Wait until the node list has been stable for ~2 min.
```bash
scripts/measure.sh castai-final
ls results/
```
Expected: the measurement table, `saved results/castai-final.json`, and `ls` listing at least `karpenter-baseline.json castai-autoscaler.json castai-rightsized.json castai-final.json` (plus `price-cache.json`).

### Step 2 — Node-level effect (same requests)
```bash
scripts/compare.sh karpenter-baseline castai-autoscaler
```
Expected (real run):
```text
METRIC                      A       B       DELTA    CHANGE
worker nodes                2       4       +2       +100%
spot workers                2       4       +2       +100%
provisioned vCPU (workers)  8       8       0        0%
requested vCPU (shop)       6       6       0        0%
$/h workers                 0.1047  0.0652  -0.0395  -37.7%
$/h all-in                  0.254   0.2145  -0.0395  -15.6%
...
Node types:
  karpenter-baseline:    1x c6a.xlarge/spot, 1x c8i-flex.xlarge/spot
  castai-autoscaler:     4x c8i-flex.large/spot
```
Say what you see: same vCPU, same requests, all spot on both sides. The gap is the price of one spot pool (c8i-flex.large in 1c), not a better algorithm. Karpenter's `price-capacity-optimized` weighs interruption risk; CAST AI went for the cheapest pool, all in one AZ.

### Step 3 — Rightsizing effect (same autoscaler)
```bash
scripts/compare.sh castai-autoscaler castai-rightsized
scripts/compare.sh castai-rightsized castai-final
```
Expected (real run, 25 % cap): `requested vCPU (shop)` 6 → 4.5, worker nodes 4 → 2, worker vCPU 8 → 6, `used vCPU (shop)` unchanged, but `$/h workers` 0.0652 → 0.0681 (+4.4 %): the remaining c6a.xlarge costs more per vCPU than the c8i-flex.large it replaced. The second comparison is all zeros (settling only). On a 24 h+ install shop requests fall to ~1.8 vCPU and one 4 vCPU or two 2 vCPU workers remain.

### Step 4 — End to end
```bash
scripts/compare.sh karpenter-baseline castai-final
```
Expected (real run):
```text
worker nodes                2       2       0        0%
provisioned vCPU (workers)  8       6       -2       -25%
requested vCPU (shop)       6       4.5     -1.5     -25%
used vCPU (shop)            1.59    1.591   +0.001   +0.1%
$/h workers                 0.1047  0.0681  -0.0366  -35%
$/h all-in                  0.254   0.2174  -0.0366  -14.4%
$/month workers             76.43   49.71   -26.72   -35%
```
Read both `$/h workers` and `$/h all-in` out loud; the all-in % is smaller because of the system node and EKS fee. Of the -35 %, the honest split is: spot-pool choice did most of it, rightsizing (capped) removed 2 vCPU.

### Step 5 — CAST AI's own view (API)
Point-in-time endpoints only: on a cluster connected the same day, the history endpoints (`/cost`, `/node-count-history`, `namespace-totalcost`, `workload-costs`) returned empty `items` and zero totals even 6 h after connect, and `node-count-history` rejects most `stepSeconds` values. Do not show them live.
```bash
T1=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); T0=$(date -u -v-6H '+%Y-%m-%dT%H:%M:%SZ'); echo "$T0 -> $T1"
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/efficiency?startTime=${T0}&endTime=${T1}&stepSeconds=3600" | jq '.current | {cpuProvisioned, cpuRequested, cpuUsed, cpuOverprovisioningPercent}'
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/summary" | jq '.summary | {nodeCountSpotCastai, cpuProvisionedSpot, cpuRequestedSpot, costHourlySpot, costHourlyOnDemand}'
scripts/castai-api.sh GET "/v1/cost-reports/clusters/${CASTAI_CLUSTER_ID}/estimated-savings" | jq '{isRebalancingRecommended, current: .currentConfiguration.totalPrice, savingsPct: (.recommendations | map_values(.savingsPercentage))}'
```
Expected (real run, after module 12):
```json
{ "cpuProvisioned": "8.000000", "cpuRequested": "7.002000", "cpuUsed": "1.735000", "cpuOverprovisioningPercent": "12.475000" }
{ "nodeCountSpotCastai": "2", "cpuProvisionedSpot": "6.000000", "cpuRequestedSpot": "5.255000", "costHourlySpot": "0.068120", "costHourlyOnDemand": "0.049340" }
{ "isRebalancingRecommended": false, "current": { "hourly": "0.1174", "monthly": "85.7020" }, "savingsPct": { "Layman": "0", "SpotInstances": "0", "SpotOnly": "2.1294718900" } }
```
- `costHourlySpot` 0.06812 = `measure.sh` `$/h workers` 0.0681; `hourly` 0.1174 = `$/h all nodes`. Two independent price sources agree.
- `cpuOverprovisioningPercent` measures provisioned vs **requested** (12 %), not vs used. Used is 1.7 of 8: the requests are still the waste.
- Available savings dropped from 25.3 % (`SpotOnly`, module 04) to 2.1 %: the report only prices node changes, never rightsizing.
Console → Cost → **Cluster efficiency** and **Available savings** show the same numbers. Do not open "Realized savings": it needs 14+ days of history.

### Step 6 — Independent view: Prometheus/Grafana
Neither vendor's numbers; kube-state-metrics in `monitoring`.
Terminal 2 (leave running):
```bash
source scripts/env.sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```
Terminal 1 (`--data-urlencode`: curl would glob the braces):
```bash
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=count(kube_node_info)' | jq -r '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=sum(kube_pod_container_resource_requests{namespace="shop",resource="cpu"})' | jq -r '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/query_range' --data-urlencode 'query=sum(kube_pod_container_resource_requests{namespace="shop",resource="cpu"})' --data-urlencode "start=$(date -u -v-5H +%s)" --data-urlencode "end=$(date -u +%s)" --data-urlencode 'step=1800' | jq -c '[.data.result[0].values[] | [(.[0] | todate[11:16]), .[1]]]'
```
Expected: `3` (system + 2 CAST AI), `4.5`, then the history, for example `[["20:46","6"],...,["23:16","6"],["23:46","4.5"],["00:16","4.5"]]`. kube-state-metrics reports the in-place resized requests. Dips to ~2 earlier in the day are the lab profiles of modules 07–10.
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
Expected (real run, first targets 60 s after creating the objects):
```text
NAME       MODE   CPU    MEM     PROVIDED   AGE
cart       Off    93m    250Mi   True       72s
catalog    Off    143m   250Mi   True       72s
checkout   Off    126m   250Mi   True       71s
frontend   Off    126m   250Mi   True       70s
payments   Off    126m   250Mi   True       70s
worker     Off    296m   250Mi   True       69s
```
CAST AI's raw values (module 11 event log, before the cap): 78 / 137 / 111 / 111 / 111 / 276m. VPA is 5–20 % higher (p90 + 15 % margin) and floors memory at 250Mi; it has no age cap, so on a fresh install it would actually cut deeper than CAST AI today. Its first values come from minutes of data, so they are provisional.
Remove it right away (also in Reset). Each command prints `... deleted` lines:
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
Expected (~1.5–3 min): `No resources found` (VPA CRD already gone), the `shop-rightsizing` policy destroyed (`0 added, 0 changed, 1 destroyed`), `Recreating 9 pods with non-template requests`, CAST AI adds one spot node, then `shop requested vCPU: 6.000000000000001` and `CAST AI ACTIVE BASELINE reached`. It also removes VPA CRDs/RBAC and leftover `Recommendation` CRs if present.

## Q&A prep
- **Is the comparison fair to Karpenter?** Same cluster, same workloads, same quota, same measurement script, tuned NodePool disclosed. The rightsizing step is the part Karpenter does not attempt.
- **Would `SpotToSpotConsolidation` or `Balanced` change the node-level number?** Possibly a little; both already pick cheap spot. It cannot change requests.
- **Why not show Karpenter + VPA fully?** It needs updater + admission controller and its own 3 h+ of history; on this quota you cannot run both stacks side by side. The recommendation-only view shows the numbers are similar.
- **Are CAST AI's dollars the same as ours?** CAST AI uses its own price feed (and spot history); `measure.sh` uses AWS list/spot prices. Expect a few % difference.
- **What about the savings report?** Needs 14 days under management; out of scope for a same-day demo.
