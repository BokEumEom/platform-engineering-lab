# Kubernetes Platform Lab - Step by Step

이 문서는 `platform-engineering-lab`을 만들면서 실제로 수행한 Kubernetes / Platform Engineering 실습을 복습하기 위한 학습 노트입니다.

목표는 단순한 YAML 작성이 아니라 아래 흐름을 직접 이해하는 것입니다.

```text
Application Source
   -> CI
   -> Container Registry
   -> GitOps Repository State
   -> Argo CD Reconciliation
   -> Kubernetes Deployment
   -> Gateway API Routing
```

---

## 1. Lab environment

### Host

- Windows
- Docker Desktop
- Ubuntu 24.04 WSL2
- 12 vCPU
- 15 GiB RAM
- 4 GiB Swap

### Kubernetes

```text
Client: v1.36.1
Server: v1.36.1
```

Cluster topology:

```text
desktop-control-plane   control-plane
desktop-worker          worker
desktop-worker2         worker
```

3-node 구성을 선택한 이유는 단순 Pod 실행을 넘어 아래 항목을 실습하기 위해서입니다.

- scheduling
- cordon / drain
- PDB
- topology spread
- affinity / anti-affinity
- taints / tolerations

16 GiB 수준의 개발 PC에서는 더 많은 node를 늘리기보다 3-node에서 필요한 플랫폼 구성요소를 단계적으로 추가하는 편이 효율적입니다.

---

## 2. Docker Desktop + WSL integration

WSL에서 Docker CLI는 보였지만 daemon socket 접근 시 아래 오류가 발생할 수 있습니다.

```text
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

확인:

```bash
ls -l /var/run/docker.sock
id
getent group docker
```

필요한 경우 현재 사용자를 `docker` 그룹에 추가합니다.

```bash
sudo groupadd -f docker
sudo usermod -aG docker "$USER"
newgrp docker
```

Docker Desktop을 사용하는 경우 WSL 내부에 Docker Engine을 별도로 하나 더 설치하지 않는 것이 좋습니다.

Docker Desktop 설정:

```text
Settings
 -> General
 -> Use WSL 2 based engine

Settings
 -> Resources
 -> WSL Integration
 -> Ubuntu enabled
```

---

## 3. Basic cluster validation

```bash
kubectl version
kubectl get nodes -o wide
```

정상 상태:

```text
NAME                    STATUS   ROLES
desktop-control-plane   Ready    control-plane
desktop-worker          Ready    <none>
desktop-worker2         Ready    <none>
```

Shell convenience:

```bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
source ~/.bashrc
```

---

# Part 1. Gateway API

## 4. Why Gateway API

이번 lab에서는 신규 트래픽 관리 구조를 Ingress 중심으로 만들지 않고 Gateway API를 사용했습니다.

핵심 리소스:

```text
GatewayClass
    |
Gateway
    |
HTTPRoute
    |
Service
    |
Pod
```

이 구조의 핵심은 네트워크 인프라와 애플리케이션 라우팅 책임을 나눌 수 있다는 점입니다.

```text
Platform Team
 -> GatewayClass
 -> Gateway

Application Team
 -> HTTPRoute
 -> Service
 -> Deployment
```

---

## 5. Envoy Gateway

Envoy Gateway를 Gateway API controller로 사용했습니다.

```bash
helm install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  -n envoy-gateway-system \
  --create-namespace
```

확인:

```bash
kubectl get pods -n envoy-gateway-system
kubectl api-resources | grep gateway
```

주요 Gateway API resources:

```text
gatewayclasses.gateway.networking.k8s.io
gateways.gateway.networking.k8s.io
httproutes.gateway.networking.k8s.io
referencegrants.gateway.networking.k8s.io
```

---

## 6. First routing validation

Gateway API가 실제로 동작하는지 공식 quickstart backend를 이용해 먼저 검증했습니다.

테스트 구조:

```text
Client
 -> localhost port-forward
 -> Envoy Proxy
 -> Gateway
 -> HTTPRoute
 -> Service
 -> backend Pod
```

예시:

```bash
curl -v \
  -H "Host: www.example.com" \
  http://localhost:8888/get
```

정상 응답:

```text
HTTP/1.1 200 OK
```

이 단계에서 중요한 것은 YAML 존재 여부가 아니라 실제 데이터 경로 전체가 연결되었는지 확인하는 것입니다.

---

## 7. Platform ownership model

최종 구조:

```text
Platform Team
platform-system/
  GatewayClass: platform-eg
  Gateway: platform-gateway

Application Team
demo-app/
  Deployment
  Service
  HTTPRoute
```

Gateway는 특정 namespace label을 가진 application namespace만 route를 연결할 수 있도록 설정했습니다.

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        gateway-access: "true"
```

이를 통해 application team이 임의의 namespace에서 platform gateway에 route를 붙이는 것을 제한할 수 있습니다.

---

# Part 2. Application workload

## 8. FastAPI application

샘플 애플리케이션은 FastAPI로 구성했습니다.

주요 endpoint:

```text
GET /
GET /health/live
GET /health/ready
```

응답에는 현재 Pod hostname과 application version을 포함합니다.

```json
{
  "message": "platform-engineering-lab GitOps",
  "hostname": "web-xxxxxxxxxx-xxxxx",
  "version": "c17dc88"
}
```

Pod hostname을 노출한 이유는 요청이 여러 Pod로 분산되는지 쉽게 확인하기 위해서입니다.

---

## 9. Container image

Dockerfile 기본 원칙:

- slim base image
- non-root user
- explicit port
- reproducible application command
- OCI source label

이미지는 로컬 실습 초기에는:

```text
platform-api:v1
```

을 사용했지만 최종적으로 GHCR 기반 immutable image로 변경했습니다.

```text
ghcr.io/bokeumeom/platform-api:<git-commit-sha>
```

---

## 10. Deployment resource design

Deployment에는 다음 운영 요소를 추가했습니다.

```text
replicas: 2
resources requests / limits
readinessProbe
livenessProbe
topologySpreadConstraints
```

resource example:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

Probe:

```yaml
readinessProbe:
  httpGet:
    path: /health/ready
    port: 8000

livenessProbe:
  httpGet:
    path: /health/live
    port: 8000
```

### Readiness vs Liveness

```text
readiness
 -> 이 Pod가 트래픽을 받아도 되는가?

liveness
 -> 이 container를 재시작해야 하는가?
```

둘을 같은 의미로 사용하면 장애 시 잘못된 restart 또는 traffic routing이 발생할 수 있습니다.

---

# Part 3. Availability and Autoscaling

## 11. PodDisruptionBudget

PDB:

```yaml
spec:
  minAvailable: 1
```

2개의 replica 중 voluntary disruption 상황에서도 최소 1개는 유지하도록 했습니다.

확인:

```bash
kubectl get pdb -n demo-app
```

예:

```text
MIN AVAILABLE        1
ALLOWED DISRUPTIONS  1
```

PDB는 일반적인 Pod crash를 막는 기능이 아니라 `drain` 같은 voluntary disruption에 적용된다는 점이 중요합니다.

---

## 12. HPA

CPU utilization 기반 HPA를 구성했습니다.

```yaml
minReplicas: 2
maxReplicas: 6
```

Target:

```yaml
averageUtilization: 50
```

확인:

```bash
kubectl get hpa -n demo-app
kubectl top pods -n demo-app
```

HPA를 사용하려면 Pod의 resource request가 중요합니다.

```text
CPU utilization = actual CPU / requested CPU
```

request가 없으면 CPU utilization 기반 HPA 계산이 정상적으로 동작하지 않을 수 있습니다.

---

## 13. Load generation

HPA 테스트용으로 temporary BusyBox workload를 사용할 수 있습니다.

```bash
kubectl create deployment load-generator \
  -n demo-app \
  --image=busybox:1.37 \
  --replicas=10 \
  -- \
  /bin/sh -c 'while true; do wget -q -O- http://web.demo-app.svc.cluster.local/ >/dev/null; done'
```

관찰:

```bash
kubectl get hpa -n demo-app -w
kubectl get pods -n demo-app -w
kubectl top pods -n demo-app
```

테스트 종료:

```bash
kubectl delete deployment load-generator -n demo-app
```

---

# Part 4. Scheduling

## 14. cordon / drain / uncordon

Pod placement:

```bash
kubectl get pods -n demo-app \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
```

Cordon:

```bash
kubectl cordon desktop-worker
```

Cordon은 기존 Pod를 제거하지 않고 새로운 scheduling만 차단합니다.

Drain:

```bash
kubectl drain desktop-worker \
  --ignore-daemonsets \
  --delete-emptydir-data
```

Uncordon:

```bash
kubectl uncordon desktop-worker
```

중요한 점:

```text
uncordon != rebalance
```

node를 다시 schedulable 상태로 만든다고 기존 Pod가 자동으로 해당 node로 이동하지 않습니다.

---

## 15. topologySpreadConstraints

2개의 application replica가 같은 worker에 몰리지 않도록 설정했습니다.

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

최종 검증 상태:

```text
desktop-worker   -> 1 FastAPI Pod
desktop-worker2  -> 1 FastAPI Pod
```

이 실습 중 두 Pod가 모두 `desktop-worker2`에 있었는데, 원인은 이전 drain 과정에서 worker scheduling 상태를 확인해야 했기 때문입니다.

```bash
kubectl get nodes
kubectl uncordon desktop-worker
```

그리고 새 scheduling cycle이 필요하면 rolling restart로 확인할 수 있습니다.

```bash
kubectl rollout restart deployment/web -n demo-app
```

---

## 16. Pod anti-affinity comparison

strict anti-affinity example:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - web
        topologyKey: kubernetes.io/hostname
```

2개의 worker만 있는 상태에서 replica 3개를 strict anti-affinity로 실행하면 세 번째 Pod는 `Pending`이 될 수 있습니다.

차이:

```text
Pod Anti-Affinity
 -> 같이 배치하지 말라

Topology Spread Constraints
 -> 가능한 균등하게 배치하라
```

운영 환경에서는 workload 특성에 따라 두 방식의 trade-off를 이해해야 합니다.

---

## 17. Taints and Tolerations

Node taint:

```bash
kubectl taint node desktop-worker2 workload=platform:NoSchedule
```

Pod toleration:

```yaml
tolerations:
  - key: workload
    operator: Equal
    value: platform
    effect: NoSchedule
```

핵심:

```text
Toleration = 해당 taint를 견딜 수 있다
Toleration != 그 node를 선택한다
```

특정 node를 실제로 선택하려면 node affinity 또는 nodeSelector가 추가로 필요합니다.

---

## 18. Node affinity

Node label:

```bash
kubectl label node desktop-worker2 workload=platform
```

Affinity:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: workload
              operator: In
              values:
                - platform
```

Taint + toleration + affinity를 결합하면 dedicated workload node 패턴을 만들 수 있습니다.

이 개념은 이후 EKS + Karpenter 학습으로 연결됩니다.

```text
Pod Scheduling Constraints
      |
      v
Pending Pod
      |
      v
Karpenter
      |
NodePool / EC2NodeClass constraints
      |
      v
New Node Provisioning
```

로컬 kind에서는 Karpenter의 cloud node provisioning을 제대로 검증할 수 없기 때문에 실제 Karpenter 실습은 EKS 단계에서 진행할 예정입니다.

---

# Part 5. Local LoadBalancer

## 19. Gateway Programmed=False

Gateway 생성 후 다음 상태가 발생했습니다.

```text
Accepted=True
Programmed=False
```

HTTPRoute는 정상:

```text
Accepted=True
ResolvedRefs=True
```

즉 Route definition 자체보다 Gateway dataplane exposure 쪽 문제였습니다.

로컬 kind cluster에는 AWS ELB 같은 cloud LoadBalancer implementation이 없습니다.

Envoy Gateway가 생성한 Service가 `LoadBalancer` type인데 external address를 할당받지 못하면 Gateway가 완전히 Programmed되지 않을 수 있습니다.

---

## 20. MetalLB

MetalLB를 설치해 로컬 cluster에 LoadBalancer IP 할당 기능을 추가했습니다.

Docker kind network 확인:

```bash
docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
```

Lab에서는 Docker network 대역의 높은 주소를 MetalLB pool로 사용했습니다.

예:

```text
172.18.255.200-172.18.255.250
```

리소스:

```text
IPAddressPool
L2Advertisement
```

확인:

```bash
kubectl get svc -n envoy-gateway-system
kubectl get gateway -n platform-system
```

목표:

```text
PROGRAMMED=True
```

---

# Part 6. GitOps with Argo CD

## 21. Why GitOps

초기에는 직접:

```bash
kubectl apply -f ...
```

형태로 리소스를 생성했지만 이후 GitOps 구조로 전환했습니다.

핵심 모델:

```text
Git
 = desired state

Kubernetes
 = actual state

Argo CD
 = reconciliation loop
```

운영자가 cluster에 직접 변경하는 것이 아니라 Git 변경이 배포의 기준이 됩니다.

---

## 22. Argo CD applications

2개의 Argo CD Application으로 책임을 분리했습니다.

```text
platform
 -> gitops/platform

 demo-app
 -> gitops/apps/demo-app
```

두 application 모두:

```yaml
automated:
  prune: true
  selfHeal: true
```

를 사용합니다.

### prune

Git에서 제거된 resource를 cluster에서도 제거합니다.

### selfHeal

cluster에서 직접 변경해 Git desired state와 달라지면 다시 Git 상태로 복구합니다.

---

## 23. HPA vs Argo CD ownership conflict

HPA는 Deployment의 `spec.replicas`를 변경합니다.

Argo CD가 replicas를 지속적으로 Git 값으로 복원하면 HPA와 controller ownership 충돌이 생길 수 있습니다.

따라서 Application에서:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

를 사용합니다.

그리고:

```yaml
syncOptions:
  - RespectIgnoreDifferences=true
```

를 설정했습니다.

이 실습은 GitOps에서 중요한 질문을 보여줍니다.

> 어떤 필드를 Git이 소유하고 어떤 필드를 runtime controller가 소유할 것인가?

---

## 24. Kustomize failure troubleshooting

처음 Argo CD 상태:

```text
SYNC STATUS: Unknown
HEALTH STATUS: Healthy
```

Condition:

```text
ComparisonError
```

실제 원인:

```text
gitops/platform/gatewayclass.yaml: no such file or directory
gitops/apps/demo-app/deployment.yaml: no such file or directory
```

`kustomization.yaml`만 Git에 있고 실제 참조 파일이 없었던 상태였습니다.

중요한 교훈:

```text
Argo CD는 로컬 filesystem을 보지 않는다.
Argo CD는 Git에 commit된 desired state를 본다.
```

Git에 올리기 전에 아래 명령으로 manifest generation을 확인하는 습관이 좋습니다.

```bash
kubectl kustomize gitops/platform
kubectl kustomize gitops/apps/demo-app
```

그리고 server-side validation:

```bash
kubectl apply --dry-run=server -k gitops/platform
kubectl apply --dry-run=server -k gitops/apps/demo-app
```

---

## 25. Argo CD refresh

Git commit 이후 바로 최신 revision이 반영되지 않았을 때 hard refresh로 확인했습니다.

```bash
kubectl annotate application demo-app \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

Watch:

```bash
kubectl get application demo-app -n argocd -w
```

실제 상태 변화:

```text
Synced / Progressing
        ->
Synced / Healthy
```

---

# Part 7. CI/CD

## 26. GitHub Actions + GHCR

최종 CI/CD 구조:

```text
Developer
   |
 git push
   |
   v
GitHub Actions
   |
   +-- Checkout
   +-- Docker Buildx
   +-- GHCR login
   +-- Build and Push
   +-- Update deployment image SHA
   +-- Commit GitOps manifest
            |
            v
         Argo CD
            |
            v
      Kubernetes rollout
```

GitHub Actions가 `GITHUB_TOKEN`으로 GHCR에 push합니다.

필요 workflow permissions:

```yaml
permissions:
  contents: write
  packages: write
```

---

## 27. Immutable image tag

처음:

```yaml
image: platform-api:v1
```

최종:

```yaml
image: ghcr.io/bokeumeom/platform-api:<github-sha>
```

예:

```text
ghcr.io/bokeumeom/platform-api:c17dc88738aec4488d78fd51066fcf331206da67
```

왜 SHA를 사용하는가:

```text
latest
 -> mutable
 -> 동일한 이름의 이미지 내용이 바뀔 수 있음

commit SHA
 -> immutable reference
 -> source와 image 버전 매핑 가능
 -> rollback / audit / reproduction이 쉬움
```

---

## 28. GitOps manifest automatic update

CI가 image를 build한 다음 `deployment.yaml`을 자동 변경합니다.

```text
image: ghcr.io/bokeumeom/platform-api:<full-sha>
APP_VERSION: <short-sha>
```

그 다음 GitHub Actions bot이 commit합니다.

예:

```text
chore: deploy platform-api c17dc88
```

Argo CD가 이 commit을 감지하고 rolling deployment를 수행합니다.

---

## 29. End-to-end verification

### Argo CD

```bash
kubectl get applications -n argocd
```

목표:

```text
NAME       SYNC STATUS   HEALTH STATUS
demo-app   Synced        Healthy
platform   Synced        Healthy
```

### Deployment image

```bash
kubectl get deployment web \
  -n demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Rollout

```bash
kubectl rollout status deployment/web -n demo-app
```

정상:

```text
deployment "web" successfully rolled out
```

### Pod distribution

```bash
kubectl get pods -n demo-app -o wide
```

최종 확인 결과:

```text
Pod A -> desktop-worker2
Pod B -> desktop-worker
```

즉 GitOps deployment와 topology spread 모두 실제로 검증했습니다.

---

# Part 8. Troubleshooting summary

## 30. Docker socket permission denied

증상:

```text
permission denied while trying to connect to the docker API
```

확인할 것:

```text
Docker Desktop WSL integration
docker group membership
/var/run/docker.sock permissions
```

---

## 31. Argo CD Unknown + Healthy

증상:

```text
SYNC STATUS   Unknown
HEALTH STATUS Healthy
```

확인:

```bash
kubectl get application demo-app -n argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}{" : "}{.message}{"\n"}{end}'
```

이번 lab 원인:

```text
Kustomize referenced file missing from Git
```

---

## 32. Gateway Accepted=True / Programmed=False

확인:

```bash
kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{" message="}{.message}{"\n"}{end}'
```

이번 lab 원인:

```text
local kind cluster had no LoadBalancer implementation
```

해결:

```text
MetalLB
```

---

## 33. Both Pods scheduled on one worker

증상:

```text
Pod A -> desktop-worker2
Pod B -> desktop-worker2
```

확인:

```bash
kubectl get nodes
kubectl get deployment web -n demo-app \
  -o jsonpath='{.spec.template.spec.topologySpreadConstraints}'
```

확인 포인트:

- worker가 `SchedulingDisabled` 상태인가?
- topology spread가 실제 Deployment spec에 있는가?
- 기존 Pod가 scheduling 전에 생성된 상태인가?

필요시:

```bash
kubectl uncordon desktop-worker
kubectl rollout restart deployment/web -n demo-app
```

최종 결과:

```text
desktop-worker   -> 1 Pod
desktop-worker2  -> 1 Pod
```

---

# Part 9. What this lab demonstrates

이 프로젝트에서 중요한 것은 특정 tool 설치 자체가 아닙니다.

아래 연결을 실제로 구현했다는 점이 핵심입니다.

```text
Kubernetes workload operations
        +
Gateway API ownership model
        +
Scheduling / availability
        +
GitOps reconciliation
        +
CI / container registry
        +
Immutable deployment
```

CKA 관점에서는 Kubernetes object와 scheduling, troubleshooting을 연습하고, Platform Engineering 관점에서는 GitOps와 traffic ownership, delivery pipeline까지 확장합니다.

---

# Part 10. Next learning path

## Phase 1 - Observability

다음 단계:

```text
Prometheus
Grafana
kube-state-metrics
FastAPI metrics
Envoy Gateway metrics
OpenTelemetry
```

목표:

```text
Can deploy
   ->
Can observe
   ->
Can operate
```

## Phase 2 - TLS and policy

```text
cert-manager
Gateway HTTPS listener
NetworkPolicy
Admission / policy controls
```

## Phase 3 - EKS

로컬 kind에서 학습한 개념을 AWS로 옮깁니다.

```text
kind                 -> EKS
MetalLB              -> AWS Load Balancing
static worker nodes  -> Karpenter
local image flow     -> GHCR/ECR strategy
manual infra         -> Terraform
```

Karpenter 실습에서는 다음을 중점적으로 확인할 예정입니다.

```text
NodePool
EC2NodeClass
NodeClaim
Spot / On-Demand
consolidation
workload scheduling constraints
```

---

# Quick verification commands

현재 lab 상태를 빠르게 확인할 때 사용할 명령입니다.

```bash
echo "=== Argo CD ==="
kubectl get applications -n argocd

echo
echo "=== Nodes ==="
kubectl get nodes

echo
echo "=== Gateway ==="
kubectl get gateway -n platform-system

echo
echo "=== HTTPRoute ==="
kubectl get httproute -n demo-app

echo
echo "=== HPA / PDB ==="
kubectl get hpa,pdb -n demo-app

echo
echo "=== Deployment Image ==="
kubectl get deployment web -n demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

echo
echo "=== Pods ==="
kubectl get pods -n demo-app \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image'
```

Expected high-level state:

```text
Argo CD       Synced / Healthy
Gateway       Programmed
HTTPRoute     Accepted / ResolvedRefs
Deployment    GHCR commit SHA image
Pods          distributed across worker nodes
```
