# HPA + ResourceQuota Policy-Gated Benchmark

Status: **implemented / live calibration required**

This is Scenario #2 for the Infrastructure Engineering Harness reference environment. It expands the validated read-only diagnostic loop into an explicitly approved cross-owner infrastructure change.

## Goal

```text
real HTTPS load
→ HPA scale pressure
→ Terraform-owned ResourceQuota blocks Pod creation
→ Agent correlates HPA + recent FailedCreate quota evidence
→ Agent proposes Terraform + GitOps remediation
→ deterministic policy classifies risk
→ human approves the exact proposal digest
→ one-shot ChangeControl grant is created and revalidated
→ Terraform + GitOps execute
→ live post-check under continued load
→ temporary HPA change rolls back
→ final healthy verification
```

The benchmark is a local-lab mutation workflow. It is not an autonomous production write path.

## Ownership boundary

The scenario deliberately uses two independent ownership domains without managing the same object from two systems.

```text
Terraform
→ ResourceQuota/demo-app-capacity

GitOps / Argo CD
→ HorizontalPodAutoscaler/web
→ Deployments / Services / PDBs / routes / application configuration
```

Terraform must not manage the HPA, and Argo CD must not manage the ResourceQuota.

## Capacity profiles

Normal reference-environment quota:

```text
requests.cpu = 2
```

Controlled constrained profile:

```text
requests.cpu = 900m
```

The current six-service request footprint remains below the constrained limit at rest, while additional `web` replicas request `100m` CPU each. Under sufficient load, the HPA can request scale-out that the constrained namespace CPU budget rejects.

The benchmark must fail safely if this assumption does not hold in the actual local cluster. The first live run is therefore calibration evidence, not a guaranteed synthetic result.

## Agent evidence

The Kubernetes adapter already collects:

```text
k8s.hpa
  min / max / current / desired / conditions

k8s.deployments
  desired / ready / available / updated

k8s.warning_events
  recent Warning event reason/object/message/time
```

The capacity reviewer uses recent, workload-scoped `exceeded quota` events only. Historical quota events outside the configured age window are not treated as current root-cause evidence.

Correlation can be established when recent quota rejection exists together with HPA scale pressure, including either:

```text
ScalingLimited=True
OR desiredReplicas > currentReplicas
OR currentReplicas >= maxReplicas
```

This avoids assuming that Kubernetes always sets `ScalingLimited=True` when ResourceQuota prevents ReplicaSet Pod creation.

## Proposed remediation

When correlation is present, the Agent produces a bounded proposal similar to:

```text
Terraform:
  ResourceQuota/demo-app-capacity requests.cpu
  900m → 2

GitOps:
  HorizontalPodAutoscaler/web maxReplicas
  6 → 8
```

The proposal includes explicit post-check and rollback requirements.

## Policy

`change-policy` evaluates the proposal before approval.

For this scenario the expected result is:

```text
risk = medium
decision = approval_required
approval_required = true
executable = true

reasons include:
- capacity increase
- cost implication
- cross-ownership change
```

Destructive, privilege-expanding, or public-exposure proposals are classified high risk and blocked by the reference policy rather than being made executable through approval alone.

## Approval and ChangeControl

The user approves the exact canonical proposal digest, not a generic permission to change infrastructure.

Interactive execution requires:

```text
APPROVE <proposal-digest-prefix>
```

A non-interactive run may provide the exact full digest through `OPS_CAPACITY_APPROVAL`.

Only after explicit approval does the runner create the Harness `ApprovalGrant`. The grant is bound to the staged proposal digest, policy revision, resource graph and target scope, then consumed as a one-shot grant before the apply attempt.

The current reference runner stores this approval state only in the local benchmark artifact. A production implementation requires a durable host-owned approval/audit store and stronger transaction semantics around distributed Terraform/Git operations.

## Safety

The runner never uses `kubectl patch`, `kubectl scale`, or direct HPA/ResourceQuota mutation.

Intentional changes are performed only through their owners:

```text
ResourceQuota → terraform apply
HPA → Git commit/push → Argo CD reconciliation
```

The EXIT trap stops generated load and performs best-effort recovery when a constrained Terraform profile or temporary HPA increase may still be active.

The HPA apply and rollback use the same Argo revision gate learned from Scenario #1: a stale `Synced/Healthy` status from the previous revision is not accepted as completion.

## Dry run

Pull both repositories first, then:

```bash
cd ~/platform-engineering-lab
bash ops/benchmarks/hpa-quota/run.sh
```

The dry run initializes the Terraform provider, validates configuration, and creates baseline/constrained plans. It does not apply either plan or generate load.

## Intentional live execution

Only after the dry run succeeds:

```bash
OPS_CAPACITY_ACK=platform-engineering-lab \
  bash ops/benchmarks/hpa-quota/run.sh --execute
```

The runner will pause after the Agent proposal and policy decision. Review the exact changes and risk classification before entering the requested approval text.

## Expected artifacts

```text
.ops-benchmark/<run-id>-hpa-quota/
  baseline-k8s.json
  baseline-prometheus.json
  baseline-review.json
  capacity-k8s.json
  capacity-review.json
  policy.json
  hpa-before-approval.json
  quota-before-approval.json
  approval.json
  postcheck-k8s.json
  postcheck-capacity.json
  final-k8s.json
  final-prometheus.json
  final-review.json
  load.log
```

## Evaluation questions

A live PASS should answer all of these with runtime evidence:

```text
Did real load create HPA scale pressure?
Did ResourceQuota actually reject scale-out?
Did the Agent localize the cross-layer cause?
Did it propose only owner-correct changes?
Did policy classify risk before execution?
Was explicit approval bound to the exact proposal?
Did the approved change remove fresh quota blocking under load?
Did the application remain/recover healthy?
Did the temporary GitOps change roll back to maxReplicas=6?
Did Terraform remain at the safe baseline quota after the scenario?
```

If the initial load cannot reproduce HPA pressure, treat that as scenario-calibration evidence and adjust load generation rather than weakening the correlation criteria.
