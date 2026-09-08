# Phase 4 — Envoy Gateway Metrics

이 단계에서는 애플리케이션 내부 메트릭뿐 아니라 **Gateway 계층의 메트릭**을 수집합니다.

목표는 같은 요청을 두 관점에서 비교하는 것입니다.

```text
Client
  |
  v
Envoy Gateway
  |  envoy_http_* metrics
  v
FastAPI
  |  http_requests_total / request duration
  v
Application
```

## 1. 왜 Gateway metrics가 필요한가

FastAPI 메트릭만 보면 애플리케이션 내부에서 처리된 요청은 보이지만, 애플리케이션에 도달하기 전에 Gateway에서 실패하거나 지연된 요청은 구분하기 어렵습니다.

따라서 다음 두 계층을 같이 봅니다.

```text
Gateway RPS / 5xx / latency
Application RPS / 5xx / latency
```

두 값의 차이가 커지면 어느 계층에서 문제가 생겼는지 판단하는 데 도움이 됩니다.

---

## 2. Envoy Proxy metrics endpoint

Envoy Gateway가 생성하는 Envoy Proxy Pod는 Prometheus 형식의 메트릭을 노출합니다.

기본 endpoint:

```text
port: metrics
path: /stats/prometheus
```

먼저 Proxy Pod를 확인합니다.

```bash
kubectl get pods -n envoy-gateway-system \
  -l app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy \
  -o wide
```

직접 메트릭을 확인하려면:

```bash
ENVOY_POD=$(kubectl get pods -n envoy-gateway-system \
  -l app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[0].metadata.name}')

kubectl port-forward \
  -n envoy-gateway-system \
  pod/${ENVOY_POD} \
  19001:19001
```

다른 터미널:

```bash
curl -s http://localhost:19001/stats/prometheus \
  | grep '^envoy_http_' \
  | head -30
```

---

## 3. PodMonitor

이미 `kube-prometheus-stack`으로 Prometheus Operator를 사용하고 있으므로 Envoy Gateway용 Prometheus를 별도로 설치하지 않습니다.

Repository manifest:

```text
observability/envoy-proxy-podmonitor.yaml
```

핵심 selector:

```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: envoy
    app.kubernetes.io/component: proxy
```

scrape endpoint:

```yaml
podMetricsEndpoints:
  - port: metrics
    path: /stats/prometheus
    interval: 15s
```

적용:

```bash
kubectl apply -f observability/envoy-proxy-podmonitor.yaml
```

확인:

```bash
kubectl get podmonitor -A
kubectl describe podmonitor envoy-gateway-proxy -n monitoring
```

---

## 4. Prometheus가 PodMonitor를 발견하도록 설정

`kube-prometheus-stack-values.yaml`에는 다음 설정을 추가했습니다.

```yaml
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorNamespaceSelector: {}
```

values 변경 반영:

```bash
helm upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  -f observability/kube-prometheus-stack-values.yaml
```

Prometheus rollout 확인:

```bash
kubectl rollout status \
  statefulset/prometheus-monitoring-kube-prometheus-prometheus \
  -n monitoring
```

---

## 5. Prometheus 검증

Prometheus 접속:

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-kube-prometheus-prometheus \
  9090:9090
```

먼저 Envoy target 자체가 수집되는지 확인합니다.

```promql
envoy_server_live
```

정상적으로 수집되면 값이 `1`인 Envoy Proxy series가 보입니다.

Request rate:

```promql
sum(rate(envoy_http_downstream_rq_total[5m]))
```

Active requests:

```promql
sum(envoy_http_downstream_rq_active)
```

P95 latency:

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(envoy_http_downstream_rq_time_bucket[5m])
  )
)
```

Envoy histogram의 downstream request time은 millisecond 단위이므로 application metric과 seconds 단위로 비교할 때 `/ 1000`을 사용합니다.

---

## 6. Gateway vs Application 비교

Repository dashboard:

```text
observability/envoy-gateway-dashboard.yaml
```

적용:

```bash
kubectl apply -f observability/envoy-gateway-dashboard.yaml
```

Grafana Dashboard:

```text
Platform Lab - Envoy Gateway
```

주요 패널:

```text
Request Rate — Gateway vs Application
P95 Latency — Gateway vs Application
5xx Rate — Gateway vs Application
Envoy Active Requests
Envoy Live Proxies
```

---

## 7. 테스트 트래픽

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

for i in {1..500}; do
  curl -s \
    -H 'Host: web.lab.local' \
    "http://${GATEWAY_IP}/" >/dev/null
done
```

Grafana에서 Gateway와 FastAPI RPS가 비슷하게 움직이는지 확인합니다.

완전히 동일할 필요는 없습니다. scrape 시점과 계측 위치가 다르기 때문입니다.

---

## 8. 문제 해결 순서

Envoy metric이 안 보이면 다음 순서로 확인합니다.

```text
1. Envoy Proxy Pod가 Running인가?
2. Proxy Pod에 metrics port가 있는가?
3. /stats/prometheus가 직접 응답하는가?
4. Pod label이 PodMonitor selector와 일치하는가?
5. PodMonitor가 생성됐는가?
6. Prometheus가 PodMonitor를 선택하도록 설정됐는가?
7. Prometheus에서 envoy_server_live가 조회되는가?
8. 마지막에 Grafana dashboard를 확인한다.
```

명령:

```bash
kubectl get pods -n envoy-gateway-system --show-labels
kubectl get podmonitor envoy-gateway-proxy -n monitoring -o yaml
kubectl get prometheus -n monitoring -o yaml
```

---

## 9. 학습 포인트

```text
ServiceMonitor
 -> Kubernetes Service 기반 scrape discovery

PodMonitor
 -> Pod 자체 기반 scrape discovery
```

FastAPI는 안정적인 Service endpoint가 있으므로 ServiceMonitor를 사용했고, Envoy Proxy는 각 Proxy Pod의 admin metrics port를 직접 수집하므로 PodMonitor를 사용했습니다.

이 차이를 이해하는 것이 이번 단계의 핵심입니다.

다음 단계에서는 `PrometheusRule`과 Alertmanager를 추가해 단순히 "보는 것"에서 "이상 상태를 감지하는 것"으로 확장합니다.
