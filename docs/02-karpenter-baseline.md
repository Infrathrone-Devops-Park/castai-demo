# 02 — Karpenter baseline
**Time:** 30 min · **Goal:** Measure what the `shop` app costs on a tuned Karpenter setup, so every later number has a fair "before".

## What you'll show
- Karpenter is at the course BASELINE: one `NodePool default`, one `EC2NodeClass default`, unchanged from the Karpenter course.
- The `shop` app: six over-requested deployments, 6.0 vCPU requested, ~1.6 vCPU used.
- The nodes Karpenter chose for it, and why they are the right answer *for those requests*.
- The first snapshot: `scripts/measure.sh karpenter-baseline`.
- The requested-vs-used gap per node in `eks-node-viewer` and `kubectl top`.

## Concepts

### What "tuned Karpenter" means here
We compare CAST AI against a Karpenter config you would run in production, not a straw man. On screen:

| Setting (`NodePool default`) | Value | Why it matters for cost |
|---|---|---|
| `karpenter.sh/capacity-type` | `spot`, `on-demand` | Spot preferred, on-demand fallback |
| `instance-category` | `c`, `m`, `r` | Wide choice of cheap types |
| `instance-cpu` | `2`, `4` | Quota: any single replacement fits |
| `instance-generation` | `Gt 4` | No old, pricier generations |
| `consolidationPolicy` | `WhenEmptyOrUnderutilized` | Deletes and replaces under-used nodes |
| `consolidateAfter` | `1m` | Reacts quickly |
| `limits.cpu` | `10` | Quota guard |

Not enabled: `SpotToSpotConsolidation` (alpha gate, off). Say so: it affects how often a spot node is replaced with a cheaper spot node.

### The shop app

| Deployment | Replicas | Request / pod | Uses / pod | Requested | Used |
|---|---|---|---|---|---|
| frontend | 3 | 400m / 256Mi | ~100m / ~70Mi | 1200m | 300m |
| cart | 2 | 300m / 256Mi | ~70m / ~70Mi | 600m | 140m |
| catalog | 2 | 500m / 384Mi | ~120m / ~135Mi | 1000m | 240m |
| checkout | 2 | 500m / 256Mi | ~100m / ~70Mi | 1000m | 200m |
| payments | 2 | 400m / 256Mi | ~100m / ~70Mi | 800m | 200m |
| worker | 2 | 700m / 512Mi | ~250m / ~200Mi | 1400m | 500m |
| **total** | **13** | | | **6000m** | **~1580m** |

Each pod runs `stress-ng --cpu 1 --cpu-load N`: a constant, deterministic share of one core, plus a fixed block of memory (`--vm-hang 0`: allocate once, then sleep). No PDBs, so drains never block, and no capacity-type selectors, so both autoscalers can place every pod.

### How measure.sh prices nodes
- Spot nodes: latest `aws ec2 describe-spot-price-history` price for that instance type **and AZ**, cached 1 h.
- On-demand nodes: AWS Price List API (`pricing get-products`, queried via the `us-east-1` endpoint), cached; falls back to a small built-in table if the API is not reachable.
- Workers = every node except the system node. All-in adds the system node and EKS $0.10/h.
- This is list price. It ignores Savings Plans, EBS and data transfer, the same for both tools.

## Demo

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: the five-line summary from module 00.

### Step 2 — Karpenter is at BASELINE
`kubectl diff` exits 0 when live objects match the course manifests.
```bash
kubectl diff -f "$KARPENTER_DEMO_DIR/manifests/base/" && echo "BASELINE OK"
kubectl get nodepools,ec2nodeclasses
kubectl -n kube-system get deploy karpenter
```
Expected: `BASELINE OK`; one `nodepool.karpenter.sh/default` and one `ec2nodeclass.karpenter.k8s.aws/default`, both `READY True`; `karpenter 1/1`. If `kubectl diff` prints a diff, the NodePool was changed (for example frozen at `limits.cpu: "0"`): run `kubectl apply -f "$KARPENTER_DEMO_DIR/manifests/base/"` and re-check. Do **not** run `../karpenter-demo/scripts/reset.sh` while `shop` is running: it deletes all NodeClaims and waits for zero, which never happens while `shop` pods are pending.

### Step 3 — Deploy shop
Already deployed in prep (≥3 h ago); the apply proves the manifests match.
```bash
kubectl apply -f workloads/shop.yaml
kubectl -n shop wait deploy --all --for=condition=Available --timeout=300s
```
Expected: `namespace/shop unchanged` and six `deployment.apps/<name> unchanged` lines (or `created` on a fresh cluster), then six `condition met` lines (under 1 s when already running). On a fresh deploy Karpenter launches nodes in about 60–90 s.

### Step 4 — What Karpenter launched
Two or three nodes, mostly spot.
```bash
kubectl get nodeclaims -o wide
kubectl get nodes -l karpenter.sh/nodepool -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,topology.kubernetes.io/zone
```
Expected: 2–3 NodeClaims, `READY True`, typically 2 × 4-vCPU types or 1 × 4-vCPU + 2 × 2-vCPU, `CAPACITY spot` on most of them. Validation run: `c6a.xlarge` (spot, ap-south-1b) and `c8i-flex.xlarge` (spot, ap-south-1c). Exact types depend on spot prices at that moment.

### Step 5 — Baseline snapshot
The number every later module compares against.
```bash
scripts/measure.sh karpenter-baseline
```
Expected (validation run; spot prices vary):
```text
NODE                                        PROVISIONER  TYPE             CAPACITY   ZONE         VCPU  USD/H
ip-10-0-30-161.ap-south-1.compute.internal  karpenter    c6a.xlarge       spot       ap-south-1b  4     0.0519
ip-10-0-41-192.ap-south-1.compute.internal  karpenter    c8i-flex.xlarge  spot       ap-south-1c  4     0.0528
ip-10-0-19-127.ap-south-1.compute.internal  system*      t3a.large        on-demand  ap-south-1b  2     0.0493
(* system node: fixed cost, not autoscaled)

nodes (workers / spot workers)    3 (2 / 2)
provisioned vCPU (all / workers)  10 / 8
requested vCPU (all ns / shop)    7.68 / 6
used vCPU (all ns / shop)         1.731 / 1.590
shop pods scheduled               13
$/h workers                       0.1047
$/h all nodes                     0.154
$/h all-in (+EKS 0.10)            0.254
$/month workers (x730)            76.43
$/month all-in (x730)             185.42

saved results/karpenter-baseline.json
```
Read it out: workers = 8 vCPU provisioned for 6 vCPU of shop requests and ~1.6 vCPU of shop usage. `requested (all ns)` adds 1.68 vCPU: system pods (karpenter, coredns, metrics-server, monitoring, castai-agent) plus daemonsets (aws-node, kube-proxy, eks-pod-identity-agent, node-exporter on every node; spot-handler on spot nodes). For reference: on-demand list price of the same types is `c6a.xlarge` $0.0935/h and `c8i-flex.xlarge` $0.178/h, so spot is 44–70% cheaper here.

### Step 6 — The gap, per node
Full by requests, mostly idle by usage.
```bash
kubectl describe nodes -l karpenter.sh/nodepool | grep -A4 'Allocated resources'
kubectl top nodes -l karpenter.sh/nodepool
```
Expected: `cpu` requests between ~60% and ~99% of allocatable per Karpenter node (validation run: `3880m (98%)` and `2480m (63%)`); `kubectl top` `CPU%` around 20–25%.

### Step 7 — eks-node-viewer
The neutral price view both camps already use.
```bash
eks-node-viewer --resources cpu --extra-labels karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```
Expected: one bar per node filled to roughly the request percentage, a `$/hour` per node, and a total line such as `3 nodes (7680m/9770m) 78.6% cpu ... $0.154/hour | $112.420/month`. The total includes the system node, so compare it with `$/h all nodes` from `measure.sh` (validation run: both `0.154`). The first frame can show a higher figure (`$0.180/hour`) until live spot prices load. Press `q` to quit.

### Step 8 — Try to beat it by hand (optional)
Karpenter has nothing left to consolidate.
```bash
kubectl get nodeclaims -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Consolidatable")].status}{"\n"}{end}'
kubectl get events -A --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp | tail -5
```
Expected: NodeClaims `True` (eligible), but no recent `DisruptionLaunching` / `disrupting node(s)` activity: no cheaper packing exists **for these requests**. `Unconsolidatable` events (for example `SpotToSpotConsolidation is disabled`) may appear.

## Talking points
- "This is the before picture. Karpenter did exactly what it should: cheap spot nodes, tightly packed. By requests, these nodes are nearly full."
- "By usage, they are about three-quarters idle. No node autoscaler can fix that without touching requests."
- "Write down $/h workers. Every module from now on is measured against it."

## Reset
Leave `shop` running: every later module uses it. To fully remove it during rehearsal:
```bash
kubectl delete -f workloads/shop.yaml
kubectl get nodeclaims
```
Expected: `namespace "shop" deleted` and six `deployment.apps "<name>" deleted`; Karpenter removes the now-empty nodes within about 2 minutes (`No resources found`).

## Q&A prep
- **Is this Karpenter config tuned enough?** It uses the default and recommended consolidation, wide instance choice and spot. Enabling `SpotToSpotConsolidation` might shave a little more; it does not change requests.
- **Why do both tools get the same workload with no spot/on-demand pinning?** CAST AI's template here is spot-only, and a `karpenter.sh/capacity-type` selector would block CAST AI. Same pods, same freedom.
- **Why stress-ng and not a real app?** Deterministic CPU usage. A real app's usage wanders, and the before/after comparison would be noise.
- **Do these prices include Savings Plans?** No. List on-demand and current spot only, for both phases.
