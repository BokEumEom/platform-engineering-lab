# Platform Engineering Lab — Beginner Walkthrough

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

# Part 1. 개발 환경 준비

## 1. 현재 Lab 환경

이 실습에서 사용한 환경입니다.

```text
Windows
Ubuntu 24.04 WSL2
Docker Desktop
12 vCPU
15 GiB RAM
4 GiB Swap

Kubernetes client: v1.36.1
Kubernetes server: v1.36.1
```

Docker Desktop Kubernetes의 `kind` provisioner를 사용했고 node는 3개로 구성했습니다.

```text
desktop-control-plane
desktop-worker
desktop-worker2
```

왜 3개인가?

1개 node만 있어도 Deployment/Service는 배울 수 있지만 다음 실습은 어렵습니다.

```text
cordon / drain
Pod 분산
node affinity
pod anti-affinity
taints / tolerations
topologySpreadConstraints
PDB
```

---

## 2. Docker Desktop + WSL2 연결

Docker Desktop에서 다음 설정을 확인합니다.

```text
Settings
 -> General
 -> Use WSL 2 based engine

Settings
 -> Resources
 -> WSL Integration
 -> Ubuntu enabled
```

WSL에서 확인:

```bash
docker version
```

Docker daemon 접근 시 다음 오류가 날 수 있습니다.

```text
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

확인:

```bash
ls -l /var/run/docker.sock
id
getent group docker
```

필요하면 현재 사용자를 docker 그룹에 추가합니다.

```bash
sudo groupadd -f docker
sudo usermod -aG docker "$USER"
newgrp docker
```

> Docker Desktop을 사용하는 경우 WSL 안에 별도의 Docker Engine을 또 설치하지 않는 편이 단순합니다.

---

## 3. Kubernetes cluster 확인

```bash
kubectl version
kubectl get nodes -o wide
```

정상 예시:

```text
NAME                    STATUS   ROLES
desktop-control-plane   Ready    control-plane
desktop-worker          Ready    <none>
desktop-worker2         Ready    <none>
```

모든 node가 `Ready`인지 먼저 확인합니다.

초보자가 기억할 것:

```text
kubectl
  = Kubernetes API Server에 명령을 보내는 CLI

kubectl get
  = 현재 상태 조회

kubectl apply
  = YAML에 선언한 desired state를 cluster에 적용
```

---

# Part 2. Helm 준비

## 4. Helm이 왜 필요한가

`kubectl apply`는 Kubernetes YAML을 직접 적용할 때 사용합니다.

반면 Envoy Gateway처럼 여러 Kubernetes resource와 CRD가 포함된 소프트웨어는 Helm chart로 배포하면 편리합니다.

```text
kubectl apply
 -> Kubernetes YAML 적용

Helm
 -> Kubernetes application package(chart) 설치/업그레이드 관리
```

이번 Lab에서는 Envoy Gateway 설치에 Helm을 사용했습니다.

---

## 5. Ubuntu / WSL에서 Helm 설치

먼저 확인합니다.

```bash
helm version
```

없다면 Debian/Ubuntu용 Helm APT repository를 사용할 수 있습니다.

```bash
HELM_BUILDKITE_APT_KEY_ID="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"

sudo apt-get install curl gpg apt-transport-https --yes

curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
  > "${TMPDIR:-/tmp}/helm.gpg"

if [ "$(gpg --show-keys --with-colons "${TMPDIR:-/tmp}/helm.gpg" \
  | awk -F: '$1 == "fpr" {print $10}' \
  | head -n 1)" != "${HELM_BUILDKITE_APT_KEY_ID}" ]; then
  echo "ERROR: Unexpected Helm APT key ID"
  exit 1
fi

cat "${TMPDIR:-/tmp}/helm.gpg" \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/helm.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

sudo apt-get update
sudo apt-get install helm
```

확인:

```bash
helm version
```

---

# Part 3. Gateway API + Envoy Gateway

## 6. Gateway API를 먼저 이해하기

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

## 7. Envoy Gateway 설치 — Helm

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

## 8. Envoy Gateway 공식 quickstart로 먼저 검증

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

# Part 4. FastAPI workload

## 9. Repository clone

```bash
git clone git@github.com:BokEumEom/platform-engineering-lab.git
cd platform-engineering-lab
```

현재 주요 구조:

```text
apps/api/
  Dockerfile
  main.py
  requirements.txt

gitops/platform/
  gatewayclass.yaml
  gateway.yaml
  kustomization.yaml

gitops/apps/demo-app/
  deployment.yaml
  service.yaml
  httproute.yaml
  hpa.yaml
  pdb.yaml
  kustomization.yaml
```

---

## 10. FastAPI endpoints

샘플 API는 다음 endpoint를 제공합니다.

```text
GET /
GET /health/live
GET /health/ready
```

`/` 응답에는 Pod hostname과 version이 포함됩니다.

이유:

```text
hostname
 -> 어느 Pod가 요청을 처리했는지 확인

version
 -> 어느 application version이 배포됐는지 확인
```

---

## 11. Probe 이해

Deployment에는 readiness와 liveness probe가 있습니다.

```text
readinessProbe
 -> 지금 traffic을 받아도 되는가?

livenessProbe
 -> container가 살아 있는가? 재시작이 필요한가?
```

확인:

```bash
kubectl describe pod -n demo-app <pod-name>
```

---

## 12. Resource requests / limits

현재 application 예시:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

중요한 이유:

```text
Scheduler
 -> requests를 기준으로 node 배치 판단

HPA CPU utilization
 -> actual CPU / requested CPU
```

따라서 requests는 단순 문서 값이 아니라 scheduling과 autoscaling에 직접 영향을 줍니다.

---

# Part 5. Metrics Server + HPA

## 13. Metrics Server가 필요한 이유

HPA에서 CPU utilization을 사용하려면 cluster가 Pod/Node resource metrics를 제공해야 합니다.

먼저 확인:

```bash
kubectl top nodes
kubectl top pods -n demo-app
```

metrics API가 없다면 Metrics Server를 설치합니다.

---

## 14. Metrics Server 설치 — kubectl apply

```bash
kubectl apply \
  -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Docker Desktop / kind local 환경에서 kubelet certificate 검증 문제로 동작하지 않는 경우 이 Lab에서는 다음 옵션을 추가했습니다.

```bash
kubectl patch deployment metrics-server \
  -n kube-system \
  --type='json' \
  -p='[
    {
      "op":"add",
      "path":"/spec/template/spec/containers/0/args/-",
      "value":"--kubelet-insecure-tls"
    }
  ]'
```

> `--kubelet-insecure-tls`는 로컬 학습 환경용 우회입니다. 운영 환경에서 기본 선택으로 사용하지 않습니다.

준비 확인:

```bash
kubectl rollout status deployment/metrics-server -n kube-system
kubectl top nodes
kubectl top pods -A
```

---

## 15. HPA 확인

현재 HPA:

```text
min replicas: 2
max replicas: 6
CPU target: 50%
```

확인:

```bash
kubectl get hpa -n demo-app
```

실시간 관찰:

```bash
kubectl get hpa -n demo-app -w
```

부하 생성 예시:

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
kubectl get pods -n demo-app -w
kubectl get hpa -n demo-app -w
kubectl top pods -n demo-app
```

테스트 종료:

```bash
kubectl delete deployment load-generator -n demo-app
```

---

# Part 6. PDB와 Node 운영

## 16. PDB

현재 PDB는 최소 1개의 application Pod가 유지되도록 합니다.

```yaml
minAvailable: 1
```

확인:

```bash
kubectl get pdb -n demo-app
```

PDB는 Pod crash 자체를 방지하는 기능이 아닙니다.

주로 다음과 같은 **voluntary disruption**에서 사용됩니다.

```text
kubectl drain
node maintenance
cluster upgrade
```

---

## 17. cordon / drain / uncordon

현재 Pod 위치:

```bash
kubectl get pods -n demo-app -o wide
```

특정 node에 신규 Pod scheduling 중지:

```bash
kubectl cordon desktop-worker
```

node의 workload를 안전하게 비우기:

```bash
kubectl drain desktop-worker \
  --ignore-daemonsets \
  --delete-emptydir-data
```

다시 scheduling 허용:

```bash
kubectl uncordon desktop-worker
```

중요:

```text
uncordon != rebalance
```

uncordon은 node를 다시 사용 가능하게 할 뿐 기존 Pod를 자동으로 재배치하지 않습니다.

---

# Part 7. Pod Scheduling

## 18. topologySpreadConstraints

두 replica가 같은 worker에 몰리지 않도록 사용합니다.

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

최종 Lab 상태:

```text
desktop-worker   -> web Pod 1개
desktop-worker2  -> web Pod 1개
```

확인:

```bash
kubectl get pods -n demo-app -o wide
```

---

## 19. Pod anti-affinity

개념 비교:

```text
Pod Anti-Affinity
 -> 특정 Pod끼리 같은 topology에 놓이지 않도록 제한

Topology Spread Constraints
 -> Pod를 topology에 가능한 균등하게 분산
```

strict anti-affinity는 node가 부족하면 Pod를 `Pending`으로 만들 수 있습니다.

---

## 20. Taint / Toleration / Node Affinity

Node에 taint 추가:

```bash
kubectl taint node desktop-worker2 workload=platform:NoSchedule
```

핵심:

```text
Taint
 -> 이 node에는 조건을 만족하지 않는 Pod를 받지 마라

Toleration
 -> 이 Pod는 해당 taint를 견딜 수 있다
```

중요:

```text
Toleration != node 선택
```

특정 node를 선택하려면 label과 affinity를 함께 사용합니다.

```bash
kubectl label node desktop-worker2 workload=platform
```

이 개념은 이후 EKS의 Karpenter 학습으로 연결됩니다.

---

# Part 8. 로컬 LoadBalancer — MetalLB

## 21. 왜 MetalLB가 필요했는가

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

## 22. MetalLB 설치 — kubectl apply

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

## 23. MetalLB IP pool 설정

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

# Part 9. Argo CD 설치

## 24. Argo CD가 왜 필요한가

처음에는 다음처럼 직접 cluster에 YAML을 적용할 수 있습니다.

```bash
kubectl apply -f deployment.yaml
```

하지만 GitOps에서는 Git을 desired state의 기준으로 사용합니다.

```text
Git
 = 원하는 상태(desired state)

Kubernetes
 = 현재 실제 상태(actual state)

Argo CD
 = 둘을 계속 비교하고 맞추는 controller
```

---

## 25. Argo CD 설치 — kubectl apply

이 Lab에서는 non-HA 설치를 사용했습니다.

실습 당시 사용한 버전은 `v3.5.2`입니다.

```bash
kubectl create namespace argocd

kubectl apply \
  -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
```

왜 `--server-side --force-conflicts`인가?

Argo CD의 일부 CRD는 크고, server-side apply 방식이 설치 시 더 적합합니다.

설치 확인:

```bash
kubectl get pods -n argocd -w
```

또는:

```bash
kubectl get deploy,statefulset,pods -n argocd
```

모든 주요 component가 `Running` 또는 `Available` 상태인지 확인합니다.

---

## 26. Argo CD UI 접속

로컬 cluster에서는 port-forward가 간단합니다.

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

브라우저:

```text
https://localhost:8080
```

초기 username:

```text
admin
```

초기 password:

```bash
kubectl -n argocd \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' \
  | base64 -d

echo
```

---

## 27. Argo CD CLI 설치

Lab에서 사용한 버전에 맞추는 예시:

```bash
curl -sSL \
  -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/download/v3.5.2/argocd-linux-amd64

sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
rm /tmp/argocd
```

확인:

```bash
argocd version --client
```

port-forward가 실행된 상태에서 login:

```bash
argocd login localhost:8080 \
  --username admin \
  --insecure
```

---

# Part 10. GitOps Bootstrap

## 28. Kustomize 먼저 로컬 검증

Argo CD에게 맡기기 전에 Git에 올라갈 manifest가 정상적으로 생성되는지 확인합니다.

```bash
kubectl kustomize gitops/platform
kubectl kustomize gitops/apps/demo-app
```

server-side dry run:

```bash
kubectl apply --dry-run=server -k gitops/platform
kubectl apply --dry-run=server -k gitops/apps/demo-app
```

이 단계는 매우 중요합니다.

실제로 처음 Argo CD를 연결했을 때 다음 오류가 발생했습니다.

```text
ComparisonError

gatewayclass.yaml: no such file or directory
deployment.yaml: no such file or directory
```

원인은 `kustomization.yaml`은 Git에 있었지만 참조하는 실제 YAML 파일이 Git에 없었기 때문입니다.

기억할 것:

```text
Argo CD는 내 WSL local filesystem을 보지 않는다.
Argo CD는 Git에 commit된 내용을 본다.
```

---

## 29. Argo CD Application bootstrap

이 Lab은 Application을 두 개로 나눕니다.

```text
platform
 -> gitops/platform

 demo-app
 -> gitops/apps/demo-app
```

Bootstrap:

```bash
kubectl apply -f argocd/platform.yaml
kubectl apply -f argocd/demo-app.yaml
```

확인:

```bash
kubectl get applications -n argocd
```

최종 목표:

```text
NAME       SYNC STATUS   HEALTH STATUS
demo-app   Synced        Healthy
platform   Synced        Healthy
```

---

## 30. Argo CD 자동 동기화

Application은 다음을 사용합니다.

```yaml
automated:
  prune: true
  selfHeal: true
```

의미:

```text
prune
 -> Git에서 지운 resource를 cluster에서도 제거

selfHeal
 -> cluster에서 수동 변경해 Git과 달라지면 다시 Git 상태로 복원
```

---

## 31. HPA와 Argo CD 충돌 방지

HPA는 Deployment의 replica 수를 runtime에서 변경합니다.

GitOps가 replicas를 계속 Git 값으로 복구하면 HPA와 충돌합니다.

그래서 `argocd/demo-app.yaml`에는 다음 설정이 있습니다.

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

그리고:

```yaml
syncOptions:
  - RespectIgnoreDifferences=true
```

이것은 GitOps에서 중요한 ownership 문제입니다.

```text
Git이 소유하는 field는 무엇인가?
runtime controller가 소유하는 field는 무엇인가?
```

---

# Part 11. GitHub 인증

## 32. HTTPS password가 동작하지 않는 이유

Git push 중:

```text
Username for 'https://github.com':
Password for 'https://...@github.com':
```

가 나와도 GitHub 계정 password를 사용하는 방식이 아닙니다.

HTTPS를 사용하려면 PAT를 사용할 수 있지만, 이 Lab의 WSL 개발 환경은 SSH 방식으로 전환했습니다.

---

## 33. SSH key 사용

```bash
ssh-keygen -t ed25519 -C "BokEumEom"
```

agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

GitHub의:

```text
Settings
 -> SSH and GPG keys
 -> New SSH key
```

에 등록합니다.

테스트:

```bash
ssh -T git@github.com
```

repository remote를 SSH로 변경:

```bash
git remote set-url origin \
  git@github.com:BokEumEom/platform-engineering-lab.git
```

확인:

```bash
git remote -v
```

이후 `git push`, `git pull`에서 GitHub username/PAT를 반복 입력하지 않아도 됩니다.

---

# Part 12. GitHub Actions + GHCR

## 34. 최종 CI/CD 구조

```text
apps/api source change
      |
      v
GitHub Actions
      |
      +-- Checkout
      +-- Docker Buildx
      +-- GHCR login
      +-- Build image
      +-- Push image
      +-- GitOps manifest image update
      +-- bot commit
              |
              v
           Argo CD
              |
              v
       Kubernetes RollingUpdate
```

Workflow:

```text
.github/workflows/api-ci.yaml
```

GitHub Actions 권한:

```yaml
permissions:
  contents: write
  packages: write
```

GHCR image:

```text
ghcr.io/bokeumeom/platform-api:<git-commit-sha>
```

`latest`만 사용하는 대신 source commit SHA를 image tag로 사용합니다.

장점:

```text
source 추적
rollback
배포 audit
재현성
```

---

## 35. GitOps manifest 자동 변경

CI build 후 `deployment.yaml`은 자동으로 다음 형태로 변경됩니다.

```yaml
image: ghcr.io/bokeumeom/platform-api:<full-sha>
```

그리고:

```yaml
APP_VERSION: <short-sha>
```

도 함께 갱신합니다.

GitHub Actions bot commit 예:

```text
chore: deploy platform-api c17dc88
```

이 commit을 Argo CD가 감지해 Kubernetes를 업데이트합니다.

---

# Part 13. 최종 End-to-End 검증

## 36. Git 최신화

CI bot이 GitOps manifest를 commit하므로 local repository도 당겨옵니다.

```bash
git pull
```

---

## 37. Argo CD

```bash
kubectl get applications -n argocd
```

목표:

```text
demo-app   Synced   Healthy
platform   Synced   Healthy
```

필요하면 hard refresh:

```bash
kubectl annotate application demo-app \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

watch:

```bash
kubectl get application demo-app -n argocd -w
```

실제 Lab에서 확인한 상태 변화:

```text
Synced / Progressing
        ->
Synced / Healthy
```

---

## 38. Deployment image 확인

```bash
kubectl get deployment web \
  -n demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

검증된 예:

```text
ghcr.io/bokeumeom/platform-api:c17dc88738aec4488d78fd51066fcf331206da67
```

---

## 39. Rolling Update

```bash
kubectl rollout status deployment/web -n demo-app
```

정상:

```text
deployment "web" successfully rolled out
```

---

## 40. Pod 분산

```bash
kubectl get pods -n demo-app -o wide
```

최종 Lab 결과:

```text
web Pod -> desktop-worker
web Pod -> desktop-worker2
```

Node:

```bash
kubectl get nodes
```

모든 node가 `Ready` 상태인지 확인합니다.

---

# Part 14. 초보자가 꼭 기억할 Troubleshooting 순서

## 41. Pod가 이상하다

```bash
kubectl get pods -A
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace>
```

`describe`의 Events를 먼저 보는 습관이 중요합니다.

---

## 42. Argo CD가 Unknown이다

```bash
kubectl get application demo-app -n argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}{" : "}{.message}{"\n"}{end}'
```

이번 Lab의 실제 원인:

```text
Kustomize referenced YAML files were not committed to Git
```

---

## 43. Gateway가 Programmed=False다

Gateway:

```bash
kubectl get gateway platform-gateway -n platform-system
```

Route:

```bash
kubectl get httproute web -n demo-app \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}{"="}{.status}{" "}{.reason}{"\n"}{end}'
```

이번 Lab에서는:

```text
HTTPRoute Accepted=True
ResolvedRefs=True
Gateway Programmed=False
```

였고 원인은 local LoadBalancer implementation 부재였습니다.

해결:

```text
MetalLB 설치 + IPAddressPool + L2Advertisement
```

---

## 44. Pod가 한 worker에 몰린다

```bash
kubectl get nodes
kubectl get pods -n demo-app -o wide
```

확인:

```text
worker가 SchedulingDisabled인가?
topologySpreadConstraints가 Deployment에 존재하는가?
```

node가 cordon 상태라면:

```bash
kubectl uncordon desktop-worker
```

기존 Pod가 자동 재분산되는 것은 아니므로 학습 환경에서 scheduling을 다시 검증하려면:

```bash
kubectl rollout restart deployment/web -n demo-app
```

---

# Part 15. 설치 방식 한눈에 보기

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

# Part 16. 지금까지 배운 것

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

# 다음 단계

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
