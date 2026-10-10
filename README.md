# CAST AI vs Karpenter: Cost Demo (EKS)

Instructor-led live demo: same EKS cluster, same workload, measured under Karpenter v1.14.1
and then under CAST AI. Shows where each one saves money, and where Karpenter (+VPA) can match.

Builds on [karpenter-demo](https://github.com/Infrathrone-Devops-Park/karpenter-demo) (cluster, Karpenter, monitoring).

> Every command was run on a live cluster; expected output in each doc is real.
> Prep: install CAST AI (automation) at least 24 h before the session for full Workload Autoscaler savings (see docs/00).

## Modules

| # | Module |
|---|---|
| 00 | [Agenda & setup](docs/00-agenda-and-setup.md) |
| 01 | [Where Kubernetes money goes](docs/01-where-the-money-goes.md) |
| 02 | [Karpenter baseline](docs/02-karpenter-baseline.md) |
| 03 | [Connect CAST AI read-only](docs/03-connect-readonly.md) |
| 04 | [Savings report & cost monitoring](docs/04-savings-report.md) |
| 05 | [Automation onboarding](docs/05-automation-onboarding.md) |
| 06 | [Switch-over Karpenter to CAST AI](docs/06-switch-over.md) |
| 07 | [Autoscaler & node templates](docs/07-autoscaler-node-templates.md) |
| 08 | [Evictor bin-packing](docs/08-evictor.md) |
| 09 | [Rebalancing](docs/09-rebalancing.md) |
| 10 | [Spot: fallback & interruption](docs/10-spot.md) |
| 11 | [Workload Autoscaler (rightsizing)](docs/11-workload-autoscaler.md) |
| 12 | [Workload Autoscaler + HPA](docs/12-workload-autoscaler-hpa.md) |
| 13 | [Head-to-head results](docs/13-head-to-head.md) |
| 14 | [Pricing, ROI, security, lock-in](docs/14-pricing-roi-security.md) |
| 15 | [Switch back & offboarding](docs/15-switch-back-offboarding.md) |

## Layout

```text
terraform/   CAST AI registration, IAM, node config/template, policies, Helm
workloads/   over-provisioned "shop" app + HPA workload
manifests/   per-module manifests
scripts/     env, measure, compare, switch, reset, offboard, API helper
docs/        module guides, run in order
```

## Setup

The CAST AI API key is read from `~/.castai/api-token` (never committed).

```bash
source scripts/env.sh
terraform -chdir=terraform init
terraform -chdir=terraform apply -var phase=readonly
```

## Key scripts

| Script | Purpose |
|---|---|
| `scripts/measure.sh <label>` | Node, CPU and $/h snapshot, saved to `results/` |
| `scripts/compare.sh A B` | Side-by-side cost diff |
| `scripts/switch-to-castai.sh` | Hand nodes from Karpenter to CAST AI |
| `scripts/switch-to-karpenter.sh` | Hand nodes back to Karpenter |
| `scripts/offboard.sh --yes-offboard` | Remove CAST AI completely |

## Capacity budget

The account has 8 on-demand + 8 spot vCPU. Only one autoscaler is active at a time.
