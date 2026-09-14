# Multi-signal observability smoke — 2026-09-14

## Runtime result

The local reference environment proves the observability backends, Gateway paths, read-only Agent evidence adapters and log-to-trace enrichment path are operational.

### First live run

The first run proved the individual sources were healthy:

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

Observed counts from the first run:

```text
Loki query entries            100
Tempo search traces           20
Harness Loki entries          50
Harness Tempo traces          21
source unavailable            []
```

The first enrichment correlation did not pass:

```text
status                        logs_without_matching_trace
correlation_count             0
decision_effect               enrichment_only
base ops state                healthy
```

This did **not** indicate that Loki or Tempo was down. Both sources had fresh data and their APIs were reachable through MetalLB -> Envoy Gateway. The failure was in the initial correlation algorithm.

## Root cause found from the first run

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

The Tempo adapter supports bounded exact follow-up for trace IDs extracted from normalized Loki evidence. An exact lookup returning HTTP 404 is classified as `not_found`, while a Tempo transport/API failure remains `unavailable`. This preserves the distinction between a missing individual trace and an unhealthy evidence source.

The multi-signal reviewer accepts successful exact trace lookups while retaining:

```text
decision_effect = enrichment_only
```

Loki/Tempo evidence therefore cannot silently override the established Kubernetes + Prometheus Ops decision.

## Second live run — verified PASS

After the correction, `bash ops/smoke/full-reference-environment.sh` completed successfully on the local Docker Desktop Kubernetes reference environment.

Observed runtime evidence:

```text
Argo applications             Synced / Healthy
Gateway routes                Accepted / ResolvedRefs
six-service rollout           PASS
application HTTPS traffic     30/30
Prometheus raw services       6/6
Prometheus error ratio        6/6
Prometheus p95                6/6
Ops review                    healthy / continue
missing required evidence     []
retained Warning events       1

Loki application logs         100 entries
Tempo recent traces           20
Prometheus firing alerts      0
Harness Loki entries          50
Harness Tempo search traces   23
exact Tempo traces observed   4
exact Tempo traces not found  0
source unavailable            []

multi-signal status           correlated
correlation count             4
decision effect               enrichment_only
base ops state                healthy
release guidance              continue
```

Final runtime gates:

```text
REFERENCE ENVIRONMENT SMOKE PASS
MULTI-SIGNAL OBSERVABILITY SMOKE PASS
MULTI-SIGNAL CORRELATION PASS
FULL REFERENCE ENVIRONMENT SMOKE PASS
```

The evidence directory for the verified run was:

```text
.ops-smoke/20260914T105205Z-full/
```

This establishes a live-verified path:

```text
Kubernetes + Prometheus
        ↓
base Ops decision
        ↓
Loki structured log
        ↓ trace_id
Tempo exact trace lookup
        ↓
enrichment correlation
```

## Small reporting defect discovered during the verified run

The second run printed:

```text
exact Tempo follow-up: requested=0 observed=4 not_found=0
```

The `observed=4` result and final four correlations were valid. The incorrect `requested=0` display came from normalized evidence omitting adapter `scope`, while the Platform smoke attempted to read `scope.exact_trace_ids_requested`.

The Tempo evidence CLI now preserves bounded scope metadata in its normalized output so future runs report the requested exact lookup count correctly. This was a reporting defect only; it did not affect the exact Tempo requests, correlation result, or PASS decision.

## Regression coverage

Harness tests cover:

- one exact Tempo lookup;
- multiple bounded exact lookups;
- `404 -> not_found` semantics;
- correlation when Tempo search sampling does not overlap Loki but exact lookup succeeds;
- preservation of the base Ops decision.

Platform smoke requires at least one successful exact Tempo follow-up before the observability stage passes.

Static validation after the correlation correction:

```text
Harness validate              PASS
Observability Validate        PASS
Platform Validate             PASS
```

## Verification status

**Live runtime verified.**

As of 2026-09-14 the reference environment has demonstrated fresh application traffic flowing through metrics, structured logs and distributed traces, with a Loki `trace_id` resolved by exact Tempo lookup and retained as enrichment-only evidence without changing the independently established Kubernetes + Prometheus Ops decision.
