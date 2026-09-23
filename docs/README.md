# Documentation

This directory is the canonical documentation home for platform-engineering-lab.

Use progressive disclosure: start with the smallest document that answers the question, then follow links to deeper architecture, operations, or evidence material. The repository root README stays intentionally short and points here.

## Start here

- [Getting started](getting-started/README.md) — local environment, Kubernetes basics, Gateway, workload, and GitOps flow.
- [Kubernetes operating environment](21-kubernetes-operating-environment.md) — current operating baseline.
- [Ops Agent runbook](13-ops-agent-runbook.md) — evidence collection, review, change, and verification flow.
- [Reference environment smoke test](18-reference-environment-smoke-test.md) — live preflight before benchmarks.
- [Evidence](evidence/README.md) — dated runtime results and benchmark evidence.
- [한국어 문서](ko/README.md) — Korean operational documentation.

## Foundations

- [00 — Beginner walkthrough](00-beginner-walkthrough.md) — compatibility entrypoint; content is now split under getting-started.
- [01 — Kubernetes platform lab](01-kubernetes-platform-lab.md) — compatibility entrypoint; content is now split under getting-started.
- [02 — Observability](02-observability.md)
- [03 — Grafana dashboard as code](03-grafana-dashboard-as-code.md)
- [04 — Envoy Gateway metrics](04-envoy-gateway-metrics.md)
- [05 — Alerting](05-alerting.md)
- [06 — OpenTelemetry tracing](06-opentelemetry-tracing.md)
- [07 — Envoy Gateway tracing](07-envoy-gateway-tracing.md)
- [08 — TLS with cert-manager](08-tls-cert-manager.md)
- [09 — HTTP to HTTPS redirect](09-http-to-https-redirect.md)

## Infrastructure Engineering Harness and operations

- [10 — Infrastructure Engineering Harness review](10-infrastructure-engineering-harness-review.md)
- [11 — NetworkPolicy hardening](11-networkpolicy-hardening.md)
- [12 — Operational observability Agent review](12-operational-observability-agent-review.md)
- [13 — Ops Agent runbook](13-ops-agent-runbook.md)
- [14 — Operational observability](14-operational-observability.md)
- [15 — Ops Agent benchmark](15-ops-agent-benchmark.md)
- [16 — Reference environment roadmap](16-reference-environment-roadmap.md)
- [17 — Gateway route namespace access invariant](17-gateway-access-invariant.md)
- [18 — Reference environment smoke test](18-reference-environment-smoke-test.md)
- [19 — HPA / ResourceQuota policy benchmark](19-hpa-quota-policy-benchmark.md)
- [20 — Multi-signal observability](20-multi-signal-observability.md)
- [21 — Kubernetes operating environment](21-kubernetes-operating-environment.md)
- [22 — Cilium / Hubble roadmap](22-cilium-hubble-roadmap.md)

## Documentation rules

1. Keep the root README as an index and quick-start page, not a full runbook.
2. Put durable project documentation under docs/.
3. Prefer small focused chapters linked from an index over one large walkthrough.
4. Keep one canonical explanation for a concept; link to it instead of copying it.
5. When a feature changes operational behavior, ownership, validation, or failure handling, update the related documentation in the same change.
6. Runtime evidence belongs under docs/evidence/ and must distinguish static configuration from live verification.
7. Review scoped AGENTS.md instructions periodically and after meaningful ownership or architecture changes.

The CI documentation guard validates these indexes generically so new Markdown documents must be discoverable without adding another hard-coded filename to the checker.
