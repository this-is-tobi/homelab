#!/usr/bin/env bash
# Unit-tests the CEL policies and exceptions the kyverno chart renders. The
# chart is rendered the way production does (homelab instance values first,
# the documented _example as fallback), the policies.kyverno.io objects are
# exported, and `kyverno test` runs every <chart>/tests/policies/<name>/.
# Fixture files reference ../../rendered/policies.yaml and
# ../../rendered/exceptions.yaml.
set -euo pipefail

chart="${1:-argo-cd/apps/kyverno}"
name=$(basename "$chart")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

shopt -s nullglob
dirs=("$chart"/tests/policies/*/)
if [ "${#dirs[@]}" -eq 0 ]; then
  echo "no policy fixtures under $chart/tests/policies"
  exit 0
fi
command -v kyverno >/dev/null || { echo "kyverno CLI not found on PATH (v1.19.1 expected)" >&2; exit 2; }

values_args() {
  local inst scope vf
  for inst in homelab _example; do
    for scope in core tenant; do
      vf="argo-cd/instances/$inst/values/$scope/$name.yaml"
      if [ -f "$vf" ]; then printf '%s\n' -f "$vf"; return; fi
    done
  done
}
mapfile -t args < <(values_args)

mkdir -p "$work/rendered" "$work/tests"
helm template ci "$chart" --namespace kyverno "${args[@]}" >"$work/all.yaml"
yq ea 'select((.apiVersion // "") | test("^policies\\.kyverno\\.io/")) | select(.kind != "PolicyException")' "$work/all.yaml" >"$work/rendered/policies.yaml"
yq ea 'select((.apiVersion // "") | test("^policies\\.kyverno\\.io/")) | select(.kind == "PolicyException")' "$work/all.yaml" >"$work/rendered/exceptions.yaml"

for d in "${dirs[@]}"; do
  t=$(basename "$d")
  cp -R "$d" "$work/tests/$t"
  echo "::group::$t"
  (cd "$work/tests/$t" && kyverno test .) || failures=$((failures + 1))
  echo "::endgroup::"
done

exit "$failures"
