# 10 — Spot: fallback, interruptions, prediction
**Time:** 25 min · **Goal:** Show how CAST AI keeps a spot-only template running (fallback and return to spot), handle a real AWS spot interruption on a CAST AI node, and compare with Karpenter's SQS-driven handling from karpenter-demo module 10.

## What you'll show
- The spot settings of `default-by-castai`: spot only, spot fallback on, `fallback_restore_rate_seconds = 1800`, prediction / reliability / diversity off.
- How fallback nodes are recognised, and why we do not force one live on this quota.
- `castai-spot-handler`: what it does and does not do.
- **Demo A (real):** an AWS FIS experiment sends a 2-minute interruption notice to one CAST AI spot node (FIS role `karpenter-demo-fis-spot`, target tag `castai-demo=managed`). Watch CAST AI label, drain and replace it.
- **Demo B (optional):** the CAST AI API simulates an interruption **prediction**; the node is replaced create-before-drain.
- Side-by-side with Karpenter.

## Concepts

### Spot settings on a node template
| Knob (Terraform `constraints`) | Ours | Effect |
|---|---|---|
| `spot` / `on_demand` | true / false | spot-only template: every node is spot, no pod toleration needed |
| `use_spot_fallbacks` | true | if no spot can be bought, create a temporary on-demand node labelled `scheduling.cast.ai/spot-fallback=true` |
| `fallback_restore_rate_seconds` | 1800 | how often CAST AI checks spot inventory and replaces fallback nodes with spot ("fall-forward") |
| `spot_interruption_predictions_enabled` | false | ML model predicts interruptions (AWS horizon ~1 h, docs vary), cordons and rebalances the node early; replacement first |
| `spot_reliability_enabled` + `..._price_increase_limit_percent` | off | prefer spot types with longer expected runtime, pay up to N % more |
| `enable_spot_diversity` + `spot_diversity_price_increase_limit_percent` | off | spread over more types; **being deprecated** in favour of reliability |

All of these are part of the CAST AI Node Autoscaler, a Premium feature. On this org (`billingType: "none"` from `GET /v1/organizations/<id>`) enabling the autoscaler was accepted without any billing prompt; check **Settings → Platform usage** in the console for the plan shown to you.

### Who reacts to an interruption
```text
 AWS (2-min notice via IMDS + EventBridge)
   |
   v
 castai-spot-handler (DaemonSet, hostNetwork, spot nodes only)
   polls IMDS every 3 s, reports to CAST AI
   ("pod deletion is disabled, will not delete pods")
   |
   v
 CAST AI platform -> cluster-controller   (validation run)
   +0 s   cordon, label autoscaling.cast.ai/draining=spot-interruption,
          taint autoscaling.cast.ai/draining=true:NoSchedule
   +15 s  drain: pods evicted, go Pending
          autoscaler: replacement node (other type/AZ)
   +28 s  CAST AI terminates the old instance itself
   +33 s  replacement registers; pods Running ~20 s later
 AWS would have reclaimed it at T+2 min; CAST AI was first
```

### Karpenter (module 10 of karpenter-demo) vs CAST AI
| | Karpenter v1.14 | CAST AI |
|---|---|---|
| Signal path | EventBridge → SQS → controller (no node agent) | spot-handler DaemonSet on each spot node → SaaS |
| On 2-min warning | CordonAndDrain + replacement NodeClaim in parallel (~1 s) | cordon/taint at +16 s, drain at +30 s, replacement after, own termination at +43 s |
| Rebalance recommendation | event only | AWS RR mode deprecated 2026-07-08 |
| Early warning | none | ML interruption prediction (Premium), create-before-drain |
| Offering just interrupted | avoided 3 min (unavailable-offerings cache) | type cooled off, other AZs preferred |
| No spot at all | falls back to OD if pool allows, instantly | spot fallback node, returns to spot after restore interval |
| Back to spot later | only if consolidation finds a cheaper spot replacement | periodic fall-forward |
| Budgets / do-not-disrupt | ignored for interruptions | prediction rebalancing respects PDBs; real reclaim does not wait |

### Capacity
Lab profile: one default spot node (~4 vCPU). During Demo A or B: old + replacement = ~8 spot vCPU, exactly the quota. A fallback on-demand node would be 4 OD vCPU (2 + 4 = 6 ≤ 8) and cluster cores 2 + 4 + 4 = 10. Never run this module with full `shop`.

## Demo

Panes:
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,scheduling.cast.ai/spot,scheduling.cast.ai/spot-fallback,autoscaling.cast.ai/draining,scheduling.cast.ai/interrupted -w
```
```bash
kubectl get pods -n shop -o wide -w
```

### Step 1 — Environment and lab profile
Start = end of module 06. Shrink to two small spot nodes so a replacement fits the quota (~4–6 min; one node stays for the WA exporter).
```bash
source scripts/env.sh
CL="$CASTAI_API_URL/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID"
EXT="$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID"
kubectl scale deploy -n shop --all --replicas=0
until [ "$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai --no-headers | wc -l)" -le 1 ]; do sleep 15; done
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai
```
Expected: nodes deleted down to one (validation: 5.4 min), then one new spot node; five `successfully rolled out`; two CAST AI nodes (validation: 2× `c8i-flex.large`, 4 spot vCPU). Demo A then needs +2 spot vCPU (6/8).

### Step 2 — Spot settings of the default template (Terraform, API, console)
```bash
terraform -chdir=terraform state show castai_node_template.default | grep -E 'spot|on_demand|fallback'
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates?includeDefault=true" | jq '.items[] | select(.template.name=="default-by-castai") | {stats, c: (.template.constraints | {spot, onDemand, useSpotFallbacks, fallbackRestoreRateSeconds, spotInterruptionPredictionsEnabled, enableSpotReliability, enableSpotDiversity})}'
```
Expected: Terraform `spot = true`, `on_demand = false`, `use_spot_fallbacks = true`, `fallback_restore_rate_seconds = 1800`, plus `enable_spot_diversity = false`, `spot_interruption_predictions_enabled = false`, `spot_reliability_enabled = false` and their `..._percent = 0` (the grep matches them too). API (needs `?includeDefault=true`): same plus `spotInterruptionPredictionsEnabled false`, `enableSpotReliability false`, `enableSpotDiversity false`; `stats.countSpot` 2, `countFallback 0`. Console: **Node templates → default-by-castai → Select resource offering**: Spot, "Use spot fallback" with interval, "Interruption prediction model", "Spot reliability".

### Step 3 — Fallback: how to see it, and why we do not force it
```bash
kubectl get nodes -l scheduling.cast.ai/spot-fallback=true
```
Expected: `No resources found`. Forcing a fallback needs spot to be unbuyable. The only reliable lever here is the 8-vCPU spot quota, and breaking it would also break the cluster CPU limit (2 system + 8 spot + 4 fallback = 14 > 10) and leave pods Pending. So: explain, do not run. What you would see: an on-demand node with `scheduling.cast.ai/spot-fallback=true`, `stats.countFallback 1`, and after `fallback_restore_rate_seconds` a rebalancing replacement back to spot (rebalancing ignores `removal-disabled` on fallback nodes on purpose).

Seen during validation (by accident, after a test left one spot instance running outside the cluster): the next scale-up hit `Max spot instance count exceeded`. Within ~40 s CAST AI blacklisted the spot families for 2 min (audit `addBlacklistExecuted`, reason `quota exceeded: creating vm: Max spot instance count exceeded`) and launched an on-demand `c6a.xlarge` with labels `scheduling.cast.ai/spot-fallback=true` and `eks.amazonaws.com/capacityType=ON_DEMAND`. No pod stayed Pending longer than ~1 min. To move it back without waiting 30 min, run a rebalancing plan for that node (module 09 Step 7 with the fallback node's ID): validation plan `diff.savingsPercentage 44.6`, green `c6a.xlarge` spot, finished in ~2.5 min. Generate the plan after the 2-min blacklist expires; earlier, green proposed an odd spot type (`inf1.xlarge`) because the usual families were blocked.

### Step 4 — The spot-handler
```bash
kubectl get ds -n castai-agent
NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=default-by-castai -o jsonpath='{.items[0].metadata.name}')
SH=$(kubectl get pods -n castai-agent --field-selector spec.nodeName="$NODE" -o name | grep spot-handler)
echo "$NODE $SH"
kubectl logs -n castai-agent "$SH" --tail=5
```
Expected: one DaemonSet `castai-spot-handler`, `DESIRED 2` (spot nodes only, not the system node), the node name, `pod/castai-spot-handler-xxxxx`, and five JSON debug lines `"msg":"poll tick completed"` 3 s apart (`spot-handler/v0.35.10`). It polls instance metadata over `hostNetwork`; it only **reports**.

### Step 5 — Demo A: pick the instance and check the tag
```bash
IID=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}'); IID=${IID##*/}
aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Lifecycle:InstanceLifecycle,AZ:Placement.AvailabilityZone,Tag:Tags[?Key==`castai-demo`]|[0].Value}' --output table
kubectl get pods -n shop -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```
Expected: `Lifecycle spot`, `Tag managed`, the instance type and AZ (note them; validation: `c8i-flex.large`, `ap-south-1c`). The five `shop` pods are spread over the two nodes (validation: `checkout` and `payments` on `$NODE`).

### Step 6 — Demo A: create the FIS template
Same action as karpenter-demo module 10; target = spot instances tagged `castai-demo=managed`, narrowed to `$IID`. Role from the sibling Terraform state.
```bash
FIS_ROLE_ARN=$(terraform -chdir="$KARPENTER_DEMO_DIR/terraform" output -raw fis_role_arn)
echo "$FIS_ROLE_ARN"
TEMPLATE_ID=$(aws fis create-experiment-template --cli-input-json "$(jq --arg role "$FIS_ROLE_ARN" --arg id "$IID" '.roleArn = $role | .targets.castaiSpot.filters[1].values = [$id]' manifests/10-spot/fis-castai-spot-template.json)" --query 'experimentTemplate.id' --output text)
echo "$TEMPLATE_ID"
```
Expected: `arn:aws:iam::146725924014:role/karpenter-demo-fis-spot` and a template ID like `EXT...`. If the sibling state is unavailable: `aws iam get-role --role-name karpenter-demo-fis-spot --query Role.Arn --output text`. The role's managed policy `AWSFaultInjectionSimulatorEC2Access` is not tag-scoped, so it also works on CAST AI instances. The `InstanceId` filter path is accepted (template targets show `"path": "InstanceId", "values": ["i-..."]`).

### Step 7 — Demo A: start the interruption
```bash
EXPERIMENT_ID=$(aws fis start-experiment --experiment-template-id "$TEMPLATE_ID" --tags Name=castai-spot-demo --query 'experiment.id' --output text)
T0=$(date -u +%s)
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state.status' --output text
```
Expected: `initiating` or `running`. FIS sends a rebalance recommendation and the 2-minute interruption warning to `$IID`.

### Step 8 — Demo A: watch CAST AI react
Grab the handler's view before the node disappears (it is gone from EC2 at ~T+45 s), then watch the panes.
```bash
sleep 25
kubectl logs -n castai-agent "$SH" --since=2m | grep -o '"msg":"[^"]*"' | grep -v 'poll tick'
kubectl get node "$NODE" -o json | jq '{labels: (.metadata.labels | with_entries(select(.key | test("draining|interrupted")))), taints: .spec.taints}'
```
Expected: handler messages `preemption notice received`, `sending interruption cloud event to mothership`, `pod deletion is disabled, will not delete pods from node`, `rebalance recommendation notice received`, `sending rebalance recommendation cloud event to mothership` (all at ~T+16 s). On the node: label `autoscaling.cast.ai/draining: "spot-interruption"` (no `interrupted` label in our run), taints `autoscaling.cast.ai/draining=true:NoSchedule` and `node.kubernetes.io/unschedulable` (cordoned). In the panes (validation run, after `T0`):
- +16 s node `SchedulingDisabled`, `DRAINING spot-interruption`
- +30 s its `shop` pods are evicted and go `Pending`; a `NodeCreationTriggered` event names a different type (validation: `c6a.large` in `ap-south-1a`; the interrupted `c8i-flex.large` in `1c` is blocked for 4 h)
- +43 s old node `NotReady`: CAST AI terminated the instance itself, well before AWS's T+2 min
- +44 s Pod Pinner binds the Pending pods to the planned node name `aws-<node-id>` before it exists; they are replaced by fresh pods when the real node registers
- +49 s replacement node registers; +67 s all pods `Running`
Pods move **before** the reclaim, but they are not replacement-first: there is a ~35 s gap for single-replica Deployments.

### Step 9 — Demo A: evidence
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl get pods -n shop -o json | jq -r --argjson t0 "$T0" '[.items[].status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime | fromdateiso8601] | "shop pods Ready again by +\(max - $t0)s"'
aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[].Instances[].[State.Name,StateReason.Code]' --output text
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state' --output json
```
Expected (validation run): two CAST AI spot nodes, one with a new name (`c6a.large`, `ap-south-1a`); `shop pods Ready again by +67s` (Karpenter's validation run: pods Running ~33 s after the warning); old instance `terminated   Client.UserInitiatedShutdown` (CAST AI deleted it first; `Server.SpotInstanceTermination` would mean AWS reclaimed it); FIS `{"status": "completed", "reason": "Experiment completed."}`.
Console: **Cluster → Audit log**. Same from the API:
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/audit?clusterId=$CASTAI_CLUSTER_ID&page.limit=15" | jq -r '.items[] | "\(.time)  \(.eventType)"'
```
Expected (newest first): `nodeDeleted`, `nodeAdded`, `autoscalerExecuted` (x2), `addBlacklistExecuted` (the interrupted type+AZ, blocked for 4 h), `nodeInterrupted` at ~T+16 s.

### Step 10 — Demo B (optional): simulate an interruption prediction
The API publishes a simulated **prediction** for one node: the node is annotated with a TTL and a rebalancing plan starts automatically (replacement first, then drain). This is the Premium early-warning path you cannot trigger with FIS. Capacity: one extra ~4 vCPU spot node.
```bash
NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=default-by-castai -o jsonpath='{.items[0].metadata.name}')
NID=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EXT/nodes" | jq -r --arg n "$NODE" '.items[] | select(.name==$n) | .id')
jq -n --arg id "$NID" '{nodeId: $id}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/simulate-spot-interruption"
sleep 60
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans?limit=3" | jq -r '.items[] | [.rebalancingPlanId, .status, .createdAt] | @tsv'
```
Expected with our template (`spot_interruption_predictions_enabled = false`): `{}` (HTTP 200), **no new plan** (the list still shows the module 09 plans), no replacement. The only effect is two node annotations:
```bash
kubectl get node "$NODE" -o json | jq '.metadata.annotations | with_entries(select(.key | startswith("predictions.cast.ai")))'
```
Expected: `{"predictions.cast.ai/remove-after": "<now + ~60 s>", "predictions.cast.ai/simulated": "true"}`. Nothing happens after that time either (checked for 3 min). That is the honest point: prediction handling is opt-in per template. With it enabled you would expect a rebalancing plan, label `autoscaling.cast.ai/draining=spot-prediction`, and the replacement Ready before the drain (vendor docs; not run here because enabling it needs a template change and +2–4 spot vCPU).
Clean up the annotations:
```bash
kubectl annotate node "$NODE" predictions.cast.ai/remove-after- predictions.cast.ai/simulated-
```

### Step 11 — Clean up the FIS template
```bash
aws fis delete-experiment-template --id "$TEMPLATE_ID" --query 'experimentTemplate.id' --output text
```
Expected: the template ID echoed back.

## Talking points
- Both tools get the same 2-minute AWS warning. Karpenter launches the replacement in parallel with the drain; in our CAST AI run the drain came first and the replacement Ready ~35 s later (pods back at +67 s vs ~33 s for Karpenter). On a reclaim the difference is plumbing and ordering; neither waits for AWS.
- CAST AI's extras are **before** and **after** the reclaim: ML prediction (move early, replacement first) and deterministic fall-forward from on-demand fallback back to spot.
- Karpenter is just as good at "no spot → on-demand now". It is weaker at "spot is back → leave on-demand", which only happens if consolidation finds a cheaper spot replacement.
- Spot-handler only reports. If it cannot run on a node (taint, crash), that node's warning is not seen early; keep it tolerant. Karpenter's queue has no per-node dependency.
- Prediction claims (lead time, accuracy) are vendor-stated and inconsistent across docs (1 h for AWS in one page, 180 min in another). Do not promise numbers; Demo B shows the mechanism, not the model.
- Spot still needs: more than one replica, PDBs, short `terminationGracePeriodSeconds`, diverse instance families.

## Reset
Back to the module 06 end state.
```bash
source scripts/env.sh
for id in $(aws fis list-experiment-templates --query "experimentTemplates[?tags.Name=='castai-spot-demo'].id" --output text); do aws fis delete-experiment-template --id "$id" --query 'experimentTemplate.id' --output text; done
kubectl apply -f workloads/shop.yaml
for d in frontend cart catalog checkout payments worker; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L scheduling.cast.ai/spot,scheduling.cast.ai/spot-fallback
```
Expected: no FIS templates left (no output if Step 11 ran), `configured` for the six deployments, six `successfully rolled out` within ~1–3 min, 3–4 CAST AI nodes (8 vCPU) all `SPOT true`, none `SPOT-FALLBACK true`.

## Q&A prep
- **Does CAST AI need an SQS queue like Karpenter?** No. The spot-handler on each spot node watches instance metadata and reports to CAST AI.
- **Can FIS interrupt CAST AI nodes?** Yes. It is an EC2-level action; any spot instance matching the target works. We reuse karpenter-demo's role and target by our own tag `castai-demo=managed`.
- **How fast does fallback return to spot?** Every `fallback_restore_rate_seconds` (1800 s here) CAST AI checks inventory and rebalances fallback nodes to spot. Shorter = cheaper, more churn.
- **Is interruption prediction free?** It is part of the Premium node autoscaler. On this org it runs under the trial.
- **Spot reliability vs diversity?** Diversity spreads across more types (deprecated). Reliability picks types with longer expected runtime within a price-increase cap. EC2 `price-capacity-optimized` (used by Karpenter) already weighs capacity, so expect a modest difference.
- **What about the rebalance recommendation signal?** Karpenter records it as an event only; CAST AI's AWS-RR mode was deprecated in July 2026 in favour of its own ML model.
- **Why not demo with full `shop`?** Replacement first means +4 spot vCPU; with 8 already used, the replacement would fail on quota and the cluster CPU limit.
