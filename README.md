# Platform Engineering Lab

로컬 Kubernetes 환경에서 **Gateway API, GitOps, Autoscaling, Scheduling, CI/CD**를 실제로 연결해보는 Platform Engineering 학습 프로젝트입니다.

단순히 Kubernetes 리소스를 배포하는 데서 끝내지 않고, 애플리케이션 소스 변경이 GitHub Actions와 GHCR, Argo CD를 거쳐 Kubernetes까지 자동 반영되는 흐름을 구성하는 것을 목표로 합니다.

## 처음 시작한다면

Kubernetes나 Platform Engineering이 익숙하지 않다면 아래 문서부터 순서대로 보는 것을 권장합니다.

1. **[Beginner Walkthrough — 처음부터 설치하고 따라 하기](docs/00-beginner-walkthrough.md)**
   - Docker Desktop + WSL2
   - `kubectl` / Helm 준비
   - Envoy Gateway `helm install`
   - Envoy Gateway quickstart `kubectl apply`
   - Metrics Server 설치
   - MetalLB `kubectl apply`
   - MetalLB IP Pool 설정
   - Argo CD `kubectl apply --server-side`
   - Argo CD UI/CLI 접속
   - GitOps bootstrap
   - GitHub Actions + GHCR
   - 최종 검증 및 Troubleshooting

2. **[Kubernetes Platform Lab — Step by Step](docs/01-kubernetes-platform-lab.md)**
   - 각 Kubernetes 개념을 조금 더 깊게 복습
   - HPA / PDB / scheduling
   - cordon / drain
   - topology spread / affinity / taints
   - GitOps ownership
   - 실제 장애 원인과 해결 과정

초보자에게 가장 중요한 구분은 다음입니다.

```text
Platform dependency 설치
  Envoy Gateway
  MetalLB
  Metrics Server
  Argo CD

        vs

우리 서비스의 desired state
  GatewayClass
  Gateway
  HTTPRoute
  Deployment
  Service
  HPA
  PDB
```

현재 Lab에서는 controller/dependency를 먼저 Helm 또는 `kubectl apply`로 bootstrap하고, 이후 애플리케이션과 Gateway resource는 Argo CD + Kustomize로 GitOps 관리합니다.

## 현재 구현 상태

- Kubernetes v1.36.1 / Docker Desktop kind 3-node cluster
- Envoy Gateway + Gateway API
- MetalLB 기반 로컬 `LoadBalancer` 구현
- FastAPI sample application
- Deployment / Service / HTTPRoute
- HPA / PDB
- `topologySpreadConstraints` 기반 Pod 분산
- Argo CD automated sync / self-heal / prune
- GitHub Actions CI
- GHCR image registry
- Git commit SHA 기반 immutable image deployment

현재 검증 상태:

```text
Argo CD
platform   Synced / Healthy
demo-app   Synced / Healthy

Application Pods
1 Pod -> desktop-worker
1 Pod -> desktop-worker2

Container Image
ghcr.io/bokeumeom/platform-api:<git-commit-sha>
```

## Architecture

```text
Developer
   |
   | git push
   v
GitHub Repository
   |
   v
GitHub Actions
   |
   +-- Docker Build
   +-- Push image to GHCR
   +-- Update GitOps manifest with commit SHA
   +-- Commit manifest change
          |
          v
       Argo CD
          |
          | automated sync
          v
      Kubernetes
          |
          +-------------------------------+
          |                               |
   desktop-worker                  desktop-worker2
    FastAPI Pod                     FastAPI Pod
          |                               |
          +---------------+---------------+
                          |
                       Service
                          |
                      HTTPRoute
                          |
                  platform-gateway
                          |
                    Envoy Gateway
                          |
                       MetalLB
```

## Platform / Application ownership model

Gateway API를 이용해 플랫폼 영역과 애플리케이션 영역을 분리했습니다.

```text
Platform Team
platform-system/
  GatewayClass: platform-eg
  Gateway:      platform-gateway

Application Team
demo-app/
  Deployment
  Service
  HTTPRoute
  HPA
  PDB
```

`platform-gateway`는 `gateway-access=true` 라벨이 있는 Namespace의 Route만 허용합니다.

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        gateway-access: "true"
```

Argo CD가 `demo-app` Namespace를 관리하면서 해당 라벨도 선언합니다.

## Repository structure

```text
platform-engineering-lab/
├── .github/
│   └── workflows/
│       └── api-ci.yaml
├── apps/
│   └── api/
│       ├── Dockerfile
│       ├── main.py
│       └── requirements.txt
├── argocd/
│   ├── platform.yaml
│   └── demo-app.yaml
├── gitops/
│   ├── platform/
│   │   ├── gatewayclass.yaml
│   │   ├── gateway.yaml
│   │   └── kustomization.yaml
│   └── apps/
│       └── demo-app/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── httproute.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── kustomization.yaml
├── docs/
│   ├── 00-beginner-walkthrough.md
│   └── 01-kubernetes-platform-lab.md
└── metallb-config.yaml
```

## Installation methods used in this Lab

| Component | Installation / Management |
|---|---|
| Envoy Gateway | Helm |
| Envoy quickstart | `kubectl apply -f` |
| Metrics Server | `kubectl apply -f` |
| MetalLB controller/speaker | `kubectl apply -f` |
| MetalLB network config | `kubectl apply -f metallb-config.yaml` |
| Argo CD | `kubectl apply --server-side -f` |
| Gateway / HTTPRoute / application workload | Argo CD + Kustomize |

이 설치 과정의 정확한 명령은 [Beginner Walkthrough](docs/00-beginner-walkthrough.md)에 기록했습니다.

## CI/CD flow

FastAPI 소스 또는 workflow가 변경되면 `API CI` workflow가 실행됩니다.

```text
apps/api change
     |
     v
GitHub Actions
     |
     +-- Buildx
     +-- Login to GHCR with GITHUB_TOKEN
     +-- Build / Push
     |
     v
ghcr.io/bokeumeom/platform-api:<github.sha>
     |
     v
Update gitops/apps/demo-app/deployment.yaml
     |
     v
github-actions[bot] commit
     |
     v
Argo CD detects Git desired state
     |
     v
Kubernetes RollingUpdate
```

Deployment에서는 `latest` 대신 Git commit SHA를 사용합니다.

```yaml
image: ghcr.io/bokeumeom/platform-api:<commit-sha>
```

이를 통해 배포된 소스 버전을 Git에서 추적하고 재현할 수 있습니다.

## Kubernetes concepts practiced

이 프로젝트에서 직접 실습한 주요 항목입니다.

- Cluster / Node / Pod 기본 구조
- Deployment / Service
- readinessProbe / livenessProbe
- requests / limits
- GatewayClass / Gateway / HTTPRoute
- Namespace 기반 route ownership
- HPA
- PDB
- cordon / drain / uncordon
- taints / tolerations
- node affinity
- pod anti-affinity
- topology spread constraints
- Kustomize
- Argo CD GitOps
- container registry / immutable image tag
- rolling deployment

## Key lessons

### Gateway API

Ingress 리소스 중심이 아니라 `GatewayClass -> Gateway -> HTTPRoute` 구조로 트래픽 관리 책임을 분리했습니다.

### GitOps

클러스터에 직접 `kubectl apply` 하는 대신 Git을 desired state의 기준으로 사용합니다.

```text
Git = desired state
Kubernetes = actual state
Argo CD = reconciliation
```

### HPA and GitOps

HPA가 Deployment replica 수를 변경할 수 있으므로 Argo CD가 `/spec/replicas`를 다시 덮어쓰지 않도록 설정했습니다.

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

### Scheduling

2개의 worker node에 FastAPI Pod가 분산되도록 `topologySpreadConstraints`를 사용했습니다.

```text
desktop-worker   -> FastAPI Pod
desktop-worker2  -> FastAPI Pod
```

### Immutable deployment

CI가 만든 이미지의 Git commit SHA를 GitOps manifest에 기록합니다.

```text
source commit
   == container image tag
   == GitOps deployment version
```

## Learning notes

- [00 — Beginner Walkthrough](docs/00-beginner-walkthrough.md)
- [01 — Kubernetes Platform Lab Step by Step](docs/01-kubernetes-platform-lab.md)

## Next phases

다음 단계는 아래 순서로 확장할 예정입니다.

1. Observability
   - Prometheus
   - Grafana
   - kube-state-metrics
   - FastAPI metrics
   - Envoy Gateway metrics
   - OpenTelemetry
2. TLS / cert-manager
3. Policy / security
4. EKS migration
5. Karpenter
6. AWS Load Balancing
7. Terraform based environment provisioning

로컬 환경에서는 Kubernetes 스케줄링과 GitOps 동작을 검증하고, 이후 EKS에서 클라우드 node provisioning과 Karpenter까지 확장하는 방향입니다.
