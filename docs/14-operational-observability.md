# Operational Observability and Ops Agent Rollout

This document describes the current reference environment used by the Infrastructure Engineering Agent. It is not a static learning lab: the environment exists to generate realistic Kubernetes/GitOps/observability evidence, controlled failures, remediation proposals and post-change verification.

## 1. Current service topology

The reference application now contains six independently deployable services:

```text
Client
  -> MetalLB
  -> Envoy Gateway
  -> platform-api
       ├─> catalog-service
       ├─> recommendations-service
       └─> orders-service
             ├─> inventory-service
             └─> payments-service
```

Every service has its own:

- Deployment;
- Service;
- ServiceAccount;
- HPA;
- PDB;
- Prometheus target identity (`platform_service`);
- OpenTelemetry `service.name`;
- structured JSON logs;
- controlled `FAULT_LATENCY_MS` / `FAULT_ERROR_RATE_PERCENT` settings.

The same immutable application image is reused with different `SERVICE_ROLE` values. This keeps the reference environment small enough for local kind while still creating fan-out and multi-hop dependency behavior.

Expected Deployments:

```text
web
catalog
orders
inventory
payments
recommendations
```

## 2. Ownership model

```text
Helm
  -> telemetry engines
     Prometheus / Grafana / Alertmanager
     Tempo / OpenTelemetry Collector
     Loki / Alloy

Argo CD
  -> desired-state resources
     application Deployments / Services / HPAs / PDBs
     Gateway API resources
     ServiceMonitor / PodMonitor
     PrometheusRule
     Grafana dashboards

Infrastructure Engineering Agent
  -> read-only evidence by default
  -> diagnosis / risk assessment / proposal
  -> approved mutation only through an explicit execution path
  -> fresh post-check before completion
```

A successful Git/Argo deployment is not accepted as recovery evidence by itself.

## 3. Pull and reconcile

```bash
cd ~/platform-engineering-lab
git pull

kubectl apply -f argocd/platform.yaml
kubectl apply -f argocd/demo-app.yaml
kubectl apply -f argocd/observability.yaml
```

Check:

```bash
kubectl get application -n argocd
kubectl get deploy,pod,svc,hpa,pdb -n demo-app
```

Expected Argo state:

```text
platform              Synced / Healthy
demo-app              Synced / Healthy
observability-config  Synced / Healthy
```

## 4. Prometheus / Grafana / Alertmanager

```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  --create-namespace \
  -f observability/kube-prometheus-stack-values.yaml
```

Current local operating profile:

```text
Prometheus retention:   24h / 2GB
Alertmanager retention: 24h
Grafana persistence:    disabled
Prometheus persistence: disabled
```

This is deliberately a local reference environment, not an HA monitoring architecture.

## 5. Loki and Alloy

```bash
helm repo add grafana-community \
  https://grafana-community.github.io/helm-charts
helm repo add grafana \
  https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki \
  grafana-community/loki \
  --version 18.12.1 \
  -n monitoring \
  -f observability/loki-values.yaml

helm upgrade --install alloy \
  grafana/alloy \
  --version 1.12.1 \
  -n monitoring \
  -f observability/alloy-values.yaml
```

Alloy collects Pod logs and Kubernetes Events through the Kubernetes API. Application logs keep `trace_id` and `span_id` as fields rather than Loki index labels.

## 6. Gateway traffic path

User-path validation must go through the real platform boundary:

```text
https://web.lab.local:8443
  -> local Docker TCP proxy
  -> MetalLB :443
  -> Envoy Gateway
  -> HTTPRoute
  -> platform-api
  -> internal dependency graph
```

Generate traffic:

```bash
for i in {1..30}; do
  curl -k -s \
    --resolve web.lab.local:8443:127.0.0.1 \
    https://web.lab.local:8443/ >/dev/null
done
```

A healthy response includes results from `catalog`, `orders` and `recommendations`; the `orders` result includes `inventory` and `payments` dependency results.

## 7. Grafana through MetalLB / Envoy Gateway

Grafana uses the existing Gateway rather than its own `LoadBalancer` Service:

```text
https://grafana.lab.local:8443
  -> Docker TCP proxy
  -> MetalLB
  -> Envoy Gateway
  -> HTTPRoute/grafana
  -> monitoring-grafana
```

For Windows browser access add:

```text
127.0.0.1 grafana.lab.local
```

Then open:

```text
https://grafana.lab.local:8443
```

## 8. Operational dashboards

### Platform Operations · Service Health

The dashboard discovers services from the `platform_service` label, so the same panels automatically include all six services.

Use it for:

- request rate by service;
- 5xx ratio by service;
- P95 latency by service;
- platform-api availability / error budget;
- HPA desired/current replicas;
- CPU and memory pressure;
- restarts;
- OpenTelemetry pipeline health;
- Envoy health.

### Kubernetes Operations · Capacity & Reliability

Use it for node readiness, Pending Pods, unavailable replicas, OOMKilled, PDB allowance, HPA saturation and namespace resource pressure.

### Platform Operations · Logs & Events

Use it for structured application logs, Kubernetes Events and log-to-Tempo `trace_id` correlation.

## 9. Prometheus service evidence contract

`ServiceMonitor` copies each Service's `platform_service` label onto Prometheus targets. Recording rules aggregate by that label.

For every discovered application dependency the Agent expects at least:

```text
target_up
error_ratio_5m
p95_latency_seconds_5m
```

Current dependency components:

```text
catalog-service
orders-service
inventory-service
payments-service
recommendations-service
```

The query profile is:

```text
observability/agent-prometheus-queries.json
```

Healthy services with no 5xx series are explicitly materialized as an error ratio of `0`; an empty error vector is not treated as healthy evidence.

## 10. Distributed tracing target

A healthy request should produce a graph similar to:

```text
Envoy ingress
  -> platform-api GET /
       ├─> catalog-service GET /catalog
       ├─> recommendations-service GET /recommendations
       └─> orders-service GET /orders
             ├─> inventory-service GET /inventory
             └─> payments-service GET /payments
```

This topology gives the Agent enough depth to distinguish a public symptom from a first-hop or second-hop dependency failure.

## 11. Live Agent review

From the Harness repository:

```bash
cd ~/infrastructure-engineering-harness
git pull

./agent k8s-evidence \
  --namespace demo-app \
  --output /tmp/platform-k8s.json

./agent prometheus-evidence \
  --url http://127.0.0.1:9090 \
  --query-file ../platform-engineering-lab/observability/agent-prometheus-queries.json \
  --namespace demo-app \
  --service platform-api \
  --output /tmp/platform-prom.json

./agent ops-review \
  --k8s /tmp/platform-k8s.json \
  --prometheus /tmp/platform-prom.json \
  --output /tmp/platform-review.json
```

Review states:

```text
healthy
at_risk
acute
insufficient_evidence
```

The Ops reviewer discovers dependency services from Kubernetes Deployment evidence (`OTEL_SERVICE_NAME`) and matches their Prometheus evidence by `component` and `signal`. New reference services therefore require query coverage, not hardcoded review logic.

## 12. Controlled benchmark and revalidation

The first live benchmark remains the orders latency/5xx experiment:

```bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  bash ops/benchmarks/orders-fault/run.sh --execute
```

The benchmark performs:

```text
healthy baseline
-> GitOps fault injection
-> Argo reconciliation
-> real Gateway traffic
-> Kubernetes + Prometheus evidence
-> Ops review
-> GitOps remediation
-> fresh evidence
-> ops-compare
-> verified recovery or reopen
```

Evidence is written under `.ops-benchmark/<run-id>/` and is intentionally excluded from Git.

## 13. Agent improvement contract

Failures in the Agent or observability contract become reproducible evaluation assets:

```text
runtime failure / evidence gap
-> learning_candidate
-> reproducible fixture or live benchmark
-> adapter / review / Skill / Context proposal
-> regression suite
-> human review
-> merge only when existing behavior does not regress
```

The Agent does not silently rewrite its own policies or Skills.

## 14. Current readiness boundary

The reference environment is intended to exercise production-style operating behavior, but it is not itself production infrastructure.

Current intentional gaps include:

- local kind rather than managed multi-AZ Kubernetes;
- non-HA / non-durable local Prometheus, Loki and Tempo;
- Alertmanager receiver still requires a real notification destination;
- production write adapters and approval workflow are not yet enabled;
- Terraform ownership and policy-gated mutation are the next reference-environment layer;
- evaluation coverage is being expanded from the first live orders benchmark to a broader failure corpus.

The goal is to make these boundaries explicit and progressively close them with evidence, rather than label the environment `production ready` prematurely.
