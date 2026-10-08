#!/usr/bin/env bash
# Checks shared by the scripts that verify a published OCI artifact
# (scripts/ci/verify-*.sh). The caller defines fail() and ok(), and sources this
# file. Function locals carry a `_v_` prefix: bash scopes them dynamically, so a
# plain name would shadow a variable of the caller.

VERIFY_ISSUER=https://token.actions.githubusercontent.com

# verify_args <ref> <version>: sets ref, version, repo and digest for the
# caller, or fails. REPO (default $GITHUB_REPOSITORY) is the repository that
# must have built it.
# shellcheck disable=SC2034
verify_args() {
  ref=$1
  version=$2
  repo=${REPO:-${GITHUB_REPOSITORY:-}}
  [[ "$ref" =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$ ]] \
    || fail "the artifact must be a reference pinned by digest (registry/path@sha256:...), got '$ref'"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must be X.Y.Z, got '$version'"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "REPO must be owner/name, got '$repo'"
  digest=${ref##*@sha256:}
}

# verify_anonymous <workdir>: empty Docker and Helm registry configurations for
# every registry call, so no credential of the runner or the developer can make
# a private package look public.
verify_anonymous() {
  mkdir "$1/docker"
  export DOCKER_CONFIG="$1/docker"
  : >"$1/registry.json"
  export HELM_REGISTRY_CONFIG="$1/registry.json"
}

# verify_manifest <ref> <workdir>: prints the manifest, or fails with the hint
# that a new package starts private.
verify_manifest() {
  oras manifest fetch "$1" 2>"$2/err" \
    || fail "cannot pull $1 anonymously (a new package starts private: make it public in the package settings): $(head -c 300 "$2/err")"
}

# verify_signed <ref> <signer-regex> <signer-name> <repo> <digest> <workdir>:
# the keyless signature of the shared attest workflow, and a build provenance
# naming this repository and this digest.
verify_signed() {
  local _v_ref=$1 _v_signer=$2 _v_name=$3 _v_repo=$4 _v_digest=$5 _v_work=$6
  cosign verify --certificate-identity-regexp "$_v_signer" --certificate-oidc-issuer "$VERIFY_ISSUER" "$_v_ref" >/dev/null 2>"$_v_work/err" \
    || fail "the signature does not verify: $(head -c 300 "$_v_work/err")"
  ok "signed by the $_v_name workflow"

  cosign verify-attestation --type slsaprovenance1 --certificate-identity-regexp "$_v_signer" --certificate-oidc-issuer "$VERIFY_ISSUER" "$_v_ref" >"$_v_work/provenance" 2>"$_v_work/err" \
    || fail "the build provenance does not verify: $(head -c 300 "$_v_work/err")"
  jq -e --arg d "$_v_digest" --arg r "https://github.com/$_v_repo" -s '
    length > 0 and all(.[]; .payload | @base64d | fromjson
      | .subject[0].digest.sha256 == $d
        and .predicate.buildDefinition.externalParameters.workflow.repository == $r)' "$_v_work/provenance" >/dev/null \
    || fail "the build provenance must name $_v_repo and digest sha256:$_v_digest"
  ok "build provenance names $_v_repo and the digest"
}

# verify_pull <ref> <workdir>: pulls the artifact and prints the one file it
# holds (named by the push, with whatever path it was given).
verify_pull() {
  local _v_files
  oras pull "$1" --output "$2/pull" >/dev/null 2>"$2/err" || fail "cannot pull the layer: $(head -c 300 "$2/err")"
  _v_files=$(find "$2/pull" -type f)
  [ -n "$_v_files" ] && [ "$(wc -l <<<"$_v_files" | tr -d ' ')" = 1 ] || fail "the pull must yield exactly one file"
  printf '%s\n' "$_v_files"
}
