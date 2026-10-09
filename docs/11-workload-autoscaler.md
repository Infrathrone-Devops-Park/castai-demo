# 11 — Workload Autoscaler: rightsizing requests
**Time:** 40 min · **Goal:** Shrink the `shop` requests from ~6 vCPU to ~2 vCPU from measured usage, then watch the node count follow.

## What you'll show
- The core argument of the day: **Karpenter optimizes nodes for the requests it is given. The requests are wrong.** Nothing in Karpenter changes them.
- CAST AI recommendations for the 6 `shop` Deployments (console and API), computed from ≥3 h of real usage.
- A scaling policy as code: `castai_workload_scaling_policy` in `terraform/workload-autoscaler.tf` (CPU p80 + 10 %, memory max + 10 %, IMMEDIATE, 3 h look-back), assigned to namespace `shop`.
- Per-workload opt-in by annotation. Pod requests drop **in place** on Kubernetes 1.36, with no restarts expected; the Deployment template is not touched.
- Evictor + empty-node deletion remove the now half-empty nodes.
- Snapshot `castai-rightsized`, compared against `karpenter-baseline` and `castai-autoscaler`.

## Prep (do not skip)
- `workloads/shop.yaml` must be deployed and the CAST AI agent connected **at least 3 h before** this module. Deploy at **T-4h**. The minimum look-back is 3 h; with less history the recommendations are partial or missing.
- At T-30 min run Step 3. Every `shop` workload must show a non-null recommendation. If one is null, wait. Recommendations regenerate every 30 min.
- CAST AI must be the active autoscaler (`scripts/switch-to-castai.sh` done earlier, or `scripts/reset.sh`). Snapshots `karpenter-baseline` and `castai-autoscaler` must already exist in `results/`.
- Check the plan in the console: the Workload Autoscaler is a **Premium** feature (trial). Console → Settings → Platform usage. <!-- VERIFY: trial covers Workload Autoscaler -->

## Concepts

### Where a recommendation comes from
```text
usage samples (per container, look-back window: 3h .. 7d)
   -> CPU:    percentile (default p80) averaged across pods
   -> memory: max (default) over the window
   -> x (1 + overhead)                  default 10 %
   -> clamp to constraints (min / max)
   -> apply only if |new - current| > apply threshold (default 10 %, or adaptive)
regenerated every 30 min, and immediately on anomalies (usage >= 50 % above recommendation)
```
- **Look-back**: 3 h minimum, 7 d maximum. Short windows react fast. Long windows capture weekly cycles. Docs suggest 1–2 days for typical web apps; we use 3 h only because the demo has 4 h of history.
- **Overhead**: headroom added after the percentile. 10 % default; capped at 250 %.
- **Confidence**: share of expected data points actually collected. Workloads enabled through a **policy** on a cluster onboarded less than 24 h ago get gradual caps (max change 10 % / 25 % / 35 % for < 2.4 h / < 6 h / < 24 h of data). Workloads enabled **manually** (annotation or console toggle) skip those caps. That is why this module enables per workload.

### Apply types
| | IMMEDIATE | DEFERRED |
|---|---|---|
| When | As soon as a recommendation crosses the threshold | Never forces anything |
| How (k8s 1.33+) | In-place resize first; evicts the pod if the resize stays pending | In-place resize if possible, else at the next natural restart |
| How (older k8s) | Evict; the mutating webhook sets new requests on the new pod | Webhook applies at the next deploy/scale/node drain |
| PDBs | Respected (Eviction API) | n/a |

- **In-place resize** is GA in Kubernetes 1.35; this cluster runs 1.36. CPU and memory requests change on the running pod. **Memory limits are never decreased in place.** QoS class must stay the same, otherwise the change needs a restart.
- The webhook mutates **pods**, not the Deployment. Your Git manifests and `kubectl get deploy` keep the original requests. There is no drift for GitOps tools to fight, but the "real" requests now live in CAST AI.
- Two annotations land on pods: `autoscaling.cast.ai/vertical-recommendation-hash` and `autoscaling.cast.ai/recommendation-applied-at`. The second changes on every in-place apply (about every 30 min), which can add label churn in Prometheus if you index pod annotations.

### Memory safety and startup
- **OOM kill**: memory recommendation is raised by 20 % (minimum +100 Mi), applied immediately, capped at 2.5x the original. It decays back over 24 h. After 20 OOMs in 1 h, optimization is switched off for that workload for 4 h.
- **CPU stall detection** uses PSI (pressure stall) to raise CPU when pods are starved.
- **Startup**: for JVM/.NET-style workloads you can set a startup period (2–60 min). "Startup recommendations" keep the original requests during startup, then resize in place. Our `stress-ng` pods have no startup spike, so the demo policy leaves it unset.

### Karpenter has no equivalent
- Karpenter provisions from requests and consolidates. It has no recommender. The v1.14 in-place resize RFC is about *reacting* to resizes, not producing them.
- The honest open-source answer is **Karpenter + VPA** (VPA 1.8, `InPlaceOrRecreate` mode). It covers a large part of this: p90 + 15 % margin, OOM bump, in-place updates. What you give up: one VPA object per workload, no namespace policy or console, VPA must not share CPU/memory with an HPA (module 12), no savings accounting, slower convergence (8-day decaying histograms), and you run it yourself. Module 13 shows it.

### What the policy in this repo does
`terraform/workload-autoscaler.tf`, created only when `enable_workload_autoscaler=true`:

| Setting | Value | Why |
|---|---|---|
| `name` | `shop-rightsizing` | Referenced by the annotation |
| `apply_type` | `IMMEDIATE` | See the effect live |
| `management_option` | `READ_ONLY` | Policy-wide automation off; we opt in per workload |
| `assignment_rules` | namespace `shop` | Auto-assign every `shop` workload |
| `cpu` | `QUANTILE ["0.8"]`, overhead 0.1, look-back 10800 s, min 0.05 cores, `KEEP_LIMITS` | p80 + 10 %, 3 h |
| `memory` | `MAX`, overhead 0.1, look-back 10800 s, min 64 MiB, `KEEP_LIMITS` | max + 10 %, 3 h |
| `downscaling` / `memory_event` | `IMMEDIATE` | No waiting for restarts |

## Demo

### Step 1 — Confirm CAST AI is the autoscaler and the Workload Autoscaler runs
Rightsizing needs the in-cluster `castai-workload-autoscaler` (installed by `phase=automation`).
```bash
source scripts/env.sh
terraform -chdir=terraform output
kubectl -n kube-system get deploy karpenter -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n castai-agent get deploy castai-workload-autoscaler
kubectl get mutatingwebhookconfiguration castai-workload-autoscaler
```
Expected:
```text
autoscaler_enabled = true
castai_cluster_id = "<uuid>"
castai_role_arn = "arn:aws:iam::146725924014:role/castai-eks-karpenter-demo"
phase = "automation"
workload_scaling_policy_name = ""
0
NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
castai-workload-autoscaler   1/1     1            1           ...
NAME                         WEBHOOKS   AGE
castai-workload-autoscaler   1          ...
```
<!-- VERIFY: deployment name and READY count (umbrella may run 2 replicas) -->

API view of the same component:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/components/workload-autoscaler"
```
Expected: JSON with the component version and a healthy/running status. <!-- VERIFY: response field names -->

### Step 2 — The waste, in plain kubectl
Requests come from the Deployment template; usage from metrics-server.
```bash
kubectl get deploy -n shop -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory'
kubectl top pods -n shop --sum
```
Expected:
```text
DEPLOY     REPLICAS   CPU_REQ   MEM_REQ
cart       2          300m      256Mi
catalog    2          500m      384Mi
checkout   2          500m      256Mi
frontend   3          400m      256Mi
payments   2          400m      256Mi
worker     2          700m      512Mi
...
                     ________    ________
                     ~1600m      ~1000Mi
```
Say: 6.0 vCPU requested, ~1.6 vCPU used. Every node Karpenter or CAST AI bought so far was sized for the 6.0.

### Step 3 — Read the recommendations (console + API)
Recommendations exist before anything is enabled.

Console → cluster `karpenter-demo` → **Workload Autoscaler → Workloads** → filter namespace `shop`. Each row shows current requests next to the CPU and memory recommendation, plus the assigned policy (a system policy such as `balanced` until Step 4).

Same data from the API:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workloads?namespaces=shop" | jq -r '(["NAME","POLICY","CPU_REQ","CPU_REC","MEM_REQ_GiB","MEM_REC_GiB"]), (.workloads[] | [.name, .scalingPolicyName, .containers[0].resources.requests.cpuCores, .containers[0].recommendation.requests.cpuCores, .containers[0].resources.requests.memoryGib, .containers[0].recommendation.requests.memoryGib]) | @tsv' | column -t
```
Expected (values vary with real usage):
```text
NAME      POLICY    CPU_REQ  CPU_REC  MEM_REQ_GiB  MEM_REC_GiB
cart      balanced  0.3      0.08     0.25         0.08
catalog   balanced  0.5      0.14     0.375        0.15
checkout  balanced  0.5      0.11     0.25         0.08
frontend  balanced  0.4      0.11     0.25         0.08
payments  balanced  0.4      0.11     0.25         0.08
worker    balanced  0.7      0.28     0.5          0.22
```
<!-- VERIFY: path params and field names (containers[].recommendation.requests.cpuCores); system policy name shown -->
Sum of p80 + 10 % over 13 replicas is roughly 1.7–2.0 vCPU.

### Step 4 — Create the scaling policy with Terraform
Policy as code, auto-assigned to `shop`, automation still off.
```bash
cat terraform/workload-autoscaler.tf
terraform -chdir=terraform plan -input=false -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=true
```
Expected:
```text
  # castai_workload_scaling_policy.shop[0] will be created
...
Plan: 1 to add, 0 to change, 0 to destroy.
```
<!-- VERIFY: no other drift in plan -->
```bash
terraform -chdir=terraform apply -auto-approve -input=false -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=true
```
Expected: `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.` and `workload_scaling_policy_name = "shop-rightsizing"`.

Console → **Workload Autoscaler → Scaling policies** → `shop-rightsizing`: automation off, CPU p80 / overhead 10 %, memory max / overhead 10 %, look-back 3 h, apply immediately.

API check:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/policies" | jq -r '.items[] | [.name, .applyType, (.isReadonly|tostring)] | @tsv'
```
Expected: system policies (`balanced`, `cost-savings`, `stability`, `resiliency`, `burstable`, `readonly`, ...) plus a line `shop-rightsizing  IMMEDIATE  false`. <!-- VERIFY: applyType enum spelling -->

Note: `scripts/switch-to-castai.sh` and `scripts/switch-to-karpenter.sh` run `terraform apply` without `enable_workload_autoscaler`, so they **delete** this policy. Re-run this step if you use them later.

### Step 5 — Opt the 6 Deployments in
The annotation pins the policy and turns vertical scaling on; it touches metadata only, so no rollout.
```bash
cat manifests/11-workload-autoscaler/enable-patch.yaml
for d in $(kubectl get deploy -n shop -o name); do kubectl patch -n shop "$d" --type merge --patch-file manifests/11-workload-autoscaler/enable-patch.yaml; done
```
Expected:
```text
deployment.apps/cart patched
deployment.apps/catalog patched
deployment.apps/checkout patched
deployment.apps/frontend patched
deployment.apps/payments patched
deployment.apps/worker patched
```
Console equivalent: Workloads → `<workload>` → **Optimization** toggle. Once the annotation exists the console locks that workload's settings ("configured by annotations").

Verify with the API (allow ~1 min for the agent snapshot):
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workloads?namespaces=shop" | jq -r '.workloads[] | [.name, .scalingPolicyName, .managedBy, .workloadConfigV2.vpaConfig.managementOption] | @tsv'
```
Expected: every row `shop-rightsizing  ANNOTATIONS  MANAGED`. <!-- VERIFY: managementOption reflects the annotation -->

### Step 6 — Watch requests drop on the running pods
Pod spec, not the Deployment, is what changes.
```bash
while true; do kubectl get pods -n shop -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'; echo; sleep 20; done
```
Expected within ~1–5 min: same pod names, `RESTARTS 0`, CPU_REQ falling from 300m–700m to ~80m–280m and MEM_REQ to ~70–230Mi. Press Ctrl-C when all 13 pods changed.
<!-- VERIFY: time to first apply; whether IMMEDIATE resizes in place or evicts (new pod names) on this cluster -->

Proof it was applied, and that it was in place:
```bash
kubectl get pods -n shop -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.autoscaling\.cast\.ai/recommendation-applied-at}{"\t"}{.status.containerStatuses[0].resources.requests.cpu}{"\n"}{end}'
kubectl get events -n shop --field-selector reason=ResizeCompleted --sort-by=.lastTimestamp | tail -5
```
Expected: an RFC3339 timestamp per pod, the allocated CPU equals the new request; events show completed resizes. <!-- VERIFY: kubelet event reason name for in-place resize -->

Totals, and the Deployment still says the old numbers:
```bash
kubectl get pods -n shop -o json | jq '[.items[] | select(.status.phase=="Running") | .spec.containers[].resources.requests.cpu // "0" | if endswith("m") then (rtrimstr("m")|tonumber/1000) else tonumber end] | add'
kubectl get deploy -n shop -o custom-columns='DEPLOY:.metadata.name,TEMPLATE_CPU:.spec.template.spec.containers[0].resources.requests.cpu'
```
Expected: `~1.7` to `~2.2` (was `6`), and the templates still show 300m–700m.

### Step 7 — Nodes follow the requests
Smaller requests leave nodes half empty; the evictor packs, empty nodes go after 60 s.
```bash
while true; do date; kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,scheduling.cast.ai/spot; echo; sleep 30; done
```
Expected over 5–15 min: CAST AI node count drops (for example 3 → 1 or 2). The system node never changes. Ctrl-C when stable for 2 min.

Why it takes minutes: evictor cycle 60 s, node grace period 5 min, it only moves pods from multi-replica Deployments (all `shop` Deployments have 2+ replicas), then the node deletion policy removes empty nodes after 60 s.
```bash
kubectl -n castai-agent logs deploy/castai-evictor --tail=20
```
Expected: lines about candidate nodes and evicted pods. <!-- VERIFY: evictor deployment name and log wording -->

Console → cluster → **Nodes** (or Cluster dashboard): nodes marked for deletion, then removed. If one node keeps a single straggler for >10 min, Console → **Rebalancer** → plan for at most 2 nodes (quota rule: replacements start before old nodes go).

### Step 8 — Measure and compare
Same measurement as every other snapshot.
```bash
scripts/measure.sh castai-rightsized
scripts/compare.sh castai-autoscaler castai-rightsized
scripts/compare.sh karpenter-baseline castai-rightsized
```
Expected (shape; numbers from your run):
```text
METRIC                      A       B       DELTA    CHANGE
worker nodes                3       1       -2       -66.7%
requested vCPU (shop)       6       1.9     -4.1     -68.3%
used vCPU (shop)            1.6     1.6     ...      ...
$/h workers                 0.13    0.05    ...      -60%
$/h all-in                  0.28    0.20    ...      -28%
...
saved results/castai-rightsized.json
```
Point at `requested vCPU (shop)` falling while `used vCPU (shop)` stays flat. That gap is the money.

Optional console cross-check: Cost → **Cluster efficiency** (provisioned vs requested vs used CPU) and the **Workload Autoscaler** dashboard savings card.

## Talking points
- "Karpenter is price-optimal *for the requests it is given*. Today the requests were 4x too big, and no node autoscaler can fix that."
- Rightsizing happened without restarts on 1.36. On older clusters the same policy evicts pods (PDBs respected).
- The Deployment template is unchanged. Remove the annotation, restart, and you are back to 6 vCPU. Exit is clean, but so is relapse.
- 3 h look-back is a demo setting. Production: 1–2 days for web apps, 7 d for weekly cycles, longer for batch.
- Per-workload opt-in is also the safe production rollout: a few workloads first, then turn on policy automation.
- VPA + Karpenter would get a large part of this saving for free. CAST AI's edge is policies at scale, HPA coordination (next module), confidence handling and the console. Say this before someone else does.

## Reset
Returns to the CAST AI active baseline (policy gone, annotations removed, original requests, nodes re-sized by CAST AI).
```bash
scripts/reset.sh
```
Manual equivalent:
```bash
kubectl annotate deploy --all -n shop workloads.cast.ai/configuration-
terraform -chdir=terraform apply -auto-approve -input=false -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=false
kubectl delete pods -n shop --all
```
Expected: pods come back with the template requests (300m–700m); CAST AI adds nodes back (≤8 spot vCPU).
Order matters: remove the annotation **before** deleting the policy, otherwise the workloads fall back to `balanced` with optimization still on.

## Q&A prep
- **Does it fight HPA?** Not when both are on the same workload; it simulates HPA behavior to pick CPU. Module 12.
- **Will it OOM my pods?** Memory uses max + overhead, OOM kills trigger an immediate +20 % (≥100 Mi) bump, capped at 2.5x, and auto-disable after 20 OOMs/h.
- **Is the recommendation trustworthy after 3 h?** For steady `stress-ng`, yes. For real apps use 1–7 days. Confidence gates protect policy-enabled workloads; manual enable skips them, so use it deliberately.
- **Does it change limits?** Our policy uses `KEEP_LIMITS`. Other options: no limit, multiplier, keep ratio. Memory limits are never lowered in place.
- **What if CAST AI is down?** Pods keep their current requests; the webhook has a failure policy so pod creation is not blocked. <!-- VERIFY: webhook failurePolicy=Ignore -->
- **Can I see why a value was chosen?** Console → workload → Event log → "Recommendation generated" (JSON view).
- **VPA instead?** Valid, especially without HPAs on CPU/memory. See module 13 for the counterfactual.
