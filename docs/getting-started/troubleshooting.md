# Troubleshooting

[Back to getting started](README.md)

Use these checks in order before changing desired state.

## Part 14. 초보자가 꼭 기억할 Troubleshooting 순서

### 41. Pod가 이상하다

```bash
kubectl get pods -A
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace>
```

`describe`의 Events를 먼저 보는 습관이 중요합니다.

---

### 42. Argo CD가 Unknown이다

```bash
kubectl get application demo-app -n argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}{" : "}{.message}{"\n"}{end}'
```

이번 Lab의 실제 원인:

```text
Kustomize referenced YAML files were not committed to Git
```

---

### 43. Gateway가 Programmed=False다

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

### 44. Pod가 한 worker에 몰린다

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
