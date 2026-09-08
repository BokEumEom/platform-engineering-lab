# Phase 6 — OpenTelemetry Tracing

이 단계에서는 Metrics 다음으로 **Distributed Tracing**을 추가합니다.

목표는 다음 흐름을 직접 확인하는 것입니다.

```text
FastAPI
  |
  | OTLP/gRPC
  v
OpenTelemetry Collector
  |
  | OTLP/gRPC
  v
Grafana Tempo
  |
  v
Grafana Explore
```

Metrics가 "무슨 일이 일어났는가"를 알려준다면, Trace는 "요청 하나가 어디를 지나고 어디에서 시간을 썼는가"를 보여줍니다.

---

## 1. 왜 Tempo single-binary를 사용하는가

현재 Tempo 3.x distributed mode는 Kafka-compatible broker와 object storage를 요구합니다.

이 Lab은 로컬 Docker Desktop / kind 환경이므로 microservices mode보다 single-binary mode가 적합합니다.

사용 버전:

```text
Grafana Community tempo chart: 2.3.0
Tempo: 2.10.8
```

Tempo 2.10.x는 현재 유지보수 대상이며, 로컬 tracing 학습에는 충분합니다.

설정 파일:

```text
observability/tempo-values.yaml
```

Lab에서는:

```text
replica: 1
retention: 6h
persistence: disabled
local trace storage
memory ballast: disabled
memory limit: 512Mi
```

로 구성합니다.

---

## 2. 왜 OpenTelemetry Collector를 중간에 두는가

애플리케이션이 Tempo로 직접 trace를 보낼 수도 있지만 실제 플랫폼에서는 Collector를 중간 계층으로 두는 패턴이 유용합니다.

```text
Application
   |
   v
Collector
   |
   +--> Tempo
   +--> 다른 tracing backend
   +--> sampling / filtering / enrichment
```

애플리케이션은 backend 구현을 알 필요 없이 OTLP endpoint만 바라봅니다.

사용 버전:

```text
OpenTelemetry Collector Helm chart: 0.172.1
Collector: 0.159.0
```

설정 파일:

```text
observability/otel-collector-values.yaml
```

---

## 3. FastAPI instrumentation

FastAPI에는 다음 패키지를 추가했습니다.

```text
opentelemetry-sdk==1.44.0
opentelemetry-exporter-otlp-proto-grpc==1.44.0
opentelemetry-instrumentation-fastapi==0.65b0
```

Tracing endpoint가 환경변수로 주어졌을 때만 SDK를 활성화합니다.

```text
OTEL_EXPORTER_OTLP_ENDPOINT
```

따라서 개발자가 로컬에서 단순히 FastAPI를 실행하는 경우 Collector가 없어도 애플리케이션 자체는 정상 실행할 수 있습니다.

Kubernetes Deployment에서는:

```yaml
- name: OTEL_SERVICE_NAME
  value: "platform-api"
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.monitoring.svc.cluster.local:4317"
- name: OTEL_EXPORTER_OTLP_INSECURE
  value: "true"
```

를 사용합니다.

`/metrics`와 Kubernetes health probe 요청은 tracing에서 제외합니다.

이렇게 하지 않으면 5초/10초마다 실행되는 probe가 trace를 계속 생성하여 실제 사용자 요청을 보기 어렵게 만듭니다.

---

# 설치

## 4. 최신 Git 상태 가져오기

```bash
cd ~/platform-engineering-lab
git pull
```

FastAPI 새 이미지 배포 상태도 확인합니다.

```bash
kubectl get applications -n argocd
kubectl rollout status deployment/web -n demo-app
```

---

## 5. Grafana Community Helm repository 추가

```bash
helm repo add grafana-community \
  https://grafana-community.github.io/helm-charts

helm repo update
```

확인:

```bash
helm search repo grafana-community/tempo
```

Lab에서는 chart version을 고정합니다.

```text
2.3.0
```

---

## 6. Tempo 설치

```bash
helm upgrade --install tempo \
  grafana-community/tempo \
  --version 2.3.0 \
  -n monitoring \
  -f observability/tempo-values.yaml
```

확인:

```bash
helm list -n monitoring
kubectl get pods -n monitoring | grep tempo
kubectl get svc -n monitoring | grep tempo
```

Tempo Pod가 `Running` 상태가 되어야 합니다.

Readiness 확인:

```bash
kubectl port-forward \
  -n monitoring \
  svc/tempo \
  3200:3200
```

다른 터미널:

```bash
curl http://localhost:3200/ready
```

정상이면:

```text
ready
```

응답을 확인할 수 있습니다.

---

## 7. OpenTelemetry Helm repository 추가

```bash
helm repo add open-telemetry \
  https://open-telemetry.github.io/opentelemetry-helm-charts

helm repo update
```

확인:

```bash
helm search repo open-telemetry/opentelemetry-collector
```

Lab에서 사용하는 chart version:

```text
0.172.1
```

---

## 8. OpenTelemetry Collector 설치

Tempo가 먼저 준비된 후 Collector를 설치합니다.

```bash
helm upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector \
  --version 0.172.1 \
  -n monitoring \
  -f observability/otel-collector-values.yaml
```

확인:

```bash
helm list -n monitoring
kubectl get pods -n monitoring | grep otel-collector
kubectl get svc -n monitoring | grep otel-collector
```

Collector Service에는 최소 다음 OTLP port가 있어야 합니다.

```text
4317  OTLP/gRPC
4318  OTLP/HTTP
```

---

## 9. Collector pipeline 이해하기

이번 Lab의 pipeline은 매우 단순합니다.

```yaml
receivers:
  otlp:

processors:
  memory_limiter:
  batch:

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring.svc.cluster.local:4317

service:
  pipelines:
    traces:
      receivers:
        - otlp
      processors:
        - memory_limiter
        - batch
      exporters:
        - otlp/tempo
```

데이터 흐름은:

```text
OTLP Receiver
   |
Memory Limiter
   |
Batch Processor
   |
OTLP Tempo Exporter
```

입니다.

Collector 로그 확인:

```bash
kubectl logs \
  -n monitoring \
  deployment/otel-collector \
  --tail=100
```

---

## 10. Grafana에 Tempo datasource 추가

`kube-prometheus-stack-values.yaml`에 Tempo datasource가 선언되어 있습니다.

```yaml
additionalDataSources:
  - name: Tempo
    uid: tempo
    type: tempo
    url: http://tempo.monitoring.svc.cluster.local:3200
```

Helm release를 갱신합니다.

```bash
helm upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 90.0.0 \
  -n monitoring \
  -f observability/kube-prometheus-stack-values.yaml
```

Grafana rollout:

```bash
kubectl rollout status \
  deployment/monitoring-grafana \
  -n monitoring
```

Grafana가 이전 Lab에서 OOMKilled 되었기 때문에 현재 memory limit은 `512Mi`로 유지합니다.

---

# Trace 검증

## 11. FastAPI Deployment 환경변수 확인

```bash
kubectl get deployment web \
  -n demo-app \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
```

다음이 보여야 합니다.

```text
OTEL_SERVICE_NAME=platform-api
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_INSECURE=true
```

---

## 12. 테스트 요청 발생

Gateway IP를 가져옵니다.

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')
```

요청을 보냅니다.

```bash
for i in {1..20}; do
  curl -s \
    -H "Host: web.lab.local" \
    "http://${GATEWAY_IP}/" >/dev/null
  sleep 0.2
done
```

---

## 13. 애플리케이션 exporter 오류 확인

```bash
kubectl logs \
  -n demo-app \
  deployment/web \
  --tail=100
```

정상 상태라면 지속적인 OTLP connection error가 없어야 합니다.

Collector 로그도 확인합니다.

```bash
kubectl logs \
  -n monitoring \
  deployment/otel-collector \
  --tail=100
```

---

## 14. Grafana에서 Trace 확인

Grafana port-forward:

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-grafana \
  3000:80
```

접속:

```text
http://localhost:3000
```

Grafana에서:

```text
Explore
  -> Tempo datasource
  -> Search
```

Service Name에서:

```text
platform-api
```

를 찾습니다.

Trace가 보이면 하나를 열어 다음 정보를 확인합니다.

```text
Trace ID
Span ID
service.name
HTTP method
HTTP route
status code
span duration
```

---

## 15. Tempo API로 직접 확인

Grafana가 아니라 Tempo 자체를 먼저 확인하고 싶다면:

```bash
kubectl port-forward \
  -n monitoring \
  svc/tempo \
  3200:3200
```

Trace search API 예:

```bash
curl -s \
  'http://localhost:3200/api/search?tags=resource.service.name%3Dplatform-api'
```

Grafana에 데이터가 안 보일 때는 항상 아래 순서로 확인합니다.

```text
FastAPI span 생성
   ↓
Collector 수신
   ↓
Collector -> Tempo export
   ↓
Tempo 저장
   ↓
Grafana datasource query
```

---

# Troubleshooting

## 16. Collector가 시작하지 않는 경우

```bash
kubectl describe pod \
  -n monitoring \
  -l app.kubernetes.io/name=opentelemetry-collector

kubectl logs \
  -n monitoring \
  deployment/otel-collector \
  --tail=200
```

Collector 설정은 startup 시 validation되기 때문에 잘못된 receiver/exporter 이름이 있으면 Pod가 바로 실패할 수 있습니다.

---

## 17. FastAPI에서 connection refused가 발생하는 경우

먼저 Service를 확인합니다.

```bash
kubectl get svc otel-collector -n monitoring
```

DNS:

```text
otel-collector.monitoring.svc.cluster.local
```

Port:

```text
4317
```

Collector endpoint가 존재하지 않는 동안에도 FastAPI HTTP 요청 자체는 동작하지만 trace export는 실패할 수 있습니다.

---

## 18. Tempo에 trace가 없는 경우

Collector -> Tempo 연결부터 확인합니다.

```bash
kubectl logs \
  -n monitoring \
  deployment/otel-collector \
  | grep -i -E 'error|tempo|otlp'
```

Tempo 상태:

```bash
kubectl get pods -n monitoring | grep tempo
kubectl logs -n monitoring statefulset/tempo --tail=100
```

---

# 이번 단계의 성공 기준

```text
Tempo Running
OpenTelemetry Collector Running
Collector OTLP port 4317 available
FastAPI OTEL env configured
FastAPI requests create traces
Tempo stores traces
Grafana Tempo datasource works
platform-api trace visible in Explore
```

여기까지 확인한 후 다음 단계에서 Envoy Gateway에도 tracing을 활성화합니다.

최종 목표:

```text
Client
  |
  v
Envoy Gateway span
  |
  v
FastAPI span
  |
  v
OpenTelemetry Collector
  |
  v
Tempo
  |
  v
Grafana Trace View
```

이 단계가 완료되면 동일한 요청의 Gateway span과 application span이 하나의 trace context로 연결되는지 확인합니다.
