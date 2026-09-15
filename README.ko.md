# Platform Engineering Reference Environment

[English](README.md) | **한국어**

`platform-engineering-lab`은 **Infrastructure Engineering Harness**가 실제 Kubernetes/GitOps/관측성 증거를 기반으로 운영 판단과 변경을 검증하기 위한 실행 가능한 참조 환경입니다.

단순 Kubernetes 실습 환경이 아니라 다음 운영 루프를 반복 가능한 시나리오로 검증하는 것이 목적입니다.

```text
Observe
→ Diagnose
→ Propose Change
→ Risk / Policy 평가
→ Approval
→ GitOps 또는 Terraform 실행
→ Post-check
→ 필요 시 Rollback
→ Evidence 보존
→ Re-evaluate / Learning Candidate
```

## 현재 검증 상태

현재 로컬 reference environment에서 다음이 실제 실행으로 검증됐습니다.

```text
6-service Kubernetes workload
→ Argo CD Synced / Healthy
→ MetalLB + Envoy Gateway
→ Prometheus metrics
→ Loki structured logs
→ Tempo distributed traces
→ Alertmanager API
→ Loki trace_id → Tempo exact trace correlation
→ Harness Ops review
```

첫 Ops benchmark인 `orders-service` latency/5xx 장애는 GitOps 주입부터 Agent 탐지, 복구, fresh evidence, `verified_recovery=true`까지 완료했습니다.

두 번째 benchmark인 HPA + ResourceQuota는 policy/approval/Terraform/GitOps cross-owner 경로를 구현했고 live validation이 남아 있습니다.

## 현재 토폴로지

```text
Client
  ↓
MetalLB
  ↓
Envoy Gateway
  ↓
platform-api
  ├─→ catalog-service
  ├─→ recommendations-service
  └─→ orders-service
        ├─→ inventory-service
        └─→ payments-service
```

각 서비스는 독립 Deployment, Service, ServiceAccount, HPA, PDB, Prometheus identity, OpenTelemetry service name, structured logging을 가집니다.

## Kubernetes 운영 스택

```text
Kubernetes v1.36.x / Docker Desktop local cluster
Envoy Gateway + Gateway API
MetalLB
cert-manager / TLS
Argo CD / GitOps
Terraform / Kubernetes provider
Prometheus / Grafana / Alertmanager
OpenTelemetry Collector / Tempo
Grafana Alloy / Loki
StatefulSet + PVC storage probe
Infrastructure Engineering Agent evidence adapters
```

운영환경을 먼저 완성한 뒤 네트워크 dataplane을 확장합니다.

```text
Kubernetes operating baseline
→ PVC / storage observability
→ NetworkPolicy scenarios
→ Cilium + Hubble eBPF evidence
→ optional Cilium Service Mesh
```

Service Mesh를 먼저 설치하지 않는 이유는 기존 Envoy Gateway + OTel + Tempo와 역할이 일부 겹치고, CNI/dataplane 변경은 장애 범위가 크기 때문입니다.

## PVC / Storage 운영환경

`demo-app`에는 `storage-probe` StatefulSet과 1Gi PVC가 있습니다.

기본값:

```text
STORAGE_FILL_MIB=0
```

따라서 정상 상태에서는 의도적으로 PVC를 채우지 않습니다. 이후 storage saturation scenario에서는 이 값을 GitOps로 조정해 80%/90% 임계치를 재현할 수 있습니다.

Prometheus/Harness에서 사용하는 주요 지표:

```text
kube_persistentvolumeclaim_status_phase
kube_persistentvolumeclaim_resource_requests_storage_bytes
kubelet_volume_stats_capacity_bytes
kubelet_volume_stats_used_bytes
kubelet_volume_stats_available_bytes
kubelet_volume_stats_inodes
kubelet_volume_stats_inodes_used
```

Docker Desktop local storage가 `kubelet_volume_stats_*`를 노출하지 않을 때는 local lab 전용 fallback을 사용합니다.

```text
storage_probe_fill_bytes
storage_probe_requested_capacity_bytes
storage_probe_usage_ratio
```

이 fallback은 production CSI volume stats와 동일한 증거로 취급하지 않습니다.

Grafana에는 `Kubernetes Operations · Storage & PVC` dashboard가 추가되고, 다음 alert를 정의합니다.

```text
PVC Pending > 10m
PVC usage > 80% for 15m
PVC usage > 90% for 5m
PVC inode usage > 90% for 10m
```

Storage smoke는 workload, PVC, object metrics, CSI/kubelet volume stats 또는 local fallback을 검증합니다.

```bash
bash ops/smoke/storage.sh
```

## 전체 reference environment smoke

```bash
cd ~/platform-engineering-lab
bash ops/smoke/full-reference-environment.sh
```

검증 범위:

```text
Argo applications Synced/Healthy
→ Gateway namespace admission
→ HTTPRoutes Accepted/ResolvedRefs
→ six-service rollout
→ real HTTPS traffic
→ Prometheus service metrics 6/6
→ Kubernetes + Prometheus Harness evidence
→ Loki logs
→ Tempo traces
→ Alertmanager visibility
→ Loki trace_id ↔ Tempo exact trace correlation
```

Storage는 별도 smoke에서 먼저 검증한 뒤 full smoke의 blocking gate로 승격합니다.

## 첫 번째 Ops benchmark

```bash
OPS_BENCHMARK_ACK=platform-engineering-lab \
  bash ops/benchmarks/orders-fault/run.sh --execute
```

```text
healthy baseline
→ orders fault GitOps commit
→ exact Argo revision 확인
→ 실제 Gateway traffic
→ Kubernetes + Prometheus evidence
→ Agent correlated diagnosis
→ GitOps recovery
→ fresh evidence
→ ops-compare
→ verified_recovery=true
```

## 두 번째 capacity benchmark

```bash
bash ops/benchmarks/hpa-quota/run.sh
```

목표 흐름:

```text
HPA scale pressure
→ ResourceQuota rejection
→ Agent capacity correlation
→ Terraform + GitOps proposal
→ risk=medium
→ explicit approval
→ one-shot ChangeControl
→ execute
→ post-check
→ rollback
```

## Cilium / Hubble / eBPF 방향

Cilium은 단순 Service Mesh 추가가 아니라 CNI/eBPF dataplane, NetworkPolicy, Hubble network-flow evidence를 제공하는 계층으로 도입합니다.

1차 범위:

```text
Cilium CNI
Hubble Relay
Hubble metrics
NetworkPolicy
flow / drop / DNS evidence
```

초기에는 다음을 켜지 않습니다.

```text
kube-proxy replacement
L7 Service Mesh
mTLS
ClusterMesh
BGP
```

먼저 기존 운영환경의 안정성과 failure scenario를 보존한 상태에서 network evidence가 실제 root-cause localization을 개선하는지 평가합니다.

## GitOps ownership

```text
Terraform
  → ResourceQuota / foundation / future cloud resources

Argo CD
  → workloads
  → Gateway
  → observability policy
  → storage workload

Harness
  → evidence
  → diagnosis
  → proposal
  → policy / approval
  → verified execution
```

Terraform과 Argo CD가 같은 Kubernetes object를 동시에 소유하지 않도록 유지합니다.

## 저장소 구조

```text
platform-engineering-lab/
├── apps/api/
├── gitops/apps/demo-app/
├── gitops/platform/
├── terraform/reference-environment/
├── argocd/
├── observability/
├── ops/smoke/
├── ops/benchmarks/
├── docs/
├── docs/ko/
└── .github/workflows/
```

## 한국어 운영 문서

- [한국어 문서 인덱스](docs/ko/README.md)
- [Multi-signal Observability](docs/ko/20-multi-signal-observability.md)
- [Kubernetes 운영환경 기준](docs/ko/21-kubernetes-operating-environment.md)
- [Cilium / Hubble / eBPF 도입 로드맵](docs/ko/22-cilium-hubble-roadmap.md)
- [Storage / PVC Smoke Runbook](docs/ko/23-storage-smoke-runbook.md)

## Production-readiness 경계

이 프로젝트는 **production-style reference environment**이며 로컬 Kubernetes 자체를 production infrastructure라고 주장하지 않습니다.

아직 남은 핵심 과제:

- policy-gated Terraform + GitOps live loop 검증
- PVC/storage runtime smoke와 saturation scenario
- NetworkPolicy failure scenario
- Cilium/Hubble eBPF evidence 검증
- observability API 인증/인가
- durable/HA telemetry
- 실제 Slack/Teams/on-call integration
- external synthetic monitoring
- 10~20개 failure/evaluation corpus
- 외부 사용자의 재현 증거

목표는 다른 엔지니어가 저장소를 clone한 뒤 장애를 재현하고, Agent가 왜 그렇게 판단했는지 증거를 확인하고, 올바른 control plane으로 승인된 변경을 실행한 뒤 independently verify 또는 rollback할 수 있게 만드는 것입니다.
