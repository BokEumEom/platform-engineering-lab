# TLS with cert-manager and Gateway API

This lab adds HTTPS to `web.lab.local` using cert-manager and the existing Envoy Gateway.

## Goal

```text
Client
  |
  | HTTPS
  v
Docker published port (WSL/Docker Desktop lab)
  |
  v
MetalLB External IP :443
  |
  v
Envoy Gateway
  |
  | TLS termination with Secret/web-lab-local-tls
  v
HTTPRoute
  |
  v
Service/web
  |
  v
FastAPI
```

For the local `lab.local` domain we intentionally use a self-signed issuer. Public ACME providers such as Let's Encrypt cannot validate this private lab hostname. In an EKS or public-domain environment, replace the issuer without changing the Gateway certificate reference pattern.

## Runtime verification status

Verified in the local Windows + WSL2 + Docker Desktop + kind environment:

```text
cert-manager v1.21.1 installed                    ✅
cert-manager controller/webhook/cainjector Ready ✅
Issuer + Certificate reconciled                  ✅
TLS Secret created                               ✅
Gateway HTTPS listener                           ✅
Envoy TLS termination                            ✅
HTTPS request reaches demo-app / FastAPI         ✅
```

Verified application response through HTTPS:

```json
{
  "message": "platform-engineering-lab GitOps",
  "hostname": "web-674cbc59cb-2srct",
  "version": "739677a"
}
```

---

## 1. Install cert-manager

The lab pins cert-manager `v1.21.1` and keeps Gateway API integration enabled.

```bash
helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.1 \
  --namespace cert-manager \
  --create-namespace \
  -f platform/cert-manager-values.yaml
```

Wait for the controller, webhook, and CA injector:

```bash
kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager
```

Validate the CRDs:

```bash
kubectl get crd \
  issuers.cert-manager.io \
  certificates.cert-manager.io
```

---

## 2. Let Argo CD reconcile the TLS resources

The platform GitOps application manages:

- `Issuer/lab-selfsigned`
- `Certificate/web-lab-local`
- the Gateway HTTPS listener

Refresh the platform application after cert-manager is ready:

```bash
kubectl annotate application platform \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

If Argo CD was already running before the cert-manager CRDs existed and the resources do not appear, validate the manifest first without bypassing GitOps:

```bash
kubectl apply --dry-run=server \
  -f gitops/platform/tls.yaml
```

Do not use a live `kubectl apply` for the GitOps-managed TLS resources. Let Argo CD create the real objects.

Then inspect:

```bash
kubectl get application platform -n argocd
```

Expected state after reconciliation:

```text
Synced   Healthy
```

---

## 3. Validate certificate issuance

```bash
kubectl get issuer,certificate -n platform-system
```

Expected:

```text
issuer.cert-manager.io/lab-selfsigned
certificate.cert-manager.io/web-lab-local   True
```

Check the generated TLS Secret:

```bash
kubectl get secret web-lab-local-tls -n platform-system
```

The Secret should have type:

```text
kubernetes.io/tls
```

Detailed Certificate status:

```bash
kubectl describe certificate web-lab-local -n platform-system
```

Success criterion:

```text
Type:    Ready
Status:  True
```

---

## 4. Validate the Gateway listener

```bash
kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

The Gateway has HTTP on port 80 and HTTPS on port 443.

The HTTPS listener terminates TLS with:

```text
Secret/platform-system/web-lab-local-tls
```

---

## 5. Validate the HTTPRoute attachment

At this phase the application route is attached to both Gateway sections:

```text
http
https
```

Check parent conditions:

```bash
kubectl get httproute web \
  -n demo-app \
  -o jsonpath='{range .status.parents[*]}{.parentRef.sectionName}{"\t"}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

Both parents should report `Accepted=True` and `ResolvedRefs=True` before the HTTP-to-HTTPS redirect phase changes the ownership of the HTTP listener.

---

## 6. Docker Desktop / WSL HTTPS proxy

In this lab, WSL cannot reliably reach the MetalLB External IP directly because the kind network lives behind the Docker Desktop network boundary.

The HTTP tracing phase already solved this with a Docker `socat` proxy. HTTPS uses the same pattern.

Get the Gateway address:

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "$GATEWAY_IP"
```

Create the HTTPS proxy:

```bash
docker rm -f platform-gateway-https-proxy 2>/dev/null || true

docker run -d \
  --name platform-gateway-https-proxy \
  --restart unless-stopped \
  --network kind \
  -p 127.0.0.1:8443:8443 \
  alpine/socat \
  TCP-LISTEN:8443,fork,reuseaddr \
  TCP:${GATEWAY_IP}:443
```

Validate:

```bash
docker ps --filter name=platform-gateway-https-proxy
```

The traffic path is:

```text
WSL 127.0.0.1:8443
        |
        v
Docker socat proxy
        |
        v
MetalLB External IP :443
        |
        v
Envoy Gateway HTTPS listener
```

---

## 7. Test HTTPS correctly with SNI

Because the certificate is self-signed, use `-k` for this local test.

`--resolve` provides the correct hostname and SNI while connecting through the local Docker proxy.

```bash
curl -k \
  --resolve web.lab.local:8443:127.0.0.1 \
  https://web.lab.local:8443/
```

Verified response:

```json
{
  "message": "platform-engineering-lab GitOps",
  "hostname": "web-674cbc59cb-2srct",
  "version": "739677a"
}
```

This proves the runtime path:

```text
Client
 -> Docker proxy
 -> MetalLB :443
 -> Envoy Gateway
 -> TLS termination
 -> HTTPRoute
 -> demo-app Service
 -> FastAPI
```

---

## 8. Inspect the certificate presented by Envoy

```bash
openssl s_client \
  -connect 127.0.0.1:8443 \
  -servername web.lab.local \
  </dev/null 2>/dev/null \
  | openssl x509 \
      -noout \
      -subject \
      -issuer \
      -dates \
      -ext subjectAltName
```

Confirm that the SAN contains:

```text
DNS:web.lab.local
```

`-k` is required only because this local lab certificate is self-signed. HTTPS and TLS termination are functioning normally.

---

## What this lab demonstrates

This separates responsibilities cleanly:

```text
cert-manager
  -> lifecycle of the certificate and TLS Secret

Platform team
  -> Gateway listener and certificate reference

Application team
  -> HTTPRoute attachment

Envoy Gateway
  -> TLS termination and routing
```

The next hardening step is HTTP-to-HTTPS redirect and then policy/security controls.
