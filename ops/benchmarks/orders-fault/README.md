# Orders Fault Ops Agent Benchmark

This benchmark is the first end-to-end operational evaluation for the `platform-engineering-lab` + `infrastructure-engineering-harness` pair.

It is intentionally different from a unit test. The benchmark changes Git desired state, lets Argo CD reconcile it into Kubernetes, generates real Gateway traffic, captures live evidence, runs the Infrastructure Engineering Agent, remediates through GitOps, and requires fresh evidence to prove recovery.

## What it proves

```text
healthy Git desired state
  -> baseline evidence
  -> GitOps fault commit
  -> Argo reconciliation
  -> real HTTPS traffic through MetalLB/Envoy
  -> orders latency/5xx symptoms
  -> Kubernetes + Prometheus evidence
  -> Ops Agent correlation
  -> GitOps remediation commit
  -> fresh evidence
  -> ops-compare
  -> verified_recovery=true
```

The controlled fault is applied only to `orders-service`:

```text
FAULT_LATENCY_MS=800
FAULT_ERROR_RATE_PERCENT=25
```

Both values are configurable by environment variables.

## Safety model

The script defaults to dry-run. It will not mutate Git or Kubernetes unless all of the following are true:

- `--execute` is supplied;
- `OPS_BENCHMARK_ACK=platform-engineering-lab` is set;
- the platform repository is on `main`;
- the worktree/index are clean;
- local `main` exactly matches `origin/main`;
- the `demo-app` Argo CD Application exists;
- `web`, `catalog`, and `orders` Deployments exist;
- the real HTTPS Gateway path is reachable;
- the Infrastructure Engineering Agent is available.

The script does not use `kubectl set env`, restart-first remediation, or direct workload mutation. The fault and remediation are both Git commits pushed to `main`, and Argo CD owns reconciliation.

## Dry run

```bash
cd ~/platform-engineering-lab

ops/benchmarks/orders-fault/run.sh
```

This prints the planned mutation and exits.

## Execute intentionally

```bash
cd ~/platform-engineering-lab

OPS_BENCHMARK_ACK=platform-engineering-lab \
  ops/benchmarks/orders-fault/run.sh --execute
```

If the Harness repository is elsewhere:

```bash
HARNESS_DIR=/path/to/infrastructure-engineering-harness \
OPS_BENCHMARK_ACK=platform-engineering-lab \
  ops/benchmarks/orders-fault/run.sh --execute
```

## Evidence artifacts

Each run writes to:

```text
.ops-benchmark/<UTC run id>/
```

Artifacts include:

```text
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

The directory is local runtime evidence and should not be committed to Git.

## Expected Agent findings during the incident

Depending on traffic history and scrape timing, the exact set can vary. The benchmark requires at least the correlation finding:

```text
dependency.orders_fault_injection_correlated
```

Typical additional findings are:

```text
demo_app.controlled_fault_enabled
dependency.orders_high_error_ratio
dependency.orders_high_p95_latency
platform_api.high_error_ratio
platform_api.high_p95_latency
platform_api.fast_error_budget_burn
```

The important property is not a fixed number of alerts. It is that the Agent ties the dependency symptom to both:

1. runtime service telemetry; and
2. the safe allow-listed `FAULT_*` values observed from the orders Deployment.

## Recovery gate

The benchmark does not pass because Argo CD synchronized the recovery commit.

It waits for fresh evidence until there are no P0/P1 findings and then runs:

```text
ops-compare fault-review recovery-review
```

Pass criteria:

```text
verified_recovery=true
persistent_blocking=[]
new_blocking=[]
after.state=healthy
```

P2 informational findings, such as a retained historical Kubernetes Warning, are still recorded but do not block verified recovery.

## Self-improvement evidence

If the benchmark fails, do not immediately edit a Skill.

Classify the failure first:

```text
expected symptom not observed
  -> traffic/metrics/recording-rule/evidence issue

symptom observed but Agent missed it
  -> Ops review capability/eval gap

Agent found wrong root cause
  -> correlation/false-positive gap

remediation deployed but finding persists
  -> remediation hypothesis or verification-window gap

new P0/P1 appears after remediation
  -> regression
```

Promote repeatable failures into a checked-in fixture/scenario and only then propose a Context/Skill change. The change must improve the failing eval without regressing existing scenarios.

## Why this is closer to production work

The benchmark exercises the parts that demos often skip:

- desired state vs runtime state separation;
- real reconciliation rather than mocked apply success;
- user-path traffic rather than direct Pod access;
- cross-signal evidence;
- dependency localization;
- provenance-preserving findings;
- rollback/remediation through GitOps;
- independent post-change verification;
- false-positive-resistant recovery semantics;
- explicit learning candidates instead of uncontrolled self-modification.

It still does not make the Agent a production autonomous operator. Production use needs environment-specific authorization, change approval, durable telemetry, incident-routing integrations, audit retention, larger eval corpora, and measured false-positive/false-negative rates.
