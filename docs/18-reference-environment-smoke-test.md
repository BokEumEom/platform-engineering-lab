# Reference Environment Smoke Test

The reference environment has a read-only smoke suite that validates the platform before any failure benchmark is allowed to mutate GitOps or Terraform-owned state.

The canonical command is now:

```bash
cd ~/platform-engineering-lab
bash ops/smoke/full-reference-environment.sh
```

It runs two stages:

```text
reference-environment.sh
  → Kubernetes / Argo / Gateway / six-service runtime / Prometheus / Ops review

observability.sh
  → Loki / Tempo / Alertmanager Gateway APIs
  → fresh logs / traces / alert visibility
  → Harness Loki / Tempo enrichment evidence
```

The narrower metrics/runtime stage remains available independently:

```bash
bash ops/smoke/reference-environment.sh
```

No Kubernetes workload, Git desired state, Argo application or Terraform resource is mutated by either smoke stage. Generating application requests only produces runtime traffic and telemetry.

## Runtime contracts

The platform stage validates:

```text
Kubernetes context
→ Argo applications Synced/Healthy
→ Gateway namespace admission labels
→ Gateway Programmed
→ HTTPRoutes Accepted/ResolvedRefs
→ six application Deployments rolled out
→ web/grafana/prometheus/argocd reachable through MetalLB + Envoy
→ Prometheus API reachable through the Gateway HTTP route
→ real HTTPS application traffic succeeds
→ raw HTTP metrics contain all six platform_service values
→ error-ratio recording rule contains all six services
→ P95 recording rule contains all six services
→ Harness collects fresh Kubernetes + Prometheus evidence
→ ops-review has no required evidence gaps
```

The observability stage additionally validates:

```text
Loki/Tempo/Alertmanager HTTP and HTTPS routes Accepted/ResolvedRefs
→ Loki API reachable through MetalLB + Envoy
→ Tempo API reachable through MetalLB + Envoy
→ Alertmanager API reachable through MetalLB + Envoy
→ fresh HTTPS application traffic
→ fresh demo-app log entries appear in Loki
→ recent traces appear in Tempo
→ Prometheus exposes firing-alert state
→ Harness read-only Loki evidence has fresh entries
→ Harness read-only Tempo evidence has recent traces
```

Loki and Tempo observations are enrichment evidence. Until the full local smoke and scenario evaluations prove their behavior repeatedly, they do not change blocking `ops-review` thresholds.

## Verified platform-stage live run — 2026-09-14

The local Docker Desktop / Kubernetes reference environment completed the original platform-stage smoke successfully with fresh runtime evidence.

Observed result:

```text
Argo applications:
  platform                 Synced / Healthy
  demo-app                 Synced / Healthy
  observability-config     Synced / Healthy

Gateway endpoints:
  web.lab.local            HTTP 200
  grafana.lab.local        HTTP 302
  prometheus.lab.local     HTTP 302
  argocd.lab.local         HTTP 200

Application traffic:
  30/30 successful HTTPS requests through MetalLB + Envoy

Prometheus service coverage:
  raw metrics              6/6 services
  error-ratio recording    6/6 services
  P95 recording            6/6 services

Harness baseline:
  state                    healthy
  release_guidance         continue
  missing_required         []
```

The six observed services were:

```text
platform-api
catalog-service
orders-service
inventory-service
payments-service
recommendations-service
```

The cold/warm telemetry path required multiple Prometheus scrape/evaluation cycles before all recording-rule series appeared: raw metrics were immediately complete, while error-ratio/P95 coverage progressed from `0/6` to `4/6` and finally `6/6`. This is expected evidence propagation behavior, not an application failure, and justifies bounded polling.

A retained Kubernetes Warning-event finding remained as non-blocking `P2`; the Agent still classified the live baseline as `healthy` with `release_guidance=continue` and no required evidence gaps.

The new multi-signal observability stage is statically validated in CI but remains a **runtime-pending** claim until the local full smoke is executed and evidence is captured.

## Gateway access model

The local WSL environment cannot directly route to kind MetalLB addresses, so Docker TCP proxies preserve the real Gateway path:

```text
HTTPS UI/application/API traffic
127.0.0.1:8443
→ Docker TCP proxy
→ MetalLB Gateway IP:443
→ Envoy Gateway
→ HTTPRoute

Agent API traffic
127.0.0.1:8080
Host: prometheus.lab.local | loki.lab.local | tempo.lab.local | alertmanager.lab.local
→ Docker TCP proxy
→ MetalLB Gateway IP:80
→ Envoy Gateway
→ read-only backend API route
```

The Agent therefore does not require `kubectl port-forward` for Prometheus, Loki or Tempo evidence.

Gateway API runtime status is evaluated structurally rather than by concatenating JSONPath strings. A Route may expose more than one parent status entry, so multiple `Accepted=True` conditions are valid when every observed parent also has `ResolvedRefs=True`.

## Evidence output

The full run writes disposable evidence beneath:

```text
.ops-smoke/<UTC run-id>-full/
├── platform/
└── observability/
```

Typical observability evidence includes:

```text
loki-labels.json
loki-demo-app.json
tempo-ready.txt
tempo-search.json
alertmanager-status.json
firing-alerts.json
loki-evidence.json
tempo-evidence.json
```

`.ops-smoke/` is ignored by Git. These artifacts are runtime evidence, not repository truth.

## Relationship to failure benchmarks

The full smoke is the preferred prerequisite for new multi-signal scenarios:

```text
full reference-environment smoke PASS
→ controlled failure benchmark
→ Agent detection/correlation
→ proposal / policy / approval when mutation is required
→ GitOps/Terraform remediation
→ fresh post-check
→ rollback when required
→ verified recovery
```

Scenario #1 (`orders-service` latency/5xx) already has verified live recovery. Scenario #2 (`HPA + ResourceQuota`) has its Terraform/policy/approval implementation and remains pending live mutation validation.

## Failure interpretation

A smoke failure is useful evidence:

- Route failure → Gateway/namespace/backend contract problem.
- Deployment failure → GitOps/runtime reconciliation problem.
- raw metrics missing → scrape/label/traffic problem.
- recording rules missing → PrometheusRule/evaluation problem.
- Loki log gap → Alloy discovery/processing or Loki ingestion/query problem.
- Tempo trace gap → app instrumentation, OTel Collector or Tempo ingestion/search problem.
- Alertmanager API failure → alerting control-plane routing/backend problem.
- Harness source unavailable → Agent adapter/Gateway evidence contract problem.
- P0/P1 finding at baseline → environment is not safe to benchmark.

Do not bypass a failed smoke check simply to reach fault injection. Repair the reference environment or evidence contract, then rerun the same test so the fix becomes reproducible evidence.
