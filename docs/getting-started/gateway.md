# Gateway

[Back to getting started](README.md)

This chapter owns Gateway API, Envoy Gateway, and the local LoadBalancer path.

## Part 3. Gateway API + Envoy Gateway

### 6. Gateway API를 먼저 이해하기

이번 Lab의 HTTP traffic 흐름입니다.

```text
Client
  |
Gateway
  |
HTTPRoute
  |
Service
  |
Pod
```

주요 resource:

```text
GatewayClass
Gateway
HTTPRoute
```

역할을 나누면:

```text
Platform Team
 -> GatewayClass
 -> Gateway

Application Team
 -> HTTPRoute
 -> Service
 -> Deployment
```

중요한 점은 Gateway API resource만 만든다고 traffic이 흐르는 것이 아니라는 것입니다.

Gateway API를 실제로 구현하는 **controller**가 필요합니다.

이 Lab에서는 Envoy Gateway를 사용합니다.

---

### 7. Envoy Gateway 설치 — Helm

Lab에서 사용한 버전:

```text
Envoy Gateway v1.9.1
```

설치:

```bash
helm install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  -n envoy-gateway-system \
  --create-namespace
```

이 명령은 다음 작업을 수행합니다.

```text
namespace 생성
Gateway API CRD 설치
Envoy Gateway CRD 설치
Envoy Gateway controller 설치
```

설치 확인:

```bash
kubectl get pods -n envoy-gateway-system
```

controller가 준비될 때까지 기다릴 수도 있습니다.

```bash
kubectl wait \
  --timeout=5m \
  -n envoy-gateway-system \
  deployment/envoy-gateway \
  --for=condition=Available
```

CRD/API 확인:

```bash
kubectl api-resources | grep gateway
```

예상 resource:

```text
gatewayclasses
gateways
httproutes
referencegrants
```

---

### 8. Envoy Gateway 공식 quickstart로 먼저 검증

자체 애플리케이션을 만들기 전에 Envoy Gateway 자체가 정상인지 먼저 확인했습니다.

```bash
kubectl apply \
  -f https://github.com/envoyproxy/gateway/releases/download/v1.9.1/quickstart.yaml \
  -n default
```

이 quickstart는 예제의:

```text
GatewayClass
Gateway
HTTPRoute
Service
Backend Pod
```

를 한 번에 만듭니다.

확인:

```bash
kubectl get gatewayclass
kubectl get gateway
kubectl get httproute
kubectl get pods
```

로컬에서 port-forward 후 테스트했습니다.

예:

```bash
curl -v \
  -H "Host: www.example.com" \
  http://localhost:8888/get
```

정상이라면:

```text
HTTP/1.1 200 OK
```

을 확인할 수 있습니다.

학습 포인트:

```text
Controller가 Running인가?
Gateway가 생성되었는가?
Route가 Accepted 되었는가?
Backend까지 실제 요청이 도달하는가?
```

resource가 존재하는 것과 실제 traffic path가 동작하는 것은 다른 문제입니다.

---

## Part 8. 로컬 LoadBalancer — MetalLB

### 21. 왜 MetalLB가 필요했는가

Gateway를 만든 뒤 다음 상태를 확인했습니다.

```text
Accepted=True
Programmed=False
```

HTTPRoute는:

```text
Accepted=True
ResolvedRefs=True
```

였습니다.

문제는 route가 아니라 로컬 cluster에 `LoadBalancer` Service의 external address를 할당할 구현체가 없었던 것입니다.

AWS에서는 ELB/NLB 같은 cloud LoadBalancer가 있지만 로컬 kind에는 기본 제공되지 않습니다.

그래서 MetalLB를 추가했습니다.

---

### 22. MetalLB 설치 — kubectl apply

이 Lab에서는 단순한 L2 local 환경이므로 native manifest를 사용했습니다.

```bash
kubectl apply \
  -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
```

설치되는 주요 component:

```text
metallb-system/controller
metallb-system/speaker
```

확인:

```bash
kubectl get pods -n metallb-system -o wide
```

준비 상태 확인:

```bash
kubectl rollout status deployment/controller -n metallb-system
kubectl rollout status daemonset/speaker -n metallb-system
```

---

### 23. MetalLB IP pool 설정

MetalLB 설치만 해서는 IP를 할당하지 않습니다.

먼저 kind Docker network를 확인합니다.

```bash
docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
```

Lab에서는 다음 pool을 사용했습니다.

```text
172.18.255.200-172.18.255.250
```

> 자신의 Docker network가 다르면 `metallb-config.yaml`의 주소를 그대로 사용하면 안 됩니다. 먼저 network 대역을 확인하세요.

Repository의 설정:

```bash
cat metallb-config.yaml
```

적용:

```bash
kubectl apply -f metallb-config.yaml
```

확인:

```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

Envoy LoadBalancer Service 확인:

```bash
kubectl get svc -n envoy-gateway-system
```

기존:

```text
EXTERNAL-IP
<pending>
```

MetalLB 적용 후:

```text
EXTERNAL-IP
172.18.255.x
```

처럼 IP가 할당됩니다.

Gateway 확인:

```bash
kubectl get gateway platform-gateway -n platform-system
```

목표:

```text
PROGRAMMED=True
```

상세 condition:

```bash
kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{" message="}{.message}{"\n"}{end}'
```

---
