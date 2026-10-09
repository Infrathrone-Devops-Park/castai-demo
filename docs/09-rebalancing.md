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

Karpenter would handle the same template change through **drift** (module 09 of karpenter-demo): automatic replacement, no preview. CAST AI: no automatic replacement, explicit plan with a price tag (validated: the on-demand node stayed on-demand after the template flip until the plan ran).

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
Start = end of module 06. Free spot capacity first (same as module 07 Step 4, ~3–5 min; one node stays for the WA exporter).
```bash
source scripts/env.sh
CL="$CASTAI_API_URL/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID"
EXT="$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID"
kubectl scale deploy -n shop --all --replicas=0
until [ "$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai --no-headers | wc -l)" -le 1 ]; do sleep 15; done
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: CAST AI nodes deleted down to one (validation: 4.6 min; nodes younger than 5 min wait for the evictor grace period), then one more spot node (validation: `c8i-flex.large`) and five `successfully rolled out` within ~1 min. Spot in use: ~4 vCPU.

### Step 2 — Build the "before" state: an on-demand batch node
```bash
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=false
terraform -chdir=terraform apply tfplan
kubectl apply -f manifests/09-rebalancing/batch-workload.yaml
kubectl wait pods -n castai-lab -l app=batch --for=condition=Ready --timeout=600s
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L node.kubernetes.io/instance-type,scheduling.cast.ai/on-demand
```
Expected: `Plan: 1 to add`, `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.`, `batch_template_offering = "on-demand"`; within ~1 min one 2-vCPU on-demand node (validation: `c6a.large`), `ON-DEMAND true`; both pods `condition met`. The workload uses the explicit selector `scheduling.cast.ai/node-template: batch` (no partial matching needed, and not "problematic" for the Rebalancer).

### Step 3 — Measure "before"
Wait out the evictor grace period so nothing moves under us.
```bash
sleep 120
scripts/measure.sh rebalance-before
```
Expected (validation run): two `castai` spot `c8i-flex.large` (0.0163 each), one `castai` on-demand `c6a.large` (0.04675), the system node; `$/h workers 0.0794`; `saved results/rebalance-before.json`.

### Step 4 — Change the template to spot
```bash
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true
terraform -chdir=terraform apply tfplan
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates" | jq '.items[] | select(.template.name=="batch") | {spot: .template.constraints.spot, onDemand: .template.constraints.onDemand, stats}'
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L scheduling.cast.ai/on-demand,scheduling.cast.ai/spot
```
Expected: plan shows `on_demand = true -> false`, `spot = false -> true`, `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`, output `batch_template_offering = "spot"`; API `{"spot": true, "onDemand": false, "stats": {"countOnDemand": 1, "countSpot": 0, "countFallback": 0, "countSoleTenant": 0}}`; the node is **still on-demand** (`ON-DEMAND true`, `SPOT` empty). The template changed, the fleet did not. That gap is what the Rebalancer closes.

### Step 5 — Console: generate a plan and review it
Console path (show, do **not** press Execute here; the API steps below execute):
**Cluster → Node list** → tick the `batch` node → **Actions → Rebalance nodes** (labels per docs.cast.ai). Alternatively **Rebalancer → Prepare new plan** (has the **Evict nodes gracefully** toggle). Whole cluster: **Cluster → Rebalance**.
What appears: status Generating then Ready (API: `generating` / `generated`); "current vs rebalanced" cost per hour/month; a node list with the on-demand node to be replaced by a spot node of the same size; settings "Evict nodes gracefully", minimum nodes.

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
Expected: three node IDs (two default spot nodes + the batch node), a plan ID (UUID), `generating` then `generated` (~10–20 s). Validation run:
```text
diff:  priceHourly "0.02615", priceMonthly "19.08950", savingsPercentage "32.9552615000", clusterSavingsPercentage "20.3264671600"
blue:  t3a.large false 0.0493 | c6a.large false 0.04675 | c8i-flex.large true 0.0163 | c8i-flex.large true 0.0163
green: t3a.large false 0.0493 | c5a.large true 0.0206   | c8i-flex.large true 0.0163 | c8i-flex.large true 0.0163
```
Blue and green list the whole cluster, system node included (unchanged). Only the on-demand node is swapped for spot; the default spot nodes are already the cheapest and stay. All values are strings.
Do not execute it: it targets 3 nodes. It stays `generated` (not executable after ~1 h, then obsolete).

### Step 7 — API: plan for the batch node only, review, execute
```bash
BATCH_NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=batch -o jsonpath='{.items[0].metadata.name}')
BATCH_ID=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EXT/nodes" | jq -r --arg n "$BATCH_NODE" '.items[] | select(.name==$n) | .id')
echo "$BATCH_NODE $BATCH_ID"
PLAN=$(jq -n --arg id "$BATCH_ID" '{minNodes: 1, rebalancingNodes: [{nodeId: $id}], splitNodesInBatchesOf: 1, evictGracefully: true, executionConditions: {enabled: true, achievedSavingsPercentage: 10}}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/rebalancing-plans" | jq -r .rebalancingPlanId)
for i in $(seq 1 30); do S=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN" | jq -r '.status // empty' 2>/dev/null); echo "${S:-pending}"; case "$S" in generated|error|invalid) break ;; esac; sleep 10; done
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN?includeConfigurations=true" | jq '{status, diff: .configurations.diff, affected: .configurations.blue.totals, green: .configurations.green.totals}'
```
Expected: node name + UUID; `generating`, `generated`; validation run: `diff {"priceHourly": "0.02615", "priceMonthly": "19.08950", "savingsPercentage": "55.9358288800", "clusterSavingsPercentage": "20.3264671600"}`, `affected` 1 node, 6 pods (2 batch + 4 DaemonSet pods), `priceHourly "0.04675"`; `green` 1 node `priceHourly "0.0206"` (a `c5a.large` spot). Read it out: this is the "preview before you touch anything" Karpenter does not have. `achievedSavingsPercentage: 10` aborts (and deletes the new node) if the real spot price lands too close to on-demand.

Execute and follow the phases:
```bash
curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN/execute" | jq -r .status
for i in $(seq 1 60); do S=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN" | jq -r .status); echo "$(date -u +%T) $S"; case "$S" in finished|error|partially_finished) break ;; esac; sleep 10; done
```
Expected (validation run, ~2.5 min): the first line is `generated` (the execute call returns the plan before it starts), then `creating_nodes` for ~50 s (new spot node appears in the pane, `NODE-TEMPLATE batch`, `SPOT true`) → `draining_nodes` for ~90 s (old node labelled `DRAINING rebalancing`, batch pods restart on the new node) → `finished`. `preparing_nodes` and `deleting_nodes` are short and may be skipped at a 10 s poll. Never more than one extra node.

Evidence:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PLAN?includeOperations=true" | jq -r '.operations[] | [.type, (.createParams.instanceType // .drainParams.instanceType // .deleteParams.instanceType // "-"), (.createParams.isSpot // .deleteParams.isSpot // "-"), .createdAt, (.finishedAt // "-")] | @tsv'
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
```
Expected (validation run; all operations are created at plan time, so `createdAt` is identical, `finishedAt` tells the order):
```text
create_node   c5a.large  true  ...21:49:51Z  ...21:50:58Z
drain_node    c6a.large  -     ...21:49:51Z  ...21:51:27Z
delete_node   c6a.large  -     ...21:49:51Z  ...21:52:36Z
prepare_node  -          -     ...21:50:58Z  ...21:51:06Z
```
`isSpot` is only set on `create_node`. One batch node remains, `c5a.large`, `SPOT true`. Console: **Rebalancer** → plan shows Completed.

### Step 8 — Measure "after"
```bash
sleep 60
scripts/measure.sh rebalance-after
scripts/compare.sh rebalance-before rebalance-after
```
Expected (validation run): `spot workers 2 -> 3`, worker vCPU `6 -> 6`, `$/h workers 0.0794 -> 0.0532` (`-0.0262`, `-33%`), node types `1x c6a.large/on-demand, 2x c8i-flex.large/spot` → `1x c5a.large/spot, 2x c8i-flex.large/spot`. The plan said `0.02615`; our independent measurement says `0.0262`.

### Step 9 — Scheduled rebalancing (Terraform)
Schedule every 10 min, only nodes of template `batch`, 1 node per run, batches of 1, minimum node age 5 min, trigger at ≥ 5 % projected savings, abort below 5 % achieved. Job created **paused**.
```bash
sed -n '/resource "castai_rebalancing_schedule"/,/^}/p' terraform/rebalancing-demo.tf
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true -var enable_rebalancing_schedule=true
terraform -chdir=terraform apply tfplan
SCHED=$(terraform -chdir=terraform output -raw rebalancing_schedule_id)
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-jobs" | jq '.jobs[] | {rebalancingScheduleId, enabled, status, nextTriggerAt}'
```
Expected: `Plan: 2 to add`, `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.`, the schedule UUID in the output; one job `{"rebalancingScheduleId": "<uuid>", "enabled": false, "status": "JobStatusPending", "nextTriggerAt": "<next :x0 UTC>"}`. Console: **Rebalancer → Schedule rebalancing** lists `castai-demo-batch-to-spot`.

Preview which nodes a run would touch:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/rebalancing-schedules/$SCHED" | jq -c '{name, schedule, triggerConditions, launchConfiguration}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/rebalancing-schedule-preview" | jq '{affectedNodes, willTriggerAt: (.willTriggerAt // [] | .[0:3])}'
```
Expected: `{"affectedNodes": [{"id": "<batch node id>"}], "willTriggerAt": ["...:00:00Z", "...:10:00Z", "...:20:00Z"]}`. `affectedNodes` is `[]` while the batch node is younger than `node_ttl_seconds` (300 s); Step 7 just created it, so wait ~5 min after Step 7 or re-run the preview.

Thresholds, honestly:
- Standard scheduled rebalancing has **percentage** gates only: `trigger_conditions.savings_percentage` (projected) and `execution_conditions.achieved_savings_percentage` (guard during execution).
- The often-quoted "15 % **and** $50/month" defaults belong to **Kent continuous rebalancing**. On this cluster (worker fleet ≈ $0.07–0.10/h ≈ $50–75/month) 15 % is ≈ $10, far below $50: it would never fire. Hence 5 % here.
- Our batch node is already spot, so a run now finds no savings (validation: -6.8 %, the cheapest alternative cost more).

Optional (adds up to 13 min): enable the job and watch the savings guard refuse to run it.
```bash
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true -var batch_spot=true -var enable_rebalancing_schedule=true -var rebalancing_job_enabled=true
terraform -chdir=terraform apply tfplan
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-jobs" | jq '.jobs[] | {enabled, status, lastTriggerAt, nextTriggerAt, rebalancingPlanId}'
```
Expected: `{"enabled": true, "status": "JobStatusPending", "lastTriggerAt": null, ...}`. A few minutes after the next 10-minute mark (validation: trigger at :00, ran at 22:02:44): `status "JobStatusFailed"`, `lastTriggerAt` set, and a `rebalancingPlanId`. Show why:
```bash
PID=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-jobs" | jq -r '.jobs[0].rebalancingPlanId')
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans/$PID?includeConfigurations=true" | jq -c '{status, errors, diff: .configurations.diff}'
```
Expected: `status "error"`, `errors [{"reason": "achievedSavingsBelowThreshold", ...}]`, a negative `diff.savingsPercentage` (validation: `-6.8`). The guard worked: no node was touched. "Failed" here means "refused to churn", not a fault.

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
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true
terraform -chdir=terraform apply tfplan
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: namespace deleted, batch node deleted ~2 min later (or `no matching resources found`), `Plan: 0 to add, 0 to change, 3 to destroy.` and `Apply complete! Resources: 0 added, 0 changed, 3 destroyed.` (template, schedule, job), then all six deployments roll out on new spot capacity (~1–3 min). Any leftover non-executed plan simply turns obsolete.

## Q&A prep
- **What makes a pod "problematic"?** Required node affinity on custom labels no template maps, bare pods, Job pods, `removal-disabled` pods, local PVs. Check the **Rebalancer** page, or `curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/problematic-workloads" | jq '{hasProblems, controllers}'`.
- **Does it respect PDBs?** Yes, up to the drain timeout (default 20 min, max 180). Then it forces, unless `evictGracefully`, which keeps the node cordoned with `drain-failed` and uncordons it after a timeout.
- **What if the planned spot type is unavailable at execution?** Alternatives are created; if achieved savings fall below `achievedSavingsPercentage`, new nodes are deleted and the plan fails safe.
- **Can it touch the system node?** Plans can include non-CAST AI nodes if you select them. We select by node ID or by template label, never the whole cluster for execution.
- **Spot-fallback nodes?** Rebalancing ignores `removal-disabled` on spot-fallback nodes on purpose, to avoid staying on expensive fallback capacity.
- **Karpenter equivalent of a schedule?** Disruption budgets with `schedule` + `duration` restrict *when* consolidation may act; there is no savings threshold.
