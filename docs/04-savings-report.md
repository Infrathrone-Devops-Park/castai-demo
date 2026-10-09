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
  - **Workload rightsizing**: requests set from observed usage (percentile + overhead). It needs usage history; it is not part of the `estimated-savings` API response.
  - **Spot Instances**: moving spot-friendly or all workloads to spot (toggle on the card). Small here: Karpenter already runs all of `shop` on spot, so the model mostly moves the system node's pods.
  - **ARM support**: modeled savings for a chosen share of ARM CPUs (slider). We do not act on it (amd64-only course, and it needs multi-arch images).

### How to read the estimate
- It is a **model**, not a measurement. It uses list prices, assumes every workload accepts the change, and ignores the node-size floor (the smallest node here is 2 vCPU).
- It prices the **whole cluster, system node included**. Here most of the spot saving comes from replacing the on-demand `t3a.large` system node, which is a managed node group that neither Karpenter nor our CAST AI template will touch. Say so.
- Rightsizing savings assume the recommendation is applied to every replica and that nodes then shrink. Node shrink needs consolidation or rebalancing, which is modules 08–09 and 11.
- The **Realized savings** report needs about 14 days of active management (and 7 days of history for its own baseline). It will be empty today; do not promise it.
- We validate the estimate with `scripts/measure.sh` in module 13. Expect the measured result to be lower than the estimate on a cluster this small.

### Cost monitoring (free)
- Cluster cost (on-demand / spot / fallback), cost per provisioned / requested / used CPU, cluster efficiency over time, namespace and workload cost, idle resources.
- Karpenter has no equivalent. Free alternatives: OpenCost/Kubecost, AWS split cost allocation data for EKS, `eks-node-viewer` for live $/h.

### API endpoints used

| Purpose | Call |
|---|---|
| Savings estimate | `GET /v1/cost-reports/clusters/{id}/estimated-savings` (three scenarios, below) |
| Current summary | `GET /v1/cost-reports/clusters/{id}/summary` |
| Efficiency over time | `GET /v1/cost-reports/clusters/{id}/efficiency?startTime=&endTime=&stepSeconds=` |
| Namespace cost | `POST /v1/cost-reports/clusters/{id}/namespace-totalcost?startTime=&endTime=` with body `{"namespace":"shop"}` |

Numeric fields in these responses are JSON **strings** (for example `"costHourlySpot": "0.104640"`, `"nodeCountSpot": "2"`); convert with `tonumber` in jq.

`estimated-savings` returns `recommendations` with three scenarios, each with `monthly` / `hourly` `{priceBefore, priceAfter}`, `savingsPercentage` and `details.configurationAfter` (the modeled node list) plus `details.armSavingsConfiguration`:

| Key | What it models (by its node lists) |
|---|---|
| `Layman` | Same spot/on-demand split, cheapest repack |
| `SpotInstances` | Spot only for spot-friendly workloads (console toggle "spot-friendly") |
| `SpotOnly` | Everything on spot (console toggle "all workloads") |

How soon data appears (validation run, connected 20:18 UTC): `summary`, `estimated-savings` and the `current` block of `efficiency` were populated within 10 minutes. The time-series parts (`efficiency.items`, `cost`, `namespace-totalcost`, `workload-efficiency`) stayed empty for the first POLL_MINUTES.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: `CASTAI_CLUSTER_ID=<uuid>` (not `<not applied yet>`).

### Step 2 — Console: Available savings
Console (https://console.cast.ai) → cluster `karpenter-demo` → **Available savings** report. Labels differ between the Enhanced and Classic console.
Expected (per CAST AI docs): the report cards **Workload rightsizing**, **Spot Instances** (toggle "all workloads" / "spot-friendly workloads only"), **ARM support** (ARM CPU % slider) and a **Configuration comparison** over time (24 h / 7 days; hourly, daily or monthly rates). Toggle the Spot card both ways and note both numbers; they should match `SpotInstances` and `SpotOnly` in Step 3. Write the card values on the whiteboard. The rightsizing card may be empty or low in the first hours.

### Step 3 — Same estimate via API
Saved for module 13.
```bash
scripts/castai-api.sh GET /v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/estimated-savings > results/castai-estimated-savings.json
jq 'keys' results/castai-estimated-savings.json
jq '{lastUpdatedAt, isRebalancingRecommended, current: .currentConfiguration.totalPrice}' results/castai-estimated-savings.json
jq -r '.recommendations | to_entries[] | "\(.key)\t\(.value.monthly.priceBefore)\t\(.value.monthly.priceAfter)\t\(.value.savingsPercentage)"' results/castai-estimated-savings.json
jq -r '.recommendations.SpotOnly.details.configurationAfter.nodes[] | "\(.instanceType) spot=\(.spot) \(.price)"' results/castai-estimated-savings.json
```
Expected: keys `currentConfiguration`, `isRebalancingRecommended`, `lastUpdatedAt`, `recommendations`; `lastUpdatedAt` a few seconds to minutes old; `current` `{"hourly": "0.1540", "monthly": "112.4200"}`, which equals `$/h all nodes` from `measure.sh` (`0.154`; same list and spot prices). Validation run:
```text
Layman         112.4200  112.5295000000  0
SpotInstances  112.4200  106.1055000000  5.6168831200
SpotOnly       112.4200  83.950000       25.3246753200
c6a.xlarge spot=true 0.049300
c6a.xlarge spot=true 0.049300
c8i-flex.large spot=true 0.016400
```
Read it out: every scenario keeps 2 × 4-vCPU spot workers (`c6a.xlarge` at the cheapest AZ price, $0.0493 vs our $0.0519/$0.0528), so for these requests Karpenter's worker choice is already near-optimal. They differ in what replaces the system node: `Layman` (0%) an on-demand `m6a.large`, `SpotInstances` (5.6%) an on-demand `c6a.large`, `SpotOnly` (25.3%) a spot `c8i-flex.large`. Most of the modeled saving is the system node, which no autoscaler here manages. `isRebalancingRecommended: true` refers to that same delta. ARM (`details.armSavingsConfiguration.summary.price`) would be `0.0808`/h in the `SpotOnly` scenario.

### Step 4 — Cluster summary vs our measurement
Does CAST AI see the same cluster we measured?
```bash
scripts/castai-api.sh GET /v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/summary > results/castai-summary-baseline.json
jq '.summary | {nodeCountOnDemand, nodeCountSpot, cpuProvisionedOnDemand, cpuProvisionedSpot, cpuRequestedOnDemand, cpuRequestedSpot, cpuUsed, costHourlyOnDemand, costHourlySpot}' results/castai-summary-baseline.json
jq '.totals | {provisionedVcpu, requestedVcpuAll, usedVcpuAll, usdPerHourNodes}' results/karpenter-baseline.json
```
Expected (all values are strings): validation run
```json
{
  "nodeCountOnDemand": "1",
  "nodeCountSpot": "2",
  "cpuProvisionedOnDemand": "2.000000",
  "cpuProvisionedSpot": "8.000000",
  "cpuRequestedOnDemand": "1.320000",
  "cpuRequestedSpot": "6.360000",
  "cpuUsed": "1.734000",
  "costHourlyOnDemand": "0.049340",
  "costHourlySpot": "0.104640"
}
{
  "provisionedVcpu": 10,
  "requestedVcpuAll": 7.68,
  "usedVcpuAll": 1.731,
  "usdPerHourNodes": 0.154
}
```
They agree: 1.32 + 6.36 = 7.68 requested (daemonsets included on both sides), 0.0493 + 0.1046 = 0.1540 $/h. Small differences come from spot price timing. `clusterScore` is empty on this cluster, so it is not shown.

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

Console equivalent: the cluster's **Cost monitoring** reports: **Cluster**, **Workloads** (with Workload Efficiency: requested vs used per workload), **Namespaces**, **Allocation Groups** and **Cost comparison** (per docs.cast.ai cost-management). `worker` and `frontend` should top the Workloads list by cost once data has accumulated. Exact menu labels vary between Enhanced and Classic console.

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
