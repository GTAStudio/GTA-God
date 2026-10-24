# GTA-God release orchestration

This public repository contains release orchestration only. It does not contain the GTAGod product source, production configuration, credentials, or private build fixtures.

## Repository roles

- `GTAStudio/GTA-God-Dev` is the private source repository. It owns Gateway code, deployment code, tests, component locks, Dockerfiles, and release scripts.
- `GTAStudio/GTA-God` is this public orchestration repository. It owns only workflows and repository secrets used to fetch exact private inputs and run the private release scripts.
- `GTAStudio/GTACore` and `GTAStudio/GTAcore-SB` are independent component repositories. Every release workflow pins their full commit IDs.

GTACore is the only production data plane. Rollback may use only a previously signed, verified GTACore image pinned by immutable digest. SB workflows, source references, and `sb-*` image assets are historical comparison fixtures, not production or rollback candidates.

## Safe update sequence

1. Commit and push the private source change.
2. Wait for all required gates in `GTA-God-Dev` to pass.
3. Verify that the component commits match the private `components.lock.json`.
4. Update the exact source and component commit IDs in the appropriate workflow here.
5. Push the workflow update. Push-triggered runs validate only and never publish.
6. Review the validation run.
7. For publication, set repository variable `DOCKER_PUBLISH_ENABLED=true` temporarily and manually dispatch the workflow with `publish=true`.
8. The manual run must publish an immutable tag, generate SPDX SBOM and SLSA provenance attestations, sign the digest, and only then promote mutable aliases. Return `DOCKER_PUBLISH_ENABLED` to `false` immediately afterward.
9. Production deployment must verify and use the immutable digest, never a mutable alias.

Publication additionally requires `GTAGOD_COSIGN_PRIVATE_KEY` and, when applicable, `GTAGOD_COSIGN_PASSWORD`. Source checkout, component checkout, registry, and signing credentials remain encrypted repository secrets and must never be printed.
The corresponding public verification key is tracked as [`cosign.pub`](cosign.pub).

## Orchestration dependency baseline

The 2026-10-23 refresh uses the available Ubuntu 26.04 hosted image, Buildx
action v4.4.1, Cosign v3.1.4, SBOM action v0.24.3 and Syft v1.55.0.
Checkout v7.0.1, Cosign installer v4.1.2 and cargo-deny 0.20.2 were already
the latest stable releases at that check. Actions remain pinned to their full
commit IDs, not moving version aliases.

Rust-based host tooling is explicitly built with Rust 1.99.1, and the workflow
verifies the selected compiler instead of inheriting the runner's default.

These tooling updates alone do not advance the private source or component pins,
prove private CI acceptance, publish an image, or authorize deployment.
Dependency updates in private source still follow the sequence above.

## Supplied binary policy

The supplied-GTACore workflow is validation-only. It checks out the exact private GTAGod and GTACore revisions, verifies the supplied binary against the private component lock, packages it deterministically, builds the external-daemon image, and runs the artifact runtime smoke tests.

The locked supplied binary is a historical validation input, not the current source-built release. It has no signed build attestation binding its dependency and sidecar inputs; a clean source lock alone does not prove those binary inputs. The image remains labeled `blocked-unattested-artifact`. The workflow has no registry login or publication step and must never publish or promote this candidate to `latest`.
