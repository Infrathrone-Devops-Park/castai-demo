# 09 — Rebalancing: preview the savings, then execute
**Time:** 30 min · **Goal:** Build a fleet that is more expensive than its template now allows, preview the fix with dollar numbers, execute it blue/green inside quota, then automate it with a scheduled rebalancing job.

## What you'll show
- A deterministic "before" state: the `batch` template runs an **on-demand** node; then the template is switched to **spot**. The running node does not change by itself.
- A rebalancing plan with a savings preview (current "blue" vs proposed "green" nodes, $/h, %), via console and API.
- Execution: create spot node → drain on-demand node → delete it (`autoscaling.cast.ai/draining=rebalancing`).
- `scripts/measure.sh` before/after.
- Scheduled rebalancing in Terraform (`castai_rebalancing_schedule` + `castai_rebalancing_job`) with thresholds that can actually trigger on a tiny cluster, plus the schedule preview API.

## Concepts

### What the Rebalancer does
Runs **all** selected workloads through the autoscaler's placement algorithm (not only Pending pods) and proposes the cheapest node set that fits, using current templates and node configuration.
```text
POST rebalancing-plans      -> status generating -> generated   (review: blue vs green, diff $)
POST .../execute            -> creating_nodes -> preparing_nodes -> draining_nodes
                               -> deleting_nodes -> finished
plans not executed within ~1 h become obsolete
```
- **Blue/green**: new nodes first, then drain, then delete. During execution the fleet is temporarily larger. `splitNodesInBatchesOf: 1` keeps at most one extra node alive.
- Prerequisite: the unschedulable pods policy must be on (it is).
- Drain respects PDBs up to the drain timeout (default 20 min), then forces, unless `evictGracefully` keeps the node cordoned with `rebalancing.cast.ai/status=drain-failed`.
- Pods the Rebalancer cannot reason about ("problematic": unknown custom-label selectors, bare pods, Jobs, `removal-disabled`) pin their node unless aggressive options are set.

### Why this before-state
| Option | Deterministic? | Quota-safe? |
|---|---|---|
| Wait for fragmentation | no | yes |
| Rebalance the default spot fleet | savings may be 0 | needs 4 extra spot vCPU |
| **`batch` on-demand node, then template → spot** | yes: OD → spot is ~50 % cheaper | +2 spot vCPU during execution |

Karpenter would handle the same template change through **drift** (module 09 of karpenter-demo): automatic replacement, no preview. CAST AI: no automatic replacement, explicit plan with a price tag. <!-- VERIFY: CAST AI does not auto-replace on template change -->

### Capacity
| Moment | Spot vCPU (≤ 8) | On-demand vCPU (≤ 8) | Cluster cores (≤ 10) |
|---|---|---|---|
| Lab profile + `batch` OD node | ~4 | 2 + 2 = 4 | 2 + 4 + 2 = 8 |
| During execution (batch of 1) | ~4 + 2 = 6 | 4 | 10 |
| After | ~6 | 2 | 8 |

Plan scope is limited to **one** node for execution (≤ 2 for the preview-only plan).

## Demo

Panes:
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L scheduling.cast.ai/node-template,scheduling.cast.ai/spot,scheduling.cast.ai/on-demand,node.kubernetes.io/instance-type,autoscaling.cast.ai/draining -w
```
```bash
kubectl get pods -n castai-lab -o wide -w
```

### Step 1 — Environment and lab profile
Start = end of module 06. Free spot capacity first (same as module 07 Step 4, ~4 min).
```bash
source scripts/env.sh
CL="$CASTAI_API_URL/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID"
EXT="$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID"
kubectl scale deploy -n shop --all --replicas=0
kubectl wait node -l provisioner.cast.ai/managed-by=cast.ai --for=delete --timeout=600s
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: CAST AI nodes deleted, then one spot node (usually 4 vCPU) and five `successfully rolled out`.

### Step 2 — Build the "before" state: an on-demand batch node
```bash
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=false
kubectl apply -f manifests/09-rebalancing/batch-workload.yaml
kubectl wait pods -n castai-lab -l app=batch --for=condition=Ready --timeout=600s
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L node.kubernetes.io/instance-type,scheduling.cast.ai/on-demand
```
Expected: `batch_template_offering = "on-demand"`; within ~2–3 min one 2-vCPU on-demand node (`c6a.large` class), `ON-DEMAND true`; both pods `condition met`. The workload uses the explicit selector `scheduling.cast.ai/node-template: batch` (no partial matching needed, and not "problematic" for the Rebalancer).

### Step 3 — Measure "before"
Wait out the evictor grace period so nothing moves under us.
```bash
sleep 120
scripts/measure.sh rebalance-before
```
Expected: node table with one `castai` spot node, one `castai` on-demand node (`c6a.large` ≈ $0.047/h), the system node; `saved results/rebalance-before.json`.

### Step 4 — Change the template to spot
```bash
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates" | jq '.items[] | select(.template.name=="batch") | {spot: .template.constraints.spot, onDemand: .template.constraints.onDemand, stats}'
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L scheduling.cast.ai/on-demand,scheduling.cast.ai/spot
```
Expected: `1 changed`, output `batch_template_offering = "spot"`; API `{"spot": true, "onDemand": false, "stats": {"countOnDemand": 1, ...}}`; the node is **still on-demand**. The template changed, the fleet did not. That gap is what the Rebalancer closes.

### Step 5 — Console: generate a plan and review it
Console path (show, do **not** press Execute here; the API steps below execute):
**Cluster → Node list** → tick the `batch` node → **Actions → Rebalance nodes** → **Generate plan**. Alternatively **Rebalancer → Prepare new plan**. <!-- VERIFY: console labels -->
What appears: status Generating then Ready; "current vs rebalanced" cost per hour/month; a node list with the on-demand node to be replaced by a spot node of the same size; settings "Evict nodes gracefully", minimum nodes.

### Step 6 — API: whole-fleet preview (no execute)
Ask for a plan over both CAST AI nodes. Review only.
```bash
NODES=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EXT/nodes" | jq -c '[.items[] | select(.labels["provisioner.cast.ai/managed-by"]=="cast.ai") | {nodeId: .id}]')
echo "$NODES"
PREVIEW=$(jq -n --argjson n "$NODES" '{minNodes: 1, rebalancingNodes: $n, splitNodesInBatchesOf: 1}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/rebalancing-plans" | jq -r .rebalancingPlanId)
echo "$PREVIEW"
for i in $(seq 1 30); do S=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PREVIEW" | jq -r '.status // empty' 2>/dev/null); echo "${S:-pending}"; case "$S" in generated|error|invalid) break ;; esac; sleep 10; done
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PREVIEW?includeConfigurations=true" | jq '{status, diff: .configurations.diff, blue: [.configurations.blue.nodes[] | {name, instanceType, isSpot, priceHourly}], green: [.configurations.green.nodes[] | {instanceType, isSpot, priceHourly}]}'
```
Expected: two node IDs, a plan ID (UUID), `pending`/`generating` lines then `generated` (usually < 1 min). The summary shows blue = system node + default spot node + `batch` on-demand node; green = the same with the on-demand node swapped for a spot 2-vCPU type; the default spot node is kept or swapped for a marginally cheaper type. `diff.priceHourly` ≈ `"0.02"`–`"0.03"`, `diff.savingsPercentage` (affected nodes) and `diff.clusterSavingsPercentage` (whole cluster) as strings. <!-- VERIFY: green includes unchanged nodes; exact diff values -->
Do not execute it: it targets 2 nodes. Generating the next plan makes this one obsolete.

### Step 7 — API: plan for the batch node only, review, execute
```bash
BATCH_NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=batch -o jsonpath='{.items[0].metadata.name}')
BATCH_ID=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EXT/nodes" | jq -r --arg n "$BATCH_NODE" '.items[] | select(.name==$n) | .id')
echo "$BATCH_NODE $BATCH_ID"
PLAN=$(jq -n --arg id "$BATCH_ID" '{minNodes: 1, rebalancingNodes: [{nodeId: $id}], splitNodesInBatchesOf: 1, evictGracefully: true, executionConditions: {enabled: true, achievedSavingsPercentage: 10}}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/rebalancing-plans" | jq -r .rebalancingPlanId)
for i in $(seq 1 30); do S=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN" | jq -r '.status // empty' 2>/dev/null); echo "${S:-pending}"; case "$S" in generated|error|invalid) break ;; esac; sleep 10; done
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN?includeConfigurations=true" | jq '{status, diff: .configurations.diff, affected: .configurations.blue.totals, green: .configurations.green.totals}'
```
Expected: node name + UUID; `generated`; `diff` ≈ `{"priceHourly": "0.02x", "priceMonthly": "~17", "savingsPercentage": "~50", "clusterSavingsPercentage": "~15-25"}`. Read it out: this is the "preview before you touch anything" Karpenter does not have. `achievedSavingsPercentage: 10` aborts (and deletes the new node) if the real spot price lands too close to on-demand. <!-- VERIFY: numbers -->

Execute and follow the phases:
```bash
curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN/execute" | jq -r .status
for i in $(seq 1 60); do S=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN" | jq -r .status); echo "$(date -u +%T) $S"; case "$S" in finished|error|partially_finished) break ;; esac; sleep 10; done
```
Expected sequence over ~4–7 min: `creating_nodes` (new spot node appears in the pane, `NODE-TEMPLATE batch`, `SPOT true`) → `preparing_nodes` → `draining_nodes` (old node labelled `DRAINING rebalancing`, batch pods restart on the new node) → `deleting_nodes` → `finished`. Never more than one extra node. <!-- VERIFY: initial execute response status value -->

Evidence:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN?includeOperations=true" | jq -r '.operations[] | [.type, (.createParams.instanceType // .drainParams.instanceType // .deleteParams.instanceType // "-"), (.createParams.isSpot // .deleteParams.isSpot // "-"), .createdAt, (.finishedAt // "-")] | @tsv'
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
```
Expected: `create_node <type> true`, `prepare_node`, `drain_node`, `delete_node <c6a.large> false` with timestamps; one batch node, `SPOT true`. Console: **Rebalancer** → plan shows Completed.

### Step 8 — Measure "after"
```bash
sleep 60
scripts/measure.sh rebalance-after
scripts/compare.sh rebalance-before rebalance-after
```
Expected: `spot workers` +1, same worker vCPU, `$/h workers` down by ≈ the plan's `diff.priceHourly` (±spot noise). The plan's number and our independent measurement should agree within a cent or two.

### Step 9 — Scheduled rebalancing (Terraform)
Schedule every 10 min, only nodes of template `batch`, 1 node per run, batches of 1, minimum node age 5 min, trigger at ≥ 5 % projected savings, abort below 5 % achieved. Job created **paused**.
```bash
sed -n '/resource "castai_rebalancing_schedule"/,/^}/p' terraform/rebalancing-demo.tf
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true -var enable_rebalancing_schedule=true
SCHED=$(terraform -chdir=terraform output -raw rebalancing_schedule_id)
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-jobs" | jq '.jobs[] | {rebalancingScheduleId, enabled, status, nextTriggerAt}'
```
Expected: `2 added`; one job `{"enabled": false, "status": null or "JobStatusPending", ...}`. Console: **Rebalancer → Schedule rebalancing** (or org-level **Optimization**) lists `castai-demo-batch-to-spot`. <!-- VERIFY: job fields when paused -->

Preview which nodes a run would touch:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/rebalancing-schedules/$SCHED" | jq -c '{name, schedule, triggerConditions, launchConfiguration}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/rebalancing-schedule-preview" | jq '{affectedNodes, willTriggerAt: (.willTriggerAt // [] | .[0:3])}'
```
Expected: `affectedNodes` = the one batch node ID (older than 300 s), next three trigger times at :00/:10/:20 UTC. <!-- VERIFY: preview body shape -->

Thresholds, honestly:
- Standard scheduled rebalancing has **percentage** gates only: `trigger_conditions.savings_percentage` (projected) and `execution_conditions.achieved_savings_percentage` (guard during execution).
- The often-quoted "15 % **and** $50/month" defaults belong to **Kent continuous rebalancing**. On this cluster (worker fleet ≈ $0.07–0.10/h ≈ $50–75/month) 15 % is ≈ $10, far below $50: it would never fire. Hence 5 % here.
- Our batch node is already spot, so a run now would find ≈ 0 % savings.

Optional (adds up to 10 min): enable the job and watch it skip.
```bash
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true -var enable_rebalancing_schedule=true -var rebalancing_job_enabled=true
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-jobs" | jq '.jobs[] | {enabled, status, lastTriggerAt, nextTriggerAt, rebalancingPlanId}'
```
Expected: `enabled true`; after the next 10-minute mark, `lastTriggerAt` set and `status "JobStatusSkipped"` (savings below 5 %). <!-- VERIFY -->

## Talking points
- The plan is the product: a reviewable diff with $/h and % before anything moves. Karpenter's equivalent decisions show up only as events after the fact.
- Execution is blue/green, like Karpenter replace-consolidation. Budget quota for the extra node; `splitNodesInBatchesOf` is the knob that keeps it to one.
- Template changes do not roll the fleet by themselves. Karpenter drift does that automatically; CAST AI makes it a plan you run or schedule. Pick which you prefer; both are defensible.
- Savings guards (`savings_percentage`, `achieved_savings_percentage`) stop pointless churn. Tune them to cluster size; defaults are made for big fleets.
- The real cost story at node level was the on-demand → spot swap. On a fleet already on spot and already bin-packed, rebalancing finds little. It gets interesting after rightsizing (module 11+) leaves nodes half-empty.

## Reset
Back to the module 06 end state.
```bash
source scripts/env.sh
kubectl delete ns castai-lab --ignore-not-found
kubectl wait node -l scheduling.cast.ai/node-template=batch --for=delete --timeout=600s
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: namespace deleted, batch node deleted ~2 min later (or `no matching resources found`), `Apply complete! Resources: 0 added, 0 changed, 3 destroyed.` (template, schedule, job), then all six deployments roll out on new spot capacity (~3 min). Any leftover non-executed plan simply turns obsolete.

## Q&A prep
- **What makes a pod "problematic"?** Required node affinity on custom labels no template maps, bare pods, Job pods, `removal-disabled` pods, local PVs. Check the **Rebalancer** page, or `curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/problematic-workloads" | jq '{hasProblems, controllers}'`.
- **Does it respect PDBs?** Yes, up to the drain timeout (default 20 min, max 180). Then it forces, unless `evictGracefully`, which keeps the node cordoned with `drain-failed` and uncordons it after a timeout.
- **What if the planned spot type is unavailable at execution?** Alternatives are created; if achieved savings fall below `achievedSavingsPercentage`, new nodes are deleted and the plan fails safe.
- **Can it touch the system node?** Plans can include non-CAST AI nodes if you select them. We select by node ID or by template label, never the whole cluster for execution.
- **Spot-fallback nodes?** Rebalancing ignores `removal-disabled` on spot-fallback nodes on purpose, to avoid staying on expensive fallback capacity.
- **Karpenter equivalent of a schedule?** Disruption budgets with `schedule` + `duration` restrict *when* consolidation may act; there is no savings threshold.
