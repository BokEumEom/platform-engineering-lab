# Orders Fault Benchmark — Verified Runtime Result

Date: 2026-09-14
Environment: local WSL2 / Kubernetes / Argo CD / MetalLB / Envoy Gateway / Prometheus
Scenario: controlled `orders-service` latency + 5xx fault
Result: **PASS**

## Outcome

The live benchmark completed the full loop:

```text
healthy baseline
→ GitOps fault commit
→ Argo CD reconciliation
→ real Gateway traffic
→ Agent detection and localization
→ GitOps remediation commit
→ fresh post-checks
→ ops-compare
→ verified recovery
```

The Agent baseline was healthy with no required evidence gaps. During the injected fault it classified the environment as `acute`, held release guidance, localized `orders-service`, and correlated the Kubernetes fault profile with independent Prometheus symptoms.

The final comparison reported:

```text
verified_recovery=true
resolved=6
persistent_blocking=[]
new_blocking=[]
```

Resolved findings were:

```text
demo_app.controlled_fault_enabled
dependency.orders_fault_injection_correlated
dependency.orders_high_error_ratio
dependency.orders_high_p95_latency
platform_api.fast_error_budget_burn
platform_api.high_p95_latency
```

A retained Warning-event finding remained P2 and did not block recovery.

## Observed fault evidence

Injected desired state:

```text
FAULT_LATENCY_MS=800
FAULT_ERROR_RATE_PERCENT=25
```

At detection time the Agent observed evidence including:

```text
platform-api availability burn rate > 17x
orders-service 5m 5xx ratio ≈ 5.93%
orders-service P95 ≈ 0.917s
platform-api P95 ≈ 0.902s
```

The required correlation finding was present:

```text
dependency.orders_fault_injection_correlated
```

## Timing baseline

From the captured console run:

```text
baseline healthy:             08:12:56 UTC
fault commit/reconcile start: 08:12:56 UTC
correlated fault detected:    08:14:56 UTC
remediation started:          08:14:56 UTC
fresh healthy evidence:       08:23:09 UTC
```

Approximate first-run measurements:

```text
time to correlated detection: ~2m
remediation-to-healthy:       ~8m10s
```

These numbers are a first baseline, not yet a performance claim. They include GitOps reconciliation, rollout behavior, Prometheus scrape/recording windows, traffic generation, and review polling.

## Learning discovered by the run

The run exposed a benchmark orchestration weakness: immediately after a push, Argo CD could still report the previous revision as `Synced/Healthy`. A rollout check performed at that moment could also succeed against the previous Deployment generation. As a result, the benchmark briefly generated recovery traffic while old faulted Pods were still serving.

The runner was subsequently hardened so mutation stages require all of the following before traffic begins:

```text
Argo .status.sync.revision matches the pushed commit
AND Argo state is Synced/Healthy
AND live orders Deployment FAULT_* values match expected state
AND Deployment rollout completes
```

This converts an observed runtime failure mode into a reproducible orchestration invariant.

## Interpretation

This result is evidence that the current Harness can function as an evidence-backed infrastructure/SRE diagnostic and verification copilot in the reference environment. It is not evidence of autonomous production readiness.

The next evaluation scenarios should expand failure diversity rather than repeating only application-level latency/5xx faults. Priority next scenarios are HPA/resource saturation, bad rollout, network policy failure, OOM, GitOps drift, telemetry loss, and destructive/privileged change policy evaluation.
