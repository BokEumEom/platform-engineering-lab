# Phase 3 — Grafana Dashboard as Code

이 단계에서는 Grafana UI에서 패널을 하나씩 수동 생성하지 않고, 대시보드를 Kubernetes `ConfigMap`으로 Git에 저장해 자동 로드합니다.

목표 흐름:

```text
Git
  |
  v
ConfigMap (grafana_dashboard=1)
  |
  v
Grafana dashboard sidecar
  |
  v
Grafana
```

---

## 1. 왜 Dashboard as Code인가

UI에서만 만든 dashboard는 재현과 변경 이력 관리가 어렵습니다.

Git에 dashboard 정의를 두면 다음이 가능합니다.

```text
version control
review
environment reproduction
rollback
change history
```

이 Lab에서는 다음 파일을 사용합니다.

```text
observability/demo-app-dashboard.yaml
```

---

## 2. Grafana sidecar

`kube-prometheus-stack-values.yaml`에서 dashboard sidecar를 명시적으로 활성화합니다.

```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: monitoring
```

sidecar는 `monitoring` namespace에서 다음 label을 가진 ConfigMap을 찾습니다.

```yaml
labels:
  grafana_dashboard: "1"
```

---

## 3. Helm release 업데이트

Git의 values 변경을 로컬 Helm release에 반영합니다.

```bash
cd ~/platform-engineering-lab
git pull

helm upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  -f observability/kube-prometheus-stack-values.yaml
```

확인:

```bash
helm list -n monitoring
kubectl rollout status deployment/monitoring-grafana -n monitoring
```

---

## 4. Dashboard ConfigMap 적용

```bash
kubectl apply -f observability/demo-app-dashboard.yaml
```

확인:

```bash
kubectl get configmap demo-app-grafana-dashboard \
  -n monitoring \
  --show-labels
```

`grafana_dashboard=1`이 보여야 합니다.

---

## 5. Grafana에서 확인

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-grafana \
  3000:80
```

Grafana에서 dashboard 검색:

```text
Platform Lab - Demo App
```

대시보드는 다음 6개 패널을 포함합니다.

```text
Request Rate
HTTP 5xx Rate
P95 Latency
Ready Pods
Pod CPU
Pod Memory
```

---

## 6. 주요 PromQL

### Request Rate

```promql
sum(rate(http_requests_total{namespace="demo-app"}[5m]))
```

### HTTP 5xx 비율

```promql
100 *
sum(rate(http_requests_total{namespace="demo-app",status=~"5.."}[5m]))
/
clamp_min(
  sum(rate(http_requests_total{namespace="demo-app"}[5m])),
  0.001
)
```

### P95 latency

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m])
  )
)
```

### Ready Pods

```promql
sum(
  kube_pod_status_ready{
    namespace="demo-app",
    condition="true"
  } == 1
)
```

### Pod CPU

```promql
sum by (pod) (
  rate(
    container_cpu_usage_seconds_total{
      namespace="demo-app",
      container="api"
    }[5m]
  )
)
```

### Pod Memory

```promql
sum by (pod) (
  container_memory_working_set_bytes{
    namespace="demo-app",
    container="api"
  }
)
```

---

## 7. 테스트 트래픽 만들기

대시보드가 비어 있다면 애플리케이션에 요청을 발생시킵니다.

Gateway IP 확인:

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "$GATEWAY_IP"
```

요청 생성:

```bash
for i in {1..300}; do
  curl -s \
    -H "Host: web.lab.local" \
    "http://${GATEWAY_IP}/" >/dev/null
done
```

그 다음 Grafana에서 최근 5~30분 범위로 확인합니다.

---

## 8. 문제 해결

Dashboard가 보이지 않으면:

```bash
kubectl get configmap demo-app-grafana-dashboard \
  -n monitoring \
  --show-labels

kubectl get pods -n monitoring | grep grafana
```

Grafana sidecar log 확인:

```bash
GRAFANA_POD=$(kubectl get pod -n monitoring \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}')

kubectl logs -n monitoring "$GRAFANA_POD" \
  -c grafana-sc-dashboard
```

Panel은 보이지만 `No data`라면 Grafana 문제가 아니라 먼저 Prometheus query 자체를 확인합니다.

```text
Prometheus query returns data?
       |
       +-- No  -> scrape / metric / label 문제
       |
       +-- Yes -> Grafana datasource / dashboard 문제
```

---

## 9. 학습 포인트

이번 단계의 핵심은 Grafana UI 사용법보다 다음 운영 원칙입니다.

```text
Observability configuration도 code로 관리한다.
```

애플리케이션 코드, Kubernetes manifest, CI/CD뿐 아니라 dashboard와 이후 alert rule까지 Git에서 추적할 수 있어야 합니다.

다음 단계에서는 **Envoy Gateway metrics**를 Prometheus에 연결해 application layer와 ingress/gateway layer를 함께 비교합니다.
