# 05 — Phase 2: automation onboarding
**Time:** 25 min · **Goal:** Review what CAST AI is allowed to do in AWS and in the cluster, map its objects to Karpenter's, and install the automation components with the autoscaler still off.

## What you'll show
- The IAM role CAST AI assumes, and how its write permissions are scoped.
- Node configuration vs `EC2NodeClass`, node template vs `NodePool`, side by side with the real karpenter-demo manifests.
- The V2 autoscaler policies and evictor, both still `enabled = false`.
- `terraform apply -var phase=automation`: one in-place Helm change that installs cluster-controller, evictor, pod-pinner, pod-mutator, workload-autoscaler and spot-handler.
- Karpenter is still the only active autoscaler afterwards.

## Concepts

### Phase 2 in one picture

```text
 CAST AI SaaS (decides)                         your AWS account
 ┌────────────────────┐  sts:AssumeRole        ┌───────────────────────────────┐
 │ autoscaler engine  │ ─────────────────────► │ role castai-eks-karpenter-demo │
 │ policies, template │   (ExternalId)         │  RunInstances, Terminate, ...  │
 └─────────┬──────────┘                        │  tag-scoped to this cluster    │
           │ gRPC/HTTPS (outbound from cluster)└───────────────────────────────┘
 ┌─────────▼──────────────────────── cluster ns castai-agent ─────────────────┐
 │ castai-agent          snapshots (already running)                           │
 │ cluster-controller    executes platform actions (approve CSR, drain, label) │
 │ evictor               bin-packing by eviction (scoped to CAST AI nodes)     │
 │ pod-pinner            binds pending pods to nodes being created             │
 │ pod-mutator           webhook for pod mutations (none configured)           │
 │ workload-autoscaler   rightsizing webhook + recommender sync (module 11)    │
 │ spot-handler          interruption notices (reporting only)                 │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### IAM scoping (module `castai/eks-role-iam` 2.0.4)

| Piece | Scope |
|---|---|
| Trust policy | CAST AI's AWS principal for this cluster, with `sts:ExternalId` = cluster ID |
| `AmazonEC2ReadOnlyAccess`, `IAMReadOnlyAccess` | Read everything EC2/IAM (pricing, subnets, instance profiles) |
| `CastEKSPolicy-karpenter-demo` | `ec2:RunInstances` only with request tag `kubernetes.io/cluster/karpenter-demo=owned`; subnets restricted to the cluster VPC; `TerminateInstances`/`StartInstances`/`StopInstances`/`CreateTags` only on resources tagged `kubernetes.io/cluster/karpenter-demo` = `owned` or `shared`; launch templates with the same tag |
| Instance role `castai-eks-instance-karpenter-demo` | Worker node policies (EKS worker, ECR read, CNI, EBS CSI, SSM) |
| EKS access entry `EC2_LINUX` | Lets nodes with that instance role join |

Honest caveat: Karpenter's own nodes also carry `kubernetes.io/cluster/karpenter-demo=owned`, so IAM alone would let CAST AI terminate them. Protection comes from configuration: autoscaler and evictor never touch nodes they did not create when **scoped mode** is on (evictor: on here), Karpenter is drained before CAST AI is enabled, and the system node is a managed node group CAST AI does not manage.

### CAST AI objects vs Karpenter objects

| Concept | Karpenter (karpenter-demo `manifests/base/`) | CAST AI (`terraform/nodes.tf`) |
|---|---|---|
| Node "how" | `EC2NodeClass default` | `castai_node_configuration default` |
| AMI | `alias: al2023@v20260930` (pinned) | `eks_image_family = "al2023"` (latest for 1.36) |
| Subnets | selector tag `karpenter.sh/discovery` | same subnets, resolved by Terraform data source |
| Security groups | selector tag `karpenter.sh/discovery` | cluster SG + same tagged SGs |
| Instance identity | role `karpenter-demo-karpenter-node` | instance profile `castai-eks-instance-karpenter-demo` |
| IMDS | Karpenter default: IMDSv2 required, hop limit 1 | `imds_v1 = false`; hop limit default 2 |
| Disk | Karpenter default 20 GiB gp3 | `min_disk_size = 30`, `volume_type = "gp3"` |
| Max pods | `kubelet.maxPods: 110` (prefix delegation) | CAST AI default formula <!-- VERIFY: CAST AI max-pods with prefix delegation --> |
| Tags | `Project: karpenter-demo` | `castai-demo: managed`, `Project: castai-demo` |
| Node "what" | `NodePool default` | `castai_node_template default-by-castai` |
| Architecture | `amd64` | `amd64` |
| Capacity type | `spot`, `on-demand` (spot preferred) | `spot = true`, `on_demand = false`, `use_spot_fallbacks = true` |
| Fallback return | consolidation only | `fallback_restore_rate_seconds = 1800` |
| Instance size | `instance-cpu In [2, 4]` | `min_cpu = 2`, `max_cpu = 4` |
| Families | `instance-category In [c, m, r]`, `generation Gt 4` | any family (burstable allowed by default) <!-- VERIFY: burstable default --> |
| Limit | `limits.cpu: "10"` | template `cpu_limit_max_cores = 8`; cluster `max_cores = 10` incl. system node |
| Consolidation | `WhenEmptyOrUnderutilized`, `consolidateAfter: 1m` | evictor (scoped, 60 s cycle, 5 min grace) + empty-node delete after 60 s |

Template families are wider than Karpenter's on purpose (CAST AI's default); say so when comparing node choices in module 07.

### V2 policies and evictor (still off)
- `castai_autoscaler_policies`: `enabled = var.autoscaler_enabled` (false), `scoped_mode = false`, cluster CPU limit 10, empty-node deletion after 60 s, unschedulable-pods policy with pod-pinner.
- `castai_evictor`: `enabled = var.autoscaler_enabled` (false), scoped mode, non-aggressive, 60 s cycle, 5 min node grace period.
- These are the V2 resources. The older `castai_autoscaler` (V1) is deprecated and must not be mixed with them.
- Turning `autoscaler_enabled` on is module 06, after Karpenter is drained.

### What changes in the cluster
`phase=automation` flips the umbrella chart from `tags.readonly` to `tags.full`, with `castai-live` and `castai-kvisor` disabled. Resource requests added (from the chart):

| Component | Replicas | CPU / mem request | Placement |
|---|---|---|---|
| castai-cluster-controller | 1 | 50m / 100Mi (+100m / 128Mi second container) | system node |
| castai-evictor (+ cpvpa) | 1 | 100m | system node |
| castai-pod-pinner | 1 | 20m / 256Mi | system node |
| castai-workload-autoscaler | 2 | 100m / 512Mi each | system node |
| castai-pod-mutator | 2 | 20m / 512Mi each | no node selector |
| castai-workload-autoscaler-exporter | 1 | 500m / 256Mi | no node selector |
| castai-workload-autoscaler-exporter-prometheus | 1 | 250m / 512Mi | no node selector |

The three without a node selector can land on worker nodes and add about 0.8 vCPU of requests there. Point it out: it is part of the cost of running CAST AI, and `measure.sh` will count it. <!-- VERIFY: where exporter pods schedule; whether Karpenter adds a node for them -->

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: `CASTAI_CLUSTER_ID=<uuid>`.

### Step 2 — Trial / plan check
Automation is Premium.
Console → **Organization** → **Billing** (or the plan banner). Expected: an active trial or paid plan for org `7909c3e2-...`. If the org is free-only, stop here: modules 06–12 need the trial. <!-- VERIFY: console path -->

### Step 3 — Trust policy
Who can assume the role.
```bash
aws iam get-role --role-name castai-eks-karpenter-demo --query 'Role.AssumeRolePolicyDocument.Statement[].{Principal:Principal,Condition:Condition}' --output json
```
Expected: one statement with `Principal.AWS` = an ARN in CAST AI's AWS account (`arn:aws:iam::<castai-account>:user/cast-crossrole-<cluster-id>` or similar) and a `Condition` `StringEquals` on `sts:ExternalId` = `$CASTAI_CLUSTER_ID`. <!-- VERIFY: principal ARN shape and ExternalId -->

### Step 4 — Write permissions and their conditions
The statements that can change anything.
```bash
POLICY_ARN=arn:aws:iam::146725924014:policy/CastEKSPolicy-karpenter-demo
VER=$(aws iam get-policy --policy-arn $POLICY_ARN --query Policy.DefaultVersionId --output text)
aws iam get-policy-version --policy-arn $POLICY_ARN --version-id $VER --query PolicyVersion.Document --output json | jq '.Statement[] | select(([.Action] | flatten | map(test("RunInstances|TerminateInstances")) | any)) | {Sid, Action, Resource, Condition}'
```
Expected: a statement allowing `ec2:RunInstances` on `instance/*` (and volumes/network interfaces) with `aws:RequestTag/kubernetes.io/cluster/karpenter-demo` = `owned`, and a statement allowing `ec2:TerminateInstances` (with Start/Stop/CreateTags) conditioned on `ec2:ResourceTag/kubernetes.io/cluster/karpenter-demo` in `owned`/`shared`. <!-- VERIFY: exact statement layout -->

### Step 5 — Node configuration vs EC2NodeClass
```bash
cat "$KARPENTER_DEMO_DIR/manifests/base/ec2nodeclass.yaml"
terraform -chdir=terraform state show castai_node_configuration.default
```
Expected: the EC2NodeClass YAML (AMI alias `al2023@v20260930`, discovery-tag selectors, `maxPods: 110`), then the Terraform state of the node configuration: `name = "default"`, three `subnets`, `min_disk_size = 30`, `tags` with `castai-demo = "managed"`, and an `eks` block with `eks_image_family = "al2023"`, `imds_v1 = false`, `volume_type = "gp3"`, the instance profile ARN and security groups. Walk the comparison table above.

### Step 6 — Node template vs NodePool
```bash
cat "$KARPENTER_DEMO_DIR/manifests/base/nodepool.yaml"
terraform -chdir=terraform state show castai_node_template.default
```
Expected: the NodePool YAML (spot + on-demand, c/m/r, 2/4 vCPU, `limits.cpu: "10"`), then `name = "default-by-castai"`, `constraints` with `spot = true`, `on_demand = false`, `use_spot_fallbacks = true`, `min_cpu = 2`, `max_cpu = 4`, `architectures = ["amd64"]`, `resource_limits { cpu_limit_enabled = true, cpu_limit_max_cores = 8 }`.

API view of the same template:
```bash
scripts/castai-api.sh GET /v1/kubernetes/clusters/$CASTAI_CLUSTER_ID/node-templates | jq '[.items[].template | {name, isEnabled, isDefault}]'
```
Expected: one entry `"name": "default-by-castai"`, `"isEnabled": true`, `"isDefault": true`. <!-- VERIFY: response shape items[].template -->

### Step 7 — Policies and evictor are off
```bash
terraform -chdir=terraform state show castai_autoscaler_policies.this | grep -E '^[[:space:]]+(enabled|scoped_mode|max_cores|empty_nodes_delay)[[:space:]]'
terraform -chdir=terraform state show castai_evictor.this | grep -E '^[[:space:]]+(enabled|scoped_mode|aggressive_mode|cycle_interval|status)[[:space:]]'
```
Expected: for the policies, the top-level `enabled = false` and `scoped_mode = false`; the nested `enabled = true` lines belong to `cluster_limits`, `unschedulable_pods` and `pod_pinner` (sub-policies that only act once the top level is on); `max_cores = 10`, `empty_nodes_delay = "60s"`. For the evictor: `enabled = false`, `scoped_mode = true`, `aggressive_mode = false`, `cycle_interval = "60s"`. <!-- VERIFY: evictor status value before evictor is installed -->

### Step 8 — Plan the switch to automation
One in-place change: the Helm release.
```bash
terraform -chdir=terraform plan -var phase=automation
```
Expected: `helm_release.castai` will be updated in-place (the `values` diff shows `readonly: true → false` and `full: false → true`), ending `Plan: 0 to add, 1 to change, 0 to destroy.` No change to policies or evictor. <!-- VERIFY: castai_evictor shows no diff -->

### Step 9 — Apply
```bash
terraform -chdir=terraform apply -var phase=automation
```
Type `yes`. Expected: `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.` after 1–3 minutes (Helm waits for the new pods and runs the evictor CRD and workload-autoscaler hook jobs).

### Step 10 — Components Running, on the system node
```bash
kubectl -n castai-agent get deploy,ds
kubectl -n castai-agent get pods -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
kubectl get nodes -l role=system -o name
```
Expected: deployments `castai-agent`, `castai-agent-cpvpa`, `castai-cluster-controller`, `castai-evictor`, `castai-evictor-cpvpa`, `castai-pod-pinner` `1/1`; `castai-workload-autoscaler 2/2`; `castai-pod-mutator 2/2`; `castai-workload-autoscaler-exporter` and `-exporter-prometheus` `1/1`; daemonset `castai-spot-handler`. All pods `Running`. The agent, cluster-controller, evictor, pod-pinner and workload-autoscaler pods are on the system node; mutator and exporter pods may be on Karpenter nodes. No `castai-live` or `castai-kvisor` pods. <!-- VERIFY: system node has room for all of these -->

### Step 11 — CAST AI view
```bash
scripts/castai-api.sh GET /v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID | jq '{status, agentStatus, isPhase2}'
```
Expected: `"status": "ready"`, `"agentStatus": "online"`, `"isPhase2": true`. Console → `karpenter-demo` → **Autoscaler** shows the policies switched off, and the node template `default-by-castai`. <!-- VERIFY: console labels -->

### Step 12 — Karpenter still in charge
Nothing moved.
```bash
kubectl get nodeclaims
kubectl get nodes -L karpenter.sh/nodepool,provisioner.cast.ai/managed-by
scripts/measure.sh castai-phase2-idle
```
Expected: the same NodeClaims as in module 02 (plus possibly one more if the exporter pods did not fit); no node with `MANAGED-BY cast.ai`; `requested vCPU (all ns)` up by about 0.8–1.2 vCPU vs `karpenter-baseline` (the CAST AI components), shop numbers unchanged.

## Talking points
- "Phase 2 is a privilege change, so we review it like one: who can assume the role, what it can launch, what it can terminate."
- "Every CAST AI object has a Karpenter twin. Node configuration is your EC2NodeClass, the node template is your NodePool. The template here is a bit wider than our NodePool; remember that when we compare instance choices."
- "We installed the automation and left it switched off. Two autoscalers at once is unsupported, and with our quota it would just fail."
- "The components are not free: about a vCPU of requests, some of it on worker nodes. That belongs in the ROI math."

## Reset
Leave `phase=automation` with `autoscaler_enabled=false` for module 06. To return to read-only (rehearsal only):
```bash
terraform -chdir=terraform apply -var phase=readonly
kubectl -n castai-agent get deploy
```
Expected: `Resources: 0 added, 1 changed, 0 destroyed.`; only `castai-agent` and `castai-agent-cpvpa` remain. Webhook configurations and CRDs from the full mode may remain until offboarding (module 15). <!-- VERIFY: helm downgrade full→readonly removes webhooks -->

## Q&A prep
- **Can CAST AI terminate our system node?** The IAM policy would allow any instance tagged `kubernetes.io/cluster/karpenter-demo=owned`. The system node is a managed node group CAST AI does not manage; the evictor is scoped to CAST AI nodes. Add `autoscaling.cast.ai/removal-disabled=true` on the node for extra safety.
- **Why not enable scoped mode on the autoscaler too?** Scoped autoscaler mode taints the template's nodes and only pods that tolerate the taint trigger scale-up, so every `shop` deployment would need a toleration. We keep the workloads identical for both tools.
- **Does CAST AI need Pod Identity or IRSA?** Not for the standard autoscaler: decisions run in CAST AI's account via the cross-account role. Only the Karpenter-mode controller (Kent) uses Pod Identity.
- **What if the SaaS is down?** Running pods are unaffected; new pending pods wait. Karpenter is scaled to 0 during the CAST AI phase, so there is no automatic fallback in this demo. Production designs keep a delayed fallback autoscaler.
- **Why so many components for one feature?** Each is a separate chart with its own RBAC; mode tags install what a mode needs. We disabled `castai-live` (container live migration) and `castai-kvisor` (security) to save system-node capacity.
