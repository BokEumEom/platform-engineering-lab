# Platform scoped instructions

These instructions apply to files under platform/.

## Scope

platform/ contains platform component configuration that supports the reference environment. Keep changes scoped to the component being modified and preserve the repository's existing GitOps and ownership boundaries.

## Change rules

- Inspect the consuming manifests, values, and related documentation before changing platform configuration.
- Do not introduce a second owner for a Kubernetes object already managed by Argo CD or Terraform.
- Do not use an ad-hoc runtime patch as the repository solution for an owned resource.
- Preserve safe defaults. Fault injection, public exposure, privilege expansion, destructive operations, and production-like mutations must remain explicit and gated.
- A manifest, rendered template, or passing static check is not proof of runtime health.
- When a feature change affects architecture, ownership, routing, observability, validation, failure behavior, or operator workflow, update the related document under docs/ in the same change.
- Prefer updating an existing canonical document over duplicating the same explanation in another file.
- Put dated live-run results under docs/evidence/ rather than embedding them in platform configuration notes.

## Validation

Use the narrowest validation that proves the changed surface:

- render the affected Helm chart or manifest path when configuration values change;
- run the repository Platform Validate workflow for cross-component or contract changes;
- require live smoke or benchmark evidence only when the change claims runtime behavior.

Do not require a live cluster for documentation-only or purely static changes unless the change makes a runtime claim.

## Completion

A platform change is complete when configuration, ownership, validation, and related documentation agree. Avoid unrelated refactors.

## Human review

A human maintainer should review this file periodically, and whenever platform ownership, topology, safety boundaries, or validation strategy changes materially. Remove stale instructions instead of accumulating exceptions.
