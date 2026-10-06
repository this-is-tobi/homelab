#!/usr/bin/env bash
# Builds the catalog bundle: one tar.gz with the layout of this repository,
# holding every chart of argo-cd/apps with its dependencies vendored (Chart.lock
# is honoured), the ohmlab bootstrap chart (utils/helm) and the example instance.
# Argo CD renders an app straight from it with `path: argo-cd/apps/<chart>`, with
# no access to any upstream chart repository.
#
# Only the files git tracks go in, plus untracked files that are not ignored, so
# a local secret file (*.dec.yaml, a stale charts/ directory, ...) can never end
# up in a published artifact.
#
#   build-catalog.sh <output-dir>
#
# Writes <output-dir>/catalog.tar.gz and prints its path and sha256. The Helm
# repository configuration is private to the run (the cache is shared between
# runs, under ~/.cache/ohmlab-catalog). Needs git, helm, yq (mikefarah v4), tar,
# gzip and sha256sum or shasum.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helm-repos.sh
source "$ROOT/scripts/lib/helm-repos.sh"

out="${1:?usage: build-catalog.sh <output-dir>}"
PATHS=(argo-cd/apps argo-cd/instances/_example utils/helm)

die() { echo "build-catalog: $*" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage" "$out"

cd "$ROOT"
git ls-files -z --cached --others --exclude-standard -- "${PATHS[@]}" \
  | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
  | COPYFILE_DISABLE=1 tar --null -T - -cf - \
  | tar -xf - -C "$stage"

export HELM_REPOSITORY_CONFIG="$work/repositories.yaml"
export HELM_REPOSITORY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ohmlab-catalog/helm"
mkdir -p "$HELM_REPOSITORY_CACHE"
add_dependency_repos "$stage"/argo-cd/apps/*/Chart.yaml "$stage/utils/helm/Chart.yaml"

for chart in "$stage"/argo-cd/apps/*/ "$stage/utils/helm"; do
  chart="${chart%/}"
  [ -f "$chart/Chart.yaml" ] || continue
  yq -e '.dependencies | length > 0' "$chart/Chart.yaml" >/dev/null 2>&1 || continue
  [ -f "$chart/Chart.lock" ] || die "$(basename "$chart") has dependencies but no Chart.lock: run helm dependency update and commit the lock"
  helm dependency build "$chart" >/dev/null || die "helm dependency build failed for $(basename "$chart")"
done

COPYFILE_DISABLE=1 tar -C "$stage" -czf "$out/catalog.tar.gz" .

if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$out/catalog.tar.gz" | cut -d' ' -f1); else sum=$(shasum -a 256 "$out/catalog.tar.gz" | cut -d' ' -f1); fi
echo "$out/catalog.tar.gz sha256:$sum"
