# 14 — Pricing, ROI and security
**Time:** 15 min · **Goal:** Turn the measured saving into a buy/don't-buy number, and answer the security and lock-in questions with evidence from this cluster.

## What you'll show
- What is free and what is paid, and how CAST AI counts billable CPUs.
- ROI on the demo's own snapshots (ROI-negative, said out loud) and scaled to a 500 vCPU fleet.
- The AWS IAM role CAST AI assumes, read live from IAM, and the in-cluster RBAC.
- What data leaves the cluster, what happens when CAST AI SaaS is down, and how you leave.
- The Karpenter-native alternative: Cast AI for Karpenter ("Kent").

## Concepts

### Pricing (as published; confirm in writing before quoting)
| Item | What you get | Price |
|---|---|---|
| Free / read-only | Agent, cost monitoring, Available savings report, security report; no stated cluster or CPU limit | $0 |
| Premium: Node Autoscaler | Autoscaler, evictor, rebalancer, spot fallback | per billable CPU |
| Premium: Workload Autoscaler | Rightsizing, HPA coordination | per billable CPU |
| AWS Marketplace tiers (1-month) | Cost Monitoring $200 · Growth $1,000 (4 clusters / 500 CPU) · Growth 700 $1,000 · GrowthPro $1,000 (unlimited clusters / 2,000 CPU) · Enterprise $5,000 | plus $0.00694444 per CPU-hour ≈ **$5.07 per CPU-month** |
- **Billable CPU** = one provisioned CPU running for the whole month (15 days = 0.5). The Platform usage doc lists Node Autoscaler and Workload Autoscaler as two billable products, each metered in "CPUs per cluster". It does not say whether one CPU is charged once or once per product. Ask in writing.
- The Marketplace listing is ambiguous too: each tier says "Up to N CPU (charged based on usage)", while the general text says usage fees cover "overages or additional usage not covered in the contract" and are "applied on top of the contract price". Additive or overage-only is not stated. The table below shows both readings.
- cast.ai/pricing shows a quote form only. A savings-share model (a % of savings) is reported by third parties, not by CAST AI. Treat it as negotiable.
- The trial: check Console → Settings → Platform usage (or Manage Organization → Platform usage) for days remaining.

### ROI formula
```text
saving/month   = (before $/h - after $/h) x 730
fee/month      = base tier + per-CPU x billable CPUs after optimization
net/month      = saving - fee
```
Reference unit costs in ap-south-1 (x730 h): on-demand c6a.large $0.04675/h ≈ $17.06 per vCPU-month; spot c6a ≈ $7.74–9.47 per vCPU-month on the day measured (c6a.large 1b $0.0212, c6a.xlarge 1b $0.0519), ~$8.25 used below. $0.00694444 x 730 = $5.07. A $5.07 CPU fee is ~30 % of an on-demand vCPU but ~60 % of a spot vCPU. Rightsizing on spot-heavy fleets pays less than on on-demand fleets.

### Scaled example: 500 vCPU fleet, 60 % on-demand / 40 % spot
Blended ≈ $13.54 per vCPU-month → **$6,770/month** before.

| Provisioned vCPU reduction | After | Saving | Net if fee = $1,000 flat | Net if $1,000 + $5.07/CPU | Net if $5.07/CPU only |
|---|---|---|---|---|---|
| 20 % | 400 vCPU, $5,416 | $1,354 | **+$354** | **-$1,674** | **-$674** |
| 35 % | 325 vCPU, $4,400 | $2,370 | **+$1,370** | **-$278** | **+$722** |
| 50 % | 250 vCPU, $3,385 | $3,385 | **+$2,385** | **+$1,117** | **+$2,117** |

All-on-demand 500 vCPU ($8,530/month) at 35 %: saving $2,986, net +$1,986 / +$338 / +$1,338.
Takeaways: ROI is clearly positive for large, on-demand-heavy, badly over-requested fleets. It is marginal for spot-heavy fleets that are already tuned. The free Available-savings report is the input to this table; run it on your own clusters first.

### Security model
- **AWS**: a cross-account role `castai-eks-karpenter-demo`, trusted by the CAST AI IAM user `arn:aws:iam::809060229965:user/cast-crossrole-<cluster-id>`. On this cluster (module `castai/eks-role-iam` 2.0.4) the trust has **no condition**: no `sts:ExternalId`. The per-cluster IAM user is the only binding. Attached: `AmazonEC2ReadOnlyAccess`, `IAMReadOnlyAccess`, `CastEKSPolicy-karpenter-demo` (PassRole to EC2/EKS, `CreateTags`, key pairs, unconditioned `RunInstances` on images/volumes/ENIs/SGs). The conditions live in the inline `castai-user-policy-karpenter-demo`: `RunInstances` only with request tag `kubernetes.io/cluster/karpenter-demo=owned` and only in the cluster VPC; `Terminate/Start/Stop/CreateTags` only on instances tagged `owned` or `shared`; ASG actions with the same tag; `eks:Create/DeleteNodegroup`; launch templates with the owned tag. Nodes use `castai-eks-instance-karpenter-demo` (EKS worker, ECR read-only, CNI, EBS CSI, SSM).
- **Blast radius**: the tag condition also matches the other instances of this cluster. Checked live: the system MNG instance carries `kubernetes.io/cluster/karpenter-demo=owned`, and Karpenter tags its nodes the same way. Our guardrails: evictor `scoped_mode = true` (only CAST AI nodes), template and cluster CPU limits, and optionally the `autoscaling.cast.ai/removal-disabled=true` label on the system node. The autoscaler itself runs with `scoped_mode = false` so `shop` pods need no extra tolerations.
- **Read-only mode needs no AWS role at all.**
- **Kubernetes**: read-only agent ClusterRole (no Secrets/ConfigMaps). Automation adds write RBAC for cluster-controller, evictor, pod-pinner and the workload-autoscaler webhook.
- **Data sent**: object metadata/specs (nodes, pods, workloads) and metrics. Literal env values whose names look like `pass|secret|token|key|creds` are scrubbed in-cluster. Stored on GCP `us-east4` (US) or `europe-west3` (EU); **no India region for data at rest** is documented, even though an India API endpoint exists. Retention per docs.cast.ai data-collection-and-storage: Kubernetes metadata "at least 10 years", cluster snapshots 21 days, audit logs 90 days in the console then archived; ISO 27001, SOC 2 Type II.
- **SaaS down**: running pods and nodes are unaffected; recommendations already applied stay. What stops: new nodes for pending pods (CAST AI normally adds them in 60–120 s), evictor/rebalancing, new recommendations. Detect with `castai_autoscaler_agent_snapshots_received_total` dropping to 0. Documented EKS fallback: a delayed secondary autoscaler (Cluster Autoscaler with `--new-pod-scale-up-delay=600s`; Karpenter with long batch windows is also mentioned).

### Lock-in and exit
- CAST AI nodes are **plain EC2 instances** (EKS AL2023 AMI) joined through an EKS access entry. Nothing proprietary runs on them beyond DaemonSets.
- Node templates/configurations are CAST AI objects. Leaving the standard autoscaler means re-creating NodePools (this repo keeps Karpenter's manifests, so that is one script: `switch-to-karpenter.sh`).
- Workload Autoscaler mutates **pods**, not your manifests. Remove it and restart: original requests return (and so does the cost).
- Exit path is code: `terraform destroy` in a set order (module 15), then a leftover sweep.
- **Kent (Cast AI for Karpenter)**: keeps Karpenter as the provisioner; CAST AI adds Workload Autoscaler, Rebalancer/continuous rebalancing, commitments and reports on top. Smaller blast radius (no node-launch role; Pod Identity read-only), and Karpenter keeps working if CAST AI is down. Missing in Kent today: Pod Pinner, hibernation, automatic return from on-demand fallback to spot. Switching between Kent and the standard autoscaler requires off-boarding and re-onboarding. Priced as a separate product ("Karpenter Cluster Optimization").

## Demo

### Step 1 — Billable CPUs on this cluster
Billing counts provisioned CPU, system node included.
```bash
source scripts/env.sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.capacity.cpu,BY:.metadata.labels.provisioner\.cast\.ai/managed-by'
```
Expected after module 13's reset: the system `t3a.large` (2 CPU, `BY` `<none>`) plus 3 CAST AI spot nodes, for example `c6a.large` 2, `c6a.xlarge` 4, `c8i-flex.large` 2. Total 10 CPU (8 at the rightsized point).
CAST AI's Platform usage doc defines billable CPU as provisioned CPU per cluster; it does not say whether nodes CAST AI does not manage (our system MNG node) count. The ROI below counts them (worst case). Ask.
Console → **Settings → Platform usage** (classic: **Manage Organization → Platform usage**): Node Autoscaler / Workload Autoscaler cards with this month's billable CPUs and trial days left.

### Step 2 — ROI on the demo's own numbers
```bash
jq -n --slurpfile a results/karpenter-baseline.json --slurpfile b results/castai-final.json 'def r2: (. * 100 | round) / 100; {before_usd_month: $a[0].totals.usdPerMonthWorkers, after_usd_month: $b[0].totals.usdPerMonthWorkers, billable_cpu: $b[0].totals.provisionedVcpu} | .saving = (.before_usd_month - .after_usd_month | r2) | .fee_per_cpu_only = (.billable_cpu * 5.07 | r2) | .net_per_cpu_only = (.saving - .fee_per_cpu_only | r2) | .net_with_1000_tier = (.saving - 1000 | r2)'
```
Expected (real run, 3 h old install):
```json
{
  "before_usd_month": 76.43,
  "after_usd_month": 49.71,
  "billable_cpu": 8,
  "saving": 26.72,
  "fee_per_cpu_only": 40.56,
  "net_per_cpu_only": -13.84,
  "net_with_1000_tier": -973.28
}
```
Say it: **this demo cluster is ROI-negative** even per-CPU only: $26.72 saved vs $40.56 fee. Two reasons: workers were already spot (~$8 per vCPU-month, so a $5.07 fee eats 60 %), and the rightsizing was capped at 25 % on a fresh install. The point is the ratio, not the dollars. Then show the 500 vCPU table above.

### Step 3 — The AWS role CAST AI assumes
```bash
aws iam get-role --role-name castai-eks-karpenter-demo --query 'Role.AssumeRolePolicyDocument.Statement[].{Principal:Principal,Condition:Condition}' --output json
aws iam list-attached-role-policies --role-name castai-eks-karpenter-demo --query 'AttachedPolicies[].PolicyName' --output text
aws iam list-role-policies --role-name castai-eks-karpenter-demo --query 'PolicyNames' --output text
```
Expected:
```text
[
    {
        "Principal": {
            "AWS": "arn:aws:iam::809060229965:user/cast-crossrole-<cluster-id>"
        },
        "Condition": null
    }
]
CastEKSPolicy-karpenter-demo	AmazonEC2ReadOnlyAccess	IAMReadOnlyAccess
castai-user-policy-karpenter-demo
```
Point at `"Condition": null`: no ExternalId. Trust rests on the per-cluster CAST AI user.

The write permissions and their tag conditions (inline policy):
```bash
aws iam get-role-policy --role-name castai-eks-karpenter-demo --policy-name castai-user-policy-karpenter-demo --query PolicyDocument --output json | jq -c '.Statement[] | {Sid, Action, Condition}'
aws ec2 describe-instances --filters 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].[InstanceType,Tags[?Key==`kubernetes.io/cluster/karpenter-demo`]|[0].Value]' --output text
```
Expected: 8 statements, among them:
```text
{"Sid":"RunInstancesTagRestriction","Action":"ec2:RunInstances","Condition":{"StringEquals":{"aws:RequestTag/kubernetes.io/cluster/karpenter-demo":"owned"}}}
{"Sid":"RunInstancesVpcRestriction","Action":"ec2:RunInstances","Condition":{"StringEquals":{"ec2:Vpc":"arn:aws:ec2:ap-south-1:146725924014:vpc/vpc-0db2670bef5e06f86"}}}
{"Sid":"InstanceActionsTagRestriction","Action":["ec2:TerminateInstances","ec2:StartInstances","ec2:StopInstances","ec2:CreateTags"],"Condition":{"StringEquals":{"ec2:ResourceTag/kubernetes.io/cluster/karpenter-demo":["owned","shared"]}}}
{"Sid":"EKS","Action":["eks:Describe*","eks:List*","eks:TagResource","eks:UntagResource","eks:CreateNodegroup","eks:DeleteNodegroup"],"Condition":null}
```
then every running instance, system node included, with `owned`:
```text
t3a.large	owned
c6a.xlarge	owned
...
```
Point at the conditions, then at the system node: the tag scope is the whole cluster, not just CAST AI nodes. The managed `CastEKSPolicy-karpenter-demo` only holds PassRole, CreateTags, key pairs and unconditioned `RunInstances` on images, volumes, ENIs and security groups.

### Step 4 — In-cluster permissions
```bash
kubectl get clusterroles -o name | grep -i cast
kubectl get clusterrole -o json | jq -r '.items[] | select(.metadata.name|test("castai")) | .metadata.name as $n | .rules[] | select((.verbs|index("*")) or (.verbs|index("delete")) or (.verbs|index("patch"))) | "\($n)\t\(.resources|join(","))\t\(.verbs|join(","))"' | column -t
```
Expected: 14 ClusterRoles (`castai-agent`, `castai-cluster-controller`, `castai-cluster-controller-ext`, `castai-evictor`, `castai-evictor-crd-upgrade`, `castai-evictor-ext`, `castai-pod-mutator`, `castai-pod-pinner`, `castai-pod-pinner-ext`, `castai-spot-handler`, `castai-spot-handler-phase2`, `castai-workload-autoscaler`, `castai-workload-autoscaler-exporter`, `castai-workload-autoscaler-exporter-prometheus`), then 43 write rules. `castai-agent` never appears in the second list. Lines to point at:
```text
castai-cluster-controller   nodes                                  delete
castai-cluster-controller   pods                                   delete
castai-cluster-controller   namespaces                             delete
castai-cluster-controller   clusterroles,clusterrolebindings       get,delete
castai-evictor              pods                                   delete,get,list,watch
castai-pod-pinner           nodes                                  create,delete,get
castai-workload-autoscaler  replicasets,deployments,statefulsets   update,patch
castai-workload-autoscaler  pods/resize                            patch
castai-workload-autoscaler  horizontalpodautoscalers               list,update,create,patch,watch,delete,get
```
The cluster-controller is the powerful one; it exists only in `phase=automation`.

### Step 5 — What the agent sends
Show the agent cannot read Secrets.
```bash
SA=$(kubectl -n castai-agent get deploy castai-agent -o jsonpath='{.spec.template.spec.serviceAccountName}'); echo "$SA"
kubectl auth can-i get secrets --all-namespaces --as="system:serviceaccount:castai-agent:${SA}"
kubectl auth can-i list pods --all-namespaces --as="system:serviceaccount:castai-agent:${SA}"
```
Expected: `castai-agent`, then `no`, then `yes`.

## Talking points
- Free tier first: install read-only on every cluster, read Available savings, only then talk price.
- Ask three pricing questions in writing: per-CPU once or per product, base tier or overage, savings-share or not.
- The IAM role is tag-scoped but still can terminate any instance tagged for this cluster. Scope it with evictor scoped mode and limits, and know it.
- SaaS outage = no optimization, not an outage. Pending pods during a scale-up are the real risk; have a delayed fallback.
- Exit is cheap because nodes are plain EC2 and requests live in pods, not in Git.

## Reset
Nothing changed in this module. Unset the helper variables:
```bash
unset SA
```

## Q&A prep
- **Is there a free trial?** Yes, length not published; check Platform usage. Read-only is free indefinitely.
- **Can I buy through AWS Marketplace and burn EDP?** The EKS listing is on Marketplace (1-month contracts, private offers available). The listing does not mention EDP; ask AWS and CAST AI whether your EDP covers it.
- **Do you see our secrets?** No Secrets/ConfigMaps access; sensitive-looking literal env values are scrubbed before sending (module on read-only showed it).
- **Data residency in India?** Not documented; data is stored in US or EU regions. Ask for a DPA if required. PrivateLink onboarding exists for private networking.
- **What if we leave?** `terraform destroy` + sweep (module 15). Karpenter comes back with its own manifests; workload requests revert on restart.
- **Kent or standard?** Kent if Karpenter is a platform standard you keep; standard if you want CAST AI to own nodes (Pod Pinner, spot fall-forward, hibernation).
