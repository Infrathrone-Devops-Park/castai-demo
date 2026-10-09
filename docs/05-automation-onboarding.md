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
 │ policies, template │ (per-cluster IAM user) │  RunInstances, Terminate, ...  │
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
| Trust policy | One principal: IAM user `cast-crossrole-<cluster-id>` in CAST AI's AWS account `809060229965`, created for this cluster only. No `sts:ExternalId` condition |
| `AmazonEC2ReadOnlyAccess`, `IAMReadOnlyAccess` | Read everything EC2/IAM (pricing, subnets, instance profiles) |
| Managed policy `CastEKSPolicy-karpenter-demo` | `iam:PassRole` (to EC2 and EKS only), key pairs, `CreateTags`, `CreateServiceLinkedRole`; `ec2:RunInstances` on the supporting resources (images, volumes, ENIs, security groups, key pairs) |
| Inline policy `castai-user-policy-karpenter-demo` | `ec2:RunInstances` on `instance/*` only with request tag `kubernetes.io/cluster/karpenter-demo=owned`; subnets only in the cluster VPC; `TerminateInstances`/`StartInstances`/`StopInstances`/`CreateTags` only on instances tagged `kubernetes.io/cluster/karpenter-demo` = `owned` or `shared`; ASG actions with the same tag; EKS describe/list and `Create`/`DeleteNodegroup` on this cluster; launch templates with the owned tag |
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
| IMDS | Karpenter default: IMDSv2 required, hop limit 1 | `imds_v1 = false`; `imds_hop_limit = 2` (provider default) |
| Disk | Karpenter default 20 GiB gp3 | `min_disk_size = 30`, `volume_type = "gp3"` |
| Max pods | `kubelet.maxPods: 110` (prefix delegation) | `max_pods_per_node_formula = null`: EKS default, computed at bootstrap (docs: "Unspecified (EKS default)") |
| Tags | `Project: karpenter-demo` | `castai-demo: managed`, `Project: castai-demo` |
| Node "what" | `NodePool default` | `castai_node_template default-by-castai` |
| Architecture | `amd64` | `amd64` |
| Capacity type | `spot`, `on-demand` (spot preferred) | `spot = true`, `on_demand = false`, `use_spot_fallbacks = true` |
| Fallback return | consolidation only | `fallback_restore_rate_seconds = 1800` |
| Instance size | `instance-cpu In [2, 4]` | `min_cpu = 2`, `max_cpu = 4` |
| Families | `instance-category In [c, m, r]`, `generation Gt 4` | any family; `burstable_instances = null` (unset, docs default "All", so `t3a`-type burstables are allowed) |
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
| castai-evictor (+ cpvpa) | 1 | 100m / ~456Mi (cpvpa-sized) | system node |
| castai-pod-pinner | 1 | 20m / 256Mi | system node |
| castai-workload-autoscaler | 2 | 100m / 512Mi each | system node |
| castai-pod-mutator | 2 | 20m / 512Mi each | no node selector |
| castai-workload-autoscaler-exporter | 1 | 500m / 256Mi in the chart; live 450m / 231Mi | no node selector |
| castai-workload-autoscaler-exporter-prometheus | 1 | 250m / 512Mi in the chart; live 225m / 461Mi | no node selector |

The three without a node selector land on worker nodes: pod-mutator has a required anti-affinity, so its 2 replicas sit on 2 different nodes. In the validation run both exporters and one mutator went to the less-full worker and the other mutator to the second worker (~0.7 vCPU of requests on workers). Karpenter added no node because the second worker had ~1.4 vCPU free; if both workers were full, Karpenter would launch one more node for them. Total new requests: +1.26 vCPU cluster-wide. Point it out: it is part of the cost of running CAST AI, and `measure.sh` counts it.

System node fit: the system node goes from `1320m (68%)` to `1790m (92%)` CPU requested and from 60% to 87% memory requested. It fits, with ~140m CPU spare. Do not enable `castai-kvisor` or `castai-live` on this node size.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: `CASTAI_CLUSTER_ID=<uuid>`.

### Step 2 — Trial / plan check
Automation is Premium.
Console → **Settings** → **Platform usage** (classic console: **Manage Organization** → **Platform usage**); the banner lists active subscriptions and days remaining. Expected: an active trial or paid plan for org `7909c3e2-...`. API cross-check:
```bash
scripts/castai-api.sh GET /v1/organizations/7909c3e2-3f87-4778-a2e8-a22fa955091b | jq '{id, billingType}'
```
On the validation day this returned `"billingType": "none"`, and installing the automation components (Step 9) was not blocked. Whether turning the autoscaler on (module 06) is gated by plan was not tested here; confirm the trial before the session. If the org is free-only, stop here: modules 06–12 need the trial.

### Step 3 — Trust policy
Who can assume the role.
```bash
aws iam get-role --role-name castai-eks-karpenter-demo --query 'Role.AssumeRolePolicyDocument.Statement[].{Principal:Principal,Condition:Condition}' --output json
```
Expected:
```json
[
    {
        "Principal": {
            "AWS": "arn:aws:iam::809060229965:user/cast-crossrole-<cluster-id>"
        },
        "Condition": null
    }
]
```
One principal: a CAST AI IAM user created for this cluster only. There is no `sts:ExternalId` condition; the per-cluster user is the scoping. Say it plainly if your security team expects an ExternalId.

### Step 4 — Write permissions and their conditions
The tag conditions live in an inline policy.
```bash
aws iam list-attached-role-policies --role-name castai-eks-karpenter-demo --query 'AttachedPolicies[].PolicyName' --output text
aws iam list-role-policies --role-name castai-eks-karpenter-demo --query PolicyNames --output text
aws iam get-role-policy --role-name castai-eks-karpenter-demo --policy-name castai-user-policy-karpenter-demo --query PolicyDocument --output json | jq -c '.Statement[] | {Sid, Action, Condition}'
```
Expected: `CastEKSPolicy-karpenter-demo  AmazonEC2ReadOnlyAccess  IAMReadOnlyAccess` (any order), then `castai-user-policy-karpenter-demo`, then 8 statements, including:
```text
{"Sid":"RunInstancesTagRestriction","Action":"ec2:RunInstances","Condition":{"StringEquals":{"aws:RequestTag/kubernetes.io/cluster/karpenter-demo":"owned"}}}
{"Sid":"RunInstancesVpcRestriction","Action":"ec2:RunInstances","Condition":{"StringEquals":{"ec2:Vpc":"arn:aws:ec2:ap-south-1:146725924014:vpc/vpc-0db2670bef5e06f86"}}}
{"Sid":"InstanceActionsTagRestriction","Action":["ec2:TerminateInstances","ec2:StartInstances","ec2:StopInstances","ec2:CreateTags"],"Condition":{"StringEquals":{"ec2:ResourceTag/kubernetes.io/cluster/karpenter-demo":["owned","shared"]}}}
```
plus `AutoscalingActionsTagRestriction`, `EKS` (`eks:Describe*`, `eks:List*`, `eks:CreateNodegroup`, `eks:DeleteNodegroup` on this cluster) and three launch-template statements tagged `owned`. The managed `CastEKSPolicy-karpenter-demo` adds `iam:PassRole` (only to `ec2`/`eks`), key-pair and tagging actions, and `RunInstances` on images, volumes, ENIs and security groups; an instance launch still needs the tagged `instance/*` statement above.

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
scripts/castai-api.sh GET "/v1/kubernetes/clusters/$CASTAI_CLUSTER_ID/node-templates?includeDefault=true" | jq '[.items[].template | {name, isEnabled, isDefault}]'
```
Expected: one entry `"name": "default-by-castai"`, `"isEnabled": true`, `"isDefault": true`. Without `?includeDefault=true` the API returns `"items": []`, because the default template is hidden by default.

### Step 7 — Policies and evictor are off
```bash
terraform -chdir=terraform state show castai_autoscaler_policies.this | grep -E '^[[:space:]]+(enabled|scoped_mode|max_cores|empty_nodes_delay)[[:space:]]'
terraform -chdir=terraform state show castai_evictor.this | grep -E '^[[:space:]]+(enabled|scoped_mode|aggressive_mode|cycle_interval|status)[[:space:]]'
```
Expected: for the policies, the top-level `enabled = false` and `scoped_mode = false`; the nested `enabled = true` lines belong to `cluster_limits`, `unschedulable_pods` and `pod_pinner` (sub-policies that only act once the top level is on); `max_cores = 10`, `empty_nodes_delay = "60s"`. For the evictor: `enabled = false`, `scoped_mode = true`, `aggressive_mode = false`, `cycle_interval = "60s"`, `status = "EVICTOR_STATUS_UNSPECIFIED"` (also after Step 9, while disabled). The `grep` prints lines in state order, not in this order.

### Step 8 — Plan the switch to automation
One in-place change: the Helm release.
```bash
terraform -chdir=terraform plan -var phase=automation
```
Expected: `helm_release.castai` will be updated in-place (the `values` diff shows `readonly: true → false` and `full: false → true`), ending `Plan: 0 to add, 1 to change, 0 to destroy.` and `Changes to Outputs: ~ phase = "readonly" -> "automation"`. The `metadata` block shows `(known after apply)` noise; the real change is at the bottom of `values`: `-   "full": false`, `+   "full": true`, `-   "readonly": true`, `+   "readonly": false`. No change to policies or evictor.

### Step 9 — Apply
```bash
terraform -chdir=terraform apply -var phase=automation
```
Type `yes`. Expected: `helm_release.castai: Modifications complete after 1m5s` (validation run) and `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`, outputs with `phase = "automation"` and `autoscaler_enabled = false`. Helm waits for the new pods and runs the evictor CRD and workload-autoscaler hook jobs. Re-running it later is safe: `No changes.`

### Step 10 — Components Running, on the system node
```bash
kubectl -n castai-agent get deploy,ds
kubectl -n castai-agent get pods -o custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
kubectl get nodes -l role=system -o name
```
Expected: deployments `castai-agent`, `castai-agent-cpvpa`, `castai-cluster-controller`, `castai-evictor`, `castai-evictor-cpvpa`, `castai-pod-pinner` `1/1`; `castai-workload-autoscaler 2/2`; `castai-pod-mutator 2/2`; `castai-workload-autoscaler-exporter` and `-exporter-prometheus` `1/1`; daemonset `castai-spot-handler`. All pods `Running`. The agent, cluster-controller, evictor, pod-pinner and workload-autoscaler pods are on the system node; mutator and exporter pods may be on Karpenter nodes. No `castai-live` or `castai-kvisor` pods. Validation run: the 8 system-node pods were agent, agent-cpvpa, cluster-controller, evictor, evictor-cpvpa, pod-pinner and both workload-autoscaler replicas; the 2 mutators split across both workers; both exporters on one worker.

Check the system node still fits:
```bash
kubectl describe node -l role=system | grep -A6 'Allocated resources'
```
Expected: `cpu  1790m (92%)` and `memory ... (87%)` requested. No pod `Pending` (`kubectl get pods -A --field-selector=status.phase=Pending` prints `No resources found`).

### Step 11 — CAST AI view
```bash
scripts/castai-api.sh GET /v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID | jq '{status, agentStatus, isPhase2}'
```
Expected: `"status": "ready"`, `"agentStatus": "online"`, `"isPhase2": true`. The `warning` from module 03 clears within about 30 s of the apply: the reconcile now reaches the cluster-controller (`reconcileError: null`). Confirm the autoscaler policy is off:
```bash
scripts/castai-api.sh GET /cluster-autoscaler/v2/clusters/$CASTAI_CLUSTER_ID/policies | jq '{version, enabled, scopedMode}'
kubectl -n castai-agent logs deploy/castai-evictor --tail=-1 | grep -c 'evictor disabled via EvictorConfig CR'
```
Expected: `"version": "2"`, `"enabled": false`, `"scopedMode": false`, and a count of 1 or more (one per 60 s cycle). Use the V2 path: the legacy V1 endpoint `/v1/kubernetes/clusters/<id>/policies` is a separate store and still shows its default `"enabled": true` (with unschedulable pods, empty-node deletion and evictor all off), which confuses audiences. In the console, open the cluster's **Autoscaler** settings page: policies off, node template `default-by-castai` listed (exact labels vary between Enhanced and Classic console).

### Step 12 — Karpenter still in charge
Nothing moved.
```bash
kubectl get nodeclaims
kubectl get nodes -L karpenter.sh/nodepool,provisioner.cast.ai/managed-by
scripts/measure.sh castai-phase2-idle
```
Expected: the same NodeClaims as in module 02 (plus possibly one more if the exporter pods did not fit); no node with `MANAGED-BY cast.ai`; `requested vCPU (all ns)` up by about 1.3 vCPU vs `karpenter-baseline` (validation run: `7.68` to `8.94`), shop numbers and $/h unchanged. `scripts/compare.sh karpenter-baseline castai-phase2-idle` shows the same: `requested vCPU (all ns)  7.68  8.94  +1.26  +16.4%`, every cost row `0%`.

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
Expected: `Resources: 0 added, 1 changed, 0 destroyed.`; only `castai-agent` and `castai-agent-cpvpa` remain. Not run during validation (the course stays in automation). The 4 webhook configurations (`castai-pod-mutator`, `castai-pod-pinner`, `castai-workload-autoscaler`, `vpodmutation.cast.ai`) and 3 of the 4 CRDs carry Helm labels, so a Helm upgrade should remove them; `evictorconfigs.autoscaling.cast.ai` is created by a hook job without Helm labels and stays until offboarding (module 15). Check with `kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations,crd -o name | grep cast`.

## Q&A prep
- **Can CAST AI terminate our system node?** The IAM policy would allow any instance tagged `kubernetes.io/cluster/karpenter-demo=owned`. The system node is a managed node group CAST AI does not manage; the evictor is scoped to CAST AI nodes. Add `autoscaling.cast.ai/removal-disabled=true` on the node for extra safety.
- **Why not enable scoped mode on the autoscaler too?** Scoped autoscaler mode taints the template's nodes and only pods that tolerate the taint trigger scale-up, so every `shop` deployment would need a toleration. We keep the workloads identical for both tools.
- **Does CAST AI need Pod Identity or IRSA?** Not for the standard autoscaler: decisions run in CAST AI's account via the cross-account role. Only the Karpenter-mode controller (Kent) uses Pod Identity.
- **What if the SaaS is down?** Running pods are unaffected; new pending pods wait. Karpenter is scaled to 0 during the CAST AI phase, so there is no automatic fallback in this demo. Production designs keep a delayed fallback autoscaler.
- **Why so many components for one feature?** Each is a separate chart with its own RBAC; mode tags install what a mode needs. We disabled `castai-live` (container live migration) and `castai-kvisor` (security) to save system-node capacity.
