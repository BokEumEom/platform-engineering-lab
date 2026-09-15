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

Storage operating layer:

- `storage-probe` StatefulSet;
- one 1Gi `ReadWriteOnce` PVC using the cluster default StorageClass;
- `STORAGE_FILL_MIB=0` as the healthy default;
- PVC object metrics through kube-state-metrics;
- standard CSI/kubelet filesystem/inode volume stats when the local driver supports them;
- deterministic `storage-probe` fallback metrics when the local driver does not expose volume stats;
- PVC alerts, Grafana storage dashboard and dedicated storage smoke.

## Storage evidence

Object-state signals:

```text
kube_persistentvolumeclaim_info
kube_persistentvolumeclaim_status_phase
kube_persistentvolumeclaim_resource_requests_storage_bytes
```

Preferred filesystem signals:

```text
kubelet_volume_stats_capacity_bytes
kubelet_volume_stats_used_bytes
kubelet_volume_stats_available_bytes
kubelet_volume_stats_inodes
kubelet_volume_stats_inodes_used
```

### Docker Desktop local volume-stats gap

A live local run on 2026-09-15 proved that the StatefulSet rolled out, the PVC was `Bound` at 1Gi and PVC object metrics were present, while the current Docker Desktop local storage path returned no `kubelet_volume_stats_*` series for that PVC.

This is treated as a storage-driver / CSI-kubelet capability gap rather than a PVC outage.

The storage probe therefore exposes these local-lab fallback metrics:

```text
storage_probe_fill_bytes
storage_probe_requested_capacity_bytes
storage_probe_usage_ratio
storage_probe_filesystem_capacity_bytes
storage_probe_filesystem_used_bytes
storage_probe_filesystem_available_bytes
```

The evidence rule is explicit:

```text
1. prefer kubelet_volume_stats_* when present;
2. otherwise use storage_probe_* only in the local reference environment;
3. do not synthesize inode evidence;
4. never claim the fallback is equivalent to production CSI volume statistics.
```

`storage_probe_usage_ratio` is the logical fill-file size divided by the requested PVC capacity. The Docker Desktop local volume may not enforce the requested 1Gi as a filesystem quota, so this is a deterministic saturation signal for the lab rather than a complete replacement for real CSI filesystem pressure.

## Storage smoke

Run:

```bash
bash ops/smoke/storage.sh
```

Argo CD periodically polls Git and the default reconciliation window is 120 seconds plus up to 60 seconds of jitter. A short polling window can therefore create a false negative even when the controller is healthy.

The smoke does not require Argo to report the exact latest `origin/main` SHA because unrelated README, CI or documentation commits should not block storage verification. It first verifies that the local checkout matches `origin/main`, then derives the latest revisions that actually changed the storage workload and storage observability resources.

Within a five-minute bounded window it requires:

```text
local HEAD == origin/main
AND required demo-app revision is an ancestor of Argo demo-app revision
AND demo-app Synced / Healthy
AND StatefulSet/storage-probe exists
AND required observability revision is an ancestor of Argo observability-config revision
AND observability-config Synced / Healthy
AND ServiceMonitor/storage-probe exists
```

On timeout it prints the configured reconciliation interval/jitter, Application revision/sync/health/reconciledAt, conditions and operation state so repository refresh delay can be distinguished from a real sync failure.

It then selects the metric source:

```text
standard volume stats present
→ metric_source=kubelet_csi

standard volume stats absent
→ verify storage_probe_usage_ratio
→ metric_source=storage_probe_fallback
```

The smoke fails only when neither source is available.

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

The scenario must check `StorageClass.allowVolumeExpansion` before proposing an online resize. A local fallback environment must not be presented as proof of real CSI resize behavior; that requires a CSI-capable environment.

## Network baseline before eBPF

Before changing the CNI, the environment should have deterministic NetworkPolicy scenarios using the current dataplane. This establishes a before/after baseline for evaluating Cilium/Hubble rather than attributing every behavior change to eBPF.

Required network scenarios:

- service-to-service deny;
- DNS deny/failure;
- allowed egress regression;
- Gateway-to-backend reachability;
- policy rollback.

## Production-style boundary

This remains a local reference environment. Production readiness additionally requires a durable StorageClass with verified CSI volume stats, snapshots/backups, CSI failure scenarios, multi-node volume behavior, topology constraints, real online expansion verification, external alert delivery, authentication/authorization and broader evaluation coverage.
