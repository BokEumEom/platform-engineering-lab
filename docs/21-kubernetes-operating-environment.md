# Kubernetes operating environment baseline

[한국어](ko/21-kubernetes-operating-environment.md)

The project prioritizes a complete Kubernetes operating baseline before changing the cluster dataplane with Cilium or enabling a service mesh.

## Completion order

```text
workload lifecycle
→ autoscaling / quota
→ storage / PVC
→ NetworkPolicy
→ observability
→ incident / recovery scenarios
→ eBPF / Hubble
→ optional service mesh
```

The goal is not to maximize the number of installed components. Each layer must create useful, reproducible evidence for the Infrastructure Engineering Harness.

## Current baseline

Already live verified:

- six independent application services;
- Argo CD GitOps reconciliation;
- MetalLB + Envoy Gateway + Gateway API;
- HPA / PDB;
- Terraform-owned ResourceQuota foundation;
- Prometheus / Grafana / Alertmanager;
- Loki / Alloy;
- OpenTelemetry Collector / Tempo;
- metric → log → exact trace enrichment correlation;
- one live verified GitOps fault/recovery benchmark.

Added as the storage operating layer:

- `storage-probe` StatefulSet;
- one 1Gi `ReadWriteOnce` PVC using the cluster default StorageClass;
- `STORAGE_FILL_MIB=0` as the healthy default fault profile;
- PVC object metrics through kube-state-metrics;
- filesystem/inode metrics through kubelet volume stats when supported by the local CSI/kubelet;
- PVC alerts and Grafana dashboard;
- dedicated storage smoke.

## Storage evidence

Object-state signals:

```text
kube_persistentvolumeclaim_info
kube_persistentvolumeclaim_status_phase
kube_persistentvolumeclaim_resource_requests_storage_bytes
```

Filesystem signals:

```text
kubelet_volume_stats_capacity_bytes
kubelet_volume_stats_used_bytes
kubelet_volume_stats_available_bytes
kubelet_volume_stats_inodes
kubelet_volume_stats_inodes_used
```

Run:

```bash
bash ops/smoke/storage.sh
```

The storage smoke is intentionally separate from the full reference-environment smoke until the current local CSI/kubelet path proves that volume stats are present. After live verification it can be promoted into the canonical full smoke.

## Storage scenario direction

A future storage benchmark will mutate only the controlled storage probe:

```text
healthy PVC
→ STORAGE_FILL_MIB increase through GitOps
→ usage > 80% / 90%
→ Prometheus + Kubernetes evidence
→ Agent storage diagnosis
→ resize / remediation proposal
→ policy / approval
→ execute through the owning control plane
→ post-check
→ rollback / truncate
```

The scenario must check `StorageClass.allowVolumeExpansion` before proposing an online resize.

## Network baseline before eBPF

Before changing the CNI, the environment should have deterministic NetworkPolicy scenarios using the current dataplane. This establishes a before/after baseline for evaluating Cilium/Hubble rather than attributing every behavior change to eBPF.

Required network scenarios:

- service-to-service deny;
- DNS deny/failure;
- allowed egress regression;
- Gateway-to-backend reachability;
- policy rollback.

## Production-style boundary

This remains a local reference environment. Production readiness additionally requires durable storage classes, snapshots/backups, CSI failure scenarios, multi-node volume behavior, topology constraints, external alert delivery, authentication/authorization and broader evaluation coverage.
