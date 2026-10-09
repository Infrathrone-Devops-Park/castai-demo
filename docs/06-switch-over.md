# 06 — Switch-over: Karpenter off, CAST AI autoscaler on
**Time:** 30 min · **Goal:** Hand the same `shop` workload from Karpenter to the CAST AI autoscaler without breaking quota, then measure the node-level result honestly.

## What you'll show
- The quota-safe hand-over order (what `scripts/switch-to-castai.sh` does), run step by step.
- `shop` pods go Pending, CAST AI creates spot nodes, Pod Pinner binds pods to them.
- The labels that identify a CAST AI node: `provisioner.cast.ai/managed-by=cast.ai`, `scheduling.cast.ai/spot=true`, `scheduling.cast.ai/node-template=default-by-castai`.
- Timing from "autoscaler enabled" to "all pods Ready".
- `scripts/measure.sh castai-autoscaler` and `scripts/compare.sh karpenter-baseline castai-autoscaler`.
- The honest result: same vCPU, same requests; the $/h difference comes only from which spot offering each tool bought. The big savings come later (Workload Autoscaler, modules 11+).

## Concepts

### Why the order matters
Only one node autoscaler may run (CAST AI: "running it alongside another node autoscaler ... will cause conflicts"). The account has **8 spot + 8 on-demand vCPU** (2 OD used by the system node). Karpenter's nodes must be **gone from EC2** before CAST AI launches, or the spot quota is double-booked.

```text
1. freeze      NodePool limits.cpu = "0"         Karpenter can drain, cannot launch
2. drain       delete NodeClaims, wait gone       shop pods -> Pending
3. settle      sleep 60                          spot quota release lag
4. stop        scale deploy/karpenter to 0
5. enable      terraform apply autoscaler_enabled=true
               -> castai_autoscaler_policies.enabled = true
               -> castai_evictor.enabled = true
6. CAST AI     unschedulable pods policy -> plan -> EC2 spot -> node joins
               Pod Pinner binds pods to the planned node
```

### What is already configured (Terraform, `terraform/nodes.tf`)
| CAST AI object | Setting | Karpenter equivalent |
|---|---|---|
| Node configuration `default` | AL2023, gp3 30 GiB, IMDSv2, tag `castai-demo=managed` | `EC2NodeClass default` |
| Node template `default-by-castai` | amd64, 2–4 vCPU, **spot only**, spot fallback, template CPU limit 8 | `NodePool default` (spot+OD, 2–4 vCPU, limit 10) |
| Autoscaler policies (V2) | unschedulable pods + Pod Pinner, empty-node delete 60 s, cluster max 10 cores (incl. system node) | provisioning + `WhenEmpty` part of consolidation + `limits` |
| Evictor (V2) | scoped mode, not aggressive, cycle 60 s, node grace 5 min | `WhenEmptyOrUnderutilized` consolidation |

Capacity in this module: CAST AI may hold at most 8 vCPU (template limit 8, cluster max 10 = 2 system + 8). `shop` requests 6.0 vCPU, so expect 2–4 spot nodes totalling 8 vCPU (validation run: 4× 2-vCPU). The spot quota is full again at the end.

## Demo

Panes (second and third terminal, repo root, after `source scripts/env.sh`):
```bash
kubectl get nodes -L provisioner.cast.ai/managed-by,karpenter.sh/nodepool,scheduling.cast.ai/spot,node.kubernetes.io/instance-type -w
```
```bash
kubectl get pods -n shop -o wide -w
```

### Step 1 — Environment and starting state
Prove Karpenter owns the workers and CAST AI is installed but idle.
```bash
source scripts/env.sh
kubectl get nodepools,nodeclaims
kubectl get pods -n shop --no-headers | awk '{print $3}' | sort | uniq -c
terraform -chdir=terraform output autoscaler_enabled
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies" | jq '{enabled, unschedulablePods: .unschedulablePods.enabled, maxCores: .clusterLimits.cpu.maxCores, emptyDelay: .nodeDownscaler.emptyNodesDelay}'
```
Expected: `nodepool default` READY True and 2 NodeClaims (for example `c6a.xlarge` + `c8i-flex.xlarge`, both `spot`); `13 Running`; `false`; JSON `{"enabled": false, "unschedulablePods": true, "maxCores": 10, "emptyDelay": "60s"}`. The sub-policies are already configured; only the master switch is off.

### Step 2 — Baseline exists?
The comparison at the end needs the Karpenter snapshot.
```bash
ls -l results/karpenter-baseline.json || scripts/measure.sh karpenter-baseline
```
Expected: the file is listed (taken in an earlier module). If it was missing, `measure.sh` prints the node table and `saved results/karpenter-baseline.json`.

### Step 3 — Shortcut or step by step
`scripts/switch-to-castai.sh` runs Steps 4–8 in one go. On stage, run the steps below instead so the audience sees each phase. **Do one or the other, not both.**
```bash
sed -n '1,200p' scripts/switch-to-castai.sh
```
Expected: the script source; walk through it and map each block to Steps 4–8: `# 1. freeze` = Step 4 (it also stores the old limit in annotation `castai-demo/original-cpu-limit`), `# 2. delete NodeClaims` = Steps 5–6 (polls NodeClaims, Nodes and EC2 every 15 s), `# 3.` = the 60 s pause, `# 4.` = Step 7, `# 5.` = Step 8 (Terraform plan saved to a file, then applied), `# 6.` = Steps 9–11. A full run takes about 3.5 min.

### Step 4 — Freeze Karpenter
`limits.cpu: "0"` stops new launches but keeps the controller alive so it can drain cleanly.
```bash
for np in $(kubectl get nodepools -o name); do kubectl patch "$np" --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'; done
kubectl get nodepools -o custom-columns=NAME:.metadata.name,LIMIT:.spec.limits.cpu
```
Expected: `nodepool.karpenter.sh/default patched`, then `default   0`.

### Step 5 — Drain Karpenter capacity
Pods are evicted and stay Pending: Karpenter may not launch, CAST AI is not enabled yet.
```bash
kubectl delete nodeclaims --all --wait=false
kubectl wait nodeclaims --all --for=delete --timeout=600s
kubectl get pods -n shop --no-headers | awk '{print $3}' | sort | uniq -c
```
Expected: `nodeclaim.karpenter.sh/default-xxxxx deleted` per claim, then `condition met` lines within 1–2 min (validation run: ~65 s and ~80 s). Finally `13 Pending`. Two CAST AI pods that live on workers (`castai-pod-mutator`, one `castai-workload-autoscaler-exporter`) are Pending too; they come back with the new nodes. This is the outage window; in production you would not do a hard cut-over like this.

### Step 6 — Confirm EC2 is clean, then wait for quota release
```bash
aws ec2 describe-instances --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=pending,running,shutting-down,stopping --query 'Reservations[].Instances[].InstanceId' --output text
sleep 60
```
Expected: empty output (no Karpenter instances left), then a 60 s pause. Spot vCPU quota frees a little after termination; skipping the wait can produce `MaxSpotInstanceCountExceeded`.

### Step 7 — Stop the Karpenter controller
```bash
kubectl -n kube-system scale deploy karpenter --replicas=0
kubectl -n kube-system get deploy karpenter
```
Expected: `deployment.apps/karpenter scaled`, then `READY 0/0`. NodePools and CRDs stay, so module rollback is a scale-up away.

### Step 8 — Enable the CAST AI autoscaler
Same Terraform, two booleans flip: policies `enabled` and evictor `enabled`.
```bash
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=true
terraform -chdir=terraform apply tfplan
T0=$(date -u +%s)
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies" | jq '{enabled, podPinner: .unschedulablePods.podPinner}'
```
Expected: the plan shows `castai_autoscaler_policies.this` and `castai_evictor.this` with `enabled = false -> true`, `Plan: 0 to add, 2 to change, 0 to destroy.` and `Saved the plan to: tfplan`; the apply prints `Apply complete! Resources: 0 added, 2 changed, 0 destroyed.` (3 changed if the Helm release was still in `readonly` mode). Then `{"enabled": true, "podPinner": {"enabled": true, "status": "POD_PINNER_STATUS_UNKNOWN"}}`; the status turns `POD_PINNER_STATUS_COMPATIBLE` within about a minute (re-run the `curl` to show it).

Console equivalent: **Cluster → Autoscaler → Settings** (newer console: **Cluster → Settings → Node autoscaling advanced settings**): "Unscheduled pods policy" and "Node deletion policy" show On. Do not toggle there; Terraform owns these.

### Step 9 — Watch CAST AI provision
Look at the node pane.
```bash
kubectl get events -n shop --sort-by=.lastTimestamp | grep -i -E 'cast|pinn|unschedul' | tail -8
```
Expected (validation run, times after the apply):
1. ~+10 s: every Pending pod gets a `NodeCreationTriggered` event from `autoscaler.cast.ai`: `CAST.AI autoscaler triggered node creation for this pod (node: <uuid>, instance type: c8i-flex.large)`. The UUID is the planned node; it becomes the node's `provisioner.cast.ai/node-id` label.
2. ~+28 s: real nodes appear in the node pane as `NotReady`, `MANAGED-BY cast.ai`, `SPOT true`. Choice in the validation run: **4× `c8i-flex.large`** (2 vCPU each, all in `ap-south-1c`) = 8 vCPU, the whole spot quota. Other runs may pick 4-vCPU types; both fit the template.
3. ~+30–35 s: Pod Pinner binds the pods to the planned nodes: in the pod pane `NODE` is set while the pod is still `Pending`, then `ContainerCreating`. No placeholder Node objects show up when the real node registers first (pinner log: `node already exists`).
4. ~+48 s: all 13 pods `Running`.

The `grep` shows the `NodeCreationTriggered` lines (it matches `CAST.AI`). There is no separate pinning event on the pod; the pinner logs it instead:
```bash
kubectl logs -n castai-agent deploy/castai-pod-pinner --since=10m --tail=-1 | grep -o '"msg":"[^"]*"' | sort | uniq -c
```
Expected: `received pod pinning actions` (one per planned node), `node already exists`, and `pod pinned` / `patching pod` once per pinned pod (13 `shop` pods + the 2 CAST AI worker pods).

### Step 10 — The CAST AI node labels
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot,scheduling.cast.ai/node-template,topology.kubernetes.io/zone,provisioner.cast.ai/node-id
```
Expected: 4 nodes (validation run: `c8i-flex.large`; 2–3 if CAST AI picks 4-vCPU types), each `SPOT true`, `NODE-TEMPLATE default-by-castai`, a zone `ap-south-1a|b|c`, and a UUID `NODE-ID` (the id the CAST AI API uses, same as in the Step 9 events).

Same view from the API and from EC2 (cross-check, not on faith):
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID/nodes" | jq -r '.items[] | [.name, .instanceType, (.spotConfig.isSpot // false), (.state.phase // "-")] | @tsv'
aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' --output table
```
Expected: the API lists the same CAST AI nodes with `true` (spot) plus the system node `t3a.large` (`false`); phase `ready` for all. EC2 table: one row per CAST AI node, same type, `spot`, same AZ. The system node is not listed: the `castai-demo=managed` tag comes from our node configuration, so only CAST AI-launched instances carry it.

Console: **Cluster → Nodes**: same nodes, "Spot" badge, template `default-by-castai`.

### Step 11 — How long did it take?
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -o json | jq -r --argjson t0 "$T0" '.items[] | "\(.metadata.name)  created +\((.metadata.creationTimestamp | fromdateiso8601) - $t0)s"'
kubectl get pods -n shop -o json | jq -r --argjson t0 "$T0" '[.items[].status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime | fromdateiso8601] | "all 13 Ready at +\(max - $t0)s"'
```
Expected: nodes created at about `+28s`, `all 13 Ready at +48s` (validation run). The vendor quotes 60–120 s; this run was faster. Karpenter in karpenter-demo took ~35 s per NodeClaim to Ready. On a cold start both are in the same range; CAST AI's decision runs in the SaaS, Karpenter's in-cluster. Read out your own numbers.

If `T0` is not set (panes re-opened), the numbers are relative to whatever `T0` holds; re-run Step 8's `T0=...` line only if you just applied.

### Step 12 — Steady state, then measure
Wait for the evictor's node grace period (5 min) so the fleet is stable.
```bash
sleep 300
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
scripts/measure.sh castai-autoscaler
```
Expected: same nodes as Step 10 (no churn; the evictor logs `found no nodes to evict`). `measure.sh` prints the node table with `PROVISIONER castai`, `CAPACITY spot`, then (validation run):
```text
nodes (workers / spot workers)    5 (4 / 4)
provisioned vCPU (all / workers)  10 / 8
requested vCPU (all ns / shop)    8.975 / 6
used vCPU (all ns / shop)         1.749 / 1.583
$/h workers                       0.0652
$/h all nodes                     0.1145
$/month workers (x730)            47.6
saved results/castai-autoscaler.json
```
Each `c8i-flex.large` spot node was $0.0163/h in `ap-south-1c`.

### Step 13 — Compare with Karpenter
```bash
scripts/compare.sh karpenter-baseline castai-autoscaler
```
Expected (validation run):
```text
worker nodes                2       4       +2       +100%
provisioned vCPU (workers)  8       8       0        0%
requested vCPU (all ns)     7.68    8.975   +1.295   +16.9%
requested vCPU (shop)       6       6       0        0%
used vCPU (shop)            1.59    1.583   -0.007   -0.4%
$/h workers                 0.1047  0.0652  -0.0395  -37.7%
$/h all-in                  0.254   0.2145  -0.0395  -15.6%
Node types:
  karpenter-baseline:    1x c6a.xlarge/spot, 1x c8i-flex.xlarge/spot
  castai-autoscaler:     4x c8i-flex.large/spot
```
Same worker vCPU, same `shop` requests and usage. Your $/h delta depends on the spot prices of the day; read the numbers out and explain where the difference comes from:
- **Offering choice, not packing.** In the validation run `c8i-flex.large` spot in `ap-south-1c` cost $0.008 per vCPU-hour, against $0.013 for `c6a.xlarge` and $0.026 for `c8i-flex.xlarge`. Check it yourself:
```bash
for t in c8i-flex.large c8i-flex.xlarge c6a.xlarge; do aws ec2 describe-spot-price-history --instance-types "$t" --availability-zone ap-south-1c --product-descriptions Linux/UNIX --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --query 'SpotPriceHistory[0].[InstanceType,SpotPrice]' --output text; done
```
- Karpenter's NodePool allows the same 2-vCPU sizes. It launches spot with EC2's `price-capacity-optimized` strategy, which trades a little price for pools with lower interruption risk. CAST AI bought the cheapest offering. A tuned Karpenter NodePool (for example limited to `c8i-flex` or to one AZ) can land on the same price.
- The price of the cheapest pool: all four nodes in one AZ and one instance type. One spot reclaim wave in that pool hits the whole fleet. Module 10 covers the knobs (spot reliability, diversity).
- `requested vCPU (all ns)` is higher because of the CAST AI automation components (module 05) and DaemonSet pods on 4 nodes instead of 2. Not a cost by itself, but it eats allocatable space.

## Talking points
- Same pods, same requests, same quota: both autoscalers bin-pack the **requests**. The node-level delta is the spot offering each one bought (price-capacity-optimized vs cheapest), not smarter packing. Expect it to vary day to day.
- Karpenter is already price-optimal for the requests it is given. Requests are 4x real usage here; neither node autoscaler can see that. That is where modules 11+ (Workload Autoscaler) make the real difference.
- CAST AI decides in the SaaS and acts through the in-cluster agent and cluster-controller; Karpenter decides in-cluster. Vendor-stated scale-up is 60–120 s; our run had pods Ready in under a minute. Plan headroom either way.
- Pod Pinner binds pods to the node CAST AI planned, so the scheduler cannot "steal" the new node for other pods. Karpenter gets a similar effect through nomination.
- Instance choice differs: Karpenter picked 2× 4-vCPU nodes, CAST AI 4× 2-vCPU nodes for the same 13 pods. Same vCPU total; more, smaller nodes mean more DaemonSet overhead but smaller blast radius per interruption.
- Running both autoscalers is unsupported. The freeze-drain-wait-stop order is what keeps the 8-vCPU spot quota from being double-booked.

## Reset
Stay on CAST AI for modules 07–10. Every later module starts from this end state (CAST AI active, full `shop`).

To go back to Karpenter (reverse order, quota-safe):
```bash
terraform -chdir=terraform plan -out=tfplan -var phase=automation -var autoscaler_enabled=false
terraform -chdir=terraform apply tfplan
kubectl delete node -l provisioner.cast.ai/managed-by=cast.ai
IDS=$(aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IDS" ] && aws ec2 terminate-instances --instance-ids ${=IDS} --query 'TerminatingInstances[].InstanceId' --output text
aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running,shutting-down,stopping --query 'Reservations[].Instances[].InstanceId' --output text
sleep 60
kubectl -n kube-system scale deploy karpenter --replicas=1
kubectl -n kube-system rollout status deploy karpenter --timeout=180s
for np in $(kubectl get nodepools -o name); do kubectl patch "$np" --type merge -p '{"spec":{"limits":{"cpu":"10"}}}'; done
```
Expected: plan `0 to add, 2 to change`, CAST AI policies off, CAST AI nodes deleted, the instance IDs being terminated, then the EC2 query returns empty (repeat it until it does; termination takes ~30–60 s), Karpenter `1/1`, NodePool limit back to `10`, and Karpenter relaunches nodes for `shop` within a minute. `scripts/switch-to-karpenter.sh` does the same.
Why the explicit `terminate-instances`: deleting the Node object does **not** terminate the instance. In validation the instance kept running for 5+ min, invisible to Kubernetes and to the CAST AI node list, while still holding spot quota. `${=IDS}` is zsh word-splitting for the ID list.

## Q&A prep
- **Could we run CAST AI next to Karpenter?** Not the standard autoscaler (undefined behaviour). The "Cast AI for Karpenter" (Kent) product keeps Karpenter as provisioner instead; it is a different onboarding path and lacks Pod Pinner, spot fallback recovery and evictor aggressive mode.
- **Why did CAST AI pick these instance types?** Cheapest offering that fits the pending pods inside template constraints (amd64, 2–4 vCPU, spot). Recently interrupted types and zones are temporarily avoided.
- **Why is CAST AI cheaper here?** It picked the lowest-priced spot pool (`c8i-flex.large` in one AZ); Karpenter's `price-capacity-optimized` picked pools with more capacity. Same vCPU, same requests. Tomorrow the gap may be smaller or reversed.
- **Is "all nodes in one AZ" a problem?** For interruption blast radius, yes. Enable spot reliability/diversity on the template or add topology spread to workloads; both cost a bit more.
- **What if the CAST AI SaaS is unreachable?** Running pods are unaffected; new pending pods wait. Vendor-documented fallbacks include a delayed Karpenter or Cluster Autoscaler.
- **Why `sleep 60`?** EC2 releases spot vCPU quota shortly after termination, not instantly. Without the pause, the first CAST AI launch can fail on quota.
- **Can CAST AI touch the system node?** Evictor is in scoped mode (only `managed-by=cast.ai` nodes). The autoscaler only creates nodes from templates and never resizes the managed node group.
