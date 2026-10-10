# 15 — Switch back to Karpenter, then offboard CAST AI
**Time:** 15 min · **Goal:** Prove the exit path: hand nodes back to Karpenter in one script, then (optionally) remove every CAST AI trace from the cluster, AWS and the console.

## What you'll show
- Workload Autoscaler off first, so requests return to the manifests' values.
- `scripts/switch-to-karpenter.sh`: CAST AI autoscaler off → its nodes deleted → quota released → Karpenter back with its original NodePool.
- Optional full offboarding with `scripts/offboard.sh --yes-offboard`: Terraform destroy in a safe order, in-cluster sweep (namespaces, webhooks, RBAC, `*.cast.ai` CRDs), AWS orphan sweep (instances, launch templates, volumes, access entry, IAM).
- API key rotation.

## Concepts

### Order matters (quota and safety)
```text
1. Workload Autoscaler off      remove annotation, then policy (else: fallback policy still optimizes)
2. CAST AI autoscaler off       castai_autoscaler_policies.enabled=false, evictor off
3. delete CAST AI nodes         kubectl delete node; then terminate tagged instances
4. wait instances gone + 60 s   spot/on-demand vCPU quota release lag
5. Karpenter to 1, NodePool restored (limits back)
-------------------------------- optional offboarding --------------------------------
6. destroy policies, evictor, node template
7. destroy castai_eks_cluster   disconnect: delete_nodes_on_disconnect=true, keep k8s resources
8. destroy the rest             access entry, IAM role/profile/policy, cluster id
9. sweep in-cluster + AWS leftovers, rotate key
```
- Never have both autoscalers on at the same time (8 + 8 vCPU quota, and CAST AI does not support it).
- `kubectl delete node` does **not** terminate a CAST AI instance once the autoscaler is off (checked twice: instances stayed `running`). The script terminates instances tagged `castai-demo=managed` after 45 s. Without that tag sweep they are orphans that hold spot quota.
- **Terraform ordering:** `-target=castai_eks_cluster.this` also destroys everything that depends on it, and dependents go first. The umbrella `helm_release.castai` reads the cluster token, so Helm is uninstalled just before the disconnect call. That is safe here because step 3 already removed CAST AI nodes, and the IAM role (a dependency, not a dependent) still exists for the disconnect to delete stragglers.
- On disconnect the provider keeps Kubernetes resources (`KeepKubernetesResources=true`), hence the in-cluster sweep.
- CAST AI documents no EC2 tag of its own. Our node configuration adds `castai-demo=managed`; every AWS sweep filters on it.

### What "clean" means
| Where | Leftover | Check |
|---|---|---|
| Kubernetes | ns `castai-agent` (+ `castai-omni`, `liqo-storage` if ever installed) | `kubectl get ns` |
| Kubernetes | webhooks `castai-*` (pod-mutator, pod-pinner, workload-autoscaler) | `kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations` |
| Kubernetes | ClusterRoles/Bindings `castai*`, CRDs `*.cast.ai` | `kubectl get clusterroles,crd` |
| Kubernetes | pods still carrying rightsized requests | pod annotation `autoscaling.cast.ai/vertical-recommendation-hash` |
| AWS | instances / launch templates / volumes with `castai-demo=managed` | `aws ec2 describe-*` |
| AWS | access entry for `castai-eks-instance-karpenter-demo` | `aws eks list-access-entries` |
| AWS | IAM `castai-eks-karpenter-demo`, `castai-eks-instance-karpenter-demo`, `CastEKSPolicy-karpenter-demo` | `aws iam get-role` |
| CAST AI | cluster record, API key | console / API |

## Demo

### Step 1 — Turn the Workload Autoscaler off
Annotation first, then the policy (the switch's `terraform apply` with `-var enable_workload_autoscaler=false`).
```bash
source scripts/env.sh
for d in $(kubectl get deploy -n shop -o name); do kubectl annotate -n shop "$d" workloads.cast.ai/configuration-; done
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found
kubectl delete -f workloads/hpa.yaml --ignore-not-found
```
Expected: `deployment.apps/<name> annotated` for each of the 6 Deployments (also when the annotation is already gone), then `... deleted from shop namespace` lines for the job and HPA objects, or nothing if they are already gone.

### Step 2 — Switch back to Karpenter
One script; it prints each phase. Extra args go to Terraform; without `enable_workload_autoscaler=false` the script would keep the `shop-rightsizing` policy if it exists.
```bash
scripts/switch-to-karpenter.sh -var enable_workload_autoscaler=false
```
Expected (real run: 3 min 37 s):
```text
==> terraform apply phase=automation autoscaler_enabled=false
...
Plan: 0 to add, 2 to change, 0 to destroy.
...
Apply complete! Resources: 0 added, 2 changed, 0 destroyed.
...
autoscaler_enabled = false
workload_scaling_policy_name = ""
==> Deleting CAST AI nodes (shop pods go Pending)
node "ip-10-0-0-43.ap-south-1.compute.internal" deleted
...
    1s: castai-nodes=0 castai-instances=3
    48s: castai-nodes=0 castai-instances=3
==> Instances still running; terminating tag castai-demo=managed: i-... i-... i-...
    80s: castai-nodes=0 castai-instances=0
==> Sleeping 60s (quota release lag)
==> Scaling Karpenter to 1
deployment "karpenter" successfully rolled out
==> Restoring NodePool default from karpenter-demo
nodepool.karpenter.sh/default configured
NAME      NODECLASS   NODES   READY   AGE
default   default     0       True    5h42m
==> Waiting for Karpenter nodes and shop pods
    1s: karpenter-nodes-ready=0 shop-pods=13 not-running=13
    50s: karpenter-nodes-ready=2 shop-pods=13 not-running=0
==> Karpenter is the autoscaler again
NAME                     ...   NODEPOOL   INSTANCE-TYPE   CAPACITY-TYPE   ZONE
ip-10-0-19-127...        ...              t3a.large                       ap-south-1b
ip-10-0-25-216...        ...   default    c6a.xlarge      spot            ap-south-1b
ip-10-0-37-168...        ...   default    c6a.xlarge      spot            ap-south-1c
```
`2 changed` = autoscaler policies and evictor off. If the module 11 policy still exists the plan also shows `1 to destroy`. The `terminating` line is expected: it is the orphan guard, not an error. Cross-check: `aws ec2 describe-instances --filters 'Name=tag:castai-demo,Values=managed' 'Name=instance-state-name,Values=pending,running' --query 'length(Reservations[].Instances[])'` prints `0`.

### Step 3 — Requests are back to the manifests
Pods rescheduled during the switch; any still resized are recreated.
```bash
kubectl get pods -n shop -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,NODE:.spec.nodeName'
kubectl get pods -n shop -o json | jq '[.items[] | .spec.containers[].resources.requests.cpu | if endswith("m") then (rtrimstr("m")|tonumber/1000) else tonumber end] | add'
```
Expected: 300m–700m per pod and a total of `6.000000000000001` (float sum). If any pod still shows a rightsized value: `kubectl delete pods -n shop --all`.

Optional: `scripts/measure.sh karpenter-after` and `scripts/compare.sh karpenter-baseline karpenter-after` to show the cost came back with the requests. Real run: 2x c6a.xlarge spot, `requested vCPU (shop)` 6 → 6, `$/h workers` 0.1047 → 0.1015 (-3.1 %, spot price drift only).

Stop here if the cluster keeps CAST AI in read-only mode for later sessions:
```bash
terraform -chdir=terraform plan -input=false -out=tfplan -var phase=readonly -var autoscaler_enabled=false
terraform -chdir=terraform apply -input=false tfplan
rm -f terraform/tfplan
```
Expected plan: `helm_release.castai will be updated in-place` with `full = true` removed and `readonly` false → true, `Plan: 0 to add, 1 to change, 0 to destroy`, output `phase = "automation" -> "readonly"`. Only the plan was validated (the validation run had to end in `phase=automation`); after the apply check `kubectl -n castai-agent get deploy` for leftovers of the automation components.

### Step 4 (optional) — Full offboarding
Destructive; refuses to run without the flag.
```bash
scripts/offboard.sh
echo "exit=$?"
```
Expected: `usage: scripts/offboard.sh --yes-offboard` and `exit=1`.
```bash
scripts/offboard.sh --yes-offboard
```
Not executed during validation (destructive); logic and plans were checked. Every Terraform step is a saved plan (`plan -out=tfplan`, `plan -destroy -out=tfplan`) applied with `apply tfplan`, so Terraform prints `Apply complete! Resources: 0 added, 0 changed, N destroyed.` rather than `Destroy complete!`. Plan-only previews on the live state: the targeted policies/evictor/template step destroys 3; the cluster step destroys 7 (`helm_release.castai`, `castai_node_configuration.default`, `castai_node_configuration_default.this`, `castai_node_template.default`, `castai_autoscaler_policies.this`, `castai_evictor.this`, `castai_eks_cluster.this`).
Expected (~10–15 min), sections in this order:
```text
==> Removing Workload Autoscaler annotations
==> terraform apply autoscaler_enabled=false enable_workload_autoscaler=false
==> Destroying policies, evictor, node template
Apply complete! Resources: 0 added, 0 changed, 3 destroyed.
==> Destroying castai_eks_cluster (disconnect, delete CAST AI nodes)
Apply complete! Resources: 0 added, 0 changed, N destroyed.
==> Destroying remaining Terraform resources
Apply complete! Resources: 0 added, 0 changed, N destroyed.
==> Sweeping in-cluster CAST AI leftovers
==> Recreating shop pods resized by CAST AI
==> AWS sweep: instances tag castai-demo=managed
    none
...
==> Offboarding done. Rotate the CAST AI API key now:
```
If the cluster destroy hangs on a Helm pre-delete hook (the workload-autoscaler hook Job has no tolerations), the script prints the recovery:
```bash
helm uninstall castai -n castai-agent --no-hooks
terraform -chdir=terraform state rm helm_release.castai
scripts/offboard.sh --yes-offboard
```
`default-by-castai` is the cluster's default template: Terraform plans a destroy, but the API side was not exercised. If the targeted step fails on it, the script warns and the cluster step retries it.

### Step 5 — Verify nothing is left
Kubernetes:
```bash
kubectl get ns | grep -Ei 'castai|liqo' || echo "no castai namespaces"
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -Ei 'castai|cast\.ai|liqo' || echo "no castai webhooks"
kubectl get crd -o name | grep -Ei 'cast\.ai|liqo\.io' || echo "no castai CRDs"
kubectl get clusterroles,clusterrolebindings -o name | grep -i castai || echo "no castai RBAC"
```
Expected: the four `no castai ...` lines.

AWS:
```bash
aws ec2 describe-instances --filters 'Name=tag:castai-demo,Values=managed' 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'length(Reservations[].Instances[])'
aws ec2 describe-launch-templates --filters 'Name=tag:castai-demo,Values=managed' --query 'length(LaunchTemplates)'
aws iam get-role --role-name castai-eks-karpenter-demo --query Role.RoleName --output text 2>&1 | tail -1
aws eks list-access-entries --cluster-name karpenter-demo --query 'accessEntries' --output text | tr '\t' '\n' | grep castai || echo "no castai access entry"
```
Expected: `0`, `0`, an `(NoSuchEntity)` error line, `no castai access entry`.

CAST AI:
```bash
scripts/castai-api.sh GET /v1/kubernetes/external-clusters | jq -r '.items[]? | select(.name=="karpenter-demo") | "\(.id) \(.status)"'
```
Expected: no output. If a line remains, Console → cluster → **Disconnect** → **Remove cluster**.

Karpenter still serves the workload:
```bash
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
kubectl get pods -n shop --field-selector=status.phase!=Running
```
Expected: system node + Karpenter nodes; `No resources found in shop namespace.`

### Step 6 — Rotate the API key
Console → **API keys** (or **Service Accounts**) → delete the key used for the demo. Then locally:
```bash
rm -f ~/.castai/api-token
ls ~/.castai/
```
Expected: `api-token` no longer listed. Rotate even if you plan to re-onboard; create a fresh key then.

## Talking points
- Exit took two scripts and ~20 min. Nodes were plain EC2; Karpenter's NodePool came straight back from its own manifest.
- Requests went back to 6 vCPU on the first restart: the Workload Autoscaler never wrote to Git. That is both clean and a warning: the saving disappears with the tool unless you feed the recommendations back into your manifests.
- Disconnect keeps Kubernetes objects by design; budget 5 minutes for the sweep.
- Tag your own resources (`castai-demo=managed`); the vendor's IAM tag condition is shared with Karpenter and the MNG.

## Reset
After `switch-to-karpenter.sh` only: return to the CAST AI active baseline with `scripts/switch-to-castai.sh` then `scripts/reset.sh`.
After `offboard.sh`: there is no reset; re-onboarding means `terraform -chdir=terraform apply -var phase=readonly` with a new API key in `~/.castai/api-token`, then the earlier modules. The Workload Autoscaler needs another 3 h of history.

## Q&A prep
- **Do running pods restart when CAST AI is removed?** Only the ones you restart (or that move nodes). Requests stay as last set until then.
- **Does disconnect delete my Karpenter or MNG nodes?** It deletes CAST AI-provisioned nodes only (`delete_nodes_on_disconnect=true`). Our nodes were already gone.
- **What if Terraform state is lost?** Console: Autoscaler off → Disconnect (tick "delete nodes CAST AI created") → Remove cluster → run the cleanup script; then the same sweeps.
- **Is the IAM role removed?** Yes, by `terraform destroy` (module `castai/eks-role-iam`); `offboard.sh` deletes it directly if Terraform did not.
- **Kent instead?** Offboarding Kent is lighter: uninstall the Helm release and Pod Identity association; NodePools never changed hands (vendor statement; shadow `zzz-castai-*` NodePools must be checked).
