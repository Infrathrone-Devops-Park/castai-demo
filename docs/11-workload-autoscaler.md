# 11 — Workload Autoscaler: rightsizing requests
**Time:** 40 min · **Goal:** Shrink the `shop` requests from measured usage (6 vCPU to ~1.8 vCPU once the install is 24 h old; to 4.5 vCPU on a 3 h old install), then watch the node count follow.

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
- Check the plan in the console: the Workload Autoscaler is a **Premium** feature (trial). Console → Settings → Platform usage. On this org (`billingType: none`) policy creation and in-place apply were not blocked.
- **Confidence before opt-in is low; that is expected.** Until Step 4, `shop` sits on system policies (`balanced`, `stability`) with a 3-day look-back, so after 3 h the API shows `lowConfidence: true`, confidence < 1 %, and recommendations capped at the gradual limit: exactly 0.9x the request in the first 2.4 h after the Workload Autoscaler install, 0.75x until 6 h (the cluster-age cap below). Confidence is measured against the policy look-back: it jumps to ~0.96–1.0 within a minute of Step 5, once the 3 h `shop-rightsizing` policy owns the workloads.
- **T-4h gives only a capped saving.** CAST AI caps every change by *cluster age*, counted from the Workload Autoscaler install (`phase=automation`, module 05), and the annotation does **not** bypass it on this version (v1.14.2), contrary to the docs: max change 10 % (< 2.4 h), 25 % (< 6 h), 35 % (< 24 h), uncapped after 24 h. Real run, install + 3 h: the event log shows the raw p80 + 10 % (cart 78m) and then `"maxAllowedChangePercent": 25`, `"message": "Newly onboarded clusters achieve full recommendations over time"`, applied value 225m. For the full drop, apply `phase=automation` (module 05 Step 9, autoscaler still off) **at least 24 h before the session**. The rest of this module shows both: the capped value applied live and the raw value from the event log.

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
- **Confidence**: share of expected data points within the policy look-back (threshold 0.9). Workloads enabled **manually** (annotation or console toggle) skip the confidence gate; policy-enabled ones wait for it.
- **Cluster-age cap**: on a cluster whose Workload Autoscaler is younger than 24 h, every change is capped: 10 % / 25 % / 35 % for < 2.4 h / < 6 h / < 24 h. The docs say manual enable bypasses this; on this cluster (v1.14.2) it did **not**. Per-workload opt-in is still used here because it is the safe rollout pattern.

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
castai-workload-autoscaler   2/2     2            2           ...
NAME                         WEBHOOKS   AGE
castai-workload-autoscaler   2          ...
```
`terraform output` also lists `batch_template_offering = "disabled"` and `rebalancing_schedule_id = ""`. Two webhooks: `workload-autoscaler.cast.ai` and `hpa-ownership.cast.ai`, both `failurePolicy: Ignore`, timeout 10 s.

API view of the same component:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/components/workload-autoscaler"
```
Expected (trimmed):
```json
{
  "status": "AGENT_STATUS_RUNNING",
  "latestVersion": "v1.14.2",
  "currentVersion": "v1.14.2",
  "inPlaceResizeEnabled": true,
  "workloadAutoscalerReplicaCount": 2,
  "psiMetricsSupported": true,
  ...
}
```
Point at `inPlaceResizeEnabled: true`.

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
                     ~1590m      ~1260Mi
```
Say: 6.0 vCPU requested, ~1.6 vCPU used. Every node Karpenter or CAST AI bought so far was sized for the 6.0.

### Step 3 — Read the recommendations (console + API)
Recommendations exist before anything is enabled.

Console → cluster `karpenter-demo` → **Workload Autoscaler → Workloads** → filter namespace `shop`. Each row shows current requests next to the CPU and memory recommendation, plus the assigned policy (a system policy such as `balanced` until Step 4).

Same data from the API (the endpoint ignores namespace filters, so jq selects `shop`):
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workloads" | jq -r '(["NAME","POLICY","CPU_REQ","CPU_REC","MEM_REQ_GiB","MEM_REC_GiB","CONF","LOW_CONF"]), (.workloads[] | select(.namespace=="shop") | [.name, .scalingPolicyName, .containers[0].resources.requests.cpuCores, .containers[0].recommendation.requests.cpuCores, .containers[0].resources.requests.memoryGib, .containers[0].recommendation.requests.memoryGib, (.recommendation.confidence*1000|round/1000), .recommendationStatus.lowConfidence]) | @tsv' | column -t
```
Expected at ~3 h (real run, connect + 3 h 07 min):
```text
NAME      POLICY     CPU_REQ  CPU_REC  MEM_REQ_GiB  MEM_REC_GiB  CONF   LOW_CONF
frontend  stability  0.4      0.3      0.25         0.1875       0.015  true
catalog   balanced   0.5      0.375    0.375        0.28125      0.01   true
worker    balanced   0.7      0.525    0.5          0.375        0.005  true
checkout  balanced   0.5      0.375    0.25         0.1875       0.01   true
payments  balanced   0.4      0.3      0.25         0.1875       0.011  true
cart      balanced   0.3      0.225    0.25         0.1875       0.011  true
```
Every recommendation is exactly 0.75x the request: that is the gradual cap, not usage. Say so. Actual usage (Step 2) is 70–250m per pod, so the uncapped p80 + 10 % is 1.76 vCPU for all 13 replicas (event log, Step 6). Row order varies between calls.

### Step 4 — Create the scaling policy with Terraform
Policy as code, auto-assigned to `shop`, automation still off.
```bash
cat terraform/workload-autoscaler.tf
terraform -chdir=terraform plan -input=false -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=true
```
Expected:
```text
  # castai_workload_scaling_policy.shop[0] will be created
...
Plan: 1 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  ~ workload_scaling_policy_name = "" -> "shop-rightsizing"
...
Saved the plan to: tfplan
```
No other resource changes.
```bash
terraform -chdir=terraform apply -input=false tfplan
rm -f terraform/tfplan
```
Expected: `Creation complete after 1s`, `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.` and `workload_scaling_policy_name = "shop-rightsizing"`.

Console → **Workload Autoscaler → Scaling policies** → `shop-rightsizing`: automation off, CPU p80 / overhead 10 %, memory max / overhead 10 %, look-back 3 h, apply immediately.

API check:
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/policies" | jq -r '.items[] | [.name, .applyType, (.isReadonly|tostring)] | @tsv'
```
Expected:
```text
readonly	IMMEDIATE	true
resiliency	DEFERRED	true
burstable	DEFERRED	true
stability	IMMEDIATE	true
cost-savings	IMMEDIATE	true
balanced	IMMEDIATE	true
shop-rightsizing	IMMEDIATE	false
```
Assignment does not move workloads at once: right after the apply the `shop` rows still show `balanced`/`stability`. Step 5 switches them.

Note: `scripts/switch-to-karpenter.sh` keeps this policy if it exists (it reads the Terraform output). `scripts/reset.sh` deletes it.

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
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workloads" | jq -r '.workloads[] | select(.namespace=="shop") | [.name, .scalingPolicyName, .managedBy, .workloadConfigV2.vpaConfig.managementOption, (.recommendation.confidence*1000|round/1000)] | @tsv'
```
Expected (real run, 38 s after the patch):
```text
catalog   shop-rightsizing  ANNOTATIONS  MANAGED  0.961
frontend  shop-rightsizing  ANNOTATIONS  MANAGED  0.961
...
```
Six rows, all `shop-rightsizing  ANNOTATIONS  MANAGED`. Confidence is now measured against the 3 h look-back: 0.96, 1.0 a few minutes later, `lowConfidence: false`. Before the patch the rows read `balanced  API  READ_ONLY`.

### Step 6 — Watch requests drop on the running pods
Pod spec, not the Deployment, is what changes.
```bash
while true; do kubectl get pods -n shop -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'; echo; sleep 20; done
```
Expected: within 15–25 s of the patch all 13 pods resize **in place** (same names, `RESTARTS 0`). On a 3 h old install every value drops by exactly 25 %:
```text
POD                         CPU_REQ   MEM_REQ   RESTARTS   NODE
cart-95964d456-rmc8k        225m      192Mi     0          ip-10-0-42-175...
catalog-ccb466788-7mwz8     375m      288Mi     0          ip-10-0-20-53...
frontend-648f7d5586-l9g7s   300m      192Mi     0          ip-10-0-20-53...
worker-5c5549fc45-7h8hc     525m      384Mi     0          ip-10-0-20-53...
...
```
On a 24 h+ install expect roughly cart 80m, catalog 140m, checkout/frontend/payments 110m, worker 280m. About 40 s later the evictor empties the now-underused node: a few pods get **new names** (evicted, not restarted). Press Ctrl-C.

Proof it was applied, and that it was in place:
```bash
kubectl get pods -n shop -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.autoscaling\.cast\.ai/recommendation-applied-at}{"\t"}{.status.containerStatuses[0].resources.requests.cpu}{"\n"}{end}'
kubectl get events -n shop --field-selector reason=ResizeCompleted --sort-by=.lastTimestamp | tail -5
```
Expected: an RFC3339 timestamp per pod and the running (status) CPU equal to the new request; kubelet events `ResizeStarted` then `ResizeCompleted` (`Pod resize completed: {"containers":[{"name":"app","resources":{...,"requests":{"cpu":"225m",...`). Pods also carry `autoscaling.cast.ai/original-container-resources` with the template values.

Where the number came from (raw value, then the cap):
```bash
scripts/castai-api.sh GET "/v1/workload-autoscaling/clusters/${CASTAI_CLUSTER_ID}/workload-events?workloadNamespace=shop&workloadName=cart&page.limit=1" | jq -c '.items[0].event.recommendedRequestsChanged.debugData.recommendations.app.changes[] | {message, cpu, maxAllowedChangePercent, clusterAge}'
```
Expected (3 h old install):
```text
{"message":"Base requests","cpu":71,...}
{"message":"Adjusted for overhead","cpu":78,...}
{"message":"Newly onboarded clusters achieve full recommendations over time","cpu":225,"maxAllowedChangePercent":25,"clusterAge":"3h2m58s"}
...
```
Read it out: usage says 78m, the cluster-age cap allows 225m today.

Totals, and the Deployment still says the old numbers:
```bash
kubectl get pods -n shop -o json | jq '[.items[] | select(.status.phase=="Running") | .spec.containers[].resources.requests.cpu // "0" | if endswith("m") then (rtrimstr("m")|tonumber/1000) else tonumber end] | add'
kubectl get deploy -n shop -o custom-columns='DEPLOY:.metadata.name,TEMPLATE_CPU:.spec.template.spec.containers[0].resources.requests.cpu'
```
Expected: `4.5` on a 3 h old install (about `1.8` after 24 h; was `6`), and the templates still show 300m–700m.

### Step 7 — Nodes follow the requests
Smaller requests leave nodes half empty; the evictor packs, empty nodes go after 60 s.
```bash
while true; do date; kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,scheduling.cast.ai/spot; echo; sleep 30; done
```
Expected: CAST AI node count drops by one within ~1–2 min of the resize (real run: c5a.large cordoned 23:28:39, 9 pods evicted, instance terminated 23:28:54; 3 → 2 workers). The system node never changes. Ctrl-C when stable for 2 min. On a 24 h+ install (~1.8 vCPU) expect 1–2 workers.

Why it can take minutes: evictor cycle 60 s, node grace period 5 min for young nodes, it only moves pods from multi-replica Deployments (all `shop` Deployments have 2+ replicas), then empty nodes go after 60 s. The node hosting `castai-workload-autoscaler-exporter` (1 replica) is never drained.
```bash
kubectl -n castai-agent logs deploy/castai-evictor --tail=20
```
Expected: one cycle per minute. When it packs: `pricing-aware sorting strategy picked the following nodes for drain: [<node>]`, `cordoned nodes`, `starting eviction ... num_pods=9`. When stable: `#2 node - ... eliminated by filters, reason: single replica - castai-agent/castai-workload-autoscaler-exporter-...`, `couldn't find any nodes to drain`.

Console → cluster → **Nodes** (or Cluster dashboard): nodes marked for deletion, then removed. If one node keeps a single straggler for >10 min, Console → **Rebalancer** → plan for at most 2 nodes (quota rule: replacements start before old nodes go).

### Step 8 — Measure and compare
Same measurement as every other snapshot.
```bash
scripts/measure.sh castai-rightsized
scripts/compare.sh castai-autoscaler castai-rightsized
scripts/compare.sh karpenter-baseline castai-rightsized
```
Expected (real run, 3 h old install, 25 % cap), last comparison:
```text
METRIC                      A       B       DELTA    CHANGE
worker nodes                2       2       0        0%
provisioned vCPU (workers)  8       6       -2       -25%
requested vCPU (shop)       6       4.5     -1.5     -25%
used vCPU (shop)            1.59    1.589   -0.001   -0.1%
$/h workers                 0.1047  0.0681  -0.0366  -35%
$/h all-in                  0.254   0.2174  -0.0366  -14.4%
$/month workers             76.43   49.71   -26.72   -35%

Node types:
  karpenter-baseline:    1x c6a.xlarge/spot, 1x c8i-flex.xlarge/spot
  castai-rightsized:     1x c6a.xlarge/spot, 1x c8i-flex.large/spot
```
Point at `requested vCPU (shop)` falling while `used vCPU (shop)` stays flat. That gap is the money. Be honest about `castai-autoscaler` vs `castai-rightsized`: in the real run workers fell 4 → 2 and vCPU 8 → 6, yet `$/h workers` rose 4.4 % (0.0652 → 0.0681), because the evictor kept a c6a.xlarge (0.0518/h) and four c8i-flex.large were cheaper per vCPU (0.0163/h). Spot price per vCPU, not node count, decides the bill.

Optional console cross-check: Cost → **Cluster efficiency** (provisioned vs requested vs used CPU) and the **Workload Autoscaler** dashboard savings card.

## Talking points
- "Karpenter is price-optimal *for the requests it is given*. Today the requests were 3.4x too big (6 vs 1.76 raw recommendation), and no node autoscaler can fix that."
- New installs are throttled on purpose: 25 % per change in the first 6 h, 35 % until 24 h. That is a safety feature; say so instead of apologising for it.
- Rightsizing happened without restarts on 1.36 (kubelet `ResizeCompleted`). Only the evictor's node packing moved pods. On older clusters the same policy evicts pods (PDBs respected).
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
terraform -chdir=terraform plan -input=false -out=tfplan -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=false
terraform -chdir=terraform apply -input=false tfplan
rm -f terraform/tfplan
until [ -z "$(kubectl get recommendations.autoscaling.cast.ai -n shop -o name)" ]; do sleep 10; done
kubectl delete pods -n shop --all
```
Expected: pods come back with the template requests (300m–700m); CAST AI adds nodes back (≤8 spot vCPU).
Order matters: remove the annotation **before** deleting the policy, otherwise the workloads fall back to `balanced` with optimization still on. Then wait for the `Recommendation` CRs to go (~40 s): pods recreated earlier get the rightsized values from the webhook, and the later in-place revert to template values fails with `ResizeDeferred ... OutOfcpu`, so the pod spec shows 6 vCPU while the node still runs the small allocation and CAST AI adds no node. `scripts/reset.sh` handles both.

## Q&A prep
- **Does it fight HPA?** Not when both are on the same workload; it simulates HPA behavior to pick CPU. Module 12.
- **Will it OOM my pods?** Memory uses max + overhead, OOM kills trigger an immediate +20 % (≥100 Mi) bump, capped at 2.5x, and auto-disable after 20 OOMs/h.
- **Is the recommendation trustworthy after 3 h?** For steady `stress-ng`, yes. For real apps use 1–7 days. Manual enable skips the confidence gate (event log: `Confidence is not required for option managed`), but not the cluster-age cap (25 % / 35 % per change in the first 6 h / 24 h).
- **Does it change limits?** Our policy uses `KEEP_LIMITS`. Other options: no limit, multiplier, keep ratio. Memory limits are never lowered in place.
- **What if CAST AI is down?** Pods keep their current requests; both webhooks (`workload-autoscaler.cast.ai`, `hpa-ownership.cast.ai`) have `failurePolicy: Ignore` and a 10 s timeout, so pod creation is not blocked.
- **Can I see why a value was chosen?** Console → workload → Event log → "Recommendation generated" (JSON view).
- **VPA instead?** Valid, especially without HPAs on CPU/memory. See module 13 for the counterfactual.
