# Platform Engineering Reference Environment

[한국어](README.ko.md) | [Documentation](docs/README.md)

platform-engineering-lab is the executable Kubernetes reference environment for the Infrastructure Engineering Harness. It exists to test whether infrastructure changes can be diagnosed, proposed, executed through the correct owner, and verified from fresh runtime evidence.

## Operating loop

~~~text
Observe
→ Diagnose
→ Propose Change
→ Evaluate Risk / Policy
→ Approval
→ Execute through GitOps or Terraform ownership
→ Post-check
→ Rollback when verification fails
→ Preserve evidence
~~~

## Reference topology

~~~text
Client
  → MetalLB
  → Envoy Gateway
  → platform-api
      ├─ catalog-service
      ├─ recommendations-service
      └─ orders-service
          ├─ inventory-service
          └─ payments-service
~~~

The environment combines Kubernetes, Envoy Gateway, Argo CD, Terraform, Prometheus, Grafana, Alertmanager, OpenTelemetry, Tempo, Alloy, Loki, and read-only Harness evidence adapters.

## Quick validation

Before controlled failure scenarios, validate the live reference environment:

~~~bash
bash ops/smoke/full-reference-environment.sh
~~~

The narrower runtime checks remain available under ops/smoke/. Static manifests and green CI are not treated as proof that the runtime is healthy.

## Benchmarks

Orders fault benchmark dry run:

~~~bash
bash ops/benchmarks/orders-fault/run.sh
~~~

Intentional execution:

~~~bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  bash ops/benchmarks/orders-fault/run.sh --execute
~~~

HPA / ResourceQuota policy benchmark dry run:

~~~bash
bash ops/benchmarks/hpa-quota/run.sh
~~~

The orders latency/5xx scenario has live verified-recovery evidence. The cross-owner HPA / ResourceQuota scenario is implemented but remains a live-validation milestone.

## Ownership invariants

~~~text
Terraform
  → ResourceQuota / foundation / future cloud resources

Argo CD
  → application workloads
  → Gateway resources
  → observability policy

Harness
  → evidence
  → diagnosis
  → proposal
  → policy / approval aware execution
  → independent verification
~~~

Terraform and Argo CD must not own the same Kubernetes object. An ad-hoc kubectl patch is not a durable fix for an owned resource.

## Repository map

~~~text
apps/api/                         application image and service roles
gitops/apps/demo-app/             application desired state
gitops/platform/                  shared platform desired state
platform/                         platform component configuration
terraform/reference-environment/  Terraform-owned capacity layer
argocd/                           Argo CD Applications
observability/                    metrics, logs, traces, alerts, dashboards
ops/smoke/                        live environment validation
ops/benchmarks/                   controlled failure scenarios
docs/                             architecture, runbooks, guides, evidence
.github/workflows/                validation and CI
~~~

## Documentation

Start with [docs/README.md](docs/README.md). It is the canonical documentation index and links to the focused getting-started chapters, architecture and operations material, Korean documentation, and dated runtime evidence.

Important entrypoints:

- [Getting started](docs/getting-started/README.md)
- [Ops Agent runbook](docs/13-ops-agent-runbook.md)
- [Reference environment smoke test](docs/18-reference-environment-smoke-test.md)
- [Kubernetes operating environment](docs/21-kubernetes-operating-environment.md)
- [Runtime evidence](docs/evidence/README.md)

## Production-readiness boundary

This repository is a production-style reference environment, not a claim that a local Kubernetes cluster is production infrastructure. Runtime claims require fresh evidence, and destructive, privilege-expanding, public-exposure, and production-like changes remain explicit approval boundaries.
