# Storage / PVC Smoke Runbook

이 문서는 `ops/smoke/storage.sh`의 로컬 실행과 실패 해석을 위한 한국어 runbook입니다.

## 검증 대상

```text
Git / Argo reconciliation
→ StatefulSet/storage-probe
→ PVC Bound
→ kube-state-metrics PVC object metrics
→ CSI/kubelet volume stats
→ local fallback metrics
```

## Namespace 계약

`storage-probe` workload와 PVC는 `demo-app` namespace에 있습니다.

```text
StatefulSet/storage-probe       namespace=demo-app
Service/storage-probe           namespace=demo-app
PVC/data-storage-probe-0        namespace=demo-app
ServiceMonitor/storage-probe    namespace=demo-app
```

`ServiceMonitor`는 Prometheus가 위치한 `monitoring` namespace가 아니라 **scrape 대상 Service와 같은 `demo-app` namespace**에 있습니다. `observability-config` Argo Application이 이 manifest를 관리하지만 `metadata.namespace`가 명시되어 있으므로 실제 resource 위치는 `demo-app`입니다.

Smoke도 같은 계약을 사용합니다.

```bash
kubectl get servicemonitor storage-probe -n demo-app
```

## 정상 실행

```bash
cd ~/platform-engineering-lab
git pull
bash ops/smoke/storage.sh
```

성공 예시는 다음과 같습니다.

```text
Argo CD storage reconciliation
  ... statefulset=yes
  ... servicemonitor=yes namespace=demo-app

Stateful storage workload
  pvc=data-storage-probe-0 phase=Bound capacity=1Gi

PVC object metrics through Prometheus
  pvc_info_series=1 requested_capacity_series=1

PVC filesystem usage metrics
  kubelet capacity_series=0 used_series=0 available_series=0
  standard kubelet/CSI volume stats unavailable; trying deterministic storage-probe fallback
  fallback poll 1/12: storage_probe_usage_ratio series=1
  metric_source=storage_probe_fallback usage_ratio=0

PVC STORAGE SMOKE PASS
```

## 실패 분류

```text
StatefulSet 없음
→ demo-app GitOps/Argo reconciliation 확인

PVC Pending
→ StorageClass / provisioner / Pod event 확인

PVC object metrics 없음
→ kube-state-metrics / Prometheus scrape 확인

kubelet_volume_stats_* 없음
→ 현재 Docker Desktop local storage에서는 capability gap일 수 있음
→ storage_probe_* fallback 확인

ServiceMonitor 없음
→ 반드시 demo-app namespace에서 확인

storage_probe_usage_ratio 없음
→ storage-probe rollout / Service / ServiceMonitor / Prometheus target 확인
```

## Production 경계

`storage_probe_usage_ratio`는 로컬 reference environment에서 재현 가능한 saturation signal입니다. 실제 production CSI filesystem pressure와 동일한 증거로 취급하지 않습니다. Production storage 검증에는 CSI volume stats, durable StorageClass, snapshot/backup, online expansion, topology/multi-node behavior가 별도로 필요합니다.
