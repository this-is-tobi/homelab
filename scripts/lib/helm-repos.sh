#!/usr/bin/env bash
# Shared helpers for the scripts that build charts from Chart.yaml files.

# add_dependency_repos <Chart.yaml>...: `helm repo add` every http(s) repository
# the charts depend on, then refresh the indexes. `helm dependency build` fails
# for a repository that is not added first (OCI repositories need nothing).
add_dependency_repos() {
  local i=0 repo
  while IFS= read -r repo; do
    i=$((i + 1))
    helm repo add "repo$i" "$repo" >/dev/null
  done < <(yq -N '.dependencies[]?.repository' "$@" 2>/dev/null | grep '^http' | sort -u)
  helm repo update >/dev/null
}
