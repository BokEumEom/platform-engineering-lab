# Phase 2 — Observability: Prometheus + Grafana + FastAPI metrics

이 단계에서는 지금까지 만든 Kubernetes 플랫폼에 **관측 가능성(Observability)** 을 추가합니다.

목표는 단순히 Grafana 화면을 띄우는 것이 아니라 아래 흐름을 이해하는 것입니다.

```text
FastAPI /metrics
      |
      v
Kubernetes Service
      |
      v
ServiceMonitor
      |
      v
Prometheus Operator
      |
      v
Prometheus
      |
      v
Grafana
```

---

## 1. 왜 kube-prometheus-stack을 사용하는가

`kube-prometheus-stack`은 Kubernetes 모니터링에 자주 함께 사용하는 구성요소를 Helm chart 하나로 묶습니다.

```text
Prometheus Operator
Prometheus
Grafana
kube-state-metrics
node-exporter
ServiceMonitor / PodMonitor CRD
```

이 Lab에서는 로컬 16GB 수준 환경을 고려해 전체 기본값 대신 경량 values를 사용합니다.

```text
observability/kube-prometheus-stack-values.yaml
```

초기 단계에서는 Alertmanager와 로컬 kind에서 불필요하게 DOWN으로 보일 수 있는 일부 control-plane scrape를 끕니다.

---

## 2. FastAPI metrics endpoint

애플리케이션에는 `prometheus-fastapi-instrumentator`를 추가했습니다.

```text
prometheus-fastapi-instrumentator==8.1.0
```

`main.py`에서:

```python
from prometheus_fastapi_instrumentator import Instrumentator

Instrumentator().instrument(app).expose(
    app,
    endpoint="/metrics",
    include_in_schema=False,
)
```

CI/CD가 완료되면 Pod 내부 애플리케이션이 `/metrics` endpoint를 제공합니다.

Gateway를 거치지 않고 먼저 Service 또는 Pod 기준으로 metrics endpoint가 살아 있는지 확인하는 것이 좋습니다.

---

## 3. 먼저 최신 Git 상태 반영

```bash
cd ~/platform-engineering-lab
git pull
```

Argo CD 확인:

```bash
kubectl get applications -n argocd
```

애플리케이션 rollout 확인:

```bash
kubectl rollout status deployment/web -n demo-app
```

---

## 4. Helm repository 추가

Prometheus Community chart repository를 등록합니다.

```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts

helm repo update
```

확인:

```bash
helm search repo prometheus-community/kube-prometheus-stack
```

이 Lab에서 검증 대상으로 고정한 chart version:

```text
90.0.0
```

학습 자료에서는 버전을 명시적으로 고정합니다. 그래야 같은 manifest와 values를 다시 재현하기 쉽습니다.

---

## 5. kube-prometheus-stack 설치

```bash
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  --create-namespace \
  -f observability/kube-prometheus-stack-values.yaml
```

여기서:

```text
monitoring
 -> Helm release 이름

-n monitoring
 -> 설치 namespace

--create-namespace
 -> namespace가 없으면 생성

-f ...values.yaml
 -> 이 Lab용 경량 설정 사용
```

---

## 6. 설치 확인

Helm release:

```bash
helm list -n monitoring
```

Pod:

```bash
kubectl get pods -n monitoring
```

주요 구성요소가 보여야 합니다.

```text
monitoring-grafana
monitoring-kube-prometheus-operator
prometheus-monitoring-kube-prometheus-prometheus-0
monitoring-kube-state-metrics
monitoring-prometheus-node-exporter-...
```

CRD 확인:

```bash
kubectl get crd | grep monitoring.coreos.com
```

주요 CRD:

```text
servicemonitors.monitoring.coreos.com
podmonitors.monitoring.coreos.com
prometheusrules.monitoring.coreos.com
prometheuses.monitoring.coreos.com
```

이 CRD들이 생겼기 때문에 이제 Kubernetes에 `ServiceMonitor`라는 리소스를 만들 수 있습니다.

---

## 7. ServiceMonitor란 무엇인가

Prometheus에 개별 target URL을 직접 설정하지 않고 Kubernetes 리소스로 scrape 대상을 선언합니다.

이 Lab의 `ServiceMonitor`:

```text
observability/demo-app-servicemonitor.yaml
```

핵심:

```yaml
selector:
  matchLabels:
    app: web

endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

즉:

```text
app=web 라벨을 가진 Service를 찾고
Service의 http port로 접근해서
/metrics를 30초마다 scrape
```

합니다.

적용:

```bash
kubectl apply -f observability/demo-app-servicemonitor.yaml
```

확인:

```bash
kubectl get servicemonitor -A
kubectl describe servicemonitor demo-app -n demo-app
```

---

## 8. Prometheus 접속

로컬 port-forward:

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-kube-prometheus-prometheus \
  9090:9090
```

브라우저:

```text
http://localhost:9090
```

Targets 화면:

```text
Status -> Target health
```

또는 PromQL:

```promql
up{namespace="demo-app"}
```

FastAPI request metric 예:

```promql
http_requests_total
```

먼저 애플리케이션에 몇 번 요청을 보내고 다시 조회합니다.

---

## 9. Grafana 접속

Grafana admin password:

```bash
kubectl get secret monitoring-grafana \
  -n monitoring \
  -o jsonpath='{.data.admin-password}' \
  | base64 -d

echo
```

Username:

```text
admin
```

port-forward:

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-grafana \
  3000:80
```

브라우저:

```text
http://localhost:3000
```

Prometheus datasource는 chart가 자동으로 구성합니다.

---

## 10. 처음 확인할 메트릭

### Kubernetes Pod 상태

```promql
kube_pod_status_phase{namespace="demo-app"}
```

### Pod CPU

```promql
rate(container_cpu_usage_seconds_total{namespace="demo-app",container!=""}[5m])
```

### Pod memory

```promql
container_memory_working_set_bytes{namespace="demo-app",container!=""}
```

### FastAPI 요청 수

```promql
rate(http_requests_total[5m])
```

### Target 상태

```promql
up
```

`up = 1`은 Prometheus가 해당 target scrape에 성공하고 있다는 뜻입니다.

---

## 11. 문제 해결 순서

FastAPI metric이 안 보일 때 무작정 Grafana부터 보지 않습니다.

아래 순서로 계층별 확인합니다.

```text
1. Pod Running / Ready?
2. /metrics endpoint 응답?
3. Service label이 app=web인가?
4. Service port name이 http인가?
5. ServiceMonitor selector가 맞는가?
6. Prometheus가 ServiceMonitor를 발견했는가?
7. Prometheus target이 UP인가?
8. PromQL 결과가 있는가?
9. 마지막에 Grafana panel 확인
```

확인 명령:

```bash
kubectl get pods -n demo-app
kubectl get svc web -n demo-app --show-labels
kubectl get servicemonitor -n demo-app
kubectl get pods -n monitoring
```

---

## 12. 왜 아직 Alertmanager를 끄는가

이 단계의 학습 목표는:

```text
metric exposure
 -> discovery
 -> scrape
 -> query
 -> dashboard
```

입니다.

처음부터 Alertmanager, recording rules, tracing까지 한꺼번에 넣으면 문제 발생 시 어느 계층에서 실패했는지 판단하기 어려워집니다.

Prometheus와 Grafana 흐름이 검증된 다음 단계에서 alert rule과 OpenTelemetry를 추가합니다.

---

## 13. 다음 단계

이번 단계 성공 기준:

```text
FastAPI /metrics available
ServiceMonitor discovered
Prometheus target UP
PromQL returns application metrics
Grafana can query Prometheus
```

그 다음:

```text
Envoy Gateway metrics
PrometheusRule
Alertmanager
Grafana application dashboard
OpenTelemetry traces
```
