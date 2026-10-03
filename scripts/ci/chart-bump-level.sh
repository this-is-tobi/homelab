#!/usr/bin/env bash
# Decide the chart bump level for a cd.yml run.
#
#   chart-bump-level.sh <chart-dir> <dispatch-level>
#
# An explicit dispatch level wins. Otherwise the answer comes from history, not
# from the pushed range: anything changed under <chart-dir> since the commit
# that last changed the chart's version gets a patch bump. A range would miss
# changes from runs GitHub never ran (a pending run in the same concurrency
# group is replaced by the next one); history cannot. A merged bump PR or a
# deliberate hand bump moves the version, so nothing is left to bump.
# Prints none|patch|minor|major.
set -euo pipefail

chart_dir="${1%/}" dispatch="$2"

case "$dispatch" in
  none) ;;
  patch|minor|major) echo "$dispatch"; exit 0 ;;
  *) echo "invalid dispatch level: $dispatch" >&2; exit 1 ;;
esac

# `^version:` only matches the chart's own version: dependency versions are
# indented under `dependencies:`.
since=$(git log -1 --format=%H -G '^version:' -- "$chart_dir/Chart.yaml")
if [ -z "$since" ]; then
  echo none
  exit 0
fi

if git diff --quiet "$since" HEAD -- "$chart_dir"; then
  echo none
else
  echo patch
fi
