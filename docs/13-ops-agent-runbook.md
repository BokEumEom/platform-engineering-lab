# Ops Agent Incident Runbook

This runbook is the operational handoff for `platform-engineering-lab` when it is used as a live target for `infrastructure-engineering-harness`.

The rule is simple:

```text
observe first
  -> correlate evidence
  -> change through GitOps
  -> collect new evidence
  -> verify recovery or reopen
```

Do not use restart-first, scale-first or threshold-tuning-first as a default response.

## 1. Service topology

```text
Client
  |
  v
MetalLB -> Envoy Gateway
              |
              v
         platform-api
          /        \
         v          v
 catalog-service  orders-service
         \          /
          \        /
        OTel Collector -> Tempo

all Services -> Prometheus
Pod logs/events -> Alloy -> Loki
```

The public user path is `web.lab.local`. `catalog` and `orders` are internal dependencies and are intentionally not exposed through Gateway API.

## 2. Capture pre-change evidence

From `infrastructure-engineering-harness`:

```bash
./agent k8s-evidence \
  --namespace demo-app \
  --output /tmp/platform-k8s-before.json
```

Expose Prometheus on localhost only for the Agent evidence adapter if needed:

```bash
kubectl get svc -n monitoring | grep prometheus
kubectl port-forward -n monitoring svc/<PROMETHEUS_SERVICE> 9090:9090
```

Then:

```bash
./agent prometheus-evidence \
  --url http://127.0.0.1:9090 \
  --query-file ../platform-engineering-lab/observability/agent-prometheus-queries.json \
  --namespace demo-app \
  --service platform-api \
  --output /tmp/platform-prom-before.json

./agent ops-review \
  --k8s /tmp/platform-k8s-before.json \
  --prometheus /tmp/platform-prom-before.json \
  --output /tmp/platform-review-before.json
```

The review must retain the exact evidence references used for each finding.

## 3. Confirm the user path

Use the Docker TCP proxy that reaches the MetalLB Gateway IP from WSL:

```bash
curl -k \
  --resolve web.lab.local:8443:127.0.0.1 \
  https://web.lab.local:8443/
```

Healthy response includes both dependencies:

```text
platform-api
  dependencies.catalog
  dependencies.orders
```

If this fails, do not immediately restart `web`.

Check in this order:

```bash
kubectl get gateway -n platform-system
kubectl get httproute -A
kubectl get deploy,pod,svc -n demo-app
kubectl get endpointslices -n demo-app
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp
```

## 4. Metrics triage

Use the `Platform Operations · Service Health` dashboard or Prometheus.

Primary questions:

1. Is `platform-api` target UP?
2. Is Envoy live?
3. Did request rate change?
4. Is 5xx isolated to platform-api or also catalog/orders?
5. Which service has elevated P95?
6. Is an HPA already at max desired replicas?
7. Are Pods restarting or OOMKilled?
8. Is the OTel pipeline dropping/refusing spans?

Avoid increasing replicas when CPU/HPA evidence does not support resource saturation.

## 5. Trace triage

A healthy request should form one distributed trace similar to:

```text
Envoy ingress
  -> platform-api GET /
       -> HTTP GET catalog
            -> catalog-service GET /catalog
       -> HTTP GET orders
            -> orders-service GET /orders
```

If platform-api returns 502, compare the two downstream child spans.

A slow or erroring child span is stronger dependency evidence than restarting every Pod.

## 6. Logs and events

Application logs are JSON and include:

```text
service
service_role
version
hostname
trace_id
span_id
event
status
duration_ms
```

Use Grafana `Platform Operations · Logs & Events`.

Typical LogQL:

```logql
{namespace="demo-app"} | json | level="error"
```

A trace ID in a log line links to Tempo through the Grafana Loki derived field.

Kubernetes Events are also collected into Loki. Do not treat old Warning events as current root cause without comparing timestamps.

## 7. Controlled fault experiments

The demo services support two GitOps-controlled fault settings:

```text
FAULT_LATENCY_MS
FAULT_ERROR_RATE_PERCENT
```

Default is `0`.

Use these only as an intentional experiment. Change the desired-state env value in the relevant Deployment manifest, commit it, let Argo reconcile it, and record the commit/review evidence.

Example incident hypothesis:

```text
orders-service latency 800ms
  -> platform-api P95 increases
  -> distributed trace identifies orders child span
  -> structured orders logs show duration increase
  -> Ops Agent emits high P95 finding
```

Recovery is the reverse Git change, not an imperative `kubectl set env` mutation.

## 8. Change decision

Use findings to choose the smallest change.

Examples:

```text
Pod OOM + memory evidence
  -> review memory request/limit

HPA saturated + CPU/request growth + node headroom
  -> review max replicas/capacity

orders 5xx + healthy platform-api Pods
  -> repair orders dependency; do not restart platform-api

Envoy not live + Gateway listener unhealthy
  -> investigate Gateway layer before application

OTel failed spans + application SLI healthy
  -> repair observability pipeline; do not declare incident recovery from missing traces
```

Production-impacting changes must still pass the Harness `change-review`/human-gate policy.

## 9. Post-change revalidation

Collect fresh evidence instead of reusing the pre-change files.

```bash
./agent k8s-evidence \
  --namespace demo-app \
  --output /tmp/platform-k8s-after.json

./agent prometheus-evidence \
  --url http://127.0.0.1:9090 \
  --query-file ../platform-engineering-lab/observability/agent-prometheus-queries.json \
  --namespace demo-app \
  --service platform-api \
  --output /tmp/platform-prom-after.json

./agent ops-review \
  --k8s /tmp/platform-k8s-after.json \
  --prometheus /tmp/platform-prom-after.json \
  --output /tmp/platform-review-after.json

./agent ops-compare \
  --before /tmp/platform-review-before.json \
  --after /tmp/platform-review-after.json \
  --output /tmp/platform-revalidation.json
```

A change is not considered recovered because it deployed successfully.

The strongest completion state is:

```text
verified_recovery=true
persistent=[]
new=[]
after.state=healthy
```

## 10. Learning loop

If a finding remains persistent, or the Agent lacked the evidence needed to classify the incident, keep that as a `learning_candidate`.

Do not automatically modify a Skill from one runtime outcome.

Promote a learning candidate only after:

```text
incident evidence
  -> reproducible fixture/scenario
  -> proposed context/Skill change
  -> human review
  -> independent eval
  -> regression validation
```

This keeps self-improvement measurable and reversible.
