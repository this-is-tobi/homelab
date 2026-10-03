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
  printf 'apiVersion: v2\nname: ohmlab\nversion: 0.1.0\n' >"$dir/utils/helm/Chart.yaml"
  printf 'a: 1\n' >"$dir/utils/helm/values.yaml"
  printf 'x\n' >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  echo "$dir"
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    fail=1
  fi
}

# A chart change on push gets a patch bump.
d=$(repo); b=$(git -C "$d" rev-parse HEAD)
printf 'a: 2\n' >"$d/utils/helm/values.yaml"; git -C "$d" commit -qam "fix(ohmlab): tweak"
check "chart change bumps patch" patch "$(cd "$d" && "$SCRIPT" "$b" HEAD utils/helm none)"

# A change elsewhere does nothing.
d=$(repo); b=$(git -C "$d" rev-parse HEAD)
printf 'y\n' >"$d/README.md"; git -C "$d" commit -qam "docs: readme"
check "unrelated change does nothing" none "$(cd "$d" && "$SCRIPT" "$b" HEAD utils/helm none)"

# The range already moves the chart version (a merged bump PR): no re-bump.
d=$(repo); b=$(git -C "$d" rev-parse HEAD)
printf 'apiVersion: v2\nname: ohmlab\nversion: 0.1.1\n' >"$d/utils/helm/Chart.yaml"
git -C "$d" commit -qam "chore: update chart ohmlab to v0.1.1"
check "a version bump in range does not re-bump" none "$(cd "$d" && "$SCRIPT" "$b" HEAD utils/helm none)"

# A hand bump alongside other chart changes is respected as-is.
d=$(repo); b=$(git -C "$d" rev-parse HEAD)
printf 'apiVersion: v2\nname: ohmlab\nversion: 0.2.0\n' >"$d/utils/helm/Chart.yaml"
printf 'a: 3\n' >"$d/utils/helm/values.yaml"; git -C "$d" commit -qam "feat(ohmlab): x, bumped by hand"
check "a hand bump is respected" none "$(cd "$d" && "$SCRIPT" "$b" HEAD utils/helm none)"

# An explicit dispatch level wins, whatever changed.
d=$(repo)
check "dispatch minor" minor "$(cd "$d" && "$SCRIPT" "" HEAD utils/helm minor)"

# A trailing slash on the chart dir is tolerated.
d=$(repo); b=$(git -C "$d" rev-parse HEAD)
printf 'a: 4\n' >"$d/utils/helm/values.yaml"; git -C "$d" commit -qam "fix(ohmlab): tweak"
check "trailing slash on chart dir" patch "$(cd "$d" && "$SCRIPT" "$b" HEAD utils/helm/ none)"

# An unknown base (all-zero sha on a new branch) is a no-op, never a guess.
d=$(repo)
check "unknown base is a no-op" none "$(cd "$d" && "$SCRIPT" 0000000000000000000000000000000000000000 HEAD utils/helm none)"

# A base that is not in the clone (force-push) is a no-op too.
d=$(repo)
check "base missing from the clone is a no-op" none "$(cd "$d" && "$SCRIPT" 1111111111111111111111111111111111111111 HEAD utils/helm none)"

# An invalid dispatch level fails.
d=$(repo)
if (cd "$d" && "$SCRIPT" "" HEAD utils/helm huge) >/dev/null 2>&1; then
  echo "FAIL invalid level must fail"
  fail=1
else
  echo "ok   invalid level fails"
fi

exit "$fail"
