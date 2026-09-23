# Getting started

This guide replaces the duplicated long-form 00/01 walkthroughs with small focused chapters.

## Learning path

1. [Environment](environment.md) — prepare WSL2, Docker Desktop, kubectl, Helm, and validate the cluster.
2. [Kubernetes basics](kubernetes-basics.md) — understand requests, HPA, PDB, scheduling, and node operations.
3. [Gateway](gateway.md) — understand Gateway API, Envoy Gateway, MetalLB, and routing validation.
4. [Workload and GitOps](workload.md) — run the FastAPI workload, validate Kustomize, and understand Argo CD ownership.

After the base environment is healthy, continue with:

- [Observability](../02-observability.md)
- [Alerting](../05-alerting.md)
- [OpenTelemetry tracing](../06-opentelemetry-tracing.md)
- [TLS with cert-manager](../08-tls-cert-manager.md)
- [Kubernetes operating environment](../21-kubernetes-operating-environment.md)
- [Reference environment smoke test](../18-reference-environment-smoke-test.md)

## Expected control flow

~~~text
Developer
  → Git
  → GitHub Actions / immutable image
  → desired-state repository
  → Argo CD or Terraform owner
  → Kubernetes
  → fresh runtime evidence
~~~

The key principle is to separate desired state from observed runtime state. Static validation proves configuration shape; live smoke and benchmark evidence prove runtime behavior.
