# Getting started

The original beginner walkthrough was split into focused chapters so each topic has one canonical home. Existing 00/01 paths remain as compatibility entrypoints.

## Learning path

1. [Environment](environment.md) — WSL2, Docker Desktop, cluster validation, Helm, and GitHub authentication.
2. [Kubernetes basics](kubernetes-basics.md) — metrics, HPA, PDB, node operations, and scheduling.
3. [Gateway](gateway.md) — Gateway API, Envoy Gateway, and MetalLB.
4. [Workload](workload.md) — FastAPI endpoints, probes, and resource design.
5. [GitOps](gitops.md) — Argo CD installation, bootstrap, reconciliation, and ownership.
6. [Delivery](delivery.md) — GitHub Actions, GHCR, immutable delivery, and end-to-end verification.
7. [Troubleshooting](troubleshooting.md) — the repeatable checks for Pods, Argo CD, Gateway, and scheduling.

이 문서는 Kubernetes를 처음 접하는 사람도 `platform-engineering-lab`에서 지금까지 진행한 실습을 **처음부터 순서대로 다시 따라 할 수 있도록** 정리한 가이드입니다.

> 이 문서의 버전은 이 Lab에서 실제 사용한 버전을 기준으로 기록합니다. 최신 버전 사용 전에는 각 프로젝트의 공식 문서를 확인하세요.

---

## 0. 이 Lab에서 무엇을 만드는가

최종 목표는 아래 흐름을 직접 만드는 것입니다.

```text
Developer
   |
   | git push
   v
GitHub
   |
   v
GitHub Actions
   |
   +-- Docker image build
   +-- GHCR push
   +-- GitOps manifest image SHA update
   |
   v
Git repository = desired state
   |
   v
Argo CD
   |
   v
Kubernetes
   |
   +-- Deployment / Pods
   +-- Service
   +-- HTTPRoute
   +-- Gateway
   +-- HPA / PDB
```

로컬 Kubernetes에서도 실제 플랫폼 구조를 이해할 수 있도록 다음 구성요소를 사용합니다.

```text
Docker Desktop kind cluster
Envoy Gateway
Gateway API
MetalLB
FastAPI
Metrics Server
Argo CD
GitHub Actions
GHCR
```

---

## Part 15. 설치 방식 한눈에 보기

지금까지 사용한 설치/적용 방식을 정리하면 다음과 같습니다.

| 대상 | 방법 | 이유 |
|---|---|---|
| Envoy Gateway | `helm install` | 여러 CRD/controller resource를 chart로 설치 |
| Envoy quickstart | `kubectl apply -f` | 공식 예제 YAML 적용 |
| Metrics Server | `kubectl apply -f` | 공식 manifest 설치 |
| MetalLB | `kubectl apply -f` | controller/speaker 공식 manifest 설치 |
| MetalLB IP Pool | `kubectl apply -f metallb-config.yaml` | Lab network 설정 적용 |
| Argo CD | `kubectl apply --server-side -f` | 공식 CRD/controller manifest 설치 |
| Platform Gateway resources | Argo CD + Kustomize | Git을 desired state로 사용 |
| FastAPI Deployment/Service/HPA/PDB | Argo CD + Kustomize | GitOps로 application lifecycle 관리 |

여기서 가장 중요한 구분:

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

현재 Lab에서는 전자의 controller들은 bootstrap 단계에서 Helm/kubectl로 설치하고, 후자의 application/platform resource는 GitOps로 관리합니다.

향후에는 Envoy Gateway, Metrics Server, monitoring stack 등의 설치 자체도 Argo CD Application/Helm source로 옮겨 **cluster bootstrap까지 GitOps화**할 수 있습니다.

---

## Part 16. 지금까지 배운 것

이 Lab은 단순히 Kubernetes 명령을 외우는 프로젝트가 아닙니다.

연결 관계를 이해하는 것이 목적입니다.

```text
Pod
 -> Deployment
 -> Service
 -> HTTPRoute
 -> Gateway
 -> Gateway Controller
 -> LoadBalancer
```

그리고 delivery 측면에서는:

```text
Source
 -> Container Image
 -> Registry
 -> Git Desired State
 -> Argo CD Reconciliation
 -> Kubernetes Rollout
```

운영 측면에서는:

```text
requests / limits
probes
HPA
PDB
cordon / drain
topology spread
taints / tolerations
affinity
```

까지 연결했습니다.

---

## 다음 단계

다음 학습 단계는 Observability입니다.

```text
Prometheus
Grafana
kube-state-metrics
FastAPI metrics
Envoy Gateway metrics
OpenTelemetry
```

목표는:

```text
Can deploy
   ->
Can observe
   ->
Can operate
```

으로 확장하는 것입니다.
