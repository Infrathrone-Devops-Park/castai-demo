# 04 — Savings report & cost monitoring
**Time:** 25 min · **Goal:** Read CAST AI's free savings estimate and cost reports, check them against our own measurement, and explain what the estimate does and does not include.

## What you'll show
- Console → Available savings: current vs optimized configuration and the three savings cards.
- The same data from the API, saved to `results/` for module 13.
- Cluster summary and efficiency (provisioned / requested / used) vs `results/karpenter-baseline.json`.
- Cost per namespace (`shop` vs the rest).
- How the estimate is computed and why it is not a promise.

## Concepts

### Available savings (free, read-only)
The report models "what would this cluster cost if CAST AI managed it", from the agent's snapshots:
- **Current configuration**: today's nodes, their prices, provisioned vs requested CPU/memory.
- **Optimized configuration**: the cheapest node set that fits the pods, under the chosen assumptions.
- **Cards**:
  - **Workload rightsizing**: requests set from observed usage (percentile + overhead). Expected to be the largest card here, because requests are about 4× usage.
  - **Spot instances**: moving spot-friendly (or all) workloads to spot. Expected to be small: Karpenter already runs most of `shop` on spot.
  - **ARM support**: modeled savings for a chosen share of ARM nodes. We do not act on it (amd64-only course, and it needs multi-arch images).

### How to read the estimate
- It is a **model**, not a measurement. It uses list prices, assumes every workload accepts the change, and ignores the node-size floor (the smallest node here is 2 vCPU).
- Rightsizing savings assume the recommendation is applied to every replica and that nodes then shrink. Node shrink needs consolidation or rebalancing, which is modules 08–09 and 11.
- The **Realized savings** report needs about 14 days of active management (and 7 days of history for its own baseline). It will be empty today; do not promise it.
- We validate the estimate with `scripts/measure.sh` in module 13. Expect the measured result to be lower than the estimate on a cluster this small.

### Cost monitoring (free)
- Cluster cost (on-demand / spot / fallback), cost per provisioned / requested / used CPU, cluster efficiency over time, namespace and workload cost, idle resources.
- Karpenter has no equivalent. Free alternatives: OpenCost/Kubecost, AWS split cost allocation data for EKS, `eks-node-viewer` for live $/h.

### API endpoints used

| Purpose | Call |
|---|---|
| Savings estimate | `GET /v1/cost-reports/clusters/{id}/estimated-savings` |
| Current summary | `GET /v1/cost-reports/clusters/{id}/summary` |
| Efficiency over time | `GET /v1/cost-reports/clusters/{id}/efficiency?startTime=&endTime=&stepSeconds=` |
| Namespace cost | `POST /v1/cost-reports/clusters/{id}/namespace-totalcost?startTime=&endTime=` with body `{"namespace":"shop"}` |

Numeric fields in these responses are JSON **strings** (for example `"0.0907"`); convert with `tonumber` in jq.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: `CASTAI_CLUSTER_ID=<uuid>` (not `<not applied yet>`).

### Step 2 — Console: Available savings
Console → **Clusters** → `karpenter-demo` → **Available savings**. <!-- VERIFY: nav label in current console -->
Expected: a headline "estimated savings" % and $/month, a **Current configuration** vs **Optimized configuration** comparison (node count, CPU, monthly cost), and the cards **Workload rightsizing**, **Spot instances**, **ARM support**. Toggle the Spot card between "spot-friendly" and "all workloads" and note both numbers. Write the three card values on the whiteboard.

### Step 3 — Same estimate via API
Saved for module 13.
```bash
scripts/castai-api.sh GET /v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/estimated-savings > results/castai-estimated-savings.json
jq 'keys' results/castai-estimated-savings.json
jq '{lastUpdatedAt, isRebalancingRecommended, recommendations: (.recommendations | length)}' results/castai-estimated-savings.json
```
Expected: keys include `currentConfiguration`, `isRebalancingRecommended`, `lastUpdatedAt`, `recommendations`; `lastUpdatedAt` within the last hour. Explore one level down live (`jq '.currentConfiguration | keys'`) and match the monthly figures to the console. <!-- VERIFY: field names inside currentConfiguration / recommendations -->

### Step 4 — Cluster summary vs our measurement
Does CAST AI see the same cluster we measured?
```bash
scripts/castai-api.sh GET /v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/summary > results/castai-summary-baseline.json
jq '.summary | {nodeCountOnDemand, nodeCountSpot, cpuProvisionedOnDemand, cpuProvisionedSpot, cpuRequestedOnDemand, cpuRequestedSpot, cpuUsed, costHourlyOnDemand, costHourlySpot, clusterScore}' results/castai-summary-baseline.json
jq '.totals | {provisionedVcpu, requestedVcpuAll, usedVcpuAll, usdPerHourNodes}' results/karpenter-baseline.json
```
Expected: node counts 1 on-demand (the system node) + 2–3 spot; provisioned CPU 2 + 8 (or 10); requested and used CPU close to `measure.sh`; `costHourlyOnDemand + costHourlySpot` within a few cents/hour of `usdPerHourNodes`. Small differences come from spot price timing and whether daemonset or system pods are counted. <!-- VERIFY: summary values arrive as strings -->

### Step 5 — Efficiency over the last 3 hours
The over-provisioning trend since the app started.
```bash
START=$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
scripts/castai-api.sh GET "/v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/efficiency?startTime=$START&endTime=$END&stepSeconds=3600" > results/castai-efficiency-baseline.json
jq '{current: (.current | {cpuProvisioned, cpuRequested, cpuUsed, cpuOverprovisioningPercent}), summary: (.summary | {cpuOverprovisioningPercent, costPerCpuProvisioned, costPerCpuRequested, costPerCpuUsed})}' results/castai-efficiency-baseline.json
```
Expected: `cpuProvisioned` ≈ 10, `cpuRequested` ≈ 7–8, `cpuUsed` ≈ 2; `costPerCpuUsed` several times `costPerCpuProvisioned`. That ratio is the waste in dollars. If `noDataReason` is set instead, the agent has not sent enough history yet.

### Step 6 — Cost per namespace
Who pays for the waste.
```bash
scripts/castai-api.sh POST "/v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/namespace-totalcost?startTime=$START&endTime=$END" '{"namespace":"shop"}' > results/castai-namespace-shop.json
jq '.items[] | {namespace, totalCost}' results/castai-namespace-shop.json
```
Expected: one item `"namespace": "shop"` with a `totalCost` in USD for the last 3 h (a string). The filter is a case-insensitive substring match. <!-- VERIFY: totalCost populated within 3 h of connect -->

Console equivalent: Console → **Cost monitoring** → **Namespaces** (and **Workloads**: CPU-hours and "$ wasted" per deployment; `worker` and `frontend` should top the list). <!-- VERIFY: nav labels -->

## Talking points
- "This report is free, needs no IAM, and changes nothing. If you do one thing after today, connect read-only and look at this page for your own clusters."
- "It says rightsizing is where the money is. Spot is small because Karpenter already did that work. That matches what we measured in module 02."
- "Treat the percentage as an upper bound. We will measure what is actually achieved in module 13."
- "Cost per used CPU vs cost per provisioned CPU is the most honest single number for waste."

## Reset
Nothing in this module changes the cluster. The JSON files in `results/` are kept for module 13.

## Q&A prep
- **How is the optimized configuration computed?** From the agent's snapshots: current pods and their (optionally rightsized) requests are packed onto the cheapest node set the model allows, at list prices. It does not run your workloads, so it cannot know which pods tolerate spot, restarts or smaller nodes beyond what labels and replica counts tell it.
- **Why might the estimate be wrong?** Node-size floors, PDBs, single-replica pods, startup peaks, spot availability in your AZs, and discounts (Savings Plans, EDP) that the model does not apply unless configured.
- **Can I get this without CAST AI?** Cost per namespace: OpenCost/Kubecost or AWS split cost allocation. Rightsizing estimates: VPA recommender in `Off` mode, or Goldilocks. You assemble the report yourself.
- **Why no realized savings?** It needs about 14 days of active management to build a baseline.
