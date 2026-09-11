# Gateway Route Namespace Invariant

All externally exposed local reference-environment endpoints use the shared path:

```text
client
→ Docker TCP proxy
→ MetalLB
→ Envoy Gateway
→ HTTPRoute
→ backend Service
```

The shared `platform-gateway` restricts attached `HTTPRoute` objects with a namespace selector:

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        gateway-access: "true"
```

Therefore every namespace that owns an `HTTPRoute` targeting `platform-gateway` must be declared in GitOps with:

```yaml
metadata:
  labels:
    gateway-access: "true"
```

This applies even when the Route is in the same namespace as the Gateway. A namespace created only through Argo CD `CreateNamespace=true` does not automatically receive this label.

## Incident learned from the reference environment

`argocd.lab.local` returned Envoy `HTTP 404` while Grafana and Prometheus routes worked. The Argo CD `HTTPRoute` lived in `platform-system`, but that namespace had been created implicitly and did not carry the `gateway-access=true` label. The Gateway therefore did not accept the Route.

The fix is to manage `platform-system` explicitly as desired state and keep the label under GitOps ownership. CI runs `scripts/validate_gateway_route_namespaces.py` so a future Route cannot target `platform-gateway` from an undeclared/unlabelled namespace.

## Verification

```bash
kubectl get ns platform-system --show-labels
kubectl get httproute argocd -n platform-system \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'

curl -k -I \
  --resolve argocd.lab.local:8443:127.0.0.1 \
  https://argocd.lab.local:8443/
```

Expected route conditions include `Accepted=True` and `ResolvedRefs=True`. The HTTP request should reach Argo CD rather than Envoy's unmatched-route 404.
