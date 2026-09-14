# Terraform Reference Environment

This layer owns namespace-level capacity guardrails for the local reference environment.

Ownership is intentionally split:

```text
Terraform
→ ResourceQuota / foundation capacity guardrails

GitOps / Argo CD
→ Deployments / Services / HPAs / PDBs / Gateway routes / app configuration
```

Terraform must not manage application objects that Argo CD already owns.

## Baseline

```bash
cd terraform/reference-environment
terraform init
terraform plan -var-file=baseline.tfvars
terraform apply -var-file=baseline.tfvars
```

The baseline quota is deliberately above the normal six-service request footprint.

## Scenario #2 constrained profile

`constrained.tfvars` reduces only the namespace CPU request budget. It exists for the controlled HPA/ResourceQuota benchmark and is not the normal desired state.

```bash
terraform plan -var-file=constrained.tfvars
```

The live benchmark must require explicit acknowledgement before applying this profile.

## Recovery

The safe baseline is restored with:

```bash
terraform apply -var-file=baseline.tfvars
```

The benchmark should verify the ResourceQuota hard/used values after every apply rather than treating Terraform exit code alone as runtime recovery.
