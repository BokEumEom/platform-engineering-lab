# Kubernetes 운영환경 기준

[English](../21-kubernetes-operating-environment.md) | **한국어**

이 프로젝트는 Cilium이나 Service Mesh를 먼저 추가하기보다 **Kubernetes 운영환경을 먼저 완성**합니다.

## 완료 순서

```text
workload lifecycle
→ autoscaling / quota
→ storage / PVC
→ NetworkPolicy
→ observability
→ incident / recovery scenario
→ eBPF / Hubble
→ optional Service Mesh
```

목표는 설치한 컴포넌트 수를 늘리는 것이 아니라, 각 계층이 Infrastructure Engineering Harness에 재현 가능한 운영 증거를 제공하도록 만드는 것입니다.

## 현재 baseline

이미 live verified 된 항목:

- 6개 독립 application service
- Argo CD GitOps reconciliation
- MetalLB + Envoy Gateway + Gateway API
- HPA / PDB
- Terraform-owned ResourceQuota foundation
- Prometheus / Grafana / Alertmanager
- Loki / Alloy
- OpenTelemetry Collector / Tempo
- metric → log → exact trace correlation
- GitOps fault/recovery benchmark 1건

이번에 storage 운영 계층으로 추가한 항목:

- `storage-probe` StatefulSet
- cluster 기본 StorageClass를 사용하는 1Gi `ReadWriteOnce` PVC
- 정상 기본값 `STORAGE_FILL_MIB=0`
- kube-state-metrics 기반 PVC object metrics
- kubelet/CSI가 지원하는 경우 filesystem/inode volume stats
- PVC alert
- Grafana storage dashboard
- storage 전용 smoke test

## PVC / Storage evidence

Object 상태:

```text
kube_persistentvolumeclaim_info
kube_persistentvolumeclaim_status_phase
kube_persistentvolumeclaim_resource_requests_storage_bytes
```

Filesystem 사용량:

```text
kubelet_volume_stats_capacity_bytes
kubelet_volume_stats_used_bytes
kubelet_volume_stats_available_bytes
kubelet_volume_stats_inodes
kubelet_volume_stats_inodes_used
```

검증:

```bash
bash ops/smoke/storage.sh
```

현재 local CSI/kubelet이 `kubelet_volume_stats_*`를 실제로 노출하는지 확인하기 전까지 storage smoke는 full smoke와 분리합니다. live PASS가 확인되면 canonical full smoke의 blocking gate로 승격합니다.

## Storage scenario 방향

향후 storage saturation benchmark는 `storage-probe`만 의도적으로 변경합니다.

```text
healthy PVC
→ GitOps로 STORAGE_FILL_MIB 증가
→ usage 80% / 90% 초과
→ Prometheus + Kubernetes evidence
→ Agent storage diagnosis
→ resize / remediation proposal
→ policy / approval
→ owning control plane으로 실행
→ post-check
→ rollback / truncate
```

PVC resize를 제안하기 전에는 반드시 `StorageClass.allowVolumeExpansion`을 확인해야 합니다.

## eBPF 이전 Network baseline

CNI를 바꾸기 전에 현재 dataplane에서 deterministic NetworkPolicy scenario를 먼저 확보합니다. 그래야 Cilium/Hubble 도입 전후의 Agent root-cause localization 개선을 비교할 수 있습니다.

필수 scenario:

- service-to-service deny
- DNS deny / failure
- allowed egress regression
- Gateway → backend reachability failure
- policy rollback

## Production-style 경계

이 환경은 local reference environment입니다. Production storage 운영까지 주장하려면 다음이 더 필요합니다.

- durable StorageClass
- volume snapshot / backup
- CSI failure scenario
- multi-node volume behavior
- topology / zone constraint
- external alert delivery
- observability API authentication / authorization
- 더 넓은 failure/evaluation corpus
