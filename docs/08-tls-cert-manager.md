# TLS with cert-manager and Gateway API

This lab adds HTTPS to `web.lab.local` using cert-manager and the existing Envoy Gateway.

## Goal

```text
Client
  |
  | HTTPS :443
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
kubectl get crd | grep cert-manager.io
```

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

Then inspect the application:

```bash
kubectl get application platform -n argocd
```

Expected state after reconciliation:

```text
Synced   Healthy
```

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

## 4. Validate the Gateway listener

```bash
kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

The Gateway now has HTTP on port 80 and HTTPS on port 443.

The HTTPS listener terminates TLS with:

```text
Secret/platform-system/web-lab-local-tls
```

## 5. Validate the HTTPRoute attachment

The application HTTPRoute attaches to both Gateway sections:

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

Both parents should report `Accepted=True` and `ResolvedRefs=True`.

## 6. Test HTTPS correctly with SNI

Get the Gateway address:

```bash
GATEWAY_IP=$(kubectl get gateway platform-gateway \
  -n platform-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "$GATEWAY_IP"
```

Because the certificate is self-signed, use `-k` for this local test. `--resolve` is important because it sends both the correct hostname and TLS SNI while routing directly to the MetalLB address.

```bash
curl -k \
  --resolve web.lab.local:443:${GATEWAY_IP} \
  https://web.lab.local/
```

Expected application response:

```json
{
  "message": "platform-engineering-lab GitOps",
  "hostname": "...",
  "version": "..."
}
```

## 7. Inspect the certificate presented by Envoy

```bash
openssl s_client \
  -connect ${GATEWAY_IP}:443 \
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

## What this lab demonstrates

This separates responsibilities cleanly:

```text
cert-manager
  -> lifecycle of the certificate and TLS Secret

Platform team
  -> Gateway listener and certificate reference

Application team
  -> HTTPRoute attachment to HTTP/HTTPS listeners

Envoy Gateway
  -> TLS termination and routing
```

The next hardening step is HTTP-to-HTTPS redirect and then policy/security controls.
