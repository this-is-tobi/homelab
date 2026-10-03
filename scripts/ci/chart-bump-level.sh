#!/usr/bin/env bash
# Decide the chart bump level for a cd.yml run.
#
#   chart-bump-level.sh <before-sha> <after-sha> <chart-dir> <dispatch-level>
#
# An explicit dispatch level wins. Otherwise a push that changes anything under
# <chart-dir> gets a patch bump - unless the pushed range already moves the
# chart's version (a merged bump PR, or a deliberate hand bump), which must not
# open another bump PR. Prints none|patch|minor|major.
set -euo pipefail

before="$1" after="$2" chart_dir="${3%/}" dispatch="$4"

case "$dispatch" in
  none) ;;
  patch|minor|major) echo "$dispatch"; exit 0 ;;
  *) echo "invalid dispatch level: $dispatch" >&2; exit 1 ;;
esac

# No usable base (first push of a branch, force-push to an unknown commit):
# never guess.
if [ -z "$before" ] || [[ "$before" =~ ^0+$ ]] || ! git cat-file -e "$before^{commit}" 2>/dev/null; then
  echo none
  exit 0
fi

if git diff --quiet "$before" "$after" -- "$chart_dir"; then
  echo none
  exit 0
fi

old=$(git show "$before:$chart_dir/Chart.yaml" 2>/dev/null | yq '.version' || true)
new=$(git show "$after:$chart_dir/Chart.yaml" | yq '.version')
if [ "$old" != "$new" ]; then
  echo none
  exit 0
fi

echo patch
