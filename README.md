# Platform Engineering Reference Environment

`platform-engineering-lab` is the executable Kubernetes target environment for the **Infrastructure Engineering Harness**.

The project started as a local Platform Engineering lab and has evolved into a reproducible environment for testing whether an Infrastructure Engineering Agent can operate against real Kubernetes/GitOps/observability evidence without inventing state or treating deployment success as incident recovery.

The operating goal is:

```text
Observe
→ Diagnose
→ Propose Change
→ Evaluate Risk / Policy
→ Approval
→ Execute through GitOps or Terraform ownership
→ Post-check
→ Rollback when verification fails
→ Preserve evidence
→ Re-evaluate / learn
```

The current repository implements the runtime/evidence side of this loop and the first controlled GitOps remediation benchmark. Terraform ownership and policy-gated approved execution are the next reference-environment layer.

## Current reference topology

```text
Client
  ↓
MetalLB
  ↓
Envoy Gateway
  ↓
platform-api
  ├─→ catalog-service
  ├─→ recommendations-service
  └─→ orders-service
        ├─→ inventory-service
        └─→ payments-service
```

Six services run as independent Kubernetes workloads. Each service has its own Deployment, Service, ServiceAccount, HPA, PDB, Prometheus identity, OpenTelemetry service name, structured logs and controlled fault profile.

The same immutable FastAPI image is reused with different `SERVICE_ROLE` values so the environment remains practical on local kind while still providing fan-out and multi-hop failure behavior.

## Operational stack

```text
Kubernetes v1.36.x / kind / Docker Desktop
Envoy Gateway + Gateway API
MetalLB
cert-manager / TLS
Argo CD / GitOps
GitHub Actions + GHCR
Prometheus / Grafana / Alertmanager
OpenTelemetry Collector / Tempo
Grafana Alloy / Loki
Infrastructure Engineering Agent evidence adapters
```

## Agent operating model

The Harness collects live evidence rather than inferring runtime state from repository configuration.

```text
Kubernetes evidence
        +
Prometheus evidence
        ↓
ops-review
        ↓
state:
  healthy | at_risk | acute | insufficient_evidence
        ↓
findings + evidence refs + release guidance
        ↓
remediation
        ↓
fresh evidence
        ↓
ops-compare
        ↓
verified recovery | persistent issue | regression
```

Dependency analysis is topology-generic. The Agent discovers application services from Kubernetes Deployment evidence (`OTEL_SERVICE_NAME`) and matches Prometheus observations by `component` and `signal`; new services require telemetry/query coverage rather than hardcoded review branches.

## First live Ops benchmark

The first controlled benchmark injects latency/5xx into `orders-service` through GitOps and requires the Agent to localize the dependency failure and verify recovery from fresh evidence.

Dry run:

```bash
bash ops/benchmarks/orders-fault/run.sh
```

Intentional execution:

```bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  bash ops/benchmarks/orders-fault/run.sh --execute
```

The benchmark performs:

```text
healthy baseline
→ GitOps fault commit
→ Argo reconciliation
→ real HTTPS Gateway traffic
→ Kubernetes + Prometheus evidence
→ Ops review
→ GitOps remediation
→ fresh evidence
→ ops-compare
→ verified recovery or failure
```

Runtime evidence is written under `.ops-benchmark/<run-id>/` and is not committed to Git.

## Grafana access through the real platform path

Grafana is exposed through the shared Gateway instead of its own Kubernetes `LoadBalancer` Service:

```text
https://grafana.lab.local:8443
  → local Docker TCP proxy
  → MetalLB :443
  → Envoy Gateway
  → HTTPRoute/grafana
  → monitoring-grafana
```

For Windows browser access add:

```text
127.0.0.1 grafana.lab.local
127.0.0.1 web.lab.local
```

## Operational dashboards

### Platform Operations · Service Health

Automatically discovers all services from `platform_service` and provides:

- request rate;
- 5xx ratio;
- P95 latency;
- platform-api SLO / error budget;
- HPA current/desired replicas;
- CPU/memory pressure;
- restarts;
- OpenTelemetry pipeline state;
- Envoy live state.

### Kubernetes Operations · Capacity & Reliability

Covers node readiness, Pending Pods, unavailable replicas, OOMKilled, HPA saturation, PDB disruption allowance and namespace resource pressure.

### Platform Operations · Logs & Events

Covers application JSON logs, Kubernetes Events and Loki `trace_id` → Tempo correlation.

## GitOps ownership

```text
Git = desired state
Kubernetes = actual state
Argo CD = reconciliation
```

The Agent must not bypass an owned resource with an ad-hoc patch simply because it can execute `kubectl`.

Current ownership direction:

```text
Terraform
  → bootstrap / foundation / quota / future cloud resources

Argo CD
  → application workloads
  → Gateway resources
  → operational observability policy

Agent
  → evidence
  → diagnosis
  → proposal
  → policy/approval aware execution
  → independent verification
```

Terraform and Argo CD must not concurrently own the same Kubernetes object.

## Repository structure

```text
platform-engineering-lab/
├── apps/api/                       # six-role FastAPI application
├── gitops/apps/demo-app/           # application desired state
├── gitops/platform/                # shared platform resources
├── argocd/                         # Argo Applications
├── observability/                  # metrics/logs/traces/SLO/dashboards
├── ops/benchmarks/                 # live Ops Agent benchmarks
├── platform/                       # platform component values
├── docs/                           # executable architecture/runbooks
└── .github/workflows/              # CI + manifest validation
```

## Important documentation

Start with the operational documents when evaluating the Agent:

- [10 — Infrastructure Engineering Harness Review](docs/10-infrastructure-engineering-harness-review.md)
- [11 — NetworkPolicy Hardening](docs/11-networkpolicy-hardening.md)
- [12 — Operational Observability Agent Review](docs/12-operational-observability-agent-review.md)
- [13 — Ops Agent Runbook](docs/13-ops-agent-runbook.md)
- [14 — Operational Observability and Agent Rollout](docs/14-operational-observability.md)
- [15 — Ops Agent Benchmark](docs/15-ops-agent-benchmark.md)
- [16 — Reference Environment Roadmap](docs/16-reference-environment-roadmap.md)

Earlier documents (`00`–`09`) preserve the build-up of Kubernetes, Gateway API, observability, tracing and TLS foundations.

## Current evidence boundaries

Already established in repository/runtime history:

- GitOps desired state with automated sync/self-heal/prune;
- immutable GHCR image deployment by commit SHA;
- Gateway API + MetalLB application path;
- Prometheus ServiceMonitor / Envoy PodMonitor;
- Grafana dashboards as code;
- SLO/error-budget recording rules;
- OpenTelemetry + Tempo distributed tracing;
- Loki + Alloy log/event pipeline desired state;
- read-only Kubernetes and Prometheus Agent adapters;
- evidence-backed `ops-review` and `ops-compare`;
- controlled fault injection and recovery benchmark;
- regression fixtures for Agent decision behavior.

A repository manifest is **not** treated as proof that the corresponding runtime behavior is healthy. Runtime claims remain pending until fresh evidence verifies them.

## Evaluation direction

The first benchmark is only the start. The reference environment is intended to grow toward 10–20 reproducible failure scenarios including:

```text
dependency 5xx / latency
bad rollout / probe failure
OOMKilled
HPA / ResourceQuota saturation
PDB blocked operation
NetworkPolicy / DNS failure
Gateway / TLS failure
Prometheus / OTel / Loki telemetry failure
Argo drift
Terraform destructive proposal
RBAC privilege escalation
public exposure change
failed remediation + rollback
```

Evaluation should measure detection, root-cause localization, evidence completeness, risk classification, unsafe-action avoidance, post-check quality, rollback correctness and false-positive/false-negative behavior.

## Production-readiness boundary

This project is a **production-style reference environment**, not a claim that a local kind cluster is production infrastructure.

Still to be closed before calling the Agent a production autonomous operator:

- policy engine for mutation risk/blast radius/privilege/cost;
- explicit human approval workflow;
- Terraform change adapter and ownership model;
- independently verified rollback executor;
- durable/HA production telemetry patterns;
- real notification/on-call integration;
- broader live failure/evaluation corpus;
- measurable external-user reproduction evidence.

The project is considered valuable when another engineer can clone it, reproduce an incident, understand why the Agent made a decision, execute an approved change through the correct control plane, and independently verify or roll back the result.
