# 06 — Switch-over: Karpenter off, CAST AI autoscaler on
**Time:** 30 min · **Goal:** Hand the same `shop` workload from Karpenter to the CAST AI autoscaler without breaking quota, then measure the node-level result honestly.

## What you'll show
- The quota-safe hand-over order (what `scripts/switch-to-castai.sh` does), run step by step.
- `shop` pods go Pending, CAST AI creates spot nodes, Pod Pinner binds pods to them.
- The labels that identify a CAST AI node: `provisioner.cast.ai/managed-by=cast.ai`, `scheduling.cast.ai/spot=true`, `scheduling.cast.ai/node-template=default-by-castai`.
- Timing from "autoscaler enabled" to "all pods Ready".
- `scripts/measure.sh castai-autoscaler` and `scripts/compare.sh karpenter-baseline castai-autoscaler`.
- The honest result: roughly the same $/h as Karpenter. The big savings come later (Workload Autoscaler, modules 11+).

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

Capacity in this module: CAST AI may hold at most 8 vCPU (template limit 8, cluster max 10 = 2 system + 8). `shop` requests 6.0 vCPU, so expect 2–3 spot nodes totalling 6–8 vCPU.

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
Expected: `nodepool default` READY True and 2–3 NodeClaims; `13 Running`; `false`; JSON `{"enabled": false, "unschedulablePods": true, "maxCores": 10, "emptyDelay": "60s"}`. <!-- VERIFY: field values echoed when enabled=false -->

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
Expected: the script source; walk through it and map each block to Steps 4–8. <!-- VERIFY: script written by module 00-05 author; confirm it matches Steps 4-8 -->

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
Expected: `nodeclaim.karpenter.sh/default-xxxxx deleted` per claim, then `condition met` lines within 1–2 min. Finally `13 Pending`. This is the outage window; in production you would not do a hard cut-over like this.

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
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=true
T0=$(date -u +%s)
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies" | jq '{enabled, podPinner: .unschedulablePods.podPinner}'
```
Expected: `Apply complete! Resources: 0 added, 2 changed, 0 destroyed.` (3 changed if the Helm release was still in `readonly` mode). Then `{"enabled": true, "podPinner": {"enabled": true, "status": "POD_PINNER_STATUS_COMPATIBLE"}}`. <!-- VERIFY: resource count and podPinner.status string -->

Console equivalent: **Cluster → Autoscaler → Settings** (newer console: **Cluster → Settings → Node autoscaling advanced settings**): "Unscheduled pods policy" and "Node deletion policy" show On. Do not toggle there; Terraform owns these.

### Step 9 — Watch CAST AI provision
Look at the node pane.
```bash
kubectl get events -n shop --sort-by=.lastTimestamp | grep -i -E 'cast|pinn|unschedul' | tail -8
```
Expected (watch panes, roughly):
1. 20–60 s after the apply, the autoscaler sees the 13 Pending pods (`FailedScheduling` events stop being the newest).
2. Pod Pinner creates a placeholder Node object for each planned node, and pods are bound to it (`nodeName` set while the pod is still `Pending`). <!-- VERIFY: placeholder node name/visibility in kubectl get nodes -->
3. 60–120 s: real nodes register with `MANAGED-BY cast.ai`, `SPOT true`. Typical choice: 2× 4-vCPU spot (`c6a.xlarge`/`m6a.xlarge` class) or 4 + 2 + 2.
4. Pods start Running on them.

The `grep` shows CAST AI events on pods (for example "Unscheduled Pods Policy Applied" or a pinning event). <!-- VERIFY: exact event reasons/messages emitted on pods -->

### Step 10 — The CAST AI node labels
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot,scheduling.cast.ai/node-template,topology.kubernetes.io/zone,provisioner.cast.ai/node-id
```
Expected: 2–3 nodes, each `SPOT true`, `NODE-TEMPLATE default-by-castai`, a zone `ap-south-1a|b|c`, and a UUID `NODE-ID` (the id the CAST AI API uses).

Same view from the API and from EC2 (cross-check, not on faith):
```bash
curl -s -H "X-API-Key: $CASTAI_API_KEY" "$CASTAI_API_URL/v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID/nodes" | jq -r '.items[] | [.name, .instanceType, (.spotConfig.isSpot // false), (.state.phase // "-")] | @tsv'
aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' --output table
```
Expected: the API lists the same CAST AI nodes with `true` (spot) plus the system node (`false`); phase `ready`. EC2 shows the same instance types with `InstanceLifecycle spot`. The `castai-demo=managed` tag comes from our node configuration. <!-- VERIFY: state.phase value spelling -->

Console: **Cluster → Nodes**: same nodes, "Spot" badge, template `default-by-castai`.

### Step 11 — How long did it take?
```bash
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -o json | jq -r --argjson t0 "$T0" '.items[] | "\(.metadata.name)  created +\((.metadata.creationTimestamp | fromdateiso8601) - $t0)s"'
kubectl get pods -n shop -o json | jq -r --argjson t0 "$T0" '[.items[].status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime | fromdateiso8601] | "all 13 Ready at +\(max - $t0)s"'
```
Expected: nodes created at roughly +60–120 s, all pods Ready at roughly +120–240 s after the apply. Karpenter in module 04 of karpenter-demo did the same in ~35 s per NodeClaim: CAST AI is a SaaS control loop, Karpenter is in-cluster. Say it. <!-- VERIFY: measured timings -->

### Step 12 — Steady state, then measure
Wait for the evictor's node grace period (5 min) so the fleet is stable.
```bash
sleep 300
kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai -L node.kubernetes.io/instance-type,scheduling.cast.ai/spot
scripts/measure.sh castai-autoscaler
```
Expected: same nodes as Step 10 (no churn). `measure.sh` prints the node table with `PROVISIONER castai`, `CAPACITY spot`, about 6.0 requested shop vCPU and about 1.6 used, then `saved results/castai-autoscaler.json`.

### Step 13 — Compare with Karpenter
```bash
scripts/compare.sh karpenter-baseline castai-autoscaler
```
Expected: `worker nodes` and `provisioned vCPU (workers)` equal or within one node; `requested vCPU (shop)` identical (6.0); `$/h workers` within roughly ±20 % (spot prices and instance choice). The "Node types" lines show both camps on 2–4 vCPU spot. Read the numbers out; do not round in CAST AI's favour.

## Talking points
- Same pods, same requests, same quota: both autoscalers bin-pack the **requests** onto the cheapest fitting spot nodes. Node-level parity is the expected and honest result.
- Karpenter is already price-optimal for the requests it is given. Requests are 4x real usage here; neither node autoscaler can see that. That is where modules 11+ (Workload Autoscaler) make the real difference.
- CAST AI decides in the SaaS and acts through the in-cluster agent and cluster-controller; Karpenter decides in-cluster. Expect slower scale-up from CAST AI (vendor-stated 60–120 s) and plan headroom accordingly.
- Pod Pinner binds pods to the node CAST AI planned, so the scheduler cannot "steal" the new node for other pods. Karpenter gets a similar effect through nomination.
- Running both autoscalers is unsupported. The freeze-drain-wait-stop order is what keeps the 8-vCPU spot quota from being double-booked.

## Reset
Stay on CAST AI for modules 07–10. Every later module starts from this end state (CAST AI active, full `shop`).

To go back to Karpenter (reverse order, quota-safe):
```bash
terraform -chdir=terraform apply -auto-approve -var phase=automation -var autoscaler_enabled=false
kubectl delete node -l provisioner.cast.ai/managed-by=cast.ai
aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running,shutting-down,stopping --query 'Reservations[].Instances[].InstanceId' --output text
sleep 60
kubectl -n kube-system scale deploy karpenter --replicas=1
kubectl -n kube-system rollout status deploy karpenter --timeout=180s
for np in $(kubectl get nodepools -o name); do kubectl patch "$np" --type merge -p '{"spec":{"limits":{"cpu":"10"}}}'; done
```
Expected: CAST AI policies off, CAST AI nodes deleted, the EC2 query returns empty (repeat it until it does), Karpenter `1/1`, NodePool limit back to `10`, and Karpenter relaunches nodes for `shop` within a minute. `scripts/switch-to-karpenter.sh` does the same. <!-- VERIFY: deleting the Node object makes CAST AI terminate the instance -->

## Q&A prep
- **Could we run CAST AI next to Karpenter?** Not the standard autoscaler (undefined behaviour). The "Cast AI for Karpenter" (Kent) product keeps Karpenter as provisioner instead; it is a different onboarding path and lacks Pod Pinner, spot fallback recovery and evictor aggressive mode.
- **Why did CAST AI pick these instance types?** Cheapest offering that fits the pending pods inside template constraints (amd64, 2–4 vCPU, spot). Recently interrupted types and zones are temporarily avoided.
- **Why is the result not cheaper than Karpenter?** Same inputs (requests), same price-aware bin-packing. Differences of a few cents are instance-choice noise, not a capability gap.
- **What if the CAST AI SaaS is unreachable?** Running pods are unaffected; new pending pods wait. Vendor-documented fallbacks include a delayed Karpenter or Cluster Autoscaler.
- **Why `sleep 60`?** EC2 releases spot vCPU quota shortly after termination, not instantly. Without the pause, the first CAST AI launch can fail on quota.
- **Can CAST AI touch the system node?** Evictor is in scoped mode (only `managed-by=cast.ai` nodes). The autoscaler only creates nodes from templates and never resizes the managed node group.
