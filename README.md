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
8. Wait for that exact run and attempt to finish. On both success and failure, restore `DOCKER_PUBLISH_ENABLED=false` and read it back. Never cancel between immutable push and alias promotion.
9. Independently verify the registry digest, Cosign signature, SPDX and SLSA v1 identities, and every promoted alias using the trusted public key. Do not disable TLS, claims, or transparency verification.
10. Record the private source, Core and public workflow commits, run ID and attempt, immutable reference and verification results before declaring publication complete.
11. Production deployment requires separate authorization and must use the signed, verified immutable digest, never a mutable alias.

Publication additionally requires `GTAGOD_COSIGN_PRIVATE_KEY` and, when applicable, `GTAGOD_COSIGN_PASSWORD`. Source checkout, component checkout, registry, and signing credentials remain encrypted repository secrets and must never be printed.
The corresponding public verification key is tracked as [`cosign.pub`](cosign.pub).

## Latest verified image

Version **0.0.21** was built from the pinned source by the official workflow and
published in [run 45750928469, attempt 1](https://github.com/GTAStudio/GTA-God/actions/runs/45750928469),
after [public validation 45749392390](https://github.com/GTAStudio/GTA-God/actions/runs/45749392390).
The official job authenticated the Cosign v3 Sigstore bundle signature, SPDX and
SLSA v1 evidence with the trusted public key before promoting aliases. Direct
registry queries confirmed the digest, `linux/amd64`, the non-root `gtagate`
user, the product/Core revision and 0.0.21 version labels, and the three
Sigstore bundle referrers (signature, SLSA v1, SPDX).

```text
docker.io/aizhihuxiao/gtagod@sha256:5a3366b7a24c3df4785a471260ba776b544e9ebf3a07d969ccf4664ead264835
```

`v0.0.21`, `gtacore-974e2e2` and `latest` resolve to that digest.
`DOCKER_PUBLISH_ENABLED` was restored and read back as `false`.
This is publication evidence, not a claim that any server was deployed.

## Active orchestration dependency baseline

The active Rust workflow uses the available Ubuntu 26.04 hosted image, Checkout
v7.0.1, Buildx action v4.4.1, Cosign installer v4.1.4, Cosign v3.1.6, SBOM
action v0.24.4, Syft v1.57.2, cargo-deny 0.22.1, cargo-audit 0.23.0, Trivy
0.76.2 and cargo-auditable 0.7.8. Actions remain pinned to their full commit
IDs, not moving version aliases.

Rust-based host tooling is explicitly built with Rust 1.100.0, and the workflow
verifies the selected compiler instead of inheriting the runner's default.

Publisher v2 separates credential-free build/validation from the conditional
publication step. Only publication receives registry and signing credentials.
It requires Rust dependency inventory in the SBOM, a blocking High/Critical
image scan, authenticated evidence before digest-based alias promotion, and
monotonic release versions. The global publication concurrency group is never
cancelled in progress.

The workflow pins product source
`c0665417fe8fa6c2aed5fd071fc84586ff2b60c3` and Core
`974e2e27beb08394a10faf1586ee3c77f74cb16c` (0.0.21). All four required
private release gates passed for that exact product commit in
[run 45759238197, attempt 1](https://github.com/GTAStudio/GTA-God-Dev/actions/runs/45759238197)
before advancing these pins. Public validation, signed publication and server deployment remain
separate milestones; the pin update alone does not publish or deploy.

These tooling updates alone do not advance the private source or component pins,
prove private CI acceptance, publish an image, or authorize deployment.
Dependency updates in private source still follow the sequence above.

## Supplied binary policy

The supplied-artifact and SB comparison lanes are retired. Their active workflow
files reject manual execution explicitly and receive no checkout, registry or
signing credentials. Historical orchestration, including the previous tooling
refresh, is retained under [`.github/archived-workflows`](.github/archived-workflows)
for reference only; those files are not runnable GitHub workflows.

The locked supplied binary is a historical validation input, not the current source-built release. It has no signed build attestation binding its dependency and sidecar inputs; a clean source lock alone does not prove those binary inputs. The image remains labeled `blocked-unattested-artifact`. The workflow has no registry login or publication step and must never publish or promote this candidate to `latest`.
