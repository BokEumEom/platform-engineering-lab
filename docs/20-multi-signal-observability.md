# Multi-signal observability for the reference environment

The reference environment now treats metrics, logs, traces, alerts and Kubernetes runtime state as separate evidence sources. Installing observability components is not considered sufficient; the full smoke test must prove that each API is reachable through the same MetalLB -> Envoy Gateway entry path used by the rest of the lab and that fresh application traffic appears in the relevant backend.

## Runtime paths

```text
Application metrics -> Prometheus
Application stdout JSON -> Alloy -> Loki
Application OTLP traces -> OpenTelemetry Collector -> Tempo
PrometheusRule -> Prometheus -> Alertmanager

Harness / operator
  -> MetalLB / Envoy Gateway
     -> Prometheus API
     -> Loki API
     -> Tempo API
     -> Alertmanager API
```

The local Gateway hostnames are:

- `prometheus.lab.local`
- `loki.lab.local`
- `tempo.lab.local`
- `alertmanager.lab.local`
- `grafana.lab.local`

HTTP routes on port 8080 are intended for bounded read-only Agent API access in the local lab. HTTPS routes on port 8443 provide the equivalent local Gateway path for manual inspection. These are local reference-environment endpoints, not a production exposure recommendation.

## Canonical smoke test

Run the platform/runtime, observability and cross-source correlation checks with one command:

```bash
bash ops/smoke/full-reference-environment.sh
```

The observability stage verifies:

1. Loki, Tempo and Alertmanager HTTPRoutes are Accepted and have ResolvedRefs.
2. Their APIs are reachable through MetalLB/Envoy rather than `kubectl port-forward`.
3. Fresh requests are sent through `web.lab.local`.
4. Loki contains fresh `demo-app` log entries.
5. Tempo contains recent traces.
6. Prometheus can expose the current firing-alert count and Alertmanager's status API is reachable.
7. When the adjacent Harness checkout is present, its read-only Loki and Tempo evidence adapters return normalized observations with no unavailable sources.
8. A Loki `trace_id` must match a Tempo trace in the same run before the full smoke is considered multi-signal complete.

Evidence is written beneath `.ops-smoke/<UTC>-full/` and is intentionally ignored by Git.

## Harness evidence contracts

Platform-owned query/search profiles:

- `observability/agent-prometheus-queries.json`
- `observability/agent-loki-queries.json`
- `observability/agent-tempo-searches.json`

Harness read-only adapters:

- `adapters/evidence/prometheus.py`
- `adapters/evidence/loki.py`
- `adapters/evidence/tempo.py`

The Harness also has deterministic enrichment-only correlation in `runtime/multisignal_review.py`. It extracts structured log `trace_id` values, matches them against Tempo search results and records the associated log service/event/level plus Tempo summary. The output explicitly keeps:

```text
decision_effect = enrichment_only
ops_state = original ops-review state
release_guidance = original ops-review guidance
```

This means log/trace evidence can strengthen or expose gaps in an explanation without silently changing the current Kubernetes + Prometheus blocking decision. Promotion into blocking incident logic requires scenario/evaluation evidence showing better root-cause localization without unacceptable regressions.

The full smoke writes `multi-signal-review.json` and requires at least one real Loki-to-Tempo trace correlation from fresh local traffic.

## Current local-lab durability boundaries

- Prometheus retention: 24h, no persistent volume.
- Loki retention: 24h, monolithic single replica, filesystem, no persistent volume.
- Tempo retention: 6h, single replica, local storage, no persistent volume.
- Alertmanager retention: 24h; receiver remains `null`, so external paging is not yet configured.

These choices are appropriate for repeatable local incident evaluation but are not production HA or durable telemetry architecture.

## Production-readiness gaps

Before calling the observability plane production-ready, the project still needs durable/HA storage, external alert delivery, authentication/authorization on observability APIs, synthetic monitoring, explicit telemetry-loss scenarios, and evaluation showing that Loki/Tempo enrichment improves root-cause localization without increasing false positives.
