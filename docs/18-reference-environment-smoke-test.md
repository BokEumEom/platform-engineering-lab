# Reference Environment Smoke Test

The reference environment now has a single read-only smoke test that validates the platform before any failure benchmark is allowed to mutate GitOps state.

Run it after pulling both repositories and after Argo CD finishes reconciling:

```bash
cd ~/platform-engineering-lab
bash ops/smoke/reference-environment.sh
```

The script validates the following contracts against the live local cluster:

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

No Kubernetes workload, Git desired state, Argo application or Terraform resource is mutated by this test. Generating application requests only produces runtime traffic and telemetry.

## Gateway access model

The local WSL environment cannot directly route to kind MetalLB addresses, so Docker TCP proxies preserve the real Gateway path:

```text
HTTPS UI/application traffic
127.0.0.1:8443
→ Docker TCP proxy
→ MetalLB Gateway IP:443
→ Envoy Gateway
→ HTTPRoute

Prometheus Agent API traffic
127.0.0.1:8080
Host: prometheus.lab.local
→ Docker TCP proxy
→ MetalLB Gateway IP:80
→ Envoy Gateway
→ HTTPRoute/prometheus-agent
→ Prometheus:9090
```

The Agent therefore does not require `kubectl port-forward` for Prometheus evidence.

## Evidence output

Each run writes disposable evidence to:

```text
.ops-smoke/<UTC run-id>/
```

Typical files include:

```text
prometheus-ready.txt
raw-http-requests.json
error-ratio-5m.json
p95-latency-5m.json
k8s.json
prometheus.json
review.json
```

`.ops-smoke/` is ignored by Git. These artifacts are runtime evidence, not repository truth.

## Expected service set

All three Prometheus checks must discover:

```text
platform-api
catalog-service
orders-service
inventory-service
payments-service
recommendations-service
```

If raw metrics contain six services but the recording rules do not, investigate `PrometheusRule` loading/evaluation rather than ServiceMonitor discovery. If raw metrics themselves are incomplete, inspect ServiceMonitor target labels, scrape targets and application traffic.

## Relationship to failure benchmarks

The smoke test is the prerequisite for live mutation benchmarks.

```text
reference-environment smoke PASS
→ controlled failure benchmark
→ Agent detection/correlation
→ GitOps remediation
→ fresh post-check
→ ops-compare
→ verified recovery
```

For the first live benchmark:

```bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  bash ops/benchmarks/orders-fault/run.sh --execute
```

The benchmark also performs its own healthy-baseline gate. It requires the initial `orders-service` fault profile to be zero and performs a best-effort safety recovery if execution terminates while the benchmark-injected fault may still be active.

## Failure interpretation

The smoke test is deliberately strict. A failure is useful evidence:

- Route failure → Gateway/namespace/backend contract problem.
- Deployment failure → GitOps/runtime reconciliation problem.
- raw metrics missing → scrape/label/traffic problem.
- recording rules missing → PrometheusRule/evaluation problem.
- Harness missing evidence → Agent evidence contract problem.
- P0/P1 finding at baseline → environment is not safe to benchmark.

Do not bypass a failed smoke check simply to reach the fault-injection stage. Repair the reference environment or evidence contract, then rerun the same test so the fix becomes reproducible evidence.
