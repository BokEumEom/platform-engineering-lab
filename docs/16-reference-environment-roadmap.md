# Reference Environment Roadmap

This repository is the executable target environment for `infrastructure-engineering-harness`.

The objective is not to accumulate Kubernetes examples. The objective is to provide a reproducible environment in which an Infrastructure Engineering Agent can observe real runtime evidence, diagnose failures, propose changes, pass policy and approval gates, execute through the correct ownership layer, verify the result, and roll back when verification fails.

## Current topology

```text
Client
  -> MetalLB
  -> Envoy Gateway
  -> platform-api
       ├─> catalog-service
       ├─> recommendations-service
       └─> orders-service
             ├─> inventory-service
             └─> payments-service
```

Supporting runtime:

```text
Kubernetes / kind
Argo CD / GitOps
Prometheus / Grafana / Alertmanager
OpenTelemetry Collector / Tempo
Alloy / Loki
cert-manager / Gateway API
```

## Current Agent loop

```text
live Kubernetes evidence
        +
live Prometheus evidence
        ↓
ops-review
        ↓
findings / evidence refs / release guidance
        ↓
GitOps remediation benchmark
        ↓
fresh evidence
        ↓
ops-compare
        ↓
verified recovery / regression / learning candidate
```

The current live mutation benchmark is intentionally limited to a controlled GitOps fault experiment. Production write privileges are not implied.

## Target end-to-end operating loop

```text
Observe
  ↓
Diagnose
  ↓
Change Proposal
  ↓
Policy Evaluation
  ├─ risk
  ├─ blast radius
  ├─ destructive action
  ├─ privilege expansion
  └─ cost/capacity impact
  ↓
Approval Gate
  ↓
Executor
  ├─ GitOps
  └─ Terraform
  ↓
Reconcile / Apply
  ↓
Post-check
  ↓
PASS ──────────────> Evidence Record
  ↓ FAIL
Rollback
  ↓
Post-rollback verification
  ↓
Evaluation / Learning Candidate
```

## Ownership boundary

The same object must not be concurrently owned by Terraform and Argo CD.

Planned ownership:

```text
Terraform
  -> namespace/bootstrap/foundation resources
  -> quotas/capacity policy where appropriate
  -> future cloud infrastructure

Argo CD
  -> application Deployments/Services
  -> HPA/PDB
  -> Gateway API application routes
  -> observability policy resources

Agent
  -> no implicit ownership
  -> evidence / proposal / approved execution / verification
```

## Evaluation corpus target

The environment should grow toward 10-20 reproducible failure scenarios. Initial target set:

1. downstream 5xx;
2. downstream latency;
3. bad image rollout;
4. readiness-probe failure;
5. OOMKilled;
6. HPA saturation;
7. ResourceQuota saturation;
8. PDB-blocked operation;
9. NetworkPolicy dependency block;
10. DNS/service-discovery failure;
11. HTTPRoute failure;
12. TLS/certificate failure;
13. Prometheus target loss;
14. OpenTelemetry pipeline loss;
15. Loki/Alloy telemetry loss;
16. Argo CD drift;
17. destructive Terraform proposal;
18. RBAC privilege escalation;
19. public-exposure change;
20. failed remediation requiring rollback.

Each scenario should measure at least:

```text
Detection
Root-cause localization
Evidence completeness
Risk classification
Approval decision
Unsafe-action avoidance
Post-change verification
Rollback correctness
False positive / false negative behavior
```

## Documentation rule

Documentation is part of the executable contract.

When topology, ownership, query profiles, dashboards, benchmarks or Agent behavior changes, update the corresponding docs in the same change series. A stale README or runbook is treated as a product defect because external users must be able to reproduce the demonstrated behavior.

## Completion evidence

A milestone is considered complete only when the repository contains evidence that another engineer can reproduce it:

- deterministic quickstart;
- architecture diagram;
- executable reference environment;
- live Agent benchmark;
- evaluation fixtures and CI regression checks;
- post-change verification and rollback evidence;
- documented safety/approval boundary;
- evaluation report;
- external user feedback.

The long-term value of the project is the accumulated operating model, failure corpus, evaluation history and verified Agent behavior—not the number of individual manifests or integrations.
