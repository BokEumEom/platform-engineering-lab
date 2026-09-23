# Kubernetes basics

This chapter keeps the workload-availability and scheduling concepts that were duplicated across the original 00/01 walkthroughs.

## Resource requests and limits

Requests influence scheduler placement and are also the denominator for CPU-utilization based HPA decisions. Limits cap container resource use. Treat these values as operational behavior, not documentation-only metadata.

## Metrics and HPA

Check whether resource metrics are available:

~~~bash
kubectl top nodes
kubectl top pods -A
~~~

Then inspect the application HPA:

~~~bash
kubectl get hpa -n demo-app
kubectl get hpa -n demo-app -w
~~~

The repository's desired state is canonical; temporary load generators are test tooling and should be removed after the experiment.

## PodDisruptionBudget

PDB protects availability during voluntary disruption such as drain or maintenance. It does not prevent a crashing process or involuntary node failure.

~~~bash
kubectl get pdb -n demo-app
~~~

## Node operations

~~~bash
kubectl get pods -n demo-app -o wide
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
~~~

uncordon makes a node schedulable again; it does not rebalance existing Pods.

## Scheduling controls

Use topologySpreadConstraints when replicas should be distributed across topology domains. Pod anti-affinity can impose stronger separation but may leave Pods Pending when capacity is insufficient.

Taints repel Pods unless they have a matching toleration. A toleration does not select a node; use labels and node affinity when placement must target a particular node class.

## Troubleshooting order

When a Pod is unhealthy:

~~~bash
kubectl get pods -n demo-app -o wide
kubectl describe pod -n demo-app <pod>
kubectl logs -n demo-app <pod>
kubectl get events -n demo-app --sort-by=.lastTimestamp
~~~

Continue with [Gateway](gateway.md).
