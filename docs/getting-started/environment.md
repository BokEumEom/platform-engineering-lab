# Environment

[Back to getting started](README.md)

This chapter preserves the environment, Helm, and GitHub access steps from the original beginner walkthrough.

## Part 1. 개발 환경 준비

### 1. 현재 Lab 환경

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

### 2. Docker Desktop + WSL2 연결

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

### 3. Kubernetes cluster 확인

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

## Part 2. Helm 준비

### 4. Helm이 왜 필요한가

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

### 5. Ubuntu / WSL에서 Helm 설치

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

## Part 11. GitHub 인증

### 32. HTTPS password가 동작하지 않는 이유

Git push 중:

```text
Username for 'https://github.com':
Password for 'https://...@github.com':
```

가 나와도 GitHub 계정 password를 사용하는 방식이 아닙니다.

HTTPS를 사용하려면 PAT를 사용할 수 있지만, 이 Lab의 WSL 개발 환경은 SSH 방식으로 전환했습니다.

---

### 33. SSH key 사용

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
