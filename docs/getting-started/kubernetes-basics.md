# Kubernetes basics

[Back to getting started](README.md)

This chapter owns autoscaling, disruption, node operations, and scheduling concepts.

## Part 5. Metrics Server + HPA

### 13. Metrics Server가 필요한 이유

HPA에서 CPU utilization을 사용하려면 cluster가 Pod/Node resource metrics를 제공해야 합니다.

먼저 확인:

```bash
kubectl top nodes
kubectl top pods -n demo-app
```

metrics API가 없다면 Metrics Server를 설치합니다.

---

### 14. Metrics Server 설치 — kubectl apply

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

### 15. HPA 확인

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

## Part 6. PDB와 Node 운영

### 16. PDB

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

### 17. cordon / drain / uncordon

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

## Part 7. Pod Scheduling

### 18. topologySpreadConstraints

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

### 19. Pod anti-affinity

개념 비교:

```text
Pod Anti-Affinity
 -> 특정 Pod끼리 같은 topology에 놓이지 않도록 제한

Topology Spread Constraints
 -> Pod를 topology에 가능한 균등하게 분산
```

strict anti-affinity는 node가 부족하면 Pod를 `Pending`으로 만들 수 있습니다.

---

### 20. Taint / Toleration / Node Affinity

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
