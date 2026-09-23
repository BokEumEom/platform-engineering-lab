# Gateway

The reference environment uses Gateway API with Envoy Gateway for HTTP routing and MetalLB for a local LoadBalancer address.

## Traffic model

~~~text
Client
  → MetalLB
  → Envoy Gateway
  → Gateway / HTTPRoute
  → Service
  → Pod
~~~

GatewayClass and Gateway are platform concerns. HTTPRoute and backend Service configuration are application-facing concerns, while the repository keeps their ownership explicit through GitOps.

## Validate Gateway API and Envoy

Check the controller and API resources before debugging an application route:

~~~bash
kubectl get pods -n envoy-gateway-system
kubectl api-resources | grep -E 'gateway|httproute'
kubectl get gatewayclass
kubectl get gateway -A
kubectl get httproute -A
~~~

A Route can be Accepted while the Gateway is not Programmed. Resource existence is not the same as a working traffic path.

## Local LoadBalancer with MetalLB

On a local cluster, Programmed=False may mean there is no implementation assigning an external address to the Envoy LoadBalancer Service.

Inspect the Docker network before configuring an address pool:

~~~bash
docker network inspect kind
kubectl get svc -n envoy-gateway-system
kubectl get ipaddresspool,l2advertisement -n metallb-system
~~~

Do not copy an IP pool from another machine without confirming the local Docker network range.

## Route admission invariant

Gateway listeners in this repository restrict route attachment by namespace labels. When a syntactically valid HTTPRoute returns 404, verify namespace admission as well as Accepted and ResolvedRefs conditions.

For the current invariant and CI guard, see [Gateway route namespace access invariant](../17-gateway-access-invariant.md).

Continue with [Workload and GitOps](workload.md).
