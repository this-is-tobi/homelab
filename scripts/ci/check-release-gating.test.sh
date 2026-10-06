#!/usr/bin/env bash
# Decision table for scripts/ci/check-release-gating.sh on hand-written
# release configs and workflows.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-release-gating.sh"
fail=0
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

GATE_UTILS="\${{ contains(fromJSON(needs.release.outputs.paths-released), 'utils') }}"
GATE_CATALOG="\${{ contains(fromJSON(needs.release.outputs.paths-released), 'argo-cd/apps') }}"
VERSION_UTILS="\${{ fromJSON(needs.release.outputs.release-outputs)['utils--version'] }}"
VERSION_CATALOG="\${{ fromJSON(needs.release.outputs.release-outputs)['argo-cd/apps--version'] }}"

config() { # config <path>...
  local p out='' sep=''
  for p in "$@"; do out="$out$sep\"$p\": {}"; sep=','; done
  printf '{"packages": {%s}}\n' "$out" >"$dir/config.json"
}

# workflow <job yaml>... -> a workflow with the release job plus the given jobs
workflow() {
  {
    printf 'jobs:\n  release:\n    uses: x/y/.github/workflows/release-app.yml@v0\n'
    printf '%s\n' "$@"
  } >"$dir/cd.yml"
}

check() { # label expected-exit
  local out rc
  out=$("$SCRIPT" "$dir/config.json" "$dir/cd.yml" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: exit $rc, expected $2"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; fi
}

has() { # label pattern: the last run named the finding
  local out
  out=$("$SCRIPT" "$dir/config.json" "$dir/cd.yml" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$2"; then echo "ok   $1"; else echo "FAIL $1: no '$2' in:"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; fi
}

utils_image="  image:
    needs: release
    if: $GATE_UTILS
    uses: x/y/.github/workflows/build-docker.yml@v0
    with:
      IMAGE_TAG: $VERSION_UTILS"
utils_attest="  attest-image:
    needs: image
    uses: x/y/.github/workflows/attest-docker.yml@v0"
utils_binaries="  binaries:
    needs: release
    if: $GATE_UTILS
    uses: x/y/.github/workflows/release-go.yml@v0"
catalog_build="  catalog:
    needs: release
    if: $GATE_CATALOG
    uses: x/y/.github/workflows/build-oci-artifact.yml@v0
    with:
      ARTIFACT_TAG: $VERSION_CATALOG"
catalog_attest="  attest-catalog:
    needs: catalog
    uses: x/y/.github/workflows/attest-docker.yml@v0
    with:
      TAG: \${{ fromJSON(needs.release.outputs.release-outputs)['argo-cd/apps--tag_name'] }}"

config utils argo-cd/apps
workflow "$utils_image" "$utils_attest" "$utils_binaries" "$catalog_build" "$catalog_attest"
check "each package runs only the jobs gated on its own release" 0

workflow "$utils_image" "$utils_attest" "$utils_binaries" "$catalog_build" "$catalog_attest" \
  "  attest-binaries:
    needs: [release, binaries]
    uses: x/y/.github/workflows/attest-go.yml@v0
    with:
      TAG: \${{ fromJSON(needs.release.outputs.release-outputs)['utils--tag_name'] }}"
check "a job reading outputs inherits the gate of a job it needs, as a string or in a list" 0

workflow "$utils_image" "$utils_attest" "$utils_binaries" "  catalog:
    needs: release
    if: \${{ needs.release.outputs.releases-created == 'true' && contains(fromJSON(needs.release.outputs.paths-released), 'argo-cd/apps') }}
    uses: x/y/.github/workflows/build-oci-artifact.yml@v0
    with:
      ARTIFACT_TAG: $VERSION_CATALOG" "$catalog_attest"
check "any release and the package's own gate can be combined" 0

workflow "  image:
    needs: release
    if: \${{ needs.release.outputs.releases-created == 'true' }}
    uses: x/y/.github/workflows/build-docker.yml@v0
    with:
      IMAGE_TAG: $VERSION_UTILS" "$utils_binaries" "$catalog_build" "$catalog_attest"
check "a job reading a package's outputs without that package's gate is refused" 1
has "the finding names the job and the package" "image reads the release outputs of 'utils'"

workflow "$utils_image" "  binaries:
    needs: release
    if: \${{ needs.release.outputs.releases-created == 'true' }}
    uses: x/y/.github/workflows/release-go.yml@v0" "$catalog_build" "$catalog_attest"
check "a job gated on any release is refused even when it reads no output" 1
has "the finding names the job" "binaries is gated on any release"

workflow "$utils_image" "$utils_binaries" "  catalog:
    needs: release
    if: $GATE_CATALOG
    uses: x/y/.github/workflows/build-oci-artifact.yml@v0
    with:
      ARTIFACT_TAG: $VERSION_UTILS"
check "a job gated on one package but reading another's outputs is refused" 1

workflow "$utils_image" "$utils_binaries" "$catalog_build" \
  "  attest-catalog:
    needs: release
    uses: x/y/.github/workflows/attest-docker.yml@v0
    with:
      DIGEST: $VERSION_CATALOG"
has "an attest job that skips the build job and is not gated itself is refused" "attest-catalog reads the release outputs of 'argo-cd/apps'"

workflow "$utils_image" "$utils_binaries" "  catalog:
    needs: release
    if: \${{ contains(fromJSON(needs.release.outputs.paths-released), 'argo-cd/app') }}
    uses: x/y/.github/workflows/build-oci-artifact.yml@v0
    with:
      ARTIFACT_TAG: $VERSION_CATALOG"
check "a gate naming something that is not a package is refused" 1
has "the finding names the unknown path" "'argo-cd/app', which is not a package"

workflow "$utils_image" "$utils_binaries"
check "a package whose release triggers no job is refused" 1
has "the finding names the package" "gated on the release of 'argo-cd/apps'"

config utils
workflow "$utils_image" "$utils_binaries"
check "a single package is enough" 0

exit "$fail"
