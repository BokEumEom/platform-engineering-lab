# Workload

[Back to getting started](README.md)

This chapter owns the application workload, probes, and resource configuration.

## Part 4. FastAPI workload

### 9. Repository clone

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

### 10. FastAPI endpoints

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

### 11. Probe 이해

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

### 12. Resource requests / limits

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
