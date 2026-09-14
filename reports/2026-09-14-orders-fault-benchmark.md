# Orders Fault Benchmark — Verified Runtime Result

Date: 2026-09-14
Environment: local WSL2 / Kubernetes / Argo CD / MetalLB / Envoy Gateway / Prometheus
Scenario: controlled `orders-service` latency + 5xx fault
Result: **PASS / REVALIDATED**

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

The final comparison reported on both successful runs:

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

At first-run detection time the Agent observed evidence including:

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

The revalidation run again reached `acute/hold` and later observed a stronger fault window, including roughly 18.40% orders 5xx and ~0.971s orders P95 before correlation was declared.

## Timing baseline

### First verified run

```text
baseline healthy:             08:12:56 UTC
fault commit/reconcile start: 08:12:56 UTC
correlated fault detected:    08:14:56 UTC
remediation started:          08:14:56 UTC
fresh healthy evidence:       08:23:09 UTC
```

Approximate measurements:

```text
time to correlated detection: ~2m
remediation-to-healthy:       ~8m10s
```

### Revision-gate revalidation run

The second run validated the hardened reconciliation gate itself:

```text
baseline healthy:              08:30:35 UTC
fault commit pushed:           08:30:35 UTC
fault revision/profile ready:  08:32:51 UTC
correlated fault detected:     08:35:45 UTC
recovery commit pushed:        08:35:45 UTC
recovery revision/profile ready: 08:40:14 UTC
fresh healthy evidence:        08:41:23 UTC
```

Key reconciliation observations were explicit:

```text
previous revision=84ed52f orders_fault=0/0
→ target revision=4b339f3 orders_fault=800/25

previous revision=4b339f3 orders_fault=800/25
→ target revision=7d70f01 orders_fault=0/0
```

This proves the runner no longer treats a stale `Synced/Healthy` status from the previous revision as completion of the just-pushed change.

These numbers are evaluation baselines, not performance claims. They include GitOps reconciliation, rollout behavior, Prometheus scrape/recording windows, traffic generation, and review polling.

## Learning discovered by the run

The first run exposed a benchmark orchestration weakness: immediately after a push, Argo CD could still report the previous revision as `Synced/Healthy`. A rollout check performed at that moment could also succeed against the previous Deployment generation. As a result, the benchmark briefly generated recovery traffic while old faulted Pods were still serving.

The runner was subsequently hardened so mutation stages require all of the following before traffic begins:

```text
Argo .status.sync.revision matches the pushed commit
AND Argo state is Synced/Healthy
AND live orders Deployment FAULT_* values match expected state
AND Deployment rollout completes
```

The second live run verified this invariant against real Argo reconciliation lag. This converts an observed runtime failure mode into a reproducible orchestration contract with live evidence.

## Interpretation

This result is evidence that the current Harness can function as an evidence-backed infrastructure/SRE diagnostic and verification copilot in the reference environment. It is not evidence of autonomous production readiness.

Scenario #1 is now considered complete for the current milestone. Further repeated runs are useful for reliability statistics, but implementation effort should move to failure diversity and controlled mutation policy.

The next scenario is HPA/resource saturation across GitOps and Terraform ownership, followed by policy risk classification, explicit approval, apply-time revalidation, post-check, and rollback.
