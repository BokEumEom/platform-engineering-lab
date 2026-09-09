# Agent-driven Kubernetes Review and Operational Observability

Status: **reviewed desired state / runtime evidence required for tuning**

This phase closes the step-by-step lab and turns the environment into a target for the `infrastructure-engineering-harness` Infrastructure Engineering Agent.

The operating model changes from:

```text
learn a Kubernetes feature
  -> add manifest
  -> manually verify
```

to:

```text
collect live evidence
  -> Infrastructure/SRE/Security review
  -> prioritize risk
  -> propose GitOps change
  -> apply/reconcile
  -> collect post-change evidence
  -> verify or reopen
```

## 1. Current desired-state review

The repository already provides a strong learning baseline:

- Kubernetes / kind 3-node cluster;
- Gateway API + Envoy Gateway;
- MetalLB;
- Argo CD GitOps;
- HPA / PDB / topology spread;
- Prometheus / Grafana / Alertmanager;
- Envoy + FastAPI metrics;
- OpenTelemetry Collector + Tempo;
- distributed tracing from ingress to FastAPI;
- cert-manager + HTTPS.

The current observability configuration is intentionally lightweight rather than operationally durable.

### Prometheus / Grafana / Alertmanager

Current characteristics:

```text
Prometheus retention:     6h
Prometheus retentionSize: 1GB
Prometheus persistence:   not configured
Grafana persistence:      disabled
Alertmanager retention:   6h
Alertmanager receiver:    null
Default Kubernetes rules: disabled
```

This is appropriate for a lab, but not enough for operational review, historical comparison, incident reconstruction, or real notification delivery.

### Tempo / OpenTelemetry

Current characteristics:

```text
Tempo retention:     6h
Tempo backend:       local filesystem
Tempo persistence:   disabled
OTel Collector mode: Deployment
OTel pipeline:       traces only
```

The current trace path is valuable, but it does not yet provide a complete operational telemetry plane.

### Alerts

Current alerts are useful first checks:

- demo-app target down;
- demo-app 5xx ratio above a fixed threshold;
- demo-app P95 latency above a fixed threshold;
- Envoy proxy down.

They are component/threshold alerts, not yet service-objective alerts.

## 2. Operational observability target

The target is not "more dashboards". It is a telemetry and response system that lets an Infrastructure Engineering Agent answer:

- Is the user-facing service healthy?
- What changed?
- Which dependency or layer is responsible?
- Is the problem acute or chronic?
- Is the error budget being consumed dangerously?
- Should a release continue, stop, or roll back?
- Did the remediation actually recover the service?

Target signal model:

```text
                    ┌──────────────┐
                    │ Kubernetes   │
                    │ runtime      │
                    └──────┬───────┘
                           │
             ┌─────────────┼─────────────┐
             │             │             │
             v             v             v
          Metrics         Logs         Traces
         Prometheus       Loki          Tempo
             │             │             │
             └─────────────┼─────────────┘
                           v
                        Grafana
                           │
             ┌─────────────┼─────────────┐
             │             │             │
             v             v             v
            SLO         Incident       Agent
        / error budget   timeline      evidence
             │
             v
        Alertmanager
```

## 3. Priority P0 — make the Agent evidence-driven

Use `infrastructure-engineering-harness` to collect live Kubernetes evidence before making operational claims.

Example:

```bash
cd ~/infrastructure-engineering-harness

git pull

./agent k8s-evidence \
  --namespace demo-app \
  --output /tmp/platform-lab-k8s-evidence.json
```

The evidence should be reviewed together with this repository's Git desired state.

The next Harness integration should add a Prometheus evidence adapter so live Kubernetes state and service-level metrics can be evaluated in one review.

## 4. Priority P0 — logs and Kubernetes events

The largest telemetry gap is logs.

Target local architecture:

```text
Pod stdout/stderr ──┐
                    ├─> Grafana Alloy DaemonSet ─> Loki
Kubernetes Events ──┘

Loki ─> Grafana Explore
```

Operational requirements:

- collect application Pod logs;
- collect platform component logs where useful;
- collect Kubernetes Warning events;
- attach stable labels such as cluster, namespace, workload, pod and container;
- avoid high-cardinality labels such as request ID or trace ID as Loki index labels;
- keep trace IDs inside log fields for correlation rather than labels;
- make retention explicit;
- define limits to prevent unbounded local ingestion.

Grafana Alloy is preferred for the Loki path because current Grafana guidance recommends Alloy as the primary Kubernetes log collector.

## 5. Priority P0 — service objectives instead of threshold-only alerting

Define explicit SLIs and SLOs before adding more alerts.

Candidate demo-app objectives for exercising the operating model:

```text
Availability SLI:
  successful user-facing requests / total eligible requests

Latency SLI:
  requests below the chosen latency objective / total eligible requests

SLO window:
  30 days for the model, even if the local lab initially retains less history
```

The exact SLO percentage is a policy decision and should not be silently inferred from the current dashboard or alert threshold.

Use Prometheus recording rules for:

- request rate;
- error ratio;
- latency objective ratio;
- SLO error budget consumption;
- multi-window burn rates.

Move page-level alerts toward multi-window, multi-burn-rate logic rather than a single `5xx > 5% for 2m` threshold.

For the low-traffic local demo environment, synthetic probes are required to make availability monitoring meaningful.

## 6. Priority P1 — synthetic user-path monitoring

Add black-box HTTP probing for the actual Gateway path:

```text
HTTPS web.lab.local
   -> Envoy Gateway
   -> HTTPRoute
   -> demo-app
```

The probe should validate:

- DNS/host routing assumptions used by the environment;
- TLS handshake;
- HTTP status;
- end-to-end latency;
- application reachability through the Gateway rather than direct Service access.

This becomes the primary availability SLI for a low-traffic lab service.

## 7. Priority P1 — alert routing and runbooks

Current Alertmanager delivery goes to a null receiver. Operationalization requires a real notification path.

Target routing model:

```text
severity=critical/page
  -> immediate notification

severity=warning/ticket
  -> non-page workflow

Watchdog / dead-man signal
  -> independent delivery-path check
```

Do not commit webhook tokens or notification credentials to Git. Use Kubernetes Secrets or an external secret mechanism when a real receiver is selected.

Every actionable alert should eventually include:

- summary;
- user/service impact;
- dashboard link;
- runbook link;
- likely evidence queries;
- owning service/team label.

## 8. Priority P1 — telemetry pipeline health

The observability system must monitor itself.

Required checks include:

```text
Prometheus target health
Prometheus rule evaluation failures
Alertmanager availability
OTel Collector accepted / refused / dropped spans
OTel Collector exporter failures
Tempo ingestion/query health
Loki ingestion/query health
Alloy scrape/send errors
Grafana datasource availability
```

An unavailable telemetry backend must not be mistaken for application recovery.

## 9. Priority P1 — retention and persistence

Current 6-hour volatile retention is useful for experiments but weak for operations.

Before changing storage settings, collect cluster storage evidence:

```bash
kubectl get storageclass
kubectl get pv,pvc -A
kubectl get nodes -o wide
```

Then choose a local durability target.

Candidate lab progression:

```text
Prometheus: 24h -> 7d
Tempo:      24h -> 7d
Loki:       24h -> 7d
Alertmanager: at least 24h
```

These are learning targets, not production sizing recommendations. Actual retention and resource requests must be based on ingestion volume and available storage.

## 10. Priority P1 — correlation

Operational Grafana should allow movement between signals:

```text
Alert
  -> SLO / service dashboard
  -> metric anomaly
  -> trace
  -> related logs
  -> Kubernetes workload/event
```

Target correlation:

- Tempo datasource linked from exemplars when available;
- logs contain trace/span IDs where the application emits them;
- Grafana derived fields link log trace IDs to Tempo;
- dashboards use consistent `cluster`, `namespace`, `service`, `workload` dimensions;
- deployment/version metadata is visible during incident investigation.

## 11. Infrastructure Engineering Agent review contract

For this environment, a useful Agent review should emit:

```yaml
review:
  state: healthy | at_risk | acute | insufficient_evidence
  evidence:
    kubernetes: []
    prometheus: []
    traces: []
    logs: []
  findings:
    - severity: P0 | P1 | P2
      observation: ""
      impact: ""
      evidence_refs: []
      recommendation: ""
      verification: []
  release_guidance: continue | hold | rollback | insufficient_evidence
  open_questions: []
```

The Agent must keep repository desired state, runtime observations and independent verification distinct.

## 12. Implementation order

Recommended order from here:

```text
1. Kubernetes live evidence adapter                         DONE in Harness
2. Run first live K8s evidence collection                  NEXT
3. Prometheus evidence adapter                             NEXT
4. Loki + Alloy Pod logs + Kubernetes Events
5. SLI recording rules
6. synthetic HTTPS probe
7. SLO / burn-rate dashboard and alerts
8. real Alertmanager receiver + runbook links
9. telemetry-pipeline self-monitoring
10. retention/persistence based on measured ingestion
11. trace-log-metric correlation
12. repeated Agent review + post-change verification
```

The platform is now best treated as a small operational environment for Agent-assisted infrastructure engineering rather than as a sequence of isolated Kubernetes exercises.
