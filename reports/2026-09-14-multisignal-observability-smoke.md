# Multi-signal observability smoke — 2026-09-14

## Runtime result

The local reference environment proved that the observability backends and Gateway paths were operational:

```text
platform baseline             healthy / continue
Prometheus service coverage   6/6
Loki application logs         present
Tempo recent traces           present
Alertmanager status API       reachable
Prometheus firing alerts      0
Loki evidence adapter         available
Tempo evidence adapter        available
```

Observed live counts from the first run:

```text
Loki query entries            100
Tempo search traces           20
Harness Loki entries          50
Harness Tempo traces          21
source unavailable            []
```

The final enrichment correlation did not pass:

```text
status                        logs_without_matching_trace
correlation_count             0
decision_effect               enrichment_only
base ops state                healthy
```

This did **not** indicate that Loki or Tempo was down. Both sources had fresh data and their APIs were reachable through MetalLB -> Envoy Gateway. The failure was in the initial correlation algorithm.

## Root cause

The first implementation correlated two independently bounded samples:

```text
Loki newest log entries -> trace_id set
Tempo /api/search top N traces -> traceID set
                         ↓
                    set intersection
```

The two samples can both be valid and fresh without containing the same trace ID. Therefore a zero intersection is not evidence of a broken tracing pipeline.

## Correction

Correlation now follows evidence provenance directly:

```text
Loki log
  -> trace_id
  -> Tempo /api/traces/{trace_id}
  -> exact trace exists
  -> correlation
```

The Tempo adapter now supports bounded exact follow-up for trace IDs extracted from normalized Loki evidence. An exact lookup returning HTTP 404 is classified as `not_found`, while a Tempo transport/API failure remains `unavailable`. This preserves the distinction between a missing individual trace and an unhealthy evidence source.

The multi-signal reviewer accepts both Tempo search summaries and successful exact trace lookups, while retaining:

```text
decision_effect = enrichment_only
```

Loki/Tempo evidence therefore cannot silently override the established Kubernetes + Prometheus Ops decision.

## Regression coverage

Harness tests now cover:

- one exact Tempo lookup;
- multiple bounded exact lookups;
- `404 -> not_found` semantics;
- correlation when Tempo search sampling does not overlap Loki but exact lookup succeeds;
- preservation of the base Ops decision.

Platform smoke now requires at least one successful exact Tempo follow-up before the observability stage passes.

Static validation after the correction:

```text
Harness validate              PASS
Observability Validate        PASS
Platform Validate             PASS
```

## Verification status

The correction is merged and CI-verified. A second live run of:

```bash
bash ops/smoke/full-reference-environment.sh
```

is still required before recording the metric -> log -> trace correlation as a verified runtime PASS.
