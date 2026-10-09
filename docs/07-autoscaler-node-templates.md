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
| Lab profile (shop at 1 replica each, `worker` 0 = 2.1 vCPU requested) | ~4 spot | spot 4/8 |
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
Expected: 2–3 CAST AI nodes `Ready`; six `shop` deployments `3/3` or `2/2`.

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
Terraform shows the same values (`max_cores = 10`, `empty_nodes_delay = "60s"`). Console: **Cluster → Autoscaler → Settings** (newer console: **Cluster → Settings → Node autoscaling advanced settings → Scaling policies**). <!-- VERIFY: console path in this org -->
Point out there is no `headroom` key: V2 removed it.

### Step 3 — Read the default template
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates" | jq '.items[] | {name: .template.name, enabled: .template.isEnabled, stats, c: (.template.constraints | {spot, onDemand, useSpotFallbacks, fallbackRestoreRateSeconds, minCpu, maxCpu, architectures, burstable, azs, resourceLimits})}'
```
Expected: one item `default-by-castai`, `enabled true`, stats `countSpot` 2–3, constraints `spot true`, `onDemand false`, `useSpotFallbacks true`, `fallbackRestoreRateSeconds 1800`, `minCpu 2`, `maxCpu 4`, `architectures ["amd64"]`, `resourceLimits {"cpuLimitEnabled": true, "cpuLimitMaxCores": 8}`. Console: **Cluster → Autoscaler → Node templates → default-by-castai** ("Select resource offering", "Instance constraints", "CPU limit"). <!-- VERIFY: burstable field shape -->

### Step 4 — Enter the lab profile (free capacity)
`shop` full uses all 8 spot vCPU the template may hold. Scale to zero (empty nodes are deleted after 60 s), then back to one replica each. Deterministic, ~4 min.
```bash
kubectl scale deploy -n shop --all --replicas=0
kubectl wait node -l provisioner.cast.ai/managed-by=cast.ai --for=delete --timeout=600s
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
```
Expected: all CAST AI nodes deleted ~1.5–2.5 min after the scale-down (60 s delay + termination). Node deletion policy at work: this is Karpenter's `WhenEmpty`. Then one new spot node (usually 4 vCPU; two 2-vCPU nodes also possible) and five `successfully rolled out` lines within ~2–4 min.

### Step 5 — Create the `batch` template with Terraform
On-demand, exactly 2 vCPU, families c6a/c5a/m6a/m5a, no burstable, labels `workload=batch` + `team=data`, taint `workload=batch:NoSchedule`, template CPU limit 4.
```bash
sed -n '/resource "castai_node_template" "batch"/,/^}/p' terraform/templates-demo.tf
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true -var enable_batch_template=true
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
Expected: namespace and deployment created; both pods `Pending` after 60 s; events `FailedScheduling` (node selector mismatch) and no new node. By default a pod must match **all** custom labels of a template, and no template can produce `workload=batch` alone. <!-- VERIFY: whether CAST AI emits an explicit "no matching node template" event -->

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
Expected: within ~2–3 min one new 2-vCPU on-demand node (for example `c6a.large` / `c5a.large`), `ON-DEMAND true`, `WORKLOAD batch`, `TEAM data`; taints include `{"effect":"NoSchedule","key":"workload","value":"batch"}`. Both pods `condition met`. <!-- VERIFY: whether the default node-template taint is added next to the custom one -->
Then show why it chose `batch`:
```bash
kubectl get events -n castai-lab --sort-by=.lastTimestamp | grep -i -E 'template|unschedul|cast' | tail -3
```
Expected: an "Unscheduled Pods Policy Applied" style event naming the matched template. <!-- VERIFY: event reason text -->

### Step 8 — Template CPU limit stops the scale-up
Template limit is 4 vCPU = two 2-vCPU nodes. 8 pods x 500m need three.
```bash
kubectl scale deploy batch -n castai-lab --replicas=8
sleep 180
kubectl get pods -n castai-lab --no-headers | awk '{print $3}' | sort | uniq -c
kubectl get nodes -l scheduling.cast.ai/node-template=batch
kubectl get events -n castai-lab --sort-by=.lastTimestamp | grep -i -E 'limit|cpu' | tail -3
```
Expected: `6 Running` and `2 Pending` (3 pods of 500m fit per 2-vCPU node), exactly 2 batch nodes, and an event saying autoscaling failed because of the node template CPU limit. Cluster CPU (2 + 4 + 4 = 10) is also at its limit, so the message may name the cluster limit instead; both are guard rails doing their job. <!-- VERIFY: exact message -->
Karpenter equivalent: NodePool `limits.cpu: 4` leaves pods Pending with `all available instance types exceed limits for nodepool`.
```bash
kubectl scale deploy batch -n castai-lab --replicas=2
```
Expected: 6 pods terminate; within ~2 min one batch node becomes empty and is deleted (60 s policy).

### Step 9 — Pod Pinner
```bash
kubectl get deploy -n castai-agent castai-pod-pinner
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$POL" | jq -r '.unschedulablePods.podPinner.status'
kubectl logs -n castai-agent deploy/castai-pod-pinner --since=15m | grep -i -E 'pin|bind' | tail -5
```
Expected: `1/1`, `POD_PINNER_STATUS_COMPATIBLE`, and log lines about pinning/binding the `castai-lab` and `shop` pods to planned nodes. <!-- VERIFY: log wording -->
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
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: namespace deleted, batch nodes gone (or `no matching resources found` if already gone), `false`, `Apply complete! Resources: 0 added, 0 changed, 1 destroyed.` (the `batch` template), six `successfully rolled out` lines after CAST AI adds 1–2 spot nodes (~3 min).

## Q&A prep
- **Is partial matching risky?** Yes: a pod selecting a common label (for example `team=data`) can land on an unintended template. Prefer the explicit template selector.
- **What if two templates match equally?** More matched terms first, then average price per CPU, then name (documented order). Karpenter: highest `weight`, then any compatible pool.
- **Does changing a template replace existing nodes (like Karpenter drift)?** No automatic drift replacement; use the Rebalancer (module 09). <!-- VERIFY -->
- **Template CPU limit vs quota?** The limit is CAST AI's; AWS quota is separate. Keep the sum of template limits within quota, as we do (8 spot + 4 OD).
- **Can a pod refine instance choice inside a template?** Yes, extra `nodeSelector`/affinity (for example `scheduling.cast.ai/instance-family`) that does not conflict with the template.
- **Why no `t` (burstable) instances?** Sustained load burns CPU credits; "unlimited" surcharges distort $/h. Same rule as the Karpenter NodePool.
- **Why on-demand for `batch`?** It uses the separate on-demand quota, so it cannot starve the spot template. Module 09 flips it to spot.
