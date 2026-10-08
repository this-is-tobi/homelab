#!/usr/bin/env bash
# Check a published catalog bundle the way an adopter would use it.
#
#   verify-catalog.sh <registry/path@sha256:digest> <version>
#
# Everything runs anonymously, with no registry credentials, so a package that
# is still private fails here instead of at the first adopter's Argo CD. It
# checks, in order, that the artifact:
#   - has the shape Argo CD accepts (one tar+gzip layer) and says which
#     version it is,
#   - is signed by the shared attest-docker workflow and carries a build
#     provenance naming this repository and this digest,
#   - holds the version it is published under, and
#   - renders every chart with the example instance without reaching a Helm
#     repository (the dependencies are vendored).
# Needs oras, cosign, helm, jq and tar; REPO (default $GITHUB_REPOSITORY) is
# the repository that must have built it. The checks shared with the other
# published artifacts live in scripts/lib/verify-oci.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/verify-oci.sh
source "$ROOT/scripts/lib/verify-oci.sh"

# Same signer and provenance source as the Kyverno verify-images policy
# (argo-cd/apps/kyverno/values.yaml).
SIGNER='^https://github\.com/this-is-tobi/github-workflows/\.github/workflows/attest-docker\.yml@refs/tags/v[0-9]+(\.[0-9]+)*$'
ARTIFACT_TYPE=application/vnd.ohmlab.catalog.v1
LAYER_TYPE=application/vnd.oci.image.layer.v1.tar+gzip

fail() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

[ "$#" = 2 ] || fail "usage: verify-catalog.sh <registry/path@sha256:digest> <version>"
verify_args "$1" "$2"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
verify_anonymous "$work"

manifest=$(verify_manifest "$ref" "$work")
jq -e --arg t "$LAYER_TYPE" '.layers | length == 1 and .[0].mediaType == $t' <<<"$manifest" >/dev/null \
  || fail "the artifact must have exactly one layer of type $LAYER_TYPE, as Argo CD requires"
jq -e --arg t "$ARTIFACT_TYPE" '.artifactType == $t' <<<"$manifest" >/dev/null \
  || fail "the artifact type must be $ARTIFACT_TYPE"
jq -e --arg v "$version" '.annotations["org.opencontainers.image.version"] == $v' <<<"$manifest" >/dev/null \
  || fail "the manifest must be annotated with version $version"
ok "one tar+gzip layer, type $ARTIFACT_TYPE, version $version"

verify_signed "$ref" "$SIGNER" attest-docker "$repo" "$digest" "$work"

layer=$(verify_pull "$ref" "$work")
mkdir "$work/bundle"
tar -xzf "$layer" -C "$work/bundle" || fail "the layer is not a tar.gz archive"

[ "$(cat "$work/bundle/argo-cd/apps/version.txt" 2>/dev/null)" = "$version" ] \
  || fail "argo-cd/apps/version.txt must hold $version"
ok "the bundle says it is $version"

# The vendored dependencies must be enough: an empty Helm configuration has no
# repository to fall back to.
: >"$work/repositories.yaml"
export HELM_REPOSITORY_CONFIG="$work/repositories.yaml" HELM_REPOSITORY_CACHE="$work/helm-cache"
CATALOG_ROOT="$work/bundle" "$ROOT/scripts/ci/render-example.sh" || fail "a chart of the bundle does not render with the example instance"
ok "every chart renders from the bundle alone"
