# Workload and GitOps

The reference application reuses one immutable FastAPI image across multiple service roles. Kubernetes manifests, Argo CD, and CI/CD then provide the desired-state delivery path.

## Workload health

The application exposes liveness and readiness endpoints. Readiness answers whether a Pod should receive traffic; liveness answers whether the container should be restarted.

Inspect rollout and probes from actual cluster state:

~~~bash
kubectl get deploy,pod,svc -n demo-app
kubectl describe pod -n demo-app <pod>
~~~

## Render before reconciliation

Before asking Argo CD to reconcile a change, render the repository manifests:

~~~bash
kubectl kustomize gitops/platform >/tmp/platform.yaml
kubectl kustomize gitops/apps/demo-app >/tmp/demo-app.yaml
~~~

When a cluster is available, server-side dry run can catch API and admission problems that local rendering cannot.

## Argo CD ownership

Git is desired state, Kubernetes is actual state, and Argo CD reconciles the two.

~~~bash
kubectl get applications -n argocd
~~~

Application resources use automated reconciliation. Runtime-owned fields must not fight GitOps. The canonical example is Deployment replica count when HPA owns scaling; Argo CD must respect that field boundary.

Do not solve an owned-resource problem with a permanent ad-hoc kubectl patch.

## CI/CD

The CI/CD path builds an immutable image, publishes it, updates GitOps desired state, and lets Argo CD perform reconciliation. Verify the final deployed image and rollout from the cluster instead of assuming a successful build equals a successful deployment.

~~~bash
kubectl get deploy -n demo-app
kubectl rollout status deployment/platform-api -n demo-app
kubectl get pods -n demo-app -o wide
~~~

Use the actual Deployment names present in the current manifests when running rollout checks.

## Next validation

Before controlled failure scenarios, run the documented [reference environment smoke test](../18-reference-environment-smoke-test.md). Runtime claims should be supported by fresh evidence, not only by a rendered manifest or green CI.
