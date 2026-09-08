# Phase 2 — Alerting with PrometheusRule + Alertmanager

이 단계에서는 이미 수집 중인 메트릭을 **자동 감지 가능한 운영 신호**로 바꿉니다.

```text
Metrics
  |
  v
Prometheus
  |
  +-- query
  +-- alert rule evaluation
          |
          v
     PrometheusRule
          |
     Pending -> Firing
          |
          v
      Alertmanager
```

처음에는 Slack이나 이메일을 붙이지 않습니다. Alertmanager UI에서 alert lifecycle과 routing을 이해하는 데 집중합니다.

---

## 1. PrometheusRule이란

`PrometheusRule`은 Prometheus Operator가 제공하는 CRD입니다.

일반 PromQL을 주기적으로 평가해 조건이 일정 시간 이상 참이면 alert를 발생시킵니다.

예:

```yaml
- alert: DemoAppHighP95Latency
  expr: <PromQL expression> > 0.5
  for: 2m
```

의미:

```text
조건이 순간적으로 참
 -> Pending

2분 동안 계속 참
 -> Firing
```

`for`는 짧은 순간의 spike 때문에 바로 경보가 발생하는 것을 줄이는 역할을 합니다.

---

## 2. 이 Lab의 Alert 정책

파일:

```text
observability/platform-alerts.yaml
```

현재 rule은 네 개입니다.

### DemoAppMetricsTargetDown

```text
조건: demo-app scrape target이 DOWN 또는 사라짐
지속: 2분
severity: critical
```

### DemoAppHigh5xxRate

```text
조건: HTTP 5xx 비율 > 5%
window: 5분 rate
지속: 2분
severity: warning
```

`/metrics` 요청은 실제 사용자 traffic이 아니므로 계산에서 제외합니다.

### DemoAppHighP95Latency

```text
조건: P95 > 500ms
window: 5분 histogram
지속: 2분
severity: warning
```

### EnvoyProxyDown

```text
조건: envoy_server_live가 없거나 1 미만
지속: 2분
severity: critical
```

---

## 3. Alertmanager를 처음에는 null receiver로 사용하는 이유

이 단계에서는 외부 webhook, Slack token, email password 같은 secret을 저장하지 않습니다.

Alertmanager 설정:

```yaml
route:
  receiver: "null"

receivers:
  - name: "null"
```

이렇게 해도 Prometheus에서 발생한 alert는 Alertmanager에 전달되고 UI에서 확인할 수 있습니다.

학습 순서:

```text
Rule 작성
 -> Prometheus rule load
 -> Pending
 -> Firing
 -> Alertmanager receive
 -> resolve
 -> 그 다음 notification integration
```

---

## 4. Helm values 반영

최신 Git 상태:

```bash
cd ~/platform-engineering-lab
git pull
```

Alertmanager가 포함된 values를 적용합니다.

```bash
helm upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  -f observability/kube-prometheus-stack-values.yaml
```

확인:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring | grep alertmanager
```

Alertmanager Pod가 Running이어야 합니다.

---

## 5. PrometheusRule 적용

```bash
kubectl apply -f observability/platform-alerts.yaml
```

확인:

```bash
kubectl get prometheusrule -A
kubectl describe prometheusrule platform-lab-alerts -n monitoring
```

Prometheus가 rule을 선택하도록 Helm values에는 다음을 명시했습니다.

```yaml
ruleSelectorNilUsesHelmValues: false
ruleSelector: {}
ruleNamespaceSelector: {}
```

이 Lab에서는 Helm release label에 종속되지 않고 별도의 `PrometheusRule`을 발견하게 합니다.

---

## 6. Prometheus에서 rule 확인

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

Prometheus UI에서:

```text
Alerts
```

또는 PromQL:

```promql
ALERTS{alertstate="firing"}
```

아무 장애가 없다면 결과가 비어 있어도 정상입니다.

---

## 7. Alertmanager UI 확인

Alertmanager Service 이름 확인:

```bash
kubectl get svc -n monitoring | grep alertmanager
```

기본 release 이름 기준:

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-kube-prometheus-alertmanager \
  9093:9093
```

브라우저:

```text
http://localhost:9093
```

정상 상태에서는 active alert가 없을 수 있습니다.

---

## 8. 실제 TargetDown alert를 안전하게 테스트하기

애플리케이션 traffic을 끊지 않고 Prometheus scrape만 실패시키는 방법을 사용합니다.

현재 ServiceMonitor 백업:

```bash
kubectl get servicemonitor demo-app \
  -n demo-app \
  -o yaml > /tmp/demo-app-servicemonitor.yaml
```

metrics path를 의도적으로 잘못 바꿉니다.

```bash
kubectl patch servicemonitor demo-app \
  -n demo-app \
  --type='json' \
  -p='[
    {
      "op":"replace",
      "path":"/spec/endpoints/0/path",
      "value":"/metrics-broken"
    }
  ]'
```

Prometheus에서:

```promql
up{namespace="demo-app"}
```

`0`으로 내려가는지 확인합니다.

Rule은 `for: 2m`이므로 상태 변화는:

```text
Inactive
 -> Pending
 -> Firing
```

순서가 됩니다.

Prometheus에서:

```promql
ALERTS{alertname="DemoAppMetricsTargetDown"}
```

Alertmanager UI에서도 active alert가 보이는지 확인합니다.

---

## 9. 테스트 복구

테스트 후 반드시 Git의 정상 manifest로 되돌립니다.

```bash
kubectl apply -f observability/demo-app-servicemonitor.yaml
```

다시:

```promql
up{namespace="demo-app"}
```

목표:

```text
1
```

Alert도 잠시 후 resolved 상태가 됩니다.

중요:

```text
장애 유도
 -> Alert firing 확인
 -> 정상 설정 복구
 -> Alert resolved 확인
```

까지 해야 alert pipeline 전체를 검증한 것입니다.

---

## 10. Alert rule을 만들 때 주의할 점

### 너무 민감한 threshold

작은 local lab에서는 요청 수 자체가 적습니다.

한두 번의 오류만으로 비율이 크게 변할 수 있으므로 production threshold와 동일하게 생각하면 안 됩니다.

### `for`가 없는 alert

순간적인 spike도 바로 Firing이 됩니다.

운영에서는 사용자 영향과 신호 특성에 따라 지속 시간을 정합니다.

### metric이 없어지는 경우

단순히:

```promql
up == 0
```

만 사용하면 target 자체가 discovery에서 사라졌을 때 series도 없어져 alert가 발생하지 않을 수 있습니다.

그래서 이 Lab에서는 `absent()`도 함께 사용합니다.

### 실제 traffic과 scrape traffic

Prometheus가 `/metrics`를 계속 호출하기 때문에 application request metric에는 scrape traffic도 들어갑니다.

5xx와 latency alert에서는 가능한 경우:

```promql
handler!="/metrics"
```

로 제외합니다.

---

## 11. 이번 단계 성공 기준

```text
Alertmanager Running
PrometheusRule loaded
TargetDown 테스트 시 Pending 확인
2분 후 Firing 확인
Alertmanager UI에서 alert 확인
ServiceMonitor 복구 후 Resolved 확인
```

---

## 12. 다음 단계

이제 metric 기반 운영 루프는 다음 수준까지 왔습니다.

```text
Expose
 -> Scrape
 -> Query
 -> Dashboard
 -> Alert
```

다음 단계는 **OpenTelemetry tracing**입니다.

```text
Client request
  -> Envoy Gateway
  -> FastAPI
  -> Trace / span
  -> OpenTelemetry Collector
```

Metrics가 "무슨 문제가 발생했는가"를 보여준다면 trace는 "요청이 어디에서 시간을 소비했는가"를 추적하는 데 도움을 줍니다.
