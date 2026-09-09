# End-to-End Ops Agent Benchmark

Status: **implemented / live runtime execution required**

This benchmark evaluates whether the Infrastructure Engineering Agent behaves like a useful read-only Ops/SRE diagnostic agent against a real Kubernetes/GitOps environment.

It is not satisfied by static manifests, mocked metrics, or a successful deployment alone.

## Benchmark question

Can the system reliably do the following?

```text
healthy service
  -> intentional dependency fault through Git
  -> Argo CD reconciliation
  -> user-visible degradation
  -> live evidence collection
  -> evidence-backed dependency localization
  -> remediation through Git
  -> fresh evidence collection
  -> independently verified recovery
```

## Target incident

The first benchmark uses `orders-service` because it is an internal dependency of `platform-api` and therefore tests dependency reasoning rather than a trivial Pod-down check.

Injected desired state:

```text
FAULT_LATENCY_MS=800
FAULT_ERROR_RATE_PERCENT=25
```

Expected causal chain:

```text
orders fault configuration
   |
   +-> orders P95 increases
   +-> orders 5xx increases
   |
   v
platform-api downstream calls
   |
   +-> end-to-end P95 increases
   +-> 502/5xx ratio increases
   +-> availability error budget burns
```

The Agent receives the fault configuration only through the safe allow-listed Deployment evidence collected by the Kubernetes adapter. It does not read arbitrary Secret values.

## Run

First update both repositories and ensure the cluster/observability stack is healthy.

Dry run:

```bash
cd ~/platform-engineering-lab
ops/benchmarks/orders-fault/run.sh
```

Intentional execution:

```bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  ops/benchmarks/orders-fault/run.sh --execute
```

The script requires a clean local `main` exactly matching `origin/main`.

## Mutation boundary

The benchmark runner is target-environment automation, not a generic autonomous mutation capability in the Harness.

The Harness remains read-only for Kubernetes/Prometheus evidence and deterministic review.

The benchmark runner performs only an explicitly authorized lab GitOps experiment:

```text
edit checked-in FAULT_* desired state
 -> git commit
 -> git push main
 -> Argo CD reconcile
```

Recovery is another Git commit returning both values to `0`.

No `kubectl set env`, imperative Deployment patch, or restart-first remediation is used.

## Expected evidence during fault

Kubernetes evidence should show `orders` similar to:

```json
{
  "name": "orders",
  "operational_env": {
    "SERVICE_ROLE": "orders",
    "FAULT_LATENCY_MS": "800",
    "FAULT_ERROR_RATE_PERCENT": "25"
  }
}
```

Prometheus should show some combination of:

```text
orders_error_ratio_5m > 5%
orders_p95_latency_5m > 500ms
platform_api_error_ratio_5m > 5%
platform_api_p95_latency_5m > 500ms
platform_api burn rate elevated
```

The exact numeric values are intentionally not treated as deterministic because request sampling and scrape windows vary.

## Required Agent correlation

The benchmark requires this finding:

```text
dependency.orders_fault_injection_correlated
```

That finding must reference both:

```text
k8s.deployments
```

and at least one actual service symptom such as:

```text
prometheus.orders_error_ratio_5m
prometheus.orders_p95_latency_5m
```

This is stronger than saying "orders looks unhealthy" because it binds desired-state/runtime configuration to independent service telemetry.

## Recovery semantics

Recovery is not:

```text
Argo Synced == incident closed
```

The runner waits for new observations after remediation and then runs `ops-compare`.

Required completion:

```text
after.state=healthy
persistent_blocking=[]
new_blocking=[]
verified_recovery=true
```

P2 informational findings remain visible but do not block recovery. This prevents historical Warning events from producing false-negative incident closure while still preserving the evidence.

## Artifacts

A successful or failed run leaves a local evidence package:

```text
.ops-benchmark/<run-id>/
  baseline-k8s.json
  baseline-prometheus.json
  baseline-review.json
  fault-k8s.json
  fault-prometheus.json
  fault-review.json
  recovery-k8s.json
  recovery-prometheus.json
  recovery-review.json
  revalidation.json
  traffic.log
  metadata.txt
```

`.ops-benchmark/` is excluded from Git because live runtime evidence can be noisy and environment-specific.

For a real organization, equivalent artifacts should be sent to an auditable incident/evaluation store with retention and access policy.

## What a failed benchmark means

Do not classify every failure as "the Agent is bad".

### Telemetry failure

```text
fault happened
but Prometheus/Loki/Tempo did not observe it
```

This is primarily an observability/evidence collection failure.

### Detection failure

```text
metrics and Kubernetes evidence clearly show the fault
but Ops review misses it
```

This is an Agent review/eval coverage failure.

### Localization failure

```text
Agent detects user impact
but attributes it to the wrong layer/service
```

This is a correlation/false-positive problem and is more serious than missing a low-severity signal.

### Remediation verification failure

```text
fault is removed
but P0/P1 findings remain
```

This may indicate stale metric windows, a bad remediation hypothesis, or a genuine remaining problem. It must not be auto-closed.

### Regression

```text
original finding resolves
but a new P0/P1 appears
```

`ops-compare` marks this as regression evidence.

## Self-improvement gate

The benchmark is also the first practical self-improvement test.

The system must not rewrite its own Skill after one failure.

Instead:

```text
live failure
 -> evidence bundle
 -> reproducible eval fixture/scenario
 -> identify missing evidence/reasoning/policy
 -> proposed Context/Skill/code change
 -> review
 -> run old + new eval corpus
 -> merge only if target failure improves without regression
```

Useful measurements over repeated runs:

```text
Detection recall
Root-cause localization accuracy
False-positive rate
False-negative rate
Evidence completeness
Time-to-classification
Verified-remediation rate
Regression rate after remediation
Learning candidate recurrence
```

## Current production-readiness interpretation

Passing this one benchmark is not enough for autonomous production operations.

It is meaningful evidence toward a production **diagnostic/review copilot** because it demonstrates:

- live read-only infrastructure evidence;
- cross-signal correlation;
- GitOps-aware diagnosis;
- explicit release guidance;
- independent recovery verification;
- auditable findings/evidence references;
- controlled learning candidates.

Before broader production use, add a larger incident corpus including:

```text
Pod crash/OOM
bad rollout
Gateway failure
DNS/network failure
HPA saturation
node pressure
Prometheus/OTel/Loki telemetry loss
certificate expiry/route failure
dependency timeout
partial dependency 5xx
GitOps drift
```

Then measure accuracy over repeated executions rather than evaluating by anecdote.
