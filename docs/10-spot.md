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

All of these are part of the CAST AI Node Autoscaler, a Premium feature; this org runs it on the trial. <!-- VERIFY: plan shown in console billing page -->

### Who reacts to an interruption
```text
 AWS (2-min notice via IMDS + EventBridge)
   |
   v
 castai-spot-handler (DaemonSet, hostNetwork, spot nodes only)
   reports the event to CAST AI -- takes NO action itself
   |
   v
 CAST AI platform -> cluster-controller
   node: label scheduling.cast.ai/interrupted=true
         label autoscaling.cast.ai/draining=spot-interruption
         taint autoscaling.cast.ai/draining=true
   autoscaler: replacement capacity for the pods
   (no spot available -> fallback on-demand, label draining=spot-fallback)
 AWS reclaims the instance at T+2 min
```
Docs are not fully consistent on whether CAST AI drains on the notice or lets Kubernetes handle termination; Demo A shows what really happens. <!-- VERIFY: drain-on-notice behaviour on EKS -->

### Karpenter (module 10 of karpenter-demo) vs CAST AI
| | Karpenter v1.14 | CAST AI |
|---|---|---|
| Signal path | EventBridge → SQS → controller (no node agent) | spot-handler DaemonSet on each spot node → SaaS |
| On 2-min warning | CordonAndDrain + replacement NodeClaim in parallel (~1 s) | label/taint, replacement, drain |
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
Start = end of module 06. Shrink to one spot node so a replacement fits the quota (~4 min).
```bash
source scripts/env.sh
CL="$CASTAI_API_URL/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID"
EXT="$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID"
kubectl scale deploy -n shop --all --replicas=0
kubectl wait node -l provisioner.cast.ai/managed-by=cast.ai --for=delete --timeout=600s
kubectl scale deploy -n shop frontend cart catalog checkout payments --replicas=1
for d in frontend cart catalog checkout payments; do kubectl rollout status deploy/$d -n shop --timeout=10m; done
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai
```
Expected: old nodes deleted, then one new spot node (two 2-vCPU nodes are possible; if so Demo A still works, the replacement is smaller). Five `successfully rolled out`.

### Step 2 — Spot settings of the default template (Terraform, API, console)
```bash
terraform -chdir=terraform state show castai_node_template.default | grep -E 'spot|on_demand|fallback'
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/node-templates" | jq '.items[] | select(.template.name=="default-by-castai") | {stats, c: (.template.constraints | {spot, onDemand, useSpotFallbacks, fallbackRestoreRateSeconds, spotInterruptionPredictionsEnabled, enableSpotReliability, enableSpotDiversity})}'
```
Expected: Terraform `spot = true`, `on_demand = false`, `use_spot_fallbacks = true`, `fallback_restore_rate_seconds = 1800`. API: same plus `spotInterruptionPredictionsEnabled false`, `enableSpotReliability false`, `enableSpotDiversity false`; `stats.countSpot` 1 (or 2), `countFallback 0`. Console: **Node templates → default-by-castai → Select resource offering**: Spot, "Use spot fallback" with interval, "Interruption prediction model", "Spot reliability".

### Step 3 — Fallback: how to see it, and why we do not force it
```bash
kubectl get nodes -l scheduling.cast.ai/spot-fallback=true
```
Expected: `No resources found`. Forcing a fallback needs spot to be unbuyable. The only reliable lever here is the 8-vCPU spot quota, and breaking it would also break the cluster CPU limit (2 system + 8 spot + 4 fallback = 14 > 10) and leave pods Pending. So: explain, do not run. What you would see: an on-demand node with `scheduling.cast.ai/spot-fallback=true`, `stats.countFallback 1`, and after `fallback_restore_rate_seconds` a rebalancing replacement back to spot (rebalancing ignores `removal-disabled` on fallback nodes on purpose).

### Step 4 — The spot-handler
```bash
kubectl get ds -n castai-agent
NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=default-by-castai -o jsonpath='{.items[0].metadata.name}')
SH=$(kubectl get pods -n castai-agent --field-selector spec.nodeName="$NODE" -o name | grep spot-handler)
echo "$NODE $SH"
kubectl logs -n castai-agent "$SH" --tail=5
```
Expected: a DaemonSet `castai-spot-handler` with DESIRED = number of spot nodes (not the system node), the node name, `pod/castai-spot-handler-xxxxx`, and a few startup/poll lines. It polls instance metadata over `hostNetwork`; it only **reports**. <!-- VERIFY: DS name and log lines -->

### Step 5 — Demo A: pick the instance and check the tag
```bash
IID=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}'); IID=${IID##*/}
aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Lifecycle:InstanceLifecycle,AZ:Placement.AvailabilityZone,Tag:Tags[?Key==`castai-demo`]|[0].Value}' --output table
kubectl get pods -n shop -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```
Expected: `Lifecycle spot`, `Tag managed`, the instance type and AZ (note them). All five `shop` pods on `$NODE` (or spread over two nodes).

### Step 6 — Demo A: create the FIS template
Same action as karpenter-demo module 10; target = spot instances tagged `castai-demo=managed`, narrowed to `$IID`. Role from the sibling Terraform state.
```bash
FIS_ROLE_ARN=$(terraform -chdir="$KARPENTER_DEMO_DIR/terraform" output -raw fis_role_arn)
echo "$FIS_ROLE_ARN"
TEMPLATE_ID=$(aws fis create-experiment-template --cli-input-json "$(jq --arg role "$FIS_ROLE_ARN" --arg id "$IID" '.roleArn = $role | .targets.castaiSpot.filters[1].values = [$id]' manifests/10-spot/fis-castai-spot-template.json)" --query 'experimentTemplate.id' --output text)
echo "$TEMPLATE_ID"
```
Expected: `arn:aws:iam::146725924014:role/karpenter-demo-fis-spot` and a template ID like `EXT...`. If the sibling state is unavailable: `aws iam get-role --role-name karpenter-demo-fis-spot --query Role.Arn --output text`. The role's managed policy `AWSFaultInjectionSimulatorEC2Access` is not tag-scoped, so it also works on CAST AI instances. <!-- VERIFY: InstanceId accepted as FIS filter path -->

### Step 7 — Demo A: start the interruption
```bash
EXPERIMENT_ID=$(aws fis start-experiment --experiment-template-id "$TEMPLATE_ID" --tags Name=castai-spot-demo --query 'experiment.id' --output text)
T0=$(date -u +%s)
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state.status' --output text
```
Expected: `initiating` or `running`. FIS sends a rebalance recommendation and the 2-minute interruption warning to `$IID`.

### Step 8 — Demo A: watch CAST AI react
Grab the handler's view before the node disappears, then watch the panes.
```bash
sleep 45
kubectl logs -n castai-agent "$SH" --since=2m | tail -10
kubectl get node "$NODE" -o json | jq '{labels: (.metadata.labels | with_entries(select(.key | test("draining|interrupted")))), taints: .spec.taints}'
```
Expected (rehearse and fill in timings): handler log line reporting the interruption notice for `$IID`; on the node, `scheduling.cast.ai/interrupted: "true"` and `autoscaling.cast.ai/draining: "spot-interruption"`, taint `autoscaling.cast.ai/draining=true:NoSchedule` (and possibly cordon). In the panes: a replacement spot node appears (often a different type or AZ), `shop` pods move to it, the old node goes `NotReady` and disappears around T+2 min. <!-- VERIFY: timings and whether pods move before or after reclaim -->

### Step 9 — Demo A: evidence
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl get pods -n shop -o json | jq -r --argjson t0 "$T0" '[.items[].status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime | fromdateiso8601] | "shop pods Ready again by +\(max - $t0)s"'
aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[].Instances[].[State.Name,StateReason.Code]' --output text
aws fis get-experiment --id "$EXPERIMENT_ID" --query 'experiment.state' --output json
```
Expected: one CAST AI spot node with a new name; the "Ready again" offset (Karpenter's validation run: pods Running ~33 s after the warning); old instance `terminated` with `Server.SpotInstanceTermination` (AWS reclaimed it) or `Client.UserInitiatedShutdown` (CAST AI deleted it first; tells you who acted first); FIS `{"status": "completed", ...}`. Console: **Cluster → Audit log** shows the interruption and node operations. <!-- VERIFY: audit log entries -->

### Step 10 — Demo B (optional): simulate an interruption prediction
The API publishes a simulated **prediction** for one node: the node is annotated with a TTL and a rebalancing plan starts automatically (replacement first, then drain). This is the Premium early-warning path you cannot trigger with FIS. Capacity: one extra ~4 vCPU spot node.
```bash
NODE=$(kubectl get nodes -l scheduling.cast.ai/node-template=default-by-castai -o jsonpath='{.items[0].metadata.name}')
NID=$(curl -s -H "X-API-Key: $CASTAI_API_KEY" "$EXT/nodes" | jq -r --arg n "$NODE" '.items[] | select(.name==$n) | .id')
jq -n --arg id "$NID" '{nodeId: $id}' | curl -s -X POST -H "X-API-Key: $CASTAI_API_KEY" -H 'Content-Type: application/json' --data-binary @- "$CL/simulate-spot-interruption"
sleep 60
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CL/rebalancing-plans?limit=3" | jq -r '.items[] | [.rebalancingPlanId, .status, .createdAt] | @tsv'
```
Expected: `{}`; a new plan at the top in `creating_nodes`/`draining_nodes`; the node gets `autoscaling.cast.ai/draining=spot-prediction`; replacement Ready **before** the old node is drained; no pod is Pending longer than its restart. If the call returns an error (feature not enabled for the template/org), skip and explain with Concepts. <!-- VERIFY: works with spot_interruption_predictions_enabled=false -->

### Step 11 — Clean up the FIS template
```bash
aws fis delete-experiment-template --id "$TEMPLATE_ID" --query 'experimentTemplate.id' --output text
```
Expected: the template ID echoed back.

## Talking points
- Both tools get the same 2-minute AWS warning and both start a replacement right away. On a reclaim, the difference is plumbing (SQS vs node agent), not outcome.
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
Expected: no FIS templates left (no output if Step 11 ran), six deployments rolled out within ~3 min, 2–3 CAST AI nodes all `SPOT true`, none `SPOT-FALLBACK true`.

## Q&A prep
- **Does CAST AI need an SQS queue like Karpenter?** No. The spot-handler on each spot node watches instance metadata and reports to CAST AI.
- **Can FIS interrupt CAST AI nodes?** Yes. It is an EC2-level action; any spot instance matching the target works. We reuse karpenter-demo's role and target by our own tag `castai-demo=managed`.
- **How fast does fallback return to spot?** Every `fallback_restore_rate_seconds` (1800 s here) CAST AI checks inventory and rebalances fallback nodes to spot. Shorter = cheaper, more churn.
- **Is interruption prediction free?** It is part of the Premium node autoscaler. On this org it runs under the trial.
- **Spot reliability vs diversity?** Diversity spreads across more types (deprecated). Reliability picks types with longer expected runtime within a price-increase cap. EC2 `price-capacity-optimized` (used by Karpenter) already weighs capacity, so expect a modest difference.
- **What about the rebalance recommendation signal?** Karpenter records it as an event only; CAST AI's AWS-RR mode was deprecated in July 2026 in favour of its own ML model.
- **Why not demo with full `shop`?** Replacement first means +4 spot vCPU; with 8 already used, the replacement would fail on quota and the cluster CPU limit.
