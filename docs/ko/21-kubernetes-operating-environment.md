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

Storage 운영 계층:

- `storage-probe` StatefulSet
- cluster 기본 StorageClass를 사용하는 1Gi `ReadWriteOnce` PVC
- 정상 기본값 `STORAGE_FILL_MIB=0`
- kube-state-metrics 기반 PVC object metrics
- CSI/kubelet이 지원하는 경우 표준 filesystem/inode volume stats
- 로컬 CSI가 volume stats를 제공하지 않을 때만 사용하는 `storage-probe` fallback metrics
- PVC alert
- Grafana storage dashboard
- storage 전용 smoke test

## PVC / Storage evidence

Object 상태는 kube-state-metrics를 사용합니다.

```text
kube_persistentvolumeclaim_info
kube_persistentvolumeclaim_status_phase
kube_persistentvolumeclaim_resource_requests_storage_bytes
```

표준 filesystem 사용량은 CSI/kubelet volume stats를 최우선으로 사용합니다.

```text
kubelet_volume_stats_capacity_bytes
kubelet_volume_stats_used_bytes
kubelet_volume_stats_available_bytes
kubelet_volume_stats_inodes
kubelet_volume_stats_inodes_used
```

### Docker Desktop local storage의 volume-stats gap

2026-09-15 local runtime 검증에서 다음은 정상 동작했습니다.

```text
StatefulSet/storage-probe      rollout complete
PVC/data-storage-probe-0      Bound / 1Gi
PVC object metrics            present
```

반면 현재 Docker Desktop local storage 경로에서는 다음 series가 반환되지 않았습니다.

```text
kubelet_volume_stats_capacity_bytes = no series
kubelet_volume_stats_used_bytes      = no series
kubelet_volume_stats_available_bytes = no series
```

이 결과는 PVC 장애로 해석하지 않습니다. PVC는 Bound이고 workload도 정상이며, 현재 local storage driver/CSI-kubelet 경로가 volume stats를 제공하지 않는 capability gap입니다.

이를 위해 `storage-probe`는 `/metrics`에서 다음 deterministic fallback을 노출합니다.

```text
storage_probe_fill_bytes
storage_probe_requested_capacity_bytes
storage_probe_usage_ratio
storage_probe_filesystem_capacity_bytes
storage_probe_filesystem_used_bytes
storage_probe_filesystem_available_bytes
```

운영 규칙은 다음과 같습니다.

```text
1. kubelet_volume_stats_*가 있으면 그것을 사용
2. 없으면 local lab에서만 storage_probe_* 사용
3. inode 지표는 synthetic fallback을 만들지 않음
4. fallback을 production CSI volume stats와 동일한 증거라고 주장하지 않음
```

`storage_probe_usage_ratio`는 의도적으로 만든 fill 파일의 논리 크기를 PVC 요청 용량으로 나눈 값입니다. Docker Desktop의 기본 local volume이 PVC 요청 용량을 실제 filesystem quota로 강제하지 않을 수 있으므로, 이 지표는 **재현 가능한 lab saturation signal**이지 실제 CSI filesystem pressure의 완전한 대체물이 아닙니다.

## Storage smoke

```bash
bash ops/smoke/storage.sh
```

Argo CD의 기본 repository reconciliation은 120초 주기에 최대 60초 jitter가 더해질 수 있습니다. 따라서 `git pull` 직후 120초만 기다리는 smoke는 정상 환경에서도 false negative가 될 수 있습니다.

Storage smoke는 현재 로컬 checkout이 `origin/main`과 같은지 먼저 확인하고, 기본 5분의 bounded window 안에서 다음 조건을 기다립니다.

```text
local HEAD == origin/main
AND Argo demo-app.status.sync.revision == origin/main
AND sync.status == Synced
AND health.status == Healthy
AND StatefulSet/demo-app/storage-probe 존재
```

제한 시간 안에 맞지 않으면 다음 진단 정보를 같이 출력합니다.

```text
argocd-cm timeout.reconciliation
argocd-cm timeout.reconciliation.jitter
Application revision / sync / health / reconciledAt
Application conditions
operationState phase / message
```

즉 Git 최신화 문제, Argo repo refresh 지연, 실제 sync 실패를 같은 `StatefulSet NotFound` 오류로 뭉개지 않습니다.

그 다음 metric source를 판별합니다.

```text
kubelet/CSI volume stats 있음
→ metric_source=kubelet_csi

kubelet/CSI volume stats 없음
→ storage_probe_usage_ratio 확인
→ metric_source=storage_probe_fallback
```

둘 다 없을 때만 storage smoke를 실패시킵니다. live PASS 후 storage 검증을 canonical full smoke의 blocking gate로 승격할 수 있습니다.

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

PVC resize를 제안하기 전에는 반드시 `StorageClass.allowVolumeExpansion`을 확인해야 합니다. Local fallback 환경에서 resize를 실제 storage remediation이라고 주장하지 않고, 별도의 CSI-capable environment에서 resize semantics를 검증해야 합니다.

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

- CSI volume stats가 검증된 durable StorageClass
- volume snapshot / backup
- CSI failure scenario
- multi-node volume behavior
- topology / zone constraint
- 실제 online expansion 검증
- external alert delivery
- observability API authentication / authorization
- 더 넓은 failure/evaluation corpus
