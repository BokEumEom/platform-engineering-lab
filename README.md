# Platform Engineering Lab

로컬 Kubernetes 환경에서 **Gateway API, GitOps, Autoscaling, Scheduling, CI/CD, Observability**를 실제로 연결해보는 Platform Engineering 학습 프로젝트입니다.

단순히 Kubernetes 리소스를 배포하는 데서 끝내지 않고, 애플리케이션 소스 변경이 GitHub Actions와 GHCR, Argo CD를 거쳐 Kubernetes까지 자동 반영되고, Prometheus/Grafana/Alertmanager로 운영 상태를 관측하고 경보까지 검증하는 흐름을 구성합니다.

## 처음 시작한다면

Kubernetes나 Platform Engineering이 익숙하지 않다면 아래 문서부터 순서대로 보는 것을 권장합니다.

1. **[Beginner Walkthrough — 처음부터 설치하고 따라 하기](docs/00-beginner-walkthrough.md)**
   - Docker Desktop + WSL2
   - `kubectl` / Helm 준비
   - Envoy Gateway `helm install`
   - Metrics Server / MetalLB / Argo CD 설치
   - GitOps bootstrap
   - GitHub Actions + GHCR

2. **[Kubernetes Platform Lab — Step by Step](docs/01-kubernetes-platform-lab.md)**
   - HPA / PDB / scheduling
   - cordon / drain
   - topology spread / affinity / taints
   - GitOps ownership
   - 실제 장애 원인과 해결 과정

3. **[Observability — Prometheus + Grafana](docs/02-observability.md)**
   - FastAPI `/metrics`
   - kube-prometheus-stack 경량 설치
   - ServiceMonitor
   - Prometheus target / PromQL
   - Grafana
   - Grafana OOMKilled troubleshooting

4. **[Grafana Dashboard as Code](docs/03-grafana-dashboard-as-code.md)**
   - RPS / 5xx / P95
   - Pod CPU / Memory / Ready Pods
   - ConfigMap + Grafana sidecar 기반 자동 로드

5. **[Envoy Gateway Metrics](docs/04-envoy-gateway-metrics.md)**
   - Envoy proxy `/stats/prometheus`
   - PodMonitor
   - Gateway RPS / latency / health
   - Gateway vs FastAPI 비교

6. **[Alerting — PrometheusRule + Alertmanager](docs/05-alerting.md)**
   - Target Down
   - 5xx rate
   - P95 latency
   - Envoy proxy down
   - Pending / Firing / Resolved lifecycle

## 현재 구현 상태

- Kubernetes v1.36.1 / Docker Desktop kind 3-node cluster
- Envoy Gateway + Gateway API
- MetalLB local `LoadBalancer`
- FastAPI sample application
- Deployment / Service / HTTPRoute
- HPA / PDB
- `topologySpreadConstraints` 기반 Pod 분산
- Argo CD automated sync / self-heal / prune
- GitHub Actions CI
- GHCR image registry
- Git commit SHA 기반 immutable deployment
- FastAPI Prometheus `/metrics`
- ServiceMonitor / PodMonitor
- Prometheus + Grafana
- Grafana Dashboard as Code
- Envoy Gateway metrics
- PrometheusRule
- Alertmanager

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
   |
   v
Argo CD
   |
   v
Kubernetes
   |
   +-------------------------------+
   |                               |
FastAPI Pod                     FastAPI Pod
   |                               |
   +---------------+---------------+
                   |
                Service
                   |
               HTTPRoute
                   |
           Envoy Gateway
                   |
                MetalLB

FastAPI /metrics  -------- ServiceMonitor ---+
                                            |
Envoy /stats/prometheus ---- PodMonitor -----+
                                            v
                                        Prometheus
                                         /      \
                                        v        v
                                    Grafana   Alert rules
                                                |
                                                v
                                           Alertmanager
```

## Platform / Application ownership model

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

## Repository structure

```text
platform-engineering-lab/
├── .github/
│   └── workflows/
│       └── api-ci.yaml
├── apps/
│   └── api/
├── argocd/
├── gitops/
│   ├── platform/
│   └── apps/demo-app/
├── observability/
│   ├── kube-prometheus-stack-values.yaml
│   ├── demo-app-servicemonitor.yaml
│   ├── demo-app-dashboard.yaml
│   ├── envoy-proxy-podmonitor.yaml
│   ├── envoy-gateway-dashboard.yaml
│   └── platform-alerts.yaml
├── docs/
│   ├── 00-beginner-walkthrough.md
│   ├── 01-kubernetes-platform-lab.md
│   ├── 02-observability.md
│   ├── 03-grafana-dashboard-as-code.md
│   ├── 04-envoy-gateway-metrics.md
│   └── 05-alerting.md
└── metallb-config.yaml
```

## Installation / Management model

| Component | Installation / Management |
|---|---|
| Envoy Gateway | Helm |
| Metrics Server | `kubectl apply -f` |
| MetalLB | `kubectl apply -f` |
| Argo CD | `kubectl apply --server-side -f` |
| Application / Gateway resources | Argo CD + Kustomize |
| Prometheus / Grafana / Alertmanager | Helm (`kube-prometheus-stack`) |
| FastAPI metrics discovery | ServiceMonitor |
| Envoy proxy metrics discovery | PodMonitor |
| Dashboards | ConfigMap / Dashboard as Code |
| Alert rules | PrometheusRule |

## Key operational lessons

### GitOps ownership

```text
Git = desired state
Kubernetes = actual state
Argo CD = reconciliation
```

HPA가 `Deployment.spec.replicas`를 소유하므로 Argo CD에서는 해당 필드를 ignore합니다.

### Immutable deployment

```text
source commit
   == container image tag
   == GitOps deployment version
```

### CI writing back to Git

CI가 같은 저장소의 GitOps manifest를 갱신하기 때문에 concurrent commit으로 non-fast-forward push가 발생할 수 있습니다. 현재 workflow는 최신 `main`을 동기화하고 push를 재시도하도록 보강했습니다.

### Resource limits are operational behavior

Grafana를 256Mi memory limit으로 시작했을 때 dashboard가 추가된 뒤 실제 `OOMKilled`가 발생했습니다.

```text
port-forward disconnect
 -> restartCount 확인
 -> lastState.reason=OOMKilled
 -> Helm values memory 조정
 -> rollout 재검증
```

### Observability layers

```text
Kubernetes metrics
        +
FastAPI application metrics
        +
Envoy Gateway metrics
        ↓
    Prometheus
       /   \
      v     v
 Grafana   Alertmanager
```

## Learning notes

- [00 — Beginner Walkthrough](docs/00-beginner-walkthrough.md)
- [01 — Kubernetes Platform Lab Step by Step](docs/01-kubernetes-platform-lab.md)
- [02 — Observability: Prometheus + Grafana](docs/02-observability.md)
- [03 — Grafana Dashboard as Code](docs/03-grafana-dashboard-as-code.md)
- [04 — Envoy Gateway Metrics](docs/04-envoy-gateway-metrics.md)
- [05 — Alerting: PrometheusRule + Alertmanager](docs/05-alerting.md)

## Next phases

1. OpenTelemetry traces
2. TLS / cert-manager
3. NetworkPolicy / RBAC / policy
4. EKS migration
5. Karpenter
6. AWS Load Balancing
7. Terraform based environment provisioning

로컬 환경에서는 Kubernetes scheduling, GitOps, traffic management, observability와 alerting을 검증하고 이후 EKS에서 cloud-native provisioning까지 확장합니다.
