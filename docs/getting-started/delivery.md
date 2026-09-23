# Delivery

[Back to getting started](README.md)

This chapter owns CI/CD, GHCR delivery, immutable image updates, and end-to-end verification.

## Part 12. GitHub Actions + GHCR

### 34. 최종 CI/CD 구조

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

### 35. GitOps manifest 자동 변경

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

## Part 13. 최종 End-to-End 검증

### 36. Git 최신화

CI bot이 GitOps manifest를 commit하므로 local repository도 당겨옵니다.

```bash
git pull
```

---

### 37. Argo CD

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

### 38. Deployment image 확인

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

### 39. Rolling Update

```bash
kubectl rollout status deployment/web -n demo-app
```

정상:

```text
deployment "web" successfully rolled out
```

---

### 40. Pod 분산

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
