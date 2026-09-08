# Phase 7 — Envoy Gateway + FastAPI Distributed Tracing

이 단계에서는 FastAPI tracing에 Envoy Gateway span을 추가해 하나의 요청이 Gateway와 Application에서 같은 Trace ID로 연결되는지 검증합니다.

## Runtime verification status

실제 local lab에서 다음 경로를 검증했습니다.

```text
Client
  ↓
Envoy Gateway ingress span
  ↓ same Trace ID
platform-api
  ↓
GET /
  ↓
OpenTelemetry Collector
  ↓
Tempo
  ↓
Grafana
```

Grafana Tempo trace waterfall에서 `ingress` 계열 Gateway span과 `platform-api / GET /` FastAPI span이 같은 trace 안에서 parent/child 관계로 확인되었습니다.

```text
Envoy Gateway → FastAPI demo-app distributed tracing ✅
FastAPI → Collector → Tempo                       ✅
Tempo → Grafana                                   ✅
```

---

## 1. Envoy Gateway tracing

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

Lab에서는 요청을 쉽게 찾기 위해 100% sampling을 사용합니다. Production에서는 트래픽과 저장 비용에 맞춰 조정해야 합니다.

GatewayClass는 이 EnvoyProxy를 참조합니다.

```text
GatewayClass/platform-eg
        ↓
EnvoyProxy/platform-envoy-proxy
        ↓
OTel Collector
```

확인:

```bash
kubectl get gatewayclass platform-eg \
  -o jsonpath='{.spec.parametersRef}{"\n"}'
```

---

## 2. Cross-namespace OTLP backend

EnvoyProxy는 `envoy-gateway-system`, Collector Service는 `monitoring` namespace에 있습니다.

파일:

```text
gitops/platform/otel-referencegrant.yaml
```

확인:

```bash
kubectl get referencegrant -n monitoring
```

기대:

```text
allow-envoyproxy-to-otel-collector
```

Collector Service:

```bash
kubectl get svc otel-collector -n monitoring \
  -o jsonpath='{range .spec.ports[*]}{.name}{" port="}{.port}{" appProtocol="}{.appProtocol}{"\n"}{end}'
```

OTLP/gRPC는 4317을 사용합니다.

---

## 3. Docker Desktop + WSL network boundary

이 Lab은 Windows + WSL2 + Docker Desktop + kind 조합입니다.

MetalLB External IP가 Kubernetes 내부에서는 정상이어도 WSL에서 직접 다음처럼 접근하면 timeout/hang이 발생할 수 있습니다.

```bash
curl http://${GATEWAY_IP}/
```

실제 Lab에서도 다음을 확인했습니다.

```text
WSL → MetalLB External IP direct = timeout/hang
Docker network → MetalLB         = 정상
```

따라서 Docker published port를 가진 `socat` proxy를 사용합니다.

HTTP:

```text
127.0.0.1:8080
  ↓
Docker socat
  ↓
MetalLB :80
  ↓
Envoy Gateway
```

HTTPS:

```text
127.0.0.1:8443
  ↓
Docker socat
  ↓
MetalLB :443
  ↓
Envoy Gateway
```

Gateway IP:

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')
```

HTTP proxy:

```bash
docker rm -f platform-gateway-http-proxy 2>/dev/null || true

docker run -d \
  --name platform-gateway-http-proxy \
  --restart unless-stopped \
  --network kind \
  -p 127.0.0.1:8080:8080 \
  alpine/socat \
  TCP-LISTEN:8080,fork,reuseaddr \
  TCP:${GATEWAY_IP}:80
```

HTTPS proxy:

```bash
docker rm -f platform-gateway-https-proxy 2>/dev/null || true

docker run -d \
  --name platform-gateway-https-proxy \
  --restart unless-stopped \
  --network kind \
  -p 127.0.0.1:8443:8443 \
  alpine/socat \
  TCP-LISTEN:8443,fork,reuseaddr \
  TCP:${GATEWAY_IP}:443
```

---

## 4. Distributed trace 생성 — Phase 8까지

HTTP와 HTTPS가 모두 application backend로 연결되어 있을 때는 HTTP 요청으로 trace를 만들 수 있습니다.

```bash
for i in {1..20}; do
  curl -s \
    -H "Host: web.lab.local" \
    http://127.0.0.1:8080/ >/dev/null
done
```

이 경로는 실제 Envoy Gateway를 통과하므로 distributed trace 검증에 사용할 수 있습니다.

Application Service에 직접 `kubectl port-forward`하는 방식은 Envoy를 우회하므로 Gateway tracing 검증에는 사용하지 않습니다.

---

## 5. Distributed trace 생성 — Phase 9 이후

Phase 9에서 HTTP → HTTPS redirect가 적용되면 HTTP 요청은 Gateway에서 301로 종료됩니다.

```text
HTTP :8080
  ↓
Envoy Gateway
  ↓
301 redirect
  X FastAPI까지 가지 않음
```

따라서 **Phase 9 이후 Envoy → FastAPI distributed tracing은 HTTPS 요청으로 검증해야 합니다.**

```bash
for i in {1..20}; do
  curl -k -s \
    --resolve web.lab.local:8443:127.0.0.1 \
    https://web.lab.local:8443/ >/dev/null
done
```

경로:

```text
Client HTTPS
  ↓
Docker HTTPS proxy
  ↓
MetalLB :443
  ↓
Envoy Gateway TLS termination
  ↓
HTTPRoute/web
  ↓
FastAPI
  ↓
OTel Collector
  ↓
Tempo
```

---

## 6. Grafana Tempo 검증

Grafana:

```text
Explore
 → Tempo
 → Time range: Last 15 minutes
```

TraceQL:

```text
{ resource.service.name = "platform-api" }
```

가장 최근 trace를 열어 다음 구조를 확인합니다.

```text
Gateway / ingress span
  └─ platform-api
      └─ GET /
```

핵심 성공 조건은 span 이름 자체보다 **Gateway span과 FastAPI span이 동일한 Trace ID 안에서 parent/child로 연결되는 것**입니다.

---

## 7. Tempo API 직접 확인

Tempo port-forward:

```bash
kubectl port-forward \
  -n monitoring \
  svc/tempo \
  3200:3200
```

최근 trace 검색:

```bash
curl -G -s \
  http://localhost:3200/api/search \
  --data-urlencode 'q={ resource.service.name = "platform-api" }' \
  --data-urlencode 'limit=20'
```

Trace ID 조회:

```bash
TRACE_ID=<trace-id>

curl -s \
  "http://localhost:3200/api/traces/${TRACE_ID}"
```

서비스 이름:

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

span 관계:

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

## Troubleshooting

### 새로운 trace가 보이지 않을 때

1. 요청 자체가 200인지 확인합니다.
2. Phase 9 이후라면 HTTP가 아니라 HTTPS로 trace를 생성했는지 확인합니다.
3. EnvoyProxy와 GatewayClass 연결을 확인합니다.
4. ReferenceGrant를 확인합니다.
5. Collector가 4317에서 수신하는지 확인합니다.

```bash
kubectl get envoyproxy platform-envoy-proxy \
  -n envoy-gateway-system

kubectl get gatewayclass platform-eg

kubectl get referencegrant -n monitoring
```

Collector network check:

```bash
kubectl run envoy-otel-netcheck \
  -n envoy-gateway-system \
  --image=busybox:1.36 \
  --restart=Never \
  --rm -i \
  -- sh -c \
  'nc -vz otel-collector.monitoring.svc.cluster.local 4317'
```

### FastAPI span만 보이는 경우

Gateway를 우회한 요청인지 먼저 확인합니다.

```text
svc/web direct port-forward → Envoy span 없음 = 정상
Gateway path               → Envoy + FastAPI span 필요
```

---

## Completion criteria

Runtime verified:

```text
EnvoyProxy created                             ✅
GatewayClass references EnvoyProxy             ✅
Cross-namespace OTLP backend allowed            ✅
Docker Desktop / WSL proxy path works           ✅
Gateway request reaches FastAPI                 ✅
Envoy ingress span stored in Tempo              ✅
FastAPI platform-api / GET / span stored        ✅
Same Trace ID parent/child relationship         ✅
Grafana Tempo waterfall                         ✅
```

Phase 9 이후에는 HTTPS 경로를 사용해 같은 조건을 계속 검증합니다.
