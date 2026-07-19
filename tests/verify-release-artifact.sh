#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

sha256sum --check bin/gtacore.sha256

actual_sha=$(sha256sum bin/gtacore | awk '{print $1}')
actual_size=$(stat -c '%s' bin/gtacore)
binary_version=$(bin/gtacore sing-box version | awk 'NR == 1 { print $3 }')

provenance_schema=$(jq -er '.schema' bin/gtacore.provenance.json)
provenance_sha=$(jq -er '.sha256' bin/gtacore.provenance.json)
provenance_size=$(jq -er '.size' bin/gtacore.provenance.json)
provenance_version=$(jq -er '.version' bin/gtacore.provenance.json)
provenance_commit=$(jq -er '.commit' bin/gtacore.provenance.json)
provenance_target=$(jq -er '.target' bin/gtacore.provenance.json)

docker_sha=$(sed -n 's/^ARG GTACORE_SHA256=//p' Dockerfile)
docker_version=$(sed -n 's/^ARG GTAGOD_VERSION=//p' Dockerfile)
docker_revision=$(sed -n 's/^ARG GTACORE_REVISION=//p' Dockerfile)

[ "$provenance_schema" = "gtagod.gtacore-build.v1" ]
[ "$provenance_target" = "x86_64-unknown-linux-gnu" ]
[ "$actual_sha" = "$provenance_sha" ]
[ "$actual_sha" = "$docker_sha" ]
[ "$actual_size" = "$provenance_size" ]
[ "$binary_version" = "$provenance_version" ]
[ "$binary_version" = "$docker_version" ]
[ "$provenance_commit" = "$docker_revision" ]
[ "$(jq -r '.features | index("embed-sidecars") != null' bin/gtacore.provenance.json)" = true ]
[ "$(jq -r '.embedded_sidecars | index("cloudflared") != null' bin/gtacore.provenance.json)" = true ]

commit12=$(printf '%s' "$provenance_commit" | cut -c1-12)
strings bin/gtacore | grep -F "$commit12" >/dev/null

bin/gtacore sing-box check -c tests/fixtures/gtacore-smoke.json
printf 'release artifact verified: version=%s commit=%s sha256=%s size=%s\n' \
    "$binary_version" "$commit12" "$actual_sha" "$actual_size"