# GTA-God release orchestration

This public repository contains release orchestration only. It does not contain the GTAGod product source, production configuration, credentials, or private build fixtures.

## Repository roles

- `GTAStudio/GTA-God-Dev` is the private source repository. It owns Gateway code, deployment code, tests, component locks, Dockerfiles, and release scripts.
- `GTAStudio/GTA-God` is this public orchestration repository. It owns only workflows and repository secrets used to fetch exact private inputs and run the private release scripts.
- `GTAStudio/GTACore` and `GTAStudio/GTAcore-SB` are independent component repositories. Every release workflow pins their full commit IDs.

The Rust lane is the default production architecture. The SB lane is an explicit rollback architecture and uses separate `sb-*` image aliases. The two lanes must never overwrite each other's mutable tags.

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

## Supplied binary policy

The former supplied-GTACore artifact workflow has been removed. The currently known supplied binary is an unattested dirty build whose observed wrapper lock contains a yanked dependency. The private source repository labels that lane `blocked-yanked-dependency`; it is local-validation-only and must not be published or promoted to `latest`.
