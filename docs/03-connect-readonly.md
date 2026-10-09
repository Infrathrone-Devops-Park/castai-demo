# 03 — Connect CAST AI read-only
**Time:** 25 min · **Goal:** Connect the cluster to CAST AI with only the read-only agent running, after a security review the audience can check line by line.

## What you'll show
- What the read-only agent does, what it can read, and what leaves the cluster.
- The agent's RBAC, rendered from the exact chart version we install, before installing it.
- The Terraform root that registers the cluster (`phase=readonly`) and what it creates in AWS.
- The agent running on the system node, and the cluster `online` in the API and the console.

## Concepts

### Read-only agent
- Helm umbrella chart `castai` 0.43.311, mode `tags.readonly=true`, namespace `castai-agent`.
- With our values it runs three things:

| Object | What it does |
|---|---|
| `deployment/castai-agent` (1 replica) | Watches the Kubernetes API (informers) and sends snapshots of nodes, pods, workloads and metrics-server data to `api.cast.ai` |
| `deployment/castai-agent-cpvpa` | Cluster-proportional VPA: resizes the agent's own requests as the cluster grows |
| `daemonset/castai-spot-handler` | Watches IMDS for spot interruption notices; reports only, takes no action; runs on spot nodes only |

- `castai-kvisor` (security agent) is part of read-only mode by default; our values disable it to save system-node CPU.
- On EKS the agent gets `EKS_ACCOUNT_ID`, `EKS_REGION`, `EKS_CLUSTER_NAME` and `STATIC_CLUSTER_ID` as env vars, so it never needs IMDS from a pod.
- It authenticates with the **cluster token** that Terraform receives when it registers the cluster, not with your personal API key.

### RBAC (from `helm template`, chart 0.43.311)

| Scope | Resources | Verbs |
|---|---|---|
| ClusterRole `castai-agent` | pods, nodes, services, namespaces, events, PVs/PVCs, deployments, replicasets, daemonsets, statefulsets, jobs, cronjobs, HPAs, VPAs, PDBs, storage classes, Karpenter NodePools/NodeClaims/EC2NodeClasses, RBAC objects, network policies, ingresses, `*.cast.ai` CRs | `get`, `list`, `watch` only |
| Role in `castai-agent` | leases (leader election) | create, update |
| Role in `castai-agent` | configmaps (its own metadata) | get, list, watch, create, update, patch |
| Role in `castai-agent` | `deployments/castai-agent` only | patch (for cpvpa) |
| Role in `kube-system` | configmaps | get, list, watch |
| ClusterRole `castai-spot-handler` | nodes | get, list, watch |

- **No access to Secrets anywhere.** Configmaps are readable only in `kube-system` and `castai-agent`.
- **No write access outside `castai-agent`.** It cannot create, change or delete pods, nodes or workloads.

### What leaves the cluster
- Object metadata and specs (nodes, pods, workloads, Karpenter objects) and CPU/memory usage.
- Env vars with names like `password`, `secret`, `token`, `key`, `creds` and literal values are scrubbed in the cluster before sending.
- Stored by CAST AI in GCP (US region for `api.cast.ai`). No Mumbai/in-region data residency is documented: raise it with security if that matters.
- Egress needed: `api.cast.ai:443` (the agent), plus `grpc.cast.ai:443` and `files.cast.ai:443` for later components. Private subnets reach them through the existing NAT gateway.

### What Terraform creates at `phase=readonly`
Be precise here: "read-only" describes the **in-cluster** agent. The Terraform root registers the cluster for the later phases too:

| Resource | Effect now |
|---|---|
| `castai_eks_clusterid`, `castai_eks_cluster` | Registers `karpenter-demo` in the org; `delete_nodes_on_disconnect = true` |
| `module.castai_eks_role_iam` (IAM role `castai-eks-karpenter-demo`, instance profile `castai-eks-instance-karpenter-demo`, policy `CastEKSPolicy-karpenter-demo`) | Cross-account role CAST AI can assume; `ec2:RunInstances` only with tag `kubernetes.io/cluster/karpenter-demo=owned`, terminate only on instances with that tag |
| `aws_eks_access_entry` (`EC2_LINUX`) | Lets future CAST AI nodes join |
| `castai_node_configuration`, `castai_node_template` | Templates only; nothing is launched |
| `castai_autoscaler_policies`, `castai_evictor` | Created with `enabled = false` |
| `helm_release.castai` | `tags.readonly=true`: only the agent and spot handler |

Nothing provisions nodes in this phase: the autoscaler policy is off and no cluster-controller is installed to execute actions. A strictly read-only connect (no IAM role at all) is possible with only `castai_eks_cluster` (no `assume_role_arn`) plus the agent; we pre-create IAM so phase 2 is one variable away. <!-- VERIFY: console shows "Read only" when credentials exist but only the agent runs -->

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: the five-line summary; `CASTAI_API_KEY=<set, ...>`.

### Step 2 — Render the RBAC before installing
The exact chart version, rendered locally; nothing touches the cluster.
```bash
helm template castai castai --repo https://castai.github.io/helm-charts --version 0.43.311 -n castai-agent --set tags.readonly=true --set global.castai.provider=eks --set global.castai.apiKey=placeholder --show-only charts/autoscaler/charts/castai-agent/templates/rbac.yaml | grep -E '^kind:|^  (name|namespace):|^      - (create|update|patch|delete)$|secrets'
```
Expected:
```text
kind: ServiceAccount
  name: castai-agent
  namespace: castai-agent
kind: ClusterRole
  name: castai-agent
kind: ClusterRoleBinding
  name: castai-agent
  name: castai-agent
kind: Role
  name: castai-agent
  namespace: castai-agent
      - create
      - update
      - create
      - update
      - patch
      - patch
kind: Role
  name: castai-agent
  namespace: kube-system
kind: RoleBinding
  name: castai-agent
  namespace: castai-agent
  name: castai-agent
kind: RoleBinding
  name: castai-agent
  namespace: kube-system
  name: castai-agent
```
Point out: the only write verbs sit in the namespaced Role in `castai-agent` (leases, its own configmaps, patching its own deployment). The ClusterRole has none. No line mentions `secrets`.

### Step 3 — Plan
Shows exactly what will be created in AWS and in CAST AI.
```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -var phase=readonly
```
Expected: `Terraform has been successfully initialized!`. Then either `No changes. Your infrastructure matches the configuration.` (connected during prep, the normal case) or, on a fresh cluster, a plan ending `Plan: 23 to add, 0 to change, 0 to destroy.` listing the resources in the table above. <!-- VERIFY: 23 on a fresh state -->

### Step 4 — Apply
Registers the cluster and installs the agent.
```bash
terraform -chdir=terraform apply -var phase=readonly
```
Type `yes` when asked. Expected: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` after prep, or `Resources: 23 added` on a fresh cluster (the Helm release takes 1–2 minutes). Outputs include `castai_cluster_id = "<uuid>"`, `phase = "readonly"`, `autoscaler_enabled = false`.

Reload so `CASTAI_CLUSTER_ID` is set:
```bash
source scripts/env.sh
```
Expected: `CASTAI_CLUSTER_ID=<uuid>`.

### Step 5 — Agent pods on the system node
```bash
kubectl -n castai-agent get deploy,ds
kubectl -n castai-agent get pods -o wide
```
Expected: `castai-agent 1/1`, `castai-agent-cpvpa 1/1`, `castai-spot-handler` with one pod per spot node (0 if no spot nodes). The two agent pods run on the `t3a.large` system node; spot-handler pods on the Karpenter spot nodes. No `castai-cluster-controller`, `castai-evictor` or `castai-pod-pinner` yet. <!-- VERIFY: spot-handler schedules on Karpenter spot nodes -->

### Step 6 — Prove it is read-only
Ask the API server, not the vendor.
```bash
kubectl auth can-i get secrets -A --as=system:serviceaccount:castai-agent:castai-agent
kubectl auth can-i delete pods -A --as=system:serviceaccount:castai-agent:castai-agent
kubectl auth can-i create nodes --as=system:serviceaccount:castai-agent:castai-agent
kubectl auth can-i list pods -A --as=system:serviceaccount:castai-agent:castai-agent
```
Expected: `no`, `no`, `no`, `yes`.

### Step 7 — Agent is sending data
```bash
kubectl -n castai-agent logs deploy/castai-agent --tail=10
```
Expected: recent lines about collecting and sending snapshots, no `401`/`403` and no `EC2MetadataRequestError`. <!-- VERIFY: exact log wording -->

### Step 8 — Cluster status via API
```bash
scripts/castai-api.sh GET /v1/kubernetes/external-clusters/$CASTAI_CLUSTER_ID | jq '{name, status, agentStatus, isPhase2, managedBy, providerType, kubernetesVersion}'
```
Expected:
```json
{
  "name": "karpenter-demo",
  "status": "ready",
  "agentStatus": "online",
  "isPhase2": false,
  "managedBy": "terraform",
  "providerType": "eks",
  "kubernetesVersion": "1.36"
}
```
`agentStatus: online` means snapshots arrive. Right after a fresh connect it shows `waiting-connection` for a minute or two. <!-- VERIFY: isPhase2 and managedBy values when assume_role_arn is set but only the agent runs -->

### Step 9 — Console
Console → **Clusters** → `karpenter-demo`. Expected: status **Connected**, mode **Read only** (or the cluster page offers "Enable CAST AI" / automation). The dashboard shows node count, CPU and memory provisioned vs requested within a few minutes of connecting. <!-- VERIFY: console label and nav names -->

## Talking points
- "You just saw the RBAC before it was installed: read-only cluster-wide, no Secrets, writes only to its own namespace."
- "The agent talks out over HTTPS. Nothing calls into your cluster."
- "Read-only is free and you can stay there forever. Everything from module 04 is computed from what this agent sends."
- "Our Terraform also pre-creates the IAM role. That role can launch and terminate instances tagged for this cluster. In a real rollout you would add it only when you move to phase 2."

## Reset
Leave the cluster connected; modules 04–15 need it. To rehearse a fresh connect (loses the Workload Autoscaler history, so only before prep):
```bash
terraform -chdir=terraform destroy -var phase=readonly
kubectl get ns castai-agent
```
Expected: `Destroy complete! Resources: 23 destroyed.`, then `Error from server (NotFound): namespaces "castai-agent" not found` (or the namespace in `Terminating`). Module 15 covers full offboarding. <!-- VERIFY: helm uninstall removes the namespace (create_namespace=true) -->

## Q&A prep
- **Can the agent read our Secrets?** No. `kubectl auth can-i get secrets` returned `no`. It reads configmaps only in `kube-system` and its own namespace.
- **What if CAST AI is compromised?** In read-only mode, the in-cluster blast radius is read access to object metadata. The pre-created IAM role is the bigger exposure: it is scoped by tag and VPC, but can launch and terminate cluster-tagged instances. Skip it until phase 2 if that matters.
- **Does the agent need IMDS or node IAM?** No. EKS facts come from env vars; it has no AWS credentials.
- **How much does the agent cost to run?** About 100m CPU / 128Mi on the system node (cpvpa scales it with cluster size), plus the spot handler at 20m / 40Mi per spot node.
- **Why not the console's one-line script or `castctl`?** It works, but on a Karpenter cluster it offers the Karpenter (Kent) path, and a Terraform-managed cluster should not be modified with `castctl`.
