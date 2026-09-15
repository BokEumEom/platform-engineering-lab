# Cilium / Hubble / eBPF 도입 로드맵

[English](../22-cilium-hubble-roadmap.md) | **한국어**

Cilium은 단순히 Service Mesh를 추가하는 기능으로 보지 않고 **Kubernetes network dataplane + security policy + network evidence plane** 변경으로 취급합니다.

참고한 Cloud Native Operations 교육자료는 Cilium을 eBPF 기반 Kubernetes networking/security/observability 계층으로 설명하고, Hubble을 flow visibility 및 Prometheus metrics 계층으로 구분합니다. 또한 kube-proxy replacement, L7 proxy, encryption, service mesh는 기본 CNI 설치와 별도의 선택 기능으로 다룹니다.

참고:

- https://www.atomai.click/kubernetes-docs/ko/networking/cilium/
- https://www.atomai.click/kubernetes-docs/en/service-mesh/cilium-service-mesh/04-observability.html

## Service Mesh를 먼저 설치하지 않는 이유

현재 reference environment에는 이미 다음이 있습니다.

```text
Envoy Gateway
OpenTelemetry instrumentation
Tempo distributed tracing
Loki structured logs
Prometheus metrics
```

Network failure baseline 없이 L7 mesh를 먼저 넣으면 운영 복잡도는 커지지만 Agent의 진단 정확도가 실제로 개선됐는지 비교하기 어렵습니다.

## Phase 0 — 현재 dataplane baseline

Cilium 이전에 다음을 먼저 완료합니다.

- PVC / storage 운영 검증
- deterministic Kubernetes NetworkPolicy scenario
- service-to-service deny evidence
- DNS failure evidence
- Gateway/backend reachability failure evidence
- 기존 full reference smoke 유지

이 결과가 Cilium 도입 전 비교 기준이 됩니다.

## Phase 1 — Cilium + Hubble 관측

초기 도입 범위:

```text
Cilium CNI / eBPF datapath
Hubble server
Hubble Relay
Hubble Prometheus metrics
Hubble UI optional
```

초기에는 다음 고위험/고복잡도 기능을 켜지 않습니다.

```text
kubeProxyReplacement = false
Service Mesh / L7 policy = disabled
mTLS = disabled
ClusterMesh = disabled
BGP = disabled
transparent encryption = disabled
```

실제 Helm value는 선택한 Cilium 버전과 로컬 cluster networking model에 맞춰 검증합니다.

## 수집할 evidence

Prometheus/Harness 후보:

```text
Hubble flow rate
Hubble dropped flows
DNS query / response errors
TCP failures
policy verdict
Cilium endpoint health
Cilium agent health
BPF map pressure
```

목표 상관관계:

```text
Prometheus application symptom
+ Kubernetes workload state
+ Loki logs
+ Tempo trace
+ Hubble flow / policy verdict
```

예:

```text
orders → payments timeout
payments Pods Ready
Tempo child span error
Hubble verdict DROPPED
NetworkPolicy denies orders → payments
```

이 구조가 단순 mesh dashboard 추가보다 Infrastructure Agent의 root-cause localization에 더 직접적인 가치가 있습니다.

## Phase 2 — 도입 효과 평가

동일한 NetworkPolicy/DNS scenario를 Cilium 전후로 다시 실행합니다.

측정:

- detection recall
- root-cause localization accuracy
- time-to-classification
- false positives
- evidence completeness
- rollback verification

Hubble evidence가 실제 진단 품질을 높이지 못하거나 reference environment 안정성을 크게 해치면 기본 운영 경로로 승격하지 않습니다.

## Phase 3 — optional Service Mesh

CNI/Hubble 단계가 안정된 이후 L7 identity/routing/security가 필요한 scenario에서만 Cilium Service Mesh 또는 다른 mesh를 평가합니다.

후보 scenario:

- L7 HTTP policy deny
- service identity / mTLS 검증
- retry / timeout policy
- canary traffic split
- Gateway API + east-west L7 policy

Microservices라는 이유만으로 Service Mesh를 필수 구성으로 두지 않습니다.

## 안전 경계

CNI/dataplane 변경은 blast radius가 큰 작업입니다.

반드시 필요한 조건:

- local cluster maintenance/recreate plan
- rollback path
- migration 전 full smoke evidence 보존
- 설치 후 connectivity test
- Gateway / DNS / Prometheus / Loki / Tempo / Argo 재검증
- Agent가 production CNI를 autonomous mutation하지 않음
