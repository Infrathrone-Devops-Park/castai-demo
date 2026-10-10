# 00 — Agenda & setup
**Time:** 15 min · **Goal:** Set expectations, show the lab and the measurement method, and confirm the cluster is ready before anything moves.

## What you'll show
- The agenda (modules 00–15) and where the breaks are.
- The lab: the same EKS 1.36 cluster from the Karpenter course, the same `shop` workload, measured under Karpenter and then under CAST AI.
- The vCPU quota budget and why only one autoscaler may run at a time.
- The prep that already happened (the `shop` app has been running for 3+ hours).
- A live health check.

## Concepts

### Agenda

Times are targets. Content ≈ 5 h 45 min; with breaks ≈ 6 h 35 min.

| # | Module | Min | Starts at (T+) |
|---|---|---|---|
| 00 | Agenda & setup | 15 | 0:00 |
| 01 | Where Kubernetes money goes | 20 | 0:15 |
| 02 | Karpenter baseline | 30 | 0:35 |
| 03 | Connect CAST AI read-only | 25 | 1:05 |
| — | Break | 10 | 1:30 |
| 04 | Savings report & cost monitoring | 25 | 1:40 |
| 05 | Phase 2: automation onboarding | 25 | 2:05 |
| 06 | Switch-over Karpenter → CAST AI | 20 | 2:30 |
| — | Lunch | 30 | 2:50 |
| 07 | Autoscaler & node templates | 20 | 3:20 |
| 08 | Evictor bin-packing | 20 | 3:40 |
| 09 | Rebalancing | 20 | 4:00 |
| 10 | Spot: fallback & interruption | 20 | 4:20 |
| — | Break | 10 | 4:40 |
| 11 | Workload Autoscaler (rightsizing) | 30 | 4:50 |
| 12 | Workload Autoscaler + HPA | 20 | 5:20 |
| 13 | Head-to-head results | 20 | 5:40 |
| 14 | Pricing, ROI, security, lock-in | 15 | 6:00 |
| 15 | Switch back & offboarding | 20 | 6:15 |
| | **End** | | **6:35** |

If you run behind, cut in this order: 10 (talk only), 08 (fold into 09), 12 (show the event log only). Never cut 13 or 15.

### The story in one line
Karpenter buys the cheapest nodes **for the requests it is given**. Most waste is in the requests themselves. We measure what each tool changes, and we say out loud where Karpenter (plus VPA) gets the same result for free.

### Lab architecture

```text
                       AWS account 146725924014 · ap-south-1
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ VPC (karpenter-demo), private subnets tag karpenter.sh/discovery          │
 │                                                                           │
 │  ┌──────────────────────────────┐   ┌──────────────────────────────────┐  │
 │  │ MNG "system" 1x t3a.large    │   │ Worker nodes, ONE owner at a time│  │
 │  │ role=system, CriticalAddons  │   │  A) Karpenter NodePool default   │  │
 │  │ karpenter (1 replica)        │   │     c/m/r, 2-4 vCPU, spot+OD     │  │
 │  │ coredns, metrics-server      │   │  B) CAST AI default-by-castai    │  │
 │  │ monitoring stack             │   │     amd64, 2-4 vCPU, spot only   │  │
 │  │ castai-agent + controllers   │   │     (+ on-demand fallback)       │  │
 │  └──────────────────────────────┘   │  ns shop: 6 deployments          │  │
 │                                     └──────────────────────────────────┘  │
 └───────────────────────────────────────────────────────────────────────────┘
   ▲ EKS 1.36 API                         ▲ EC2 RunInstances / Terminate
   │                                      │
 castai-agent ── HTTPS ──► api.cast.ai ───┘ (assumes role castai-eks-karpenter-demo)
 (snapshots: nodes, pods, metrics)           SaaS decides, cluster-controller acts
```

Two Terraform roots, two states:
- `../karpenter-demo/terraform`: VPC, EKS, system node group, Karpenter IAM. Not touched here.
- `castai-demo/terraform`: data sources for the cluster, plus CAST AI registration, IAM role, node configuration, node template, autoscaler policies, evictor and the `castai` Helm chart.

### Quota budget (hard limit)

| Quota (ap-south-1) | Limit | Used by system node | Free |
|---|---|---|---|
| Running On-Demand Standard vCPU | 8 | 2 | 6 |
| All Standard Spot Instance Requests vCPU | 8 | 0 | 8 |

Rules that follow from it:
- **Only one autoscaler is active.** Karpenter (NodePool `default`, limit 10 vCPU) or CAST AI (`autoscaler_enabled=true`, template limit 8, cluster limit 10). Never both: CAST AI documents running both as unsupported.
- The switch is scripted (`scripts/switch-to-castai.sh`, `scripts/switch-to-karpenter.sh`): freeze, drain, wait, `sleep 60` for quota release, then hand over.
- `shop` requests 6.0 vCPU. Two 4-vCPU nodes hold it. Rebalancing creates nodes before removing old ones, so we rebalance at most 2 nodes at a time.

### Measurement method (used in every phase)
`scripts/measure.sh <label>` prints one row per node (provisioner, type, spot/on-demand, zone, vCPU, $/h) and totals: provisioned, requested and used vCPU, plus $/h and $/month for workers only and all-in. On-demand prices come from the AWS Price List API, spot prices from `describe-spot-price-history` for that type and AZ, cached in `results/price-cache.json`. `scripts/compare.sh A B` diffs two snapshots.

### Prerequisites
- Laptop tools: `aws` v2, `kubectl` 1.35, `helm` v4.2.3, `terraform` 1.15, `jq`, `curl`, `eks-node-viewer` (in `~/.local/bin`).
- `../karpenter-demo` checked out next to this repo (its scripts and base manifests are reused).
- CAST AI API key in `~/.castai/api-token` (one line, mode 600). It is never printed: `env.sh` exports it silently.
- CAST AI org `7909c3e2-3f87-4778-a2e8-a22fa955091b` with the trial active (Node Autoscaler and Workload Autoscaler are Premium). Check the day before in Console → **Settings** → **Platform usage** (classic console: **Manage Organization** → **Platform usage**); its banner lists active subscriptions and days remaining. CAST AI's docs do not describe a trial screen, so confirm trial terms with CAST AI in writing. `scripts/castai-api.sh GET /v1/organizations/7909c3e2-3f87-4778-a2e8-a22fa955091b` returns `"billingType": "none"` for this org today (no paid subscription).
- IAM: the `infrathrone-demo` profile can read `pricing:GetProducts` and `ec2:DescribeSpotPriceHistory` (used by `measure.sh`).

### PREP timeline (before the audience arrives)

| When | Step | Command / check |
|---|---|---|
| T-1 day | Trial active, API key works | `scripts/castai-api.sh GET /v1/kubernetes/external-clusters` returns JSON, not `HTTP 401` |
| T-1 day | Terraform providers downloaded | `terraform -chdir=terraform init` |
| T-4 h | Cluster at Karpenter BASELINE | `../karpenter-demo/scripts/resume.sh` (if parked) or `../karpenter-demo/scripts/reset.sh` |
| T-4 h | Connect read-only (history starts now) | `terraform -chdir=terraform apply -var phase=readonly` |
| T-4 h (≥3 h before module 11) | Deploy `shop` | `kubectl apply -f workloads/shop.yaml` |
| T-3 h | Spot-check usage | `kubectl top pods -n shop` shows ~100m per frontend pod |
| T-1 day (optional) | Full rightsizing in module 11: Workload Autoscaler installed ≥24 h | `terraform -chdir=terraform plan -out=tfplan -var phase=automation` then `terraform -chdir=terraform apply tfplan` (autoscaler stays off). Without it, module 11 changes are capped at 25 % (install < 6 h) or 35 % (< 24 h); module 05 Step 9 then shows `No changes` |
| Same cluster, Karpenter course | Automation mode adds pods that don't fit the system node; during a karpenter-demo session keep CAST AI read-only | Run the Karpenter course first, then switch to automation ≥24 h before this course (or accept the 25/35 % cap) |
| T-30 min | Health checks (Demo below) | steps 1–6 |
| T-30 min | Fresh price cache | `rm -f results/price-cache.json` |

Why so early: the Workload Autoscaler needs at least 3 h of usage history (its minimum look-back), and the Available savings report needs the agent to have sent data for a while. Module 03 then re-runs the same `apply` live: the audience sees the plan and the security review, and Terraform reports no changes. If you prefer a truly fresh connect in module 03, you lose the 3 h history for module 11. Caveat: in read-only mode the Workload Autoscaler API answers `castai-workload-autoscaler should be installed to enable workload optimization`. Right after module 05 installs it, `shop` recommendations exist (built from agent snapshots, `origins: ["ORIGIN_SNAPSHOT"]`) but with `lowConfidence: true`. Whether read-only time counts towards the 3 h is not documented; check confidence at the start of module 11.

## Demo

### Step 1 — Load the environment
Every command in this course uses these variables.
```bash
source scripts/env.sh
```
Expected: five lines:
```text
AWS_PROFILE=infrathrone-demo AWS_REGION=ap-south-1 CLUSTER_NAME=karpenter-demo
KUBECONFIG=<repo>/.kube/karpenter-demo.kubeconfig
KARPENTER_DEMO_DIR=<parent>/karpenter-demo
CASTAI_API_URL=https://api.cast.ai CASTAI_API_KEY=<set, NN chars, masked>
CASTAI_CLUSTER_ID=<uuid>
```
`CASTAI_CLUSTER_ID=<not applied yet>` is expected only if the prep apply was skipped. `CASTAI_API_KEY=<MISSING>` means `~/.castai/api-token` is missing: stop and fix it.

### Step 2 — Identity and cluster
Right account, control plane up.
```bash
aws sts get-caller-identity --query Account --output text
aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.{Status:status,Version:version}' --output table
```
Expected: `146725924014`; `Status ACTIVE`, `Version 1.36`.

### Step 3 — Nodes and owner
Only Karpenter nodes plus the system node exist.
```bash
kubectl get nodes -L role,karpenter.sh/nodepool,provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```
Expected: one node with `ROLE system` (`t3a.large`, empty `CAPACITY-TYPE`), plus 2–3 nodes with `NODEPOOL default` (2 or 4 vCPU types such as `c6a.xlarge`, `c8i-flex.xlarge`, mostly `spot`). The `MANAGED-BY` column is empty on every node.

### Step 4 — Karpenter active, CAST AI read-only
Exactly one autoscaler is active.
```bash
kubectl -n kube-system get deploy karpenter
kubectl get nodepool default -o jsonpath='{.spec.limits.cpu}{"\n"}'
kubectl -n castai-agent get deploy,ds
terraform -chdir=terraform output
```
Expected: `karpenter 1/1`; limit `10`; in `castai-agent` the deployments `castai-agent` and `castai-agent-cpvpa` `1/1` and daemonset `castai-spot-handler` with `DESIRED` = number of spot nodes (its affinity matches `karpenter.sh/capacity-type=spot`, so `2` with two Karpenter spot workers). Outputs:
```text
autoscaler_enabled = false
batch_template_offering = "disabled"
castai_cluster_id = "<uuid>"
castai_role_arn = "arn:aws:iam::146725924014:role/castai-eks-karpenter-demo"
phase = "readonly"
rebalancing_schedule_id = ""
workload_scaling_policy_name = ""
```

### Step 5 — shop has been running
The workload has history.
```bash
kubectl -n shop get deploy
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}' | head -3
```
Expected: six deployments `frontend 3/3`, `cart 2/2`, `catalog 2/2`, `checkout 2/2`, `payments 2/2`, `worker 2/2`; creation times at least 3 h ago.

### Step 6 — Quota and EC2 instances
Nothing unexpected is running.
```bash
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle||`on-demand`,Placement.AvailabilityZone]' --output table
aws ec2 describe-instances --filters Name=tag:castai-demo,Values=managed Name=instance-state-name,Values=pending,running --query 'length(Reservations[].Instances[])'
```
Expected: the system `t3a.large` (`on-demand`) plus the Karpenter workers; `0` CAST AI instances.

### Step 7 — Open the watch panes
```text
Pane 1: eks-node-viewer --resources cpu --extra-labels karpenter.sh/nodepool,provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type
Pane 2: kubectl get pods -n shop -o wide -w
Main  : commands from docs/NN-*.md
```
Run `source scripts/env.sh` in every pane first. Expected: pane 1 shows the nodes with a `$/hour` line per node and a cluster total.

## Talking points
- "Same cluster, same app, same price source, measured the same way before and after. If CAST AI saves money here, you will see exactly where it came from."
- "We have 8 on-demand and 8 spot vCPU. That is why only one autoscaler runs at a time, and why every switch waits for the old capacity to be gone."
- "The app was started hours ago on purpose: rightsizing needs history. Anyone who promises rightsizing on a 5-minute-old workload is guessing."

## Reset
Nothing in this module changes the cluster.

## Q&A prep
- **Is this a sales demo?** No. We show where Karpenter already matches CAST AI, and we compute ROI on our own numbers in module 14.
- **Why not CAST AI's Karpenter mode (Kent)?** It keeps Karpenter as the provisioner. We want a clean head-to-head of the two autoscalers, which needs the standard CAST AI autoscaler. CAST AI documents that switching from Kent to the standard autoscaler requires off-boarding and re-onboarding, so we chose up front.
- **Why Terraform and not the console script?** Repeatable, reviewable, and `terraform destroy` disconnects cleanly. CAST AI's docs say not to use `castctl` on a Terraform-managed cluster.
- **What does the lab cost per hour?** `scripts/measure.sh` prints it. Fixed part: EKS control plane $0.10/h plus the system node; workers vary per phase.
