#!/usr/bin/env bash
# Shared helpers for the scripts that build charts from Chart.yaml files.

# retry <attempts> <command>...: runs the command until it succeeds, waiting
# RETRY_DELAY seconds (default 10) times the number of failed attempts in
# between. Upstream chart hosts fail transiently (a 500 from a release download
# is enough to fail a build), and a build must not depend on that luck.
retry() {
  # Bash locals are visible to the command that is run: names a caller could use too would be overwritten.
  local retry_max="$1" retry_n=1
  shift
  until "$@"; do
    [ "$retry_n" -lt "$retry_max" ] || return 1
    sleep $((${RETRY_DELAY:-10} * retry_n))
    retry_n=$((retry_n + 1))
  done
}

# add_dependency_repos <Chart.yaml>...: `helm repo add` every http(s) repository
# the charts depend on, then refresh the indexes. `helm dependency build` fails
# for a repository that is not added first (OCI repositories need nothing).
add_dependency_repos() {
  local i=0 repo
  while IFS= read -r repo; do
    i=$((i + 1))
    retry 3 helm repo add "repo$i" "$repo" >/dev/null
  done < <(yq -N '.dependencies[]?.repository' "$@" 2>/dev/null | grep '^http' | sort -u)
  retry 3 helm repo update >/dev/null
}
