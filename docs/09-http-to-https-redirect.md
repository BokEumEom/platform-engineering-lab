# Phase 9 — HTTP to HTTPS Redirect Enforcement

This phase changes the Gateway behavior from "HTTP and HTTPS both serve the app" to "HTTP only redirects, HTTPS serves the app".

## Goal

```text
http://web.lab.local
        |
        v
Envoy Gateway :80
        |
        v
HTTPRoute/web-http-redirect
        |
        v
301 Location: https://web.lab.local/

https://web.lab.local
        |
        v
Envoy Gateway :443
        |
        | TLS termination
        v
HTTPRoute/web
        |
        v
Service/web
        |
        v
FastAPI
```

## Why use a separate redirect route

The HTTPS application route and the HTTP redirect route have different responsibilities.

```text
HTTP listener
  -> redirect only

HTTPS listener
  -> application backend
```

Keeping them separate makes listener ownership and runtime behavior explicit.

For this lab the redirect route remains in the `demo-app` namespace because the existing Gateway only allows Routes from namespaces labeled `gateway-access=true`, and `demo-app` already participates in that model.

## 1. HTTPS application route

`gitops/apps/demo-app/httproute.yaml` now attaches only to the HTTPS listener.

```yaml
parentRefs:
  - name: platform-gateway
    namespace: platform-system
    sectionName: https
```

The backend remains:

```yaml
backendRefs:
  - name: web
    port: 80
```

TLS terminates at Envoy Gateway, so the Gateway-to-FastAPI hop remains HTTP inside the cluster.

## 2. HTTP redirect route

`gitops/apps/demo-app/http-redirect.yaml` attaches only to the HTTP listener.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-http-redirect
  namespace: demo-app
spec:
  parentRefs:
    - name: platform-gateway
      namespace: platform-system
      sectionName: http
  hostnames:
    - web.lab.local
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

`301` is used for a permanent HTTP-to-HTTPS redirect and stays within the broadly supported Gateway API redirect status-code set.

## 3. Pull Git changes

```bash
cd ~/platform-engineering-lab
git pull
```

Argo CD should reconcile automatically.

If needed, force a refresh:

```bash
kubectl annotate application demo-app \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

## 4. Validate both HTTPRoutes

```bash
kubectl get httproute -n demo-app
```

Expected resources:

```text
web
web-http-redirect
```

Inspect parent conditions:

```bash
for r in web web-http-redirect; do
  echo "=== $r ==="
  kubectl get httproute "$r" -n demo-app \
    -o jsonpath='{range .status.parents[*]}{.parentRef.sectionName}{"\t"}{range .conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{" "}{end}{"\n"}{end}'
done
```

Success criteria:

```text
web               -> https -> Accepted=True / ResolvedRefs=True
web-http-redirect -> http  -> Accepted=True / ResolvedRefs=True
```

## 5. Validate HTTP redirect through the Docker proxy

The existing WSL/Docker Desktop proxy maps local port 8080 to the MetalLB HTTP listener.

```bash
curl -I \
  -H "Host: web.lab.local" \
  http://127.0.0.1:8080/
```

Expected:

```text
HTTP/1.1 301 Moved Permanently
location: https://web.lab.local/
```

This confirms that HTTP traffic no longer reaches the application backend directly.

Because the lab HTTPS proxy listens on local port `8443` while the real Gateway listener is `443`, do not use `curl -L` against the HTTP proxy as the primary validation: the redirect correctly points to the canonical HTTPS URL on port 443.

## 6. Validate HTTPS still reaches FastAPI

```bash
curl -k \
  --resolve web.lab.local:8443:127.0.0.1 \
  https://web.lab.local:8443/
```

Expected application response:

```json
{
  "message": "platform-engineering-lab GitOps",
  "hostname": "...",
  "version": "..."
}
```

## 7. Validate routing separation

The final listener-to-route relationship should be:

```text
Gateway/platform-gateway
├─ http  :80
│   └─ HTTPRoute/web-http-redirect
│       └─ RequestRedirect 301 -> https
│
└─ https :443
    └─ HTTPRoute/web
        └─ Service/web:80
```

Check attached route counts:

```bash
kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\tattachedRoutes="}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

## Runtime completion criteria

Do not mark this phase complete until all of the following are observed:

```text
HTTPRoute/web attaches only to https              [ ]
HTTPRoute/web-http-redirect attaches only to http [ ]
HTTP request returns 301                          [ ]
Location header uses https://web.lab.local/       [ ]
HTTPS request still returns FastAPI response      [ ]
Gateway listeners remain healthy                  [ ]
```

After runtime validation, the next phase is workload and namespace security:

```text
NetworkPolicy
Pod Security Admission
ResourceQuota
LimitRange
```
