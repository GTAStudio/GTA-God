# GTAGod Release Rules

## Two Repository Boundary

- `GTAStudio/GTA-God` is the public orchestration repository. Keep product source, deployment inputs, credentials, binaries and private evidence out of this repository.
- `GTAStudio/GTA-God-Dev` is the independent private product repository. It owns Gateway, Dockerfiles, component locks, tests and release scripts. Check Git status in each repository separately; do not stage its checkout or artifacts into the public repository.
- Read [the release sequence](../README.md) and [the Rust workflow](workflows/docker-build-rust.yml) before any release action. Read the private repository's current instructions, component lock and publisher as well. Do not infer the process from historical task notes or upstream standalone GTACore build instructions.
- GTACore is the only production data plane. SB and supplied-artifact workflows are reference/validation lanes, not production publishers or rollback choices.
- Images labeled `validation-only` or `blocked-*` must never be promoted to production or used for rollback, even when a local build or smoke test passed.

## Required Sequence

1. Obtain authorization for the intended Git/publication work. A request to explain or document the process does not authorize committing, pushing, dispatching workflows or deploying servers.
2. Commit and push the reviewed private product changes first. Preserve unrelated changes. Verify all four private `Required release gates` jobs succeeded for that exact source commit: `scripts-and-static-contracts`, `gateway`, `cargo-deny`, `rust-container-smoke`.
3. Verify the private `components.lock.json` Core revision, version and Cargo.lock hashes. Update this repository's `docker-build-rust.yml` source checkout to the accepted full private commit ID and its Core checkout to the matching full component commit ID. Update descriptive pin comments with the actual values; never use moving branches or stale recorded SHAs.
4. Commit and push the public workflow change. Its push trigger watches only that workflow on `main` and validates without publication; a documentation-only push does not trigger it. Review the validation run against the intended source and component IDs.
5. Only for an authorized publication, temporarily set `DOCKER_PUBLISH_ENABLED=true` in the public repository and manually dispatch `docker-build-rust.yml` with `publish=true`. The workflow also requires the configured signing key. Neither private CI nor an ordinary public push publishes an image.
6. Wait for the exact manual run to finish. Restore `DOCKER_PUBLISH_ENABLED=false` and read it back on both success and failure. Preserve `cancel-in-progress: false`; do not cancel a publication between immutable push and alias promotion.
7. Independently verify the registry digest, Cosign signature, SPDX attestation, SLSA v1 identity and every promoted alias. Record source/Core/public-workflow commits, run ID and attempt, immutable image reference and verification results before calling publication complete.

## Publisher Contract

- The public workflow checks out private source and Core into separate directories and invokes the private `scripts/publish-rust-image.sh`. It builds clean Git archives through `scripts/build-local-rust-image.sh`; it does not upload a workstation-built binary or an offline validation image.
- Direct invocation of `publish-rust-image.sh` defaults `PUBLISH_IMAGE` to `true`. Always set `PUBLISH_IMAGE=false` explicitly for validation; prefer the public workflow for an authorized release.
- Immutable tag: `gtagod-<full-product-SHA>-gtacore-<full-Core-SHA>`. The publisher must prove it is absent and must never overwrite it.
- Order: build and validate candidate, dependency audit, push immutable tag, resolve digest, create SPDX/SLSA v1 attestations and signature, check downloaded SLSA fields, then promote `v<version>` and `gtacore-<short-Core-SHA>`, and finally `latest`. All aliases must resolve to the immutable digest. Version and short-revision tags are mutable aliases, not immutable identity.
- Use `slsaprovenance1`, not the legacy `slsaprovenance` type. Independently authenticate signature and attestation evidence with the trusted [cosign public key](../cosign.pub); structural provenance checks alone are not signature verification. Never disable TLS, claims or transparency verification to make a gate pass.
- Keep checkout, registry and signing values in encrypted repository secrets. Never print them, copy them into public files or pass them in command arguments.

## Verification And Authorization Boundaries

- GitHub runners perform the official image build. A workstation Docker/proxy failure is a local validation limitation, not proof that GitHub publication is blocked. Do not replace the official flow with a locally relabeled validation image or reconfigure the production proxy to work around it.
- The public workflow does not automatically query private CI or local soak receipts. The operator must verify private CI for the exact pinned commit and honor any additional explicitly required acceptance gates; an old green run or a running test is not acceptance.
- Local compilation, short/long stability tests, registry publication and production deployment are separate milestones. Do not claim one proves the others or silently add a local eight-hour run as a coded dependency of the public workflow.
- Publication does not authorize server deployment. Deployment/rollback requires separate explicit authorization and a signed, verified GTACore immutable digest. Do not stop, switch or update the user's production proxy or services.
- Never modify another task's frozen inputs, cancel its tests or treat historical approvals as current authorization. Report Git commit/push, private CI, public validation, signed publication and deployment status separately.