# 01 — Where Kubernetes money goes
**Time:** 20 min · **Goal:** Separate node-level waste from pod-level waste, and show honestly which one each tool attacks.

## What you'll show
- The two layers of waste: nodes that are badly packed or badly chosen, and pods that ask for far more than they use.
- What Karpenter optimizes (nodes for the requests it is given) and what it never touches (the requests).
- The CAST AI feature map and which features matter for cost.
- An honest comparison table, including where Karpenter + VPA matches.
- Three read-only commands that show the requested-vs-used gap on the live cluster.

## Concepts

### Two layers of waste

```text
 what you pay for   ┌──────────────────────────────────────────────┐
 (provisioned)      │ node capacity                                │
                    │  ┌────────────────────────────────────┐      │ <- node-level waste:
 what pods reserve  │  │ pod requests                       │ idle │    unpacked space,
 (requested)        │  │  ┌──────────────┐                  │      │    wrong instance type,
                    │  │  │ actual usage │  over-requested  │      │    on-demand vs spot
 what pods use      │  │  └──────────────┘  (pod-level)     │      │
 (used)             │  └────────────────────────────────────┘      │
                    └──────────────────────────────────────────────┘
```

- **Node-level waste** = provisioned − requested. Causes: poor bin-packing, nodes too big, empty nodes kept, on-demand where spot would do, old generations.
- **Pod-level waste** = requested − used. Causes: requests copied from a template, sized for a peak that never comes, "just in case" margins.
- The scheduler and every node autoscaler only see **requests**. A node that is "full" by requests can be 75% idle by usage.
- In most real clusters pod-level waste is the larger one. CAST AI's own 2026 report claims ~8% average CPU utilization across its customer fleet; treat that as vendor data, but the direction is widely confirmed.

### What Karpenter does (and doesn't)

| Karpenter v1.14 does | Karpenter does not |
|---|---|
| Launches just-in-time nodes sized to pending pods | Change pod requests |
| Picks the cheapest fitting type (on-demand: lowest price; spot: `price-capacity-optimized`) | Report cost per namespace or workload |
| Consolidates: deletes empty nodes, replaces with cheaper ones (`WhenEmptyOrUnderutilized`, `Balanced`) | Show a savings preview before acting |
| Falls back from spot to on-demand automatically | Probe and return to spot on a schedule (only via ordinary consolidation) |
| Handles spot interruption via SQS (2-minute notice) | Predict interruptions |

Karpenter is already price-optimal **for the requests it is given**. If requests are 4× usage, Karpenter buys a well-packed fleet that is 4× too big.

### CAST AI feature map (cost-relevant)

| Layer | CAST AI feature | Module | Plan |
|---|---|---|---|
| Visibility | Available savings report, cost monitoring, cluster efficiency | 04 | Free |
| Nodes | Autoscaler + node templates (≈ NodePool + EC2NodeClass) | 07 | Premium |
| Nodes | Evictor (continuous bin-packing) | 08 | Premium |
| Nodes | Rebalancer (plan with savings preview, then execute) | 09 | Premium |
| Nodes | Spot fallback with automatic return to spot; interruption prediction | 10 | Premium |
| Pods | Workload Autoscaler (request rightsizing, in-place on 1.35+) | 11 | Premium |
| Pods | Workload Autoscaler + HPA coordination | 12 | Premium |

### Honest comparison

| Capability | Karpenter v1.14 | CAST AI | Verdict |
|---|---|---|---|
| Provisioning / instance choice | Cheapest fitting, batched | Cheapest fitting, Pod Pinner binds | **Parity** |
| Consolidation | `WhenEmptyOrUnderutilized`, `Balanced` | Evictor + empty-node deletion | **Close to parity**; CAST AI adds aggressive mode and live migration |
| Rebalancing with preview | None | Plan → review cost → execute; schedules | **CAST AI**, mainly operability |
| Spot fallback | Automatic | Automatic | **Parity** |
| Return to spot | Only if consolidation finds a cheaper spot replacement | Timed fall-forward (standard autoscaler) | **CAST AI**, more deterministic |
| Interruption prediction | 2-minute notice only | ML prediction (vendor-stated lead time) | **CAST AI**, but not demoable on demand |
| Request rightsizing | None | Workload Autoscaler | **CAST AI** vs Karpenter alone; **smaller gap** vs Karpenter + VPA |
| VPA-style rightsizing with HPA on CPU | VPA docs say don't combine on CPU | Simulates HPA to pick the request | **CAST AI** |
| Cost visibility | None (OpenCost, Kubecost, AWS split cost allocation are free) | Free reports | **Convenience**, not unique |

What we expect to measure: almost all of CAST AI's extra savings will come from **rightsizing requests** (module 11), not from smarter node choice. Karpenter + VPA can reproduce a large share of that for free; module 13 says so explicitly.

## Demo

Read-only. Nothing changes.

### Step 1 — Load the environment
```bash
source scripts/env.sh
```
Expected: the five-line summary from module 00.

### Step 2 — Requested vs used, per pod
The scheduler sees the left column; the bill follows it.
```bash
kubectl -n shop get pods -o 'custom-columns=POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory'
kubectl -n shop top pods
```
Expected: 13 pods. Requests `400m` (frontend), `300m` (cart), `500m` (catalog, checkout), `400m` (payments), `700m` (worker). Usage around `100m`, `70m`, `120m`, `100m`, `100m`, `250m` respectively, and memory usage 70–200 Mi against 256–512 Mi requested. <!-- VERIFY: stress-ng --cpu-load accuracy within ±15m -->

### Step 3 — The total gap
One number for the whiteboard.
```bash
kubectl -n shop get pods -o json | jq '[.items[].spec.containers[].resources.requests.cpu | rtrimstr("m") | tonumber] | add / 1000'
kubectl -n shop top pods --sum --no-headers | tail -1
```
Expected: `6` (vCPU requested) and a sum line around `1600m` (vCPU used). Roughly 26% of what is reserved is used. <!-- VERIFY: kubectl 1.35 top --sum output shape -->

### Step 4 — Node view
How the requests fill nodes.
```bash
kubectl get nodes -l karpenter.sh/nodepool -o 'custom-columns=NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,CAP:.metadata.labels.karpenter\.sh/capacity-type,CPU:.status.capacity.cpu'
kubectl top nodes
```
Expected: 2–3 Karpenter nodes totalling 8–10 vCPU, `CPU%` in `kubectl top nodes` around 20–30% on each worker, even though by requests they are nearly full.

## Talking points
- "Karpenter is doing its job perfectly here. It packed 6 vCPU of requests onto as few, cheap nodes as it could. The problem is that 6 vCPU of requests describes 1.6 vCPU of work."
- "Node-level tools fight over the last 10–20%. Request-level tools go after the other 70%."
- "Everything CAST AI does at the node level, Karpenter does well too. Where they differ is operability (previews, schedules) and pods (rightsizing). Watch for that."
- "We will also show the free alternative: Karpenter plus VPA. If that is enough for you, you should know before you buy anything."

## Reset
Nothing in this module changes the cluster.

## Q&A prep
- **Why not just lower the requests by hand?** You can, once. Usage changes with every release and traffic pattern; keeping requests right continuously is the actual work.
- **Doesn't over-requesting protect us from noisy neighbours?** CPU requests set the guaranteed share under contention. Setting them to a sensible percentile (p80–p95) plus headroom keeps that protection. Memory is different: under-requesting memory risks OOM kills, which is why rightsizers use the max for memory.
- **Is 8% utilization real?** It is CAST AI's own fleet statistic, so treat it as vendor data. Check your own: `kubectl top` vs requests, as we just did.
- **Doesn't Karpenter consolidation fix this?** Consolidation reduces node-level waste only. It cannot pack pods tighter than their requests allow.
