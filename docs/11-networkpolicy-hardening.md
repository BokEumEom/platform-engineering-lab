# Phase 11 — NetworkPolicy hardening with Harness verification

Status: **candidate / runtime enforcement evidence required**

This phase follows the `infrastructure-engineering-harness` evidence boundary:

```text
reference support
  !=
runtime enforcement evidence
```

The target is to reduce `demo-app` network reachability without breaking:

- Envoy Gateway -> FastAPI traffic
- Prometheus -> `/metrics` scraping
- FastAPI -> OpenTelemetry Collector OTLP/gRPC
- DNS resolution required for the Collector service

## 1. Why verification comes first

Current kind releases use kindnetd, and modern kindnetd includes Kubernetes NetworkPolicy evaluation. That is implementation/reference evidence, not proof that the current local cluster is enforcing policies correctly.

Before changing `demo-app`, verify enforcement in an isolated namespace.

## 2. Inspect the current CNI

```bash
kind version

kubectl get daemonset -n kube-system kindnet -o wide
kubectl get pods -n kube-system -l app=kindnet -o wide
```

If the kindnet DaemonSet is present and Ready, continue with the behavioral test.

## 3. Behavioral enforcement test

Create an isolated test namespace and server:

```bash
kubectl create namespace netpol-test

kubectl create deployment server \
  -n netpol-test \
  --image=nginx:alpine

kubectl expose deployment server \
  -n netpol-test \
  --port=80

kubectl rollout status deployment/server -n netpol-test
```

Create a client Pod:

```bash
kubectl run client \
  -n netpol-test \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- sleep 3600

kubectl wait \
  -n netpol-test \
  --for=condition=Ready pod/client \
  --timeout=60s
```

Baseline request must succeed:

```bash
kubectl exec -n netpol-test client -- \
  wget -qO- --timeout=3 http://server
```

Apply a deny-ingress policy only to the test server:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-server-ingress
  namespace: netpol-test
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes:
    - Ingress
EOF
```

The same request must now fail or time out:

```bash
kubectl exec -n netpol-test client -- \
  wget -qO- --timeout=3 http://server
```

Success criterion:

```text
before NetworkPolicy: request succeeds
after NetworkPolicy:  request is denied / times out
```

Cleanup:

```bash
kubectl delete namespace netpol-test
```

Do not promote the demo-app policy to GitOps unless this behavioral test passes.

## 4. Proposed demo-app policy boundary

Once enforcement is verified, `app=web` Pods will be isolated for both ingress and egress.

### Ingress to FastAPI :8000

Allow only namespaces that currently require direct Pod/Service access:

```text
envoy-gateway-system -> TCP/8000
monitoring            -> TCP/8000
```

The `monitoring` allowance is required because Prometheus scrapes `/metrics` through the `demo-app` ServiceMonitor.

### Egress from FastAPI

Allow:

```text
kube-system -> UDP/TCP 53     # DNS
monitoring  -> TCP 4317       # OTel Collector OTLP/gRPC
```

No general internet egress is required by the current FastAPI application code.

## 5. Regression obligations after promotion

After the NetworkPolicy is included in the `demo-app` Kustomization, all of the following must remain true.

### Argo CD / workload

```bash
kubectl get application demo-app -n argocd
kubectl rollout status deployment/web -n demo-app
kubectl get networkpolicy -n demo-app
```

### HTTP redirect

```bash
curl -I \
  -H "Host: web.lab.local" \
  http://127.0.0.1:8080/
```

Expected: `301` redirect to HTTPS.

### HTTPS application path

```bash
curl -k \
  --resolve web.lab.local:8443:127.0.0.1 \
  https://web.lab.local:8443/
```

Expected: FastAPI JSON response.

### Metrics

Prometheus target for `demo-app` must remain `UP`.

### Distributed tracing

Generate HTTPS requests and confirm the same trace still contains:

```text
ingress
└─ platform-api
   └─ GET /
```

This verifies both Gateway ingress and application egress to the OpenTelemetry Collector.

## 6. Harness completion rule

This phase is complete only when:

```text
NetworkPolicy enforcement test passes
        +
GitOps policy applied
        +
Gateway request regression passes
        +
Prometheus scrape remains healthy
        +
Envoy -> FastAPI distributed trace remains healthy
```

Until then the status remains **unverified**.
