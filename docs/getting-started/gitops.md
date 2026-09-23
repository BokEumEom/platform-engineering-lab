# GitOps

[Back to getting started](README.md)

This chapter owns Argo CD installation, bootstrap, reconciliation, and field ownership.

## Part 9. Argo CD 설치

### 24. Argo CD가 왜 필요한가

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

### 25. Argo CD 설치 — kubectl apply

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

### 26. Argo CD UI 접속

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

### 27. Argo CD CLI 설치

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

## Part 10. GitOps Bootstrap

### 28. Kustomize 먼저 로컬 검증

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

### 29. Argo CD Application bootstrap

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

### 30. Argo CD 자동 동기화

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

### 31. HPA와 Argo CD 충돌 방지

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
