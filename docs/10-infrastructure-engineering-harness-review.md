# Infrastructure Engineering Harness Review — Operations and Kubernetes

This review applies the `infrastructure-engineering-harness` decision model to `platform-engineering-lab`.

Harness lenses used:

- `architecture-review`
- `sre-review`
- `security-review`
- `capability-routing`

The goal is not to add controls because they are fashionable. Changes must be justified by repository evidence or independently verified runtime evidence.

## Evidence boundary

### Repository evidence

The current desired state shows:

- two FastAPI replicas with HPA `2..6`;
- resource requests and limits;
- readiness and liveness probes;
- topology spread across nodes;
- a PodDisruptionBudget;
- Argo CD automated sync, self-heal and prune;
- immutable commit-SHA image tags;
- Envoy Gateway + HTTPS;
- Prometheus/Grafana/Alertmanager;
- Envoy + FastAPI distributed tracing through OpenTelemetry/Tempo;
- the application image already runs as UID `10001`.

### Runtime evidence already observed in the lab

- Gateway HTTP traffic reached FastAPI through the Docker/MetalLB bridge path.
- HTTPS terminated at Envoy Gateway and returned the FastAPI response.
- Tempo/Grafana showed the Gateway ingress span and `platform-api / GET /` application span in the distributed trace.

### Not yet independently verified

The following are not treated as facts until runtime evidence is collected:

- whether the current CNI actually enforces Kubernetes NetworkPolicy;
- whether CPU/memory requests and HPA thresholds are optimally sized;
- real SLO/error-budget state;
- node-pressure behavior under sustained load;
- restart and graceful-termination behavior during rolling updates;
- supply-chain provenance/SBOM/signature status.

## Harness decision

```yaml
decision: adopt_with_conditions
reason:
  - core platform path is functional and observable
  - workload reliability primitives already exist
  - workload security and operational guardrails are incomplete
conditions:
  - preserve runtime verification after every hardening change
  - do not invent capacity or quota numbers without evidence
  - do not claim NetworkPolicy protection until CNI enforcement is verified
```

## Findings

### P0 — Workload privilege should be explicitly constrained

Before this review, the Deployment relied on the Docker image's `USER 10001` but did not declare Kubernetes-level pod/container security controls.

Implemented:

- `runAsNonRoot: true`
- `runAsUser: 10001`
- `seccompProfile: RuntimeDefault`
- `allowPrivilegeEscalation: false`
- drop all Linux capabilities

This makes the Kubernetes desired state express the security invariant instead of relying only on image metadata.

### P0 — Application does not need a Kubernetes API token

The FastAPI application does not call the Kubernetes API.

Implemented:

- dedicated `ServiceAccount/web`
- `automountServiceAccountToken: false`
- explicit `serviceAccountName: web`

### P0 — Namespace Pod Security should match workload intent

Implemented in Argo CD `managedNamespaceMetadata`:

```text
pod-security.kubernetes.io/enforce=restricted
pod-security.kubernetes.io/audit=restricted
pod-security.kubernetes.io/warn=restricted
```

The policy version is pinned to Kubernetes `v1.36`, matching the lab cluster minor version at the time of this review.

### P1 — Network isolation is missing

No application NetworkPolicy is currently managed in Git.

Do not add a default-deny policy yet. First verify that the kind cluster's installed CNI enforces NetworkPolicy. A policy object without an enforcing implementation would create false confidence.

After verification, the intended policy should allow only the minimum required paths:

```text
Ingress
  Envoy Gateway -> demo-app:web:8000
  Prometheus     -> demo-app:web:8000 /metrics

Egress
  demo-app -> kube-dns
  demo-app -> otel-collector.monitoring:4317
```

### P1 — Capacity policy needs evidence before ResourceQuota/LimitRange

The current workload has explicit requests/limits, but no namespace ResourceQuota or LimitRange.

Do not invent quota values. First collect:

- current node allocatable CPU/memory;
- observed pod CPU/memory under idle and load;
- HPA behavior under synthetic traffic;
- desired maximum blast radius for the namespace.

Then derive quota from the intended service envelope.

### P1 — HPA is CPU-only

Current HPA:

```text
minReplicas: 2
maxReplicas: 6
CPU target: 50%
```

This is acceptable as a learning baseline but is not yet evidence-backed as an optimal production policy.

Next review should test:

- scale-up latency;
- scale-down stability;
- application latency while CPU approaches target;
- whether a request-rate or latency signal would better reflect demand.

### P1 — Deployment recovery behavior should be tested, not assumed

Existing controls are useful:

- readiness probe;
- liveness probe;
- PDB;
- topology spread;
- two minimum replicas.

Still verify:

- rolling update with one pod unavailable;
- node drain while serving traffic;
- termination behavior for in-flight requests;
- HPA + PDB interaction.

Only add `preStop`, `startupProbe`, or custom rolling-update values if testing identifies a real gap.

### P1 — CI supply-chain permissions can be tightened

The GitHub Actions job currently needs both package write and repository content write because it builds/pushes the image and commits the GitOps update in one job.

Future improvement:

- separate build/publish from GitOps update;
- narrow permissions per job;
- consider digest-based deployment references;
- add SBOM/provenance verification before promotion.

This is a delivery/security improvement and should be reviewed separately from workload runtime hardening.

## Implemented in this review

```text
gitops/apps/demo-app/serviceaccount.yaml
  -> dedicated ServiceAccount
  -> token automount disabled

gitops/apps/demo-app/deployment.yaml
  -> explicit non-root runtime
  -> RuntimeDefault seccomp
  -> no privilege escalation
  -> drop ALL capabilities

argocd/demo-app.yaml
  -> Restricted Pod Security labels
```

## Runtime verification — required before marking complete

Pull the Git changes:

```bash
cd ~/platform-engineering-lab
git pull
```

Refresh Argo CD if necessary:

```bash
kubectl annotate application demo-app \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

Check application state:

```bash
kubectl get application demo-app -n argocd
kubectl rollout status deployment/web -n demo-app
kubectl get pods -n demo-app -o wide
```

Verify the namespace security labels:

```bash
kubectl get ns demo-app --show-labels
```

Verify the ServiceAccount and token policy:

```bash
kubectl get sa web -n demo-app -o yaml
kubectl get pod -n demo-app -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{" serviceAccount="}{.spec.serviceAccountName}{" automount="}{.spec.automountServiceAccountToken}{"\n"}{end}'
```

Verify the effective security context:

```bash
kubectl get pod -n demo-app -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{" runAsNonRoot="}{.spec.securityContext.runAsNonRoot}{" seccomp="}{.spec.securityContext.seccompProfile.type}{"\n"}{end}'
```

Check the container UID from inside a pod:

```bash
POD=$(kubectl get pod -n demo-app -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo-app "$POD" -- id
```

Expected UID:

```text
uid=10001
```

Functional regression checks:

```bash
curl -I -H "Host: web.lab.local" http://127.0.0.1:8080/

curl -k \
  --resolve web.lab.local:8443:127.0.0.1 \
  https://web.lab.local:8443/
```

Then generate HTTPS traffic and confirm the distributed trace still contains:

```text
ingress
  -> platform-api
      -> GET /
```

## Next Harness loop

After this P0 hardening is verified, run the next loop in this order:

1. CNI / NetworkPolicy enforcement evidence
2. NetworkPolicy design and regression test
3. node drain + rolling update reliability exercise
4. HPA/load evidence collection
5. ResourceQuota/LimitRange derived from evidence
6. CI supply-chain and permission review

Completion must remain `unverified` until the runtime checks above pass.
