#!/usr/bin/env bash
# Decision table for cd.yml's chart bump, run against throwaway git repos.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chart-bump-level.sh"
fail=0

repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  mkdir -p "$dir/utils/helm"
  chart_yaml 0.1.0 1.0.0 >"$dir/utils/helm/Chart.yaml"
  printf 'a: 1\n' >"$dir/utils/helm/values.yaml"
  printf 'x\n' >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  echo "$dir"
}

# chart_yaml <chart-version> <dependency-version>
chart_yaml() {
  printf 'apiVersion: v2\nname: ohmlab\nversion: %s\ndependencies:\n  - name: argo-cd\n    version: %s\n    repository: https://argoproj.github.io/argo-helm\n' "$1" "$2"
}

commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    fail=1
  fi
}

level() { (cd "$1" && "$SCRIPT" "${2:-utils/helm}" "${3:-none}"); }

# A chart change gets a patch bump.
d=$(repo)
printf 'a: 2\n' >"$d/utils/helm/values.yaml"; commit "$d" "fix(ohmlab): tweak"
check "chart change bumps patch" patch "$(level "$d")"

# A change elsewhere does nothing.
d=$(repo)
printf 'y\n' >"$d/README.md"; commit "$d" "docs: readme"
check "unrelated change does nothing" none "$(level "$d")"

# A dependency bump (Renovate) is a chart change, not a chart version change.
d=$(repo)
chart_yaml 0.1.0 1.0.1 >"$d/utils/helm/Chart.yaml"; commit "$d" "chore(deps): update argo-cd"
check "a dependency bump bumps patch" patch "$(level "$d")"

# A merged bump PR (the version moved, nothing since) does not re-bump.
d=$(repo)
printf 'a: 2\n' >"$d/utils/helm/values.yaml"; commit "$d" "fix(ohmlab): tweak"
chart_yaml 0.1.1 1.0.0 >"$d/utils/helm/Chart.yaml"; commit "$d" "chore: update chart ohmlab to v0.1.1"
check "a merged bump does not re-bump" none "$(level "$d")"

# A hand bump alongside other chart changes is respected as-is.
d=$(repo)
chart_yaml 0.2.0 1.0.0 >"$d/utils/helm/Chart.yaml"
printf 'a: 3\n' >"$d/utils/helm/values.yaml"; commit "$d" "feat(ohmlab): x, bumped by hand"
check "a hand bump is respected" none "$(level "$d")"

# A chart change after the last version change bumps again.
d=$(repo)
chart_yaml 0.2.0 1.0.0 >"$d/utils/helm/Chart.yaml"; commit "$d" "chore: update chart ohmlab to v0.2.0"
printf 'a: 4\n' >"$d/utils/helm/values.yaml"; commit "$d" "fix(ohmlab): tweak"
check "a change after a bump bumps again" patch "$(level "$d")"

# A chart change pushed in a run that never happened (GitHub replaces a
# pending run of the same concurrency group) is still seen by the next run.
d=$(repo)
printf 'a: 5\n' >"$d/utils/helm/values.yaml"; commit "$d" "fix(ohmlab): tweak"
printf 'z\n' >"$d/README.md"; commit "$d" "docs: readme"
check "a chart change from a skipped run still bumps" patch "$(level "$d")"

# A trailing slash on the chart dir is tolerated.
d=$(repo)
printf 'a: 6\n' >"$d/utils/helm/values.yaml"; commit "$d" "fix(ohmlab): tweak"
check "trailing slash on chart dir" patch "$(level "$d" utils/helm/)"

# An explicit dispatch level wins, whatever changed.
d=$(repo)
check "dispatch minor" minor "$(level "$d" utils/helm minor)"

# An invalid dispatch level fails.
d=$(repo)
if level "$d" utils/helm huge >/dev/null 2>&1; then
  echo "FAIL invalid level must fail"
  fail=1
else
  echo "ok   invalid level fails"
fi

exit "$fail"
