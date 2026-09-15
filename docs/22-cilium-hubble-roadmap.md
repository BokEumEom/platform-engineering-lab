# Cilium, Hubble and eBPF adoption roadmap

[한국어](ko/22-cilium-hubble-roadmap.md)

Cilium is treated as a network dataplane and evidence-plane change, not as a checkbox service-mesh installation.

The reference material reviewed from Cloud Native Operations describes Cilium as a Kubernetes networking/security/observability layer implemented with eBPF, with Hubble providing flow visibility and Prometheus metrics. It also distinguishes optional features such as kube-proxy replacement, L7 proxying, encryption and service mesh from the base CNI/dataplane.

Reference:

- https://www.atomai.click/kubernetes-docs/ko/networking/cilium/
- https://www.atomai.click/kubernetes-docs/en/service-mesh/cilium-service-mesh/04-observability.html

## Why not install the service mesh first

The current environment already has:

```text
Envoy Gateway
OpenTelemetry instrumentation
Tempo distributed tracing
Loki structured logs
Prometheus metrics
```

Adding a sidecar or L7 mesh before network failure baselines are established would add complexity without proving better incident diagnosis.

## Phase 0 — current dataplane baseline

Before Cilium:

- verify storage/PVC operation;
- add deterministic Kubernetes NetworkPolicy scenarios;
- record service-to-service, DNS and Gateway failure evidence;
- keep current Gateway and multi-signal smoke green.

This becomes the comparison baseline.

## Phase 1 — Cilium + Hubble observation

Initial target:

```text
Cilium CNI / eBPF datapath
Hubble server
Hubble Relay
Hubble Prometheus metrics
optional Hubble UI
```

Keep these advanced behaviors disabled initially:

```text
kubeProxyReplacement = false
service mesh / L7 policy = disabled
mTLS = disabled
ClusterMesh = disabled
BGP = disabled
transparent encryption = disabled
```

The exact values must match the selected Cilium version and the local cluster networking model.

## Evidence to collect

Prometheus/Harness candidates:

```text
Hubble flow rate
Hubble dropped flows
DNS query/response errors
TCP failures
policy verdicts
Cilium endpoint health
Cilium agent health
BPF map pressure
```

The objective is to correlate:

```text
Prometheus application symptom
+ Kubernetes workload state
+ Loki logs
+ Tempo trace
+ Hubble network flow / policy verdict
```

Example:

```text
orders → payments timeout
payments Pods Ready
Tempo child span error
Hubble verdict DROPPED
NetworkPolicy denies orders → payments
```

This is stronger root-cause evidence than adding a mesh only for dashboards.

## Phase 2 — policy evaluation

Re-run the same NetworkPolicy/DNS scenarios and compare:

- detection recall;
- root-cause localization accuracy;
- time-to-classification;
- false positives;
- evidence completeness;
- rollback verification.

Cilium/Hubble is retained only if it improves useful evidence without destabilizing the reference environment.

## Phase 3 — optional service mesh

Only after the CNI/Hubble phase is stable, evaluate Cilium Service Mesh or another mesh for a scenario that requires L7 identity/routing/security behavior.

Candidate scenarios:

- L7 HTTP policy deny;
- service identity / mTLS verification;
- retry / timeout policy behavior;
- canary traffic split;
- Gateway API + east-west L7 policy.

The mesh is not required merely because the project has microservices.

## Safety boundary

Changing CNI/dataplane is a high-blast-radius operation. The migration requires:

- explicit maintenance/recreate plan for the local cluster;
- rollback path;
- current smoke evidence preserved before migration;
- connectivity test after installation;
- Gateway, DNS, Prometheus, Loki, Tempo and Argo paths revalidated;
- no production-autonomous CNI mutation by the Agent.
