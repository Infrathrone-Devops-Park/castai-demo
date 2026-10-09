# 08 — Evictor: bin-packing the running fleet
**Time:** 20 min · **Goal:** Watch the Evictor compact pods off an under-used node so the empty-node policy removes it, and compare it to Karpenter consolidation.

## What you'll show
- Evictor settings from API, Terraform and console: scoped mode on, aggressive off, cycle 60 s, node grace 5 min.
- **Dry-run**: Evictor logs what it would do, nothing moves.
- A protected node (`autoscaling.cast.ai/removal-disabled=true`) that is never drained.
- **Live**: scale `shop` down partially, Evictor drains the other node(s), node deletion removes them.
- PDB respect, and what **aggressive mode** would add.
- Evictor logs: `kubectl logs -n castai-agent deploy/castai-evictor`.

## Concepts

### How the Evictor works
```text
every cycle_interval (60s):
  candidates = nodes older than node_grace_period (5 min)
               scoped_mode: only provisioner.cast.ai/managed-by=cast.ai
               minus nodes with removal-disabled (node, or any pod on it)
  simulate: can all evictable pods of a node fit on the other nodes?
            (no utilization threshold; whole-cluster view)
  yes -> taint evictor.cast.ai/evicting:NoSchedule
         evict pods via Eviction API (PDBs always respected)
         taint evictor.cast.ai/evicted
node now empty -> node deletion policy deletes it (our delay: 60s)
```
The Evictor **never creates nodes**. It only moves pods onto existing free space. Replacing a node with a cheaper one is the Rebalancer (module 09).

### Which pods it may move
| Pod | Default mode | Aggressive mode |
|---|---|---|
| Deployment/ReplicaSet with more than 1 replica | yes | yes |
| Single-replica Deployment | no | yes |
| Job / bare pod | no | yes (Job progress lost) |
| StatefulSet | no, unless `autoscaling.cast.ai/disposable=true` | same as default |
| DaemonSet | never | never |
| `autoscaling.cast.ai/removal-disabled=true` (pod or node) | never | never |
| Blocked by PDB | never (unless `ignore_pod_disruption_budgets`) | never |

### Modes (`castai_evictor`)
| Field | Our value | Meaning |
|---|---|---|
| `scoped_mode` | true | only CAST AI nodes; the system node is out of scope |
| `aggressive_mode` | false | add single-replica pods and Jobs ("not advised" for production by the vendor) |
| `dry_run` | false | log decisions only |
| `cycle_interval` / `node_grace_period_minutes` | 60s / 5 | loop period / minimum node age |

### Evictor vs Karpenter consolidation
| | Karpenter `WhenEmptyOrUnderutilized` | CAST AI Evictor + node deletion |
|---|---|---|
| Delete a node whose pods fit elsewhere | yes | yes |
| Replace with one cheaper node | yes (OD; spot only with `SpotToSpotConsolidation`) | no; Rebalancer does that |
| Single-replica pods | moved (unless PDB / `do-not-disrupt`) | only in aggressive mode |
| Opt-out | `karpenter.sh/do-not-disrupt` | `autoscaling.cast.ai/removal-disabled` |
| Stability timer | `consolidateAfter` | `node_grace_period_minutes` (node age) |
| Rate limiting | disruption budgets | `max_target_nodes_per_cycle`, cycle interval |
| Dry run | no | yes |
| Live migration | no | yes, with CLM (disabled here) |

Capacity: this module only removes nodes. Peak = module 06 state (≤ 8 spot vCPU).

## Demo

Panes:
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,autoscaling.cast.ai/removal-disabled -w
```
```bash
kubectl logs -n castai-agent deploy/castai-evictor -f --since=1m
```

### Step 1 — Environment and start state
Start = end of module 06 (full `shop`, 2–3 CAST AI spot nodes).
```bash
source scripts/env.sh
EV="$CASTAI_API_URL/workload-eviction/v1/clusters/$CASTAI_CLUSTER_ID/config"
kubectl get pods -n shop -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --sort-by=.spec.nodeName
```
Expected: 13 pods spread over 2–4 nodes (8 vCPU in total). The default scheduler spreads replicas of one Deployment across nodes, so most nodes host a mix.

### Step 2 — Evictor configuration (API, Terraform, Helm, console)
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EV" | jq '{enabled, dryRun, aggressiveMode, scopedMode, cycleInterval, nodeGracePeriodMinutes, ignorePodDisruptionBudgets, status}'
terraform -chdir=terraform state show castai_evictor.this | grep -E 'dry_run|aggressive|scoped|cycle|grace'
kubectl get deploy -n castai-agent castai-evictor
```
Expected: `{"enabled": true, "dryRun": false, "aggressiveMode": false, "scopedMode": true, "cycleInterval": "60s", "nodeGracePeriodMinutes": 5, "ignorePodDisruptionBudgets": false, "status": "EVICTOR_STATUS_COMPATIBLE"}`; Terraform matches (`aggressive_mode = false`, `cycle_interval = "60s"`, `dry_run = false`, `node_grace_period_minutes = 5`, `scoped_mode = true`, plus `max/min_target_nodes_per_cycle = 0`); deployment `1/1` on the system node. `status` must be Compatible or the policy is not synced into the chart. Console (per docs.cast.ai): **Autoscaler settings → Node deletion policy → Evictor**, with an aggressive-mode option. Dry run and scoped mode are Helm/API/Terraform only.

### Step 3 — Dry-run on
Read the config, flip one field, write the full object back.
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EV" | jq -c 'del(.status) | .dryRun = true' | curl -s -X PATCH -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$EV" | jq '{dryRun, aggressiveMode, scopedMode}'
```
Expected: `{"dryRun": true, "aggressiveMode": false, "scopedMode": true}`. The cluster-controller rolls the `castai-evictor` Deployment: a new evictor pod (new ReplicaSet hash) starts ~10–15 s later, and its log shows `DryRun=true` in `resolved config settings for the cycle`. Every config change restarts the pod, so older log lines are in the previous pod.
Note: Terraform state still says `dry_run = false`; Step 7 puts the API back to that value.

### Step 4 — Make room: scale `shop` down partially
Remove 3.4 vCPU of requests; the rest (2.6 vCPU) is all multi-replica, so default mode may move it.
```bash
kubectl scale deploy -n shop worker checkout catalog --replicas=0
kubectl get deploy -n shop
```
Expected: `worker`, `checkout`, `catalog` at `0/0`; `frontend 3/3`, `cart 2/2`, `payments 2/2`. If a node happens to become completely empty, the node deletion policy removes it within ~2 min. That is not the Evictor; point it out if it happens.

### Step 5 — Protect the biggest node
We choose which node survives so the outcome is predictable.
```bash
KEEP=$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -o json | jq -r '.items | sort_by(-(.status.capacity.cpu|tonumber), .metadata.name) | .[0].metadata.name')
echo "$KEEP"
kubectl annotate node "$KEEP" autoscaling.cast.ai/removal-disabled=true
kubectl label node "$KEEP" autoscaling.cast.ai/removal-disabled=true
```
Expected: the node name (the 4-vCPU node if there is one, else the first 2-vCPU node by name), `node/... annotated`, `node/... labeled`. Docs accept the annotation or the label; we set both so the watch pane shows it. Karpenter equivalent: `karpenter.sh/do-not-disrupt: "true"` on the Node.

### Step 6 — Dry-run output
Wait two cycles, then read what it would do.
```bash
sleep 120
kubectl logs -n castai-agent deploy/castai-evictor --since=3m --tail=-1 | grep -E 'drainable nodes|dry run is enabled|eliminated by filters' | cut -c1-220 | tail -8
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai
```
Expected (validation run): `msg="processing drainable nodes" ... nodes="[ip-10-0-42-181...]"` and `msg="dry run is enabled, operation is NOOP" ... node_name=ip-10-0-42-181...`, plus the filter verdicts for the others: `#1 node - <system node> eliminated by filters, reason: not managed by CAST AI`, `... <KEEP> ... reason: marked with removal disabled`, and for the node running the WA exporter `reason: single replica - castai-agent/castai-workload-autoscaler-exporter-...`. No eviction; node list unchanged.

### Step 7 — Dry-run off: real compaction
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EV" | jq -c 'del(.status) | .dryRun = false' | curl -s -X PATCH -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$EV" | jq '{dryRun}'
T0=$(date -u +%s)
```
Expected: `{"dryRun": false}`. Then, in the panes (validation run, times after the PATCH):
1. ~+15 s the evictor pod restarts with the new config; ~+80 s the candidate node goes `SchedulingDisabled` and its `shop` pods (`cart`, `frontend`, `payments` replicas) are evicted and start again within seconds on `$KEEP` and the exporter's node.
2. The node is empty and goes away; Kubernetes events on it: `NodeNotSchedulable`, `Shutdown`, then `DeletingNode ... because it does not exist in the cloud provider`. Gone at ~+2.5–3 min.
3. The node hosting the WA exporter stays (single replica).

### Step 8 — Verify the result
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type
kubectl get pods -n shop --no-headers -o custom-columns=NODE:.spec.nodeName | sort | uniq -c
kubectl logs -n castai-agent deploy/castai-evictor --since=10m --tail=-1 | grep -E 'started evicting pods|drainable nodes|eliminated by filters' | cut -c1-220 | tail -8
```
Expected (validation run): two CAST AI nodes remain: `$KEEP` (`c6a.xlarge`, 4 pods) and the exporter's `c8i-flex.large` (3 pods). If the exporter happens to sit on `$KEEP` or on the system node, only `$KEEP` remains with all 7 pods. `$KEEP` is never drained. Logs: `started evicting pods from a node ... node_name=<drained node>`, then later cycles show `reason: already drained`, `reason: marked with removal disabled`, `reason: single replica - ...exporter...` and `couldn't find any nodes to drain`.

Same check from the API (node count and fleet price). The node list has no price (`spotConfig.price` is empty); the cost report summary has it:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/cost-reports/clusters/$CASTAI_CLUSTER_ID/summary" | jq '.summary | {nodeCountSpotCastai, costHourlySpot, costHourlyOnDemand}'
```
Expected (validation run): `{"nodeCountSpotCastai": "2", "costHourlySpot": "0.065560", "costHourlyOnDemand": "0.049340"}` (strings). Spot = `c8i-flex.large` 0.0163 + `c6a.xlarge` 0.0493; on-demand = the system node. Before compaction it was one more `c8i-flex.large` (+0.0163/h). The summary refreshes every few minutes.

### Step 9 — PDBs are respected
A PDB that allows zero disruptions for `payments` (2 replicas, `minAvailable: 2`).
```bash
kubectl apply -f manifests/08-evictor/pdb-payments.yaml
kubectl get pdb -n shop payments
```
Expected: `ALLOWED DISRUPTIONS 0`. The Evictor uses the Eviction API, so it can never move a `payments` pod now; any node hosting one is skipped. `ignore_pod_disruption_budgets = true` would override that; we keep it `false`. Karpenter behaves the same (drains via Eviction API; `DisruptionBlocked` event "Pdb prevents pod evictions").

### Step 10 — Aggressive mode (explain, do not enable)
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EV" | jq -c 'del(.status) | .aggressiveMode = true' | jq '{aggressiveMode, scopedMode, dryRun}'
```
Expected: the body we **would** PATCH: `{"aggressiveMode": true, "scopedMode": true, "dryRun": false}`. Not sent. With it on, single-replica pods (for example `catalog` at 1 replica) and Job pods would also be moved, causing a restart of a non-redundant service. Terraform: `aggressive_mode = true` in `castai_evictor`. Console: Evictor → Aggressive mode.

## Talking points
- Evictor + node deletion is CAST AI's answer to `WhenEmptyOrUnderutilized`: compact, then delete empties. It never launches a replacement, so it can never temporarily exceed quota.
- Default mode is more conservative than Karpenter: single-replica pods are left alone unless you opt in. Karpenter moves them unless you block it.
- Dry-run is a genuine operational advantage: see the plan before you trust it. Karpenter has events after the fact.
- Protection is one label/annotation: `autoscaling.cast.ai/removal-disabled=true` on the node or the pod.
- PDBs are always respected by both tools. Write good PDBs before turning either loose.
- Cost effect here: one fewer node. Same as Karpenter consolidation would achieve. No new magic; parity.

## Reset
Back to the module 06 end state.
```bash
source scripts/env.sh
kubectl delete -f manifests/08-evictor/pdb-payments.yaml --ignore-not-found
for n in $(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -o name); do kubectl annotate "$n" autoscaling.cast.ai/removal-disabled-; kubectl label "$n" autoscaling.cast.ai/removal-disabled-; done
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true
terraform -chdir=terraform apply tfplan
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/workload-eviction/v1/clusters/$CASTAI_CLUSTER_ID/config" | jq '{dryRun, aggressiveMode, scopedMode}'
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
```
Expected: PDB deleted; per node `annotated` and `unlabeled` (or `label "autoscaling.cast.ai/removal-disabled" not found.` / `not labeled`: harmless); `No changes.` and `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` if Step 7 restored `dryRun=false` (1 changed if drift remained); evictor `{"dryRun": false, "aggressiveMode": false, "scopedMode": true}`; `catalog`, `checkout`, `worker` `configured`, then CAST AI adds one spot node and all six deployments roll out (validation: ~70 s).

## Q&A prep
- **Does the Evictor use utilization thresholds?** No. It simulates whether all evictable pods of a node fit elsewhere; even a busy node may be drained if that packs better.
- **Can it drain the system node?** Not with scoped mode (only `managed-by=cast.ai` nodes). Without scoped mode it could, which is why we set it in both Terraform and Helm.
- **Why did my node not get drained?** Younger than 5 min, a single-replica/Job/StatefulSet pod on it (default mode), a PDB at 0, `removal-disabled`, or the pods do not fit elsewhere.
- **What about Karpenter's `Balanced` policy?** No direct equivalent. The Evictor's knobs are mode (default/aggressive), rate (`max_target_nodes_per_cycle`), and pricing awareness (`pricing_awareness_enabled`, newer field).
- **Does it restart pods?** Yes, eviction = restart elsewhere. Only Container Live Migration (not enabled here; AL2023 + containerd v2 required) moves a running container without restart.
- **Can I run the Evictor next to Karpenter?** The docs describe Evictor alongside OSS Karpenter (with NodeClaim cleanup), but we do not; one autoscaler at a time is the rule of this course.
