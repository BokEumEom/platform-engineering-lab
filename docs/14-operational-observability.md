# Operational Observability and Ops Agent Rollout

This document upgrades the lab telemetry into a small operational environment for Infrastructure Engineering Agent review.

It is deliberately split into two ownership layers:

```text
Helm
  -> installs/upgrades telemetry engines
     Prometheus/Grafana/Alertmanager
     Tempo/OTel Collector
     Loki
     Alloy

Argo CD
  -> owns operational policy/config
     ServiceMonitor / PodMonitor
     PrometheusRule
     SLO recording rules
     Grafana dashboards
     Gateway routes
```

## 1. Pull the desired state

```bash
cd ~/platform-engineering-lab
git pull
```

## 2. Update the platform and demo applications

The platform Gateway now serves wildcard `*.lab.local` HTTPS and includes a Grafana route. The demo application contains three services:

```text
platform-api
  -> catalog-service
  -> orders-service
```

Bootstrap/update the Argo Applications if this local cluster does not manage the `argocd/` directory through an App-of-Apps:

```bash
kubectl apply -f argocd/platform.yaml
kubectl apply -f argocd/demo-app.yaml
kubectl apply -f argocd/observability.yaml
```

Force discovery after new CRDs/components have been installed when necessary:

```bash
for app in platform demo-app observability-config; do
  kubectl annotate application "$app" \
    -n argocd \
    argocd.argoproj.io/refresh=hard \
    --overwrite
done
```

## 3. Upgrade Prometheus/Grafana/Alertmanager

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

This local operating profile currently uses:

```text
Prometheus retention:   24h / 2GB
Alertmanager retention: 24h
Grafana persistence:    disabled
Prometheus persistence: disabled
```

Persistence remains disabled until the Agent collects storage/capacity evidence. This is not a durable production monitoring architecture.

## 4. Install Loki

The repository pins the current validated chart profile used by this project:

```text
Grafana Community Loki chart: 18.12.1
Loki:                        3.7.7
```

Install:

```bash
helm repo add grafana-community \
  https://grafana-community.github.io/helm-charts
helm repo update

helm upgrade --install loki \
  grafana-community/loki \
  --version 18.12.1 \
  -n monitoring \
  -f observability/loki-values.yaml
```

The local profile is intentionally Monolithic with one replica and filesystem storage. It is suitable for this Agent/Ops environment, not an HA production Loki design.

## 5. Install Grafana Alloy

```text
Grafana Alloy chart: 1.12.1
Alloy:              v1.19.2
```

Install:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install alloy \
  grafana/alloy \
  --version 1.12.1 \
  -n monitoring \
  -f observability/alloy-values.yaml
```

Alloy collects:

- Pod stdout/stderr through the Kubernetes API;
- Kubernetes Events;
- stable namespace/pod/container/app/workload labels;
- no privileged node filesystem log mount.

Application JSON logs contain `trace_id` and `span_id` as log fields, not Loki index labels.

## 6. Verify telemetry components

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

Check Loki and Alloy specifically:

```bash
kubectl get pods -n monitoring | grep -E 'loki|alloy'
```

Argo observability config:

```bash
kubectl get application observability-config -n argocd
kubectl get servicemonitor,podmonitor,prometheusrule -A
```

Expected operational rule/dashboard resources include:

```text
platform-service-slo
platform-operations-dashboard
kubernetes-operations-dashboard
platform-logs-dashboard
```

## 7. Verify the three-service application

```bash
kubectl get deploy,pod,svc,hpa,pdb -n demo-app
```

Expected Deployments:

```text
web
catalog
orders
```

Generate user traffic through the actual Gateway/MetalLB path:

```bash
for i in {1..30}; do
  curl -k -s \
    --resolve web.lab.local:8443:127.0.0.1 \
    https://web.lab.local:8443/ >/dev/null
done
```

A normal response contains both dependency results.

Direct dependency checks from the gateway Pod can be used only for diagnosis:

```bash
POD=$(kubectl get pod -n demo-app -l app=web -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n demo-app "$POD" -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://catalog/catalog").read().decode())'

kubectl exec -n demo-app "$POD" -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://orders/orders").read().decode())'
```

## 8. Grafana through MetalLB, not kubectl port-forward

Grafana is exposed through the existing platform Gateway rather than its own LoadBalancer:

```text
Browser/curl
  -> local Docker HTTPS proxy :8443
  -> MetalLB Gateway ExternalIP :443
  -> Envoy Gateway
  -> HTTPRoute/grafana
  -> monitoring-grafana Service
```

This is **not** Kubernetes `kubectl port-forward`; it preserves the MetalLB and Envoy Gateway traffic path.

The existing Docker HTTPS proxy can be reused because it is TCP/SNI transparent.

Add a local hosts entry for browser use:

```text
127.0.0.1 grafana.lab.local
```

Then open:

```text
https://grafana.lab.local:8443
```

The local certificate is self-signed, so a browser trust warning is expected unless the lab CA/certificate is trusted locally.

Curl validation:

```bash
curl -k -I \
  --resolve grafana.lab.local:8443:127.0.0.1 \
  https://grafana.lab.local:8443/login
```

Gateway status:

```bash
kubectl get httproute -n monitoring
kubectl describe httproute grafana -n monitoring
```

## 9. Grafana dashboards

The operational dashboards are provisioned as code through the Grafana dashboard sidecar.

### Platform Operations · Service Health

Use for service/SLO triage:

- 1h availability;
- lab error-budget model;
- request rate by service;
- 5xx ratio by service;
- P95 latency by service;
- multi-window burn rate;
- HPA current/desired replicas;
- CPU request utilization;
- memory limit utilization;
- container restarts;
- OTel pipeline health;
- Envoy live state.

### Kubernetes Operations · Capacity & Reliability

Use for infrastructure triage:

- Ready Nodes;
- Pending Pods;
- unavailable Deployment replicas;
- OOMKilled containers;
- node CPU/memory;
- Pods per node;
- restart rate;
- PDB disruption allowance;
- HPA saturation;
- namespace CPU/memory;
- Deployment ready/desired replicas.

### Platform Operations · Logs & Events

Use for evidence correlation:

- log volume by app;
- application error logs;
- structured application logs;
- Kubernetes Events;
- error-only request logs;
- log `trace_id` -> Tempo trace link.

## 10. Verify metrics and SLO recording rules

Prometheus can still be port-forwarded **only as an Agent API adapter endpoint**, not as the user access method for Grafana.

Resolve its actual Service name:

```bash
kubectl get svc -n monitoring | grep prometheus
```

Then:

```bash
kubectl port-forward \
  -n monitoring \
  svc/<PROMETHEUS_SERVICE> \
  9090:9090
```

Useful PromQL:

```promql
platform:http_requests:rate5m
platform:http_error_ratio:5m
platform:http_p95_latency_seconds:5m
platform:slo_burn_rate:5m{platform_service="platform-api"}
platform:slo_burn_rate:1h{platform_service="platform-api"}
```

The `platform-api` lab policy is explicitly 99.9% availability for exercising error-budget operations. It is not a generic production SLO recommendation.

## 11. Verify distributed traces

Generate fresh HTTPS traffic and inspect Tempo.

A healthy request should include a graph similar to:

```text
Envoy ingress
  -> platform-api GET /
       -> HTTP client span / catalog
            -> catalog-service GET /catalog
       -> HTTP client span / orders
            -> orders-service GET /orders
```

This validates W3C trace-context propagation through the service dependency graph.

## 12. Verify logs and trace correlation

In Grafana Explore -> Loki:

```logql
{namespace="demo-app"} | json
```

Errors:

```logql
{namespace="demo-app"} | json | level="error"
```

A structured log carrying a valid `trace_id` should expose a Tempo link through the datasource derived field.

## 13. First live Ops Agent review

From `infrastructure-engineering-harness`:

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

Review output is intentionally conservative:

```text
healthy
at_risk
acute
insufficient_evidence
```

`insufficient_evidence` is preferred over guessing when a required query/provider is unavailable.

## 14. Incident / Agent revalidation

Use `docs/13-ops-agent-runbook.md` for controlled fault experiments and triage.

After a GitOps remediation, collect **fresh** evidence and run another review.

```bash
./agent ops-compare \
  --before /tmp/platform-review-before.json \
  --after /tmp/platform-review-after.json \
  --output /tmp/platform-revalidation.json
```

Completion requires no new regression and independent post-change evidence. A deployment success by itself is not recovery evidence.

## 15. Current production-readiness boundary

This environment is designed to evaluate a production-style operating model, but the local stack is not itself production-grade infrastructure.

Known intentional gaps:

- Prometheus/Loki/Tempo are not yet durable/HA;
- Alertmanager still has a null receiver until a real notification destination is selected;
- public synthetic probing is not yet the primary SLI;
- control-plane scrape targets remain reduced for Docker Desktop/kind;
- Agent production mutations remain human/change-review gated;
- self-improvement produces reviewable learning candidates rather than editing Skills automatically.

These gaps should remain visible instead of being hidden behind a `production ready` label.
