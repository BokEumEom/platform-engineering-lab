# Phase 7 — Envoy Gateway + FastAPI Distributed Trace

이 단계에서는 이미 검증된 FastAPI tracing에 Envoy Gateway span을 추가합니다.

목표:

```text
Client
  |
  v
Envoy Gateway span
  |
  | W3C trace context propagation
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
Grafana
```

하나의 HTTP 요청이 Gateway와 Application에서 같은 Trace ID로 이어지는지 확인합니다.

---

## 1. 이전 단계에서 이미 검증한 것

FastAPI -> Collector -> Tempo 구간은 실제 trace로 검증했습니다.

Collector debug exporter에서:

```text
service.name: platform-api
Trace ID: a01a031f99d9b9db8cb317dbf976ff82
```

Collector internal metric:

```text
otelcol_exporter_sent_spans{exporter="otlp_grpc/tempo",...} 10
```

Tempo Trace ID direct lookup에서도 `platform-api`, `GET /`, HTTP 200 span이 반환되었습니다.

따라서 다음 구간은 새로 확인할 필요가 없습니다.

```text
FastAPI -> Collector -> Tempo = verified
```

이번 단계의 새로운 검증 대상은:

```text
Envoy Gateway -> Collector
Trace context -> FastAPI
```

입니다.

---

## 2. Envoy Gateway tracing 구성

Envoy Gateway v1.9.1에서는 `EnvoyProxy.spec.telemetry.tracing`으로 proxy tracing을 구성합니다.

파일:

```text
gitops/platform/envoyproxy.yaml
```

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: platform-envoy-proxy
  namespace: envoy-gateway-system
spec:
  telemetry:
    tracing:
      samplingRate: 100
      provider:
        type: OpenTelemetry
        backendRefs:
          - name: otel-collector
            namespace: monitoring
            port: 4317
```

`samplingRate: 100`은 학습 Lab에서 모든 요청을 쉽게 찾기 위한 설정입니다.

Production에서는 트래픽 양과 비용을 고려해 sampling 정책을 조정해야 합니다.

---

## 3. GatewayClass와 EnvoyProxy 연결

`GatewayClass`는 `parametersRef`를 통해 EnvoyProxy 설정을 사용합니다.

```yaml
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: platform-envoy-proxy
    namespace: envoy-gateway-system
```

구조:

```text
GatewayClass platform-eg
        |
        v
EnvoyProxy platform-envoy-proxy
        |
        v
telemetry.tracing
        |
        v
otel-collector.monitoring:4317
```

---

# 적용

## 4. Git 변경 가져오기

```bash
cd ~/platform-engineering-lab
git pull
```

Argo CD가 platform Application을 자동 동기화합니다.

```bash
kubectl get applications -n argocd
```

`platform`이 `Synced / Healthy`가 되어야 합니다.

---

## 5. EnvoyProxy 생성 확인

```bash
kubectl get envoyproxy -A
```

기대:

```text
envoy-gateway-system   platform-envoy-proxy
```

상세 확인:

```bash
kubectl get envoyproxy platform-envoy-proxy \
  -n envoy-gateway-system \
  -o yaml
```

---

## 6. GatewayClass parametersRef 확인

```bash
kubectl get gatewayclass platform-eg -o yaml
```

다음이 있어야 합니다.

```text
parametersRef:
  group: gateway.envoyproxy.io
  kind: EnvoyProxy
  name: platform-envoy-proxy
  namespace: envoy-gateway-system
```

---

## 7. Envoy data plane 상태 확인

```bash
kubectl get pods \
  -n envoy-gateway-system \
  -l app.kubernetes.io/name=envoy \
  -o wide
```

EnvoyProxy 설정 변경 과정에서 data plane Pod가 교체될 수 있습니다.

Pod가 `Running` / `Ready`가 된 후 다음으로 진행합니다.

Gateway 상태:

```bash
kubectl get gateway platform-gateway \
  -n platform-system
```

HTTPRoute:

```bash
kubectl get httproute web -n demo-app
```

---

## 8. Collector 설정 원복

FastAPI tracing 검증 중 사용한 detailed debug exporter는 로그 노이즈가 크므로 제거했습니다.

Collector values 반영:

```bash
helm upgrade otel-collector \
  open-telemetry/opentelemetry-collector \
  --version 0.172.1 \
  -n monitoring \
  -f observability/otel-collector-values.yaml
```

확인:

```bash
kubectl rollout status deployment/otel-collector -n monitoring
```

---

# Distributed Trace 검증

## 9. Gateway를 통해 요청 발생

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "$GATEWAY_IP"
```

요청:

```bash
for i in {1..10}; do
  curl -s \
    -H "Host: web.lab.local" \
    "http://${GATEWAY_IP}/" >/dev/null
  sleep 0.2
done
```

---

## 10. Tempo에서 최근 trace 검색

Tempo port-forward:

```bash
kubectl port-forward \
  -n monitoring \
  svc/tempo \
  3200:3200
```

TraceQL:

```bash
curl -G -s \
  http://localhost:3200/api/search \
  --data-urlencode 'q={ resource.service.name = "platform-api" }' \
  --data-urlencode 'limit=20'
```

Trace ID 하나를 선택합니다.

---

## 11. Trace ID 직접 조회

```bash
TRACE_ID=<trace-id>

curl -s \
  "http://localhost:3200/api/traces/${TRACE_ID}"
```

하나의 trace 안에 최소 두 계층이 보여야 합니다.

```text
Envoy / proxy span
       |
       v
platform-api / GET /
```

중요한 것은 span 이름 자체보다 두 span이 **동일한 Trace ID** 안에 존재하는가입니다.

---

## 12. Grafana에서 확인

```bash
kubectl port-forward \
  -n monitoring \
  svc/monitoring-grafana \
  3000:80
```

Grafana:

```text
Explore
 -> Tempo
 -> Search
 -> trace open
```

Trace waterfall에서:

```text
Gateway span
  └─ FastAPI span
```

의 parent/child 관계와 duration을 확인합니다.

---

# Troubleshooting

## 13. FastAPI span만 보이고 Gateway span이 없는 경우

EnvoyProxy 적용 여부:

```bash
kubectl get envoyproxy platform-envoy-proxy \
  -n envoy-gateway-system \
  -o yaml
```

GatewayClass 연결:

```bash
kubectl get gatewayclass platform-eg -o yaml
```

Envoy Pod 최근 로그:

```bash
kubectl logs \
  -n envoy-gateway-system \
  -l app.kubernetes.io/name=envoy \
  --tail=100
```

Collector endpoint 접근성:

```bash
kubectl run envoy-otel-netcheck \
  -n envoy-gateway-system \
  --image=busybox:1.36 \
  --restart=Never \
  --rm -i \
  -- sh -c \
  'nc -vz otel-collector.monitoring.svc.cluster.local 4317'
```

---

## 14. Envoy span과 FastAPI span이 서로 다른 Trace ID인 경우

이는 trace context propagation 문제입니다.

확인 포인트:

```text
Envoy tracing enabled?
FastAPI OpenTelemetry instrumentation enabled?
Gateway를 실제로 거친 요청인가?
traceparent 헤더가 upstream으로 전달되는가?
```

FastAPI Service 직접 port-forward 요청은 Gateway를 거치지 않으므로 Envoy span이 없는 것이 정상입니다.

---

# 성공 기준

```text
EnvoyProxy created
GatewayClass references EnvoyProxy
Envoy data plane Ready
Gateway traffic succeeds
Envoy sends trace to Collector
FastAPI span still reaches Collector
Tempo stores both spans
Same Trace ID contains Gateway + FastAPI spans
Grafana waterfall shows parent/child relationship
```

이 단계가 완료되면 Metrics + Alerts + Traces 세 축이 모두 연결됩니다.

```text
Metrics -> Prometheus -> Grafana
Alerts  -> PrometheusRule -> Alertmanager
Traces  -> OTel Collector -> Tempo -> Grafana
```

다음 단계는 TLS / cert-manager입니다.
