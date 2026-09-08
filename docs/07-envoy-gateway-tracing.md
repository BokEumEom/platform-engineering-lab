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

따라서 다음 구간은 이미 검증되었습니다.

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

## 4. Cross-namespace OTLP backend 허용

`EnvoyProxy`는 `envoy-gateway-system` namespace에 있고 OpenTelemetry Collector Service는 `monitoring` namespace에 있습니다.

따라서 target namespace인 `monitoring`에서 해당 참조를 명시적으로 허용합니다.

파일:

```text
gitops/platform/otel-referencegrant.yaml
```

구조:

```text
EnvoyProxy (envoy-gateway-system)
        |
        | backendRef
        v
ReferenceGrant (monitoring)
        |
        v
otel-collector Service :4317
```

확인:

```bash
kubectl get referencegrant -n monitoring
```

기대:

```text
allow-envoyproxy-to-otel-collector
```

---

# 적용

## 5. Git 변경 가져오기

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

## 6. EnvoyProxy 생성 확인

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

## 7. GatewayClass parametersRef 확인

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

## 8. Envoy data plane 상태 확인

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

## 9. Collector 설정 확인

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

OTLP/gRPC Service port도 확인합니다.

```bash
kubectl get svc otel-collector -n monitoring \
  -o jsonpath='{range .spec.ports[*]}{.name}{" port="}{.port}{" appProtocol="}{.appProtocol}{"\n"}{end}'
```

4317 포트는 gRPC OTLP endpoint입니다.

---

# Docker Desktop + WSL 네트워크 주의사항

## 10. MetalLB External IP가 WSL에서 직접 접근되지 않는 경우

이 Lab은 Windows + WSL2 + Docker Desktop + kind 조합을 사용합니다.

MetalLB가 예를 들어 다음 External IP를 할당할 수 있습니다.

```text
172.18.255.200
```

하지만 Docker Desktop의 container network는 Windows/WSL host network와 분리되어 있기 때문에 WSL에서 아래 요청이 응답 없이 대기할 수 있습니다.

```bash
curl -H "Host: web.lab.local" http://172.18.255.200/
```

이 경우 Kubernetes Gateway, HTTPRoute 또는 FastAPI 장애로 바로 판단하면 안 됩니다.

실제 Lab에서도 다음 상태를 확인했습니다.

```text
kubectl port-forward -> Envoy Gateway -> FastAPI = 정상
WSL -> MetalLB External IP direct curl          = timeout/hang
```

따라서 Docker published port를 가진 작은 TCP proxy를 사용해 WSL과 kind network를 연결합니다.

이 proxy는 Envoy Service를 직접 port-forward하는 방식과 다르게 실제 MetalLB External IP로 전달합니다.

```text
WSL localhost:8080
        |
        v
Docker published port
        |
        v
socat container --network kind
        |
        v
MetalLB External IP :80
        |
        v
Envoy Gateway
        |
        v
HTTPRoute
        |
        v
FastAPI
```

### Gateway External IP 가져오기

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "$GATEWAY_IP"
```

### 기존 proxy 정리

```bash
docker rm -f platform-gateway-http-proxy 2>/dev/null || true
```

8080 포트를 이미 사용 중인지 확인할 수 있습니다.

```bash
ss -lntp | grep ':8080' || true
```

기존 `kubectl port-forward`가 8080을 사용 중이면 먼저 종료합니다.

### HTTP proxy 실행

```bash
docker run -d \
  --name platform-gateway-http-proxy \
  --restart unless-stopped \
  --network kind \
  -p 127.0.0.1:8080:8080 \
  alpine/socat \
  TCP-LISTEN:8080,fork,reuseaddr \
  TCP:${GATEWAY_IP}:80
```

상태 확인:

```bash
docker ps --filter name=platform-gateway-http-proxy
```

기대:

```text
STATUS   Up ...
```

실패했거나 바로 종료됐다면:

```bash
docker ps -a --filter name=platform-gateway-http-proxy
docker logs platform-gateway-http-proxy
```

---

# Distributed Trace 검증

## 11. 실제 Gateway 경로를 통해 요청 발생

Docker proxy를 사용한 요청:

```bash
curl -v \
  -H "Host: web.lab.local" \
  http://127.0.0.1:8080/
```

기대:

```text
HTTP/1.1 200 OK
```

FastAPI 응답이 반환되어야 합니다.

Trace를 충분히 생성하기 위해 여러 번 호출합니다.

```bash
for i in {1..20}; do
  curl -s \
    -H "Host: web.lab.local" \
    http://127.0.0.1:8080/ >/dev/null
  sleep 0.2
done
```

이 요청은 다음 경로를 실제로 통과합니다.

```text
Client
  -> Docker socat proxy
  -> MetalLB External IP
  -> Envoy Gateway
  -> HTTPRoute
  -> FastAPI
```

`kubectl port-forward svc/web ...`처럼 Application Service에 직접 연결하면 Envoy Gateway를 우회하므로 distributed tracing 검증에 사용하면 안 됩니다.

---

## 12. Tempo에서 최근 trace 검색

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

## 13. Trace ID 직접 조회

```bash
TRACE_ID=<trace-id>

curl -s \
  "http://localhost:3200/api/traces/${TRACE_ID}"
```

서비스 이름 확인:

```bash
curl -s \
  "http://localhost:3200/api/traces/${TRACE_ID}" \
  | jq -r '
      .batches[]
      | .resource.attributes[]
      | select(.key=="service.name")
      | .value.stringValue
    ' \
  | sort -u
```

하나의 trace 안에 Application뿐 아니라 Envoy/proxy 계열 resource가 함께 있어야 합니다.

```text
Envoy / proxy span
       |
       v
platform-api / GET /
```

중요한 것은 span 이름 자체보다 두 span이 **동일한 Trace ID** 안에 존재하는가입니다.

span parent/child 관계 확인:

```bash
curl -s \
  "http://localhost:3200/api/traces/${TRACE_ID}" \
  | jq -r '
      .batches[]
      | .scopeSpans[]
      | .spans[]
      | [.name, .traceId, .spanId, .parentSpanId]
      | @tsv
    '
```

---

## 14. Grafana에서 확인

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
 -> Time range: Last 15 minutes
 -> TraceQL: { resource.service.name = "platform-api" }
 -> Run query
 -> 최신 trace open
```

Trace waterfall에서:

```text
Gateway / Envoy span
  └─ platform-api / GET /
```

의 parent/child 관계와 duration을 확인합니다.

새 요청을 만들었는데 과거 시각의 trace만 보이면 먼저 Gateway 요청 자체가 성공했는지 확인합니다.

---

# Troubleshooting

## 15. curl이 응답 없이 멈추는 경우

MetalLB External IP에 직접 요청했다면 Docker Desktop/WSL network boundary를 먼저 의심합니다.

```bash
curl --connect-timeout 3 --max-time 5 -v \
  -H "Host: web.lab.local" \
  "http://${GATEWAY_IP}/"
```

직접 접근은 timeout인데 아래 요청은 성공한다면 proxy 경로를 사용합니다.

```bash
curl --max-time 5 -v \
  -H "Host: web.lab.local" \
  http://127.0.0.1:8080/
```

proxy 상태:

```bash
docker ps --filter name=platform-gateway-http-proxy
```

종료된 경우:

```bash
docker ps -a --filter name=platform-gateway-http-proxy
docker logs platform-gateway-http-proxy
```

---

## 16. FastAPI span만 보이고 Gateway span이 없는 경우

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

ReferenceGrant:

```bash
kubectl get referencegrant -n monitoring
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

## 17. Envoy span과 FastAPI span이 서로 다른 Trace ID인 경우

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
ReferenceGrant allows cross-namespace OTLP backend
Envoy data plane Ready
Docker proxy exposes the MetalLB path to WSL
Gateway traffic returns HTTP 200
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
