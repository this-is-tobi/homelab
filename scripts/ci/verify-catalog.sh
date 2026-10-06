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
# the repository that must have built it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Same signer and provenance source as the Kyverno verify-images policy
# (argo-cd/apps/kyverno/values.yaml).
SIGNER='^https://github\.com/this-is-tobi/github-workflows/\.github/workflows/attest-docker\.yml@refs/tags/v[0-9]+(\.[0-9]+)*$'
ISSUER=https://token.actions.githubusercontent.com
ARTIFACT_TYPE=application/vnd.ohmlab.catalog.v1
LAYER_TYPE=application/vnd.oci.image.layer.v1.tar+gzip

fail() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

[ "$#" = 2 ] || fail "usage: verify-catalog.sh <registry/path@sha256:digest> <version>"
ref=$1
version=$2
repo=${REPO:-${GITHUB_REPOSITORY:-}}
[[ "$ref" =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$ ]] \
  || fail "the artifact must be a reference pinned by digest (registry/path@sha256:...), got '$ref'"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must be X.Y.Z, got '$version'"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "REPO must be owner/name, got '$repo'"
digest=${ref##*@sha256:}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# An empty Docker config for every registry call: no credential of the
# runner or the developer can make a private package look public.
mkdir "$work/docker"
export DOCKER_CONFIG="$work/docker"

if ! manifest=$(oras manifest fetch "$ref" 2>"$work/err"); then
  fail "cannot pull $ref anonymously (a new package starts private: make it public in the package settings): $(head -c 300 "$work/err")"
fi

jq -e --arg t "$LAYER_TYPE" '.layers | length == 1 and .[0].mediaType == $t' <<<"$manifest" >/dev/null \
  || fail "the artifact must have exactly one layer of type $LAYER_TYPE, as Argo CD requires"
jq -e --arg t "$ARTIFACT_TYPE" '.artifactType == $t' <<<"$manifest" >/dev/null \
  || fail "the artifact type must be $ARTIFACT_TYPE"
jq -e --arg v "$version" '.annotations["org.opencontainers.image.version"] == $v' <<<"$manifest" >/dev/null \
  || fail "the manifest must be annotated with version $version"
ok "one tar+gzip layer, type $ARTIFACT_TYPE, version $version"

cosign verify --certificate-identity-regexp "$SIGNER" --certificate-oidc-issuer "$ISSUER" "$ref" >/dev/null 2>"$work/err" \
  || fail "the signature does not verify: $(head -c 300 "$work/err")"
ok "signed by the attest-docker workflow"

cosign verify-attestation --type slsaprovenance1 --certificate-identity-regexp "$SIGNER" --certificate-oidc-issuer "$ISSUER" "$ref" >"$work/provenance" 2>"$work/err" \
  || fail "the build provenance does not verify: $(head -c 300 "$work/err")"
jq -e --arg d "$digest" --arg r "https://github.com/$repo" -s '
  length > 0 and all(.[]; .payload | @base64d | fromjson
    | .subject[0].digest.sha256 == $d
      and .predicate.buildDefinition.externalParameters.workflow.repository == $r)' "$work/provenance" >/dev/null \
  || fail "the build provenance must name $repo and digest sha256:$digest"
ok "build provenance names $repo and the digest"

oras pull "$ref" --output "$work/pull" >/dev/null 2>"$work/err" || fail "cannot pull the layer: $(head -c 300 "$work/err")"
# Named by the push, with the path it was given: take the one file there is.
layer=$(find "$work/pull" -type f)
[ -n "$layer" ] && [ "$(wc -l <<<"$layer" | tr -d ' ')" = 1 ] || fail "the pull must yield exactly one file"
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
