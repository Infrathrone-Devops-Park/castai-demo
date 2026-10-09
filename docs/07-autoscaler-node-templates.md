# 07 — Autoscaler policies and node templates
**Time:** 30 min · **Goal:** Map Karpenter's NodePool knobs to CAST AI's cluster-wide policies and per-template constraints, and steer one workload onto a second template.

## What you'll show
- The four autoscaler policies: unschedulable pods, node deletion (empty nodes + delay), cluster CPU limit, and why "headroom" is gone in the V2 API.
- Node template constraints: spot / on-demand / fallback, instance families, min/max CPU, burstable, AZs, template CPU limit.
- A second template `batch` (Terraform, `terraform/templates-demo.tf`): on-demand, 2 vCPU, custom labels + taint, CPU limit 4.
- **Partial template matching**: a pod that names only one of the template's two labels stays Pending until the policy is turned on.
- The template CPU limit stopping a scale-up.
- Pod Pinner status, and a side-by-side with NodePool weights and limits.

## Concepts

### Policies (cluster-wide, `castai_autoscaler_policies` V2)
| Policy | Our value | What it does | Karpenter analogue |
|---|---|---|---|
| `enabled` | true | master switch | controller running |
| Unschedulable pods | on, Pod Pinner on | adds nodes for Pending pods, binds pods to the planned node | provisioner + nomination |
| Partial template matching | off (we flip it) | a pod matching **one** of a template's custom labels may use it | none (requirements must all match) |
| Node deletion: empty nodes | on, `60s` | deletes nodes with only DaemonSet pods after the delay | `consolidationPolicy: WhenEmpty` + `consolidateAfter` |
| Cluster CPU limit | max 10 cores | stops scale-up when **all worker** vCPU would exceed it (system node counts) | sum of NodePool `limits.cpu` (per pool) |
| Scoped mode | off | scale-up only for pods tolerating `scheduling.cast.ai/scoped-autoscaler`, scale-down only CAST AI nodes | n/a |
| Headroom | **removed in V2** | was spare capacity per cluster; now use low-priority placeholder pods | same pattern (overprovisioning pods) |

Evictor (bin-packing) is a separate resource since V2; module 08.

### Node template vs NodePool
| Concern | Karpenter NodePool | CAST AI node template |
|---|---|---|
| Machine-level settings | `EC2NodeClass` | node configuration (`default`) |
| Spot / on-demand | `karpenter.sh/capacity-type In [...]` | `spot`, `on_demand` booleans |
| No spot available | falls back to OD instantly if allowed | `use_spot_fallbacks`, returns to spot after `fallback_restore_rate_seconds` (module 10) |
| Families / sizes | requirements on `instance-family`, `instance-cpu` | `instance_families.include/exclude`, `min_cpu`/`max_cpu`, `min_memory`/`max_memory` |
| Burstable `t*` | exclude via category requirement | `burstable_instances = "enabled"/"disabled"` |
| Zones | `topology.kubernetes.io/zone In [...]` | `azs` (intersected with node-configuration subnets) |
| Labels / taints on nodes | `template.metadata.labels`, `taints` | `custom_labels`, `custom_taints` (`should_taint = true`) |
| Size cap | `limits.cpu` per pool | `resource_limits.cpu_limit_max_cores` per template + cluster limit |
| Pool choice | `weight` (highest first), then any compatible pool | explicit `scheduling.cast.ai/node-template: <name>` selector, else custom-label match (most matched terms wins) |
| Preference inside a pool | none (cheapest) | `custom_priority` tiers of families |
| Disruption settings | per pool (`disruption` block, budgets) | cluster-wide (policies + evictor) |

### How a pod picks a template
1. **Explicit**: `nodeSelector`/affinity on `scheduling.cast.ai/node-template: <name>` = direct lookup. Custom labels and partial matching are ignored. Recommended.
2. **Custom labels**: the pod must select **all** of a template's custom labels. With partial matching on, **one** is enough. Several matches: more matched terms first, then (docs) average price per CPU, then name.
3. Otherwise: `default-by-castai`.

### Capacity in this module
| Part | CAST AI vCPU | Quota check |
|---|---|---|
| Lab profile (shop at 1 replica each, `worker` 0 = 2.1 vCPU requested) | ~4 spot (validation: 2× `c8i-flex.large`) | spot 4/8 |
| `batch` template, 2 pods | +2 on-demand | OD 2 + 2 = 4/8, cluster 2 + 4 + 2 = 8/10 |
| CPU-limit test (8 pods) | +2 on-demand more, then blocked | OD 6/8, cluster 10/10 |

## Demo

Panes:
```bash
kubectl get nodes -L provisioner.cast.ai/managed-by,scheduling.cast.ai/node-template,scheduling.cast.ai/spot,node.kubernetes.io/instance-type -w
```
```bash
kubectl get pods -n castai-lab -o wide -w
```

### Step 1 — Environment and start state
Start = end of module 06.
```bash
source scripts/env.sh
CL="$CASTAI_API_URL/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID"
POL="$CASTAI_API_URL/cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies"
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai
kubectl get deploy -n shop
```
Expected: 2–4 CAST AI nodes `Ready` (8 vCPU in total); six `shop` deployments `3/3` or `2/2`.

### Step 2 — Read the policies (API, Terraform, console)
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$POL" | jq
terraform -chdir=terraform state show castai_autoscaler_policies.this | grep -E 'enabled|max_cores|empty_nodes|scoped'
```
Expected JSON (shape):
```json
{"enabled": true, "scopedMode": false, "version": "...",
 "unschedulablePods": {"enabled": true, "partialTemplateMatchingEnabled": false,
   "podPinner": {"enabled": true, "status": "POD_PINNER_STATUS_COMPATIBLE"}},
 "clusterLimits": {"enabled": true, "cpu": {"maxCores": 10}},
 "nodeDownscaler": {"emptyNodesEnabled": true, "emptyNodesDelay": "60s"}}
```
Real output also has `"minCores": 0` under `cpu` and `"version"` as a counter string (`"3"` after module 06; it increments on every write). Terraform shows the same values (`max_cores = 10`, `empty_nodes_delay = "60s"`, `partial_template_matching_enabled = false`). Console (per docs.cast.ai): **Cluster → Autoscaler → Settings**; newer console: **Cluster → Settings → Node autoscaling advanced settings → Scaling policies** (the "CPU limit policy" lives there). Scoped mode is not in the console (API/Terraform only).
Point out there is no `headroom` key: V2 removed it.

### Step 3 — Read the default template
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates?includeDefault=true" | jq '.items[] | {name: .template.name, enabled: .template.isEnabled, stats, c: (.template.constraints | {spot, onDemand, useSpotFallbacks, fallbackRestoreRateSeconds, minCpu, maxCpu, architectures, burstable, azs, resourceLimits})}'
```
`?includeDefault=true` is required: without it the API omits `default-by-castai` and returns nothing.
Expected: one item `default-by-castai`, `enabled true`, stats `{"countOnDemand": 0, "countSpot": 4, "countFallback": 0, "countSoleTenant": 0}` (spot count = CAST AI nodes), constraints `spot true`, `onDemand false`, `useSpotFallbacks true`, `fallbackRestoreRateSeconds 1800`, `minCpu 2`, `maxCpu 4`, `architectures ["amd64"]`, `burstable "NOT_SET"` (we never set it on the default template), `azs []` (all subnets of the node configuration), `resourceLimits {"cpuLimitEnabled": true, "cpuLimitMaxCores": 8}`. Console: **Cluster → Autoscaler → Node templates → default-by-castai** ("Select resource offering", "Instance constraints", "CPU limit").

### Step 4 — Enter the lab profile (free capacity)
`shop` full uses all 8 spot vCPU the template may hold. Scale to zero (empty nodes are deleted after 60 s), then back to one replica each. ~3–4 min.
One CAST AI node usually stays: it hosts `castai-workload-autoscaler-exporter` (1 replica, 500m), which default-mode Evictor will not move. So we wait for "at most one" node, not "none".
```bash
kubectl scale deploy -n shop --all --replicas=0
until [ "$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai --no-headers | wc -l)" -le 1 ]; do sleep 15; done
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
```
Expected: empty CAST AI nodes go `SchedulingDisabled`, then disappear ~2–3 min after the scale-down (60 s delay + drain + termination). Node deletion policy at work: this is Karpenter's `WhenEmpty`. A node that hosts a replica of `castai-pod-mutator` (2 replicas) is drained by the Evictor once it is older than 5 min; the exporter's node stays. The `until` loop returns when one node is left. Then one new spot node (validation: a second `c8i-flex.large`, 2 vCPU) and five `successfully rolled out` lines within ~1 min.

Optional proof of why one node stays:
```bash
kubectl logs -n castai-agent deploy/castai-evictor --since=5m --tail=-1 | grep -o 'reason: single replica[^"]*' | sort -u
```
Expected: `reason: single replica - castai-agent/castai-workload-autoscaler-exporter-...`.

### Step 5 — Create the `batch` template with Terraform
On-demand, exactly 2 vCPU, families c6a/c5a/m6a/m5a, no burstable, labels `workload=batch` + `team=data`, taint `workload=batch:NoSchedule`, template CPU limit 4.
```bash
sed -n '/resource "castai_node_template" "batch"/,/^}/p' terraform/templates-demo.tf
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true
terraform -chdir=terraform apply tfplan
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates" | jq '.items[] | select(.template.name=="batch") | .template | {name, shouldTaint, customLabels, customTaints, c: (.constraints | {spot, onDemand, minCpu, maxCpu, instanceFamilies, resourceLimits})}'
```
Expected: `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.` and output `batch_template_offering = "on-demand"`. API: `customLabels {"team":"data","workload":"batch"}`, `customTaints [{"key":"workload","value":"batch","effect":"NoSchedule"}]`, `onDemand true`, `spot false`, `instanceFamilies {"include":["c6a","c5a","m6a","m5a"]}`, CPU limit 4. Console: the template appears under **Node templates**.

Why a separate `.tf` file behind a flag: reproducible, and modules that do not pass the flag remove it again.

### Step 6 — A pod that selects only half the template
The workload asks for `workload: batch` but not `team: data`.
```bash
grep -A3 nodeSelector manifests/07-node-templates/batch-workload.yaml
kubectl apply -f manifests/07-node-templates/batch-workload.yaml
sleep 60
kubectl get pods -n castai-lab
kubectl get events -n castai-lab --sort-by=.lastTimestamp | tail -5
```
Expected: namespace and deployment created; both pods `Pending` after 60 s; no new node. Events: `FailedScheduling` from the scheduler (`... didn't match Pod's node affinity/selector`) and, from CAST AI, `FailedUpscaling   Impossible to schedule pod, no instance type matches selectors. For example: workload=batch. (Node template: default-by-castai)`. By default a pod must match **all** custom labels of a template; CAST AI falls back to the default template, which cannot produce `workload=batch`.

### Step 7 — Turn on partial template matching
API (read, flip one field, write back with `version` for optimistic locking):
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$POL" | jq -c 'del(.unschedulablePods.podPinner.status) | .unschedulablePods.partialTemplateMatchingEnabled = true' | curl -s -X PATCH -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$POL" | jq '.unschedulablePods'
```
Expected: `{"enabled": true, "partialTemplateMatchingEnabled": true, "podPinner": {...}}`. Console equivalent: **Autoscaler settings → Unscheduled pods policy → Partial node template matching**. Terraform equivalent: `unschedulable_pods { partial_template_matching_enabled = true }` (not changed in `nodes.tf`; Reset flips it back).

Watch the panes:
```bash
kubectl wait pods -n castai-lab -l app=batch --for=condition=Ready --timeout=600s
kubectl get nodes -l scheduling.cast.ai/node-template=batch -L node.kubernetes.io/instance-type,scheduling.cast.ai/on-demand,workload,team
kubectl get node -l scheduling.cast.ai/node-template=batch -o jsonpath='{.items[0].spec.taints}{"\n"}'
```
Expected: `{"enabled": true, "podPinner": {"enabled": true, "status": "POD_PINNER_STATUS_COMPATIBLE"}, "partialTemplateMatchingEnabled": true}`. Then within ~1–2 min (validation: 67 s) one new 2-vCPU on-demand node `c6a.large`, `ON-DEMAND true`, `WORKLOAD batch`, `TEAM data`; taints exactly `[{"effect":"NoSchedule","key":"workload","value":"batch"}]` (no extra template taint). Both pods `condition met`.
Then show what CAST AI decided:
```bash
kubectl get events -n castai-lab --field-selector reason=NodeCreationTriggered
```
Expected: `CAST.AI autoscaler triggered node creation for this pod (node: <uuid>, instance type: c6a.large)`. The event names the instance type, not the template; the node's `NODE-TEMPLATE batch` label above shows the match.

### Step 8 — Template CPU limit stops the scale-up
Template limit is 4 vCPU = two 2-vCPU nodes. 8 pods x 500m need three.
```bash
kubectl scale deploy batch -n castai-lab --replicas=8
sleep 180
kubectl get pods -n castai-lab --no-headers | awk '{print $3}' | sort | uniq -c
kubectl get nodes -l scheduling.cast.ai/node-template=batch
kubectl get events -n castai-lab --sort-by=.lastTimestamp | grep -i -E 'limit|cpu' | tail -3
```
Expected: `2 Pending` and `6 Running` (3 pods of 500m fit per 2-vCPU node), exactly 2 batch nodes, and events like `FailedUpscaling   Node template CPU limit reached. Instance type: c6a.large. (Node template: batch)`. CAST AI retries every ~60 s with the next family (`m6a.large`, `m5a.large`, `c5a.large`), each refused the same way. Cluster CPU (2 + 4 + 4 = 10) is also at its limit; in the validation run the template limit was the one reported.
Karpenter equivalent: NodePool `limits.cpu: 4` leaves pods Pending with `all available instance types exceed limits for nodepool`.
```bash
kubectl scale deploy batch -n castai-lab --replicas=2
```
Expected: 6 pods terminate; ~2 min later one batch node becomes empty and is deleted (60 s policy).

### Step 9 — Pod Pinner
```bash
kubectl get deploy -n castai-agent castai-pod-pinner
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$POL" | jq -r '.unschedulablePods.podPinner.status'
kubectl logs -n castai-agent deploy/castai-pod-pinner --since=15m --tail=-1 | grep -o '"msg":"[^"]*"' | sort | uniq -c
```
Expected: `1/1`, `POD_PINNER_STATUS_COMPATIBLE`, and JSON-log message counts including `received pod pinning actions` (one per planned node), `patching pod` and `pod pinned` (one per pinned `castai-lab`/`shop` pod), `node already exists` (the real node registered before pinning, so no placeholder Node was needed).
Talk track: Pod Pinner uses the `/pods/binding` API so pods land where the autoscaler planned. Not compatible with webhooks that change scheduling fields after pinning (Kyverno, CAST AI pod mutations, sidecar injectors).

### Step 10 — Headroom without a headroom policy
V2 has no headroom field. Use the same trick as with Karpenter: a negative-priority placeholder that real pods preempt. Dry run only (it would cost one spare vCPU).
```bash
kubectl apply --dry-run=server -f manifests/07-node-templates/headroom-placeholder.yaml
```
Expected: `priorityclass.scheduling.k8s.io/castai-lab-headroom created (server dry run)` and `deployment.apps/headroom created (server dry run)`.

## Talking points
- NodePool = "which machines for which pods". CAST AI splits that into **templates** (machines + which pods) and **cluster-wide policies** (when to add/remove). Disruption knobs are cluster-wide, not per pool.
- Pool choice: Karpenter uses `weight`; CAST AI prefers an explicit `scheduling.cast.ai/node-template` selector, otherwise label matching. Use the explicit selector in production; it avoids surprises like Step 6.
- Two limits: template CPU limit (like NodePool `limits.cpu`) and a cluster CPU limit that counts **every** worker, including nodes CAST AI did not create. Karpenter has no cluster-wide cap.
- Empty-node deletion with a delay is the `WhenEmpty` half of Karpenter consolidation. The "underutilized" half is the Evictor (module 08).
- Headroom moved out of the autoscaler; the placeholder-pod pattern works the same on both.
- None of this saves money by itself versus a tuned NodePool. It is control-plane ergonomics: console, API, Terraform, audit log.

## Reset
Back to the module 06 end state (full `shop`, no `batch`, partial matching off).
```bash
source scripts/env.sh
POL="$CASTAI_API_URL/cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies"
kubectl delete ns castai-lab --ignore-not-found
kubectl wait node -l scheduling.cast.ai/node-template=batch --for=delete --timeout=600s
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$POL" | jq -c 'del(.unschedulablePods.podPinner.status) | .unschedulablePods.partialTemplateMatchingEnabled = false' | curl -s -X PATCH -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$POL" | jq '.unschedulablePods.partialTemplateMatchingEnabled'
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true
terraform -chdir=terraform apply tfplan
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: namespace deleted, batch node gone ~2 min later (`condition met`; or `no matching resources found` if already gone), `false`, plan `0 to add, 0 to change, 1 to destroy.` and `Apply complete! Resources: 0 added, 0 changed, 1 destroyed.` (the `batch` template), `deployment.apps/... configured` x6, six `successfully rolled out` lines after CAST AI adds 1–2 spot nodes (validation: one `c6a.xlarge`, ~70 s). Total ~3.5 min.

## Q&A prep
- **Is partial matching risky?** Yes: a pod selecting a common label (for example `team=data`) can land on an unintended template. Prefer the explicit template selector.
- **What if two templates match equally?** More matched terms first, then average price per CPU, then name (documented order). Karpenter: highest `weight`, then any compatible pool.
- **Does changing a template replace existing nodes (like Karpenter drift)?** No automatic drift replacement; use the Rebalancer (module 09). Module 09 Step 4 shows it: the template flips to spot, the running node stays on-demand.
- **Template CPU limit vs quota?** The limit is CAST AI's; AWS quota is separate. Keep the sum of template limits within quota, as we do (8 spot + 4 OD).
- **Can a pod refine instance choice inside a template?** Yes, extra `nodeSelector`/affinity (for example `scheduling.cast.ai/instance-family`) that does not conflict with the template.
- **Why no `t` (burstable) instances?** Sustained load burns CPU credits; "unlimited" surcharges distort $/h. Same rule as the Karpenter NodePool.
- **Why on-demand for `batch`?** It uses the separate on-demand quota, so it cannot starve the spot template. Module 09 flips it to spot.
