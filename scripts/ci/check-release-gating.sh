#!/usr/bin/env bash
# Check the release setup of cd.yml against release-please-config.json.
#
#   check-release-gating.sh [release-please-config.json [workflow.yml]]
#
# The release job answers for every package of release-please-config.json at
# once, and `releases-created` is true when any one of them was released. A job
# that publishes package P must therefore be gated on P itself:
#
#   if: ${{ contains(fromJSON(needs.release.outputs.paths-released), 'P') }}
#
# Without it, releasing the catalog also builds the CLI image with a version
# that does not exist, and the other way round. A job counts as gated when it,
# or any job it needs, carries that condition.
#
# A package released as `simple` also needs its version file in the repository:
# release-please only updates one that exists, so without it the release PR
# carries a changelog and no version, and the published artifact cannot say
# which version it is. Needs yq and jq.
set -euo pipefail

CONFIG=${1:-release-please-config.json}
WORKFLOW=${2:-.github/workflows/cd.yml}

packages=$(jq -c '[.packages | keys[]]' "$CONFIG")
jobs=$(yq -o=json '.jobs' "$WORKFLOW")

# One TSV row per finding: <kind> <job> <path>.
#   reads  - the job reads the per-path outputs of <path>
#   gated  - the job (or a job it needs) is gated on <path>
#   any    - the job's own condition tests `releases-created`, whichever
#            package was released
rows=$(jq -r --arg q "'" '
  def listed: if type == "string" then [.] elif type == "array" then . else [] end;
  def gates($jobs; $name):
    $jobs[$name] as $j
    | [($j.if // "" | tostring | scan("paths-released\\), \($q)([^\($q)]+)\($q)") | .[0])]
      + ([($j.needs | listed)[] | gates($jobs; .)] | add // []);
  . as $jobs
  | to_entries[]
  | .key as $name
  | (.value | tojson) as $text
  | ([$text | scan("release-outputs\\)\\[\($q)([^\($q)]+)--") | .[0]] | unique[] | ["reads", $name, .]),
    (gates($jobs; $name) | unique[] | ["gated", $name, .]),
    (select(.value.if // "" | tostring | test("releases-created")) | ["any", $name, ""])
  | @tsv' <<<"$jobs")

fail=0
say() { printf '%s\n' "$*"; }

while IFS=$'\t' read -r kind job path; do
  [ "$kind" = reads ] || continue
  if ! grep -qxF "gated"$'\t'"$job"$'\t'"$path" <<<"$rows"; then
    say "FAIL $job reads the release outputs of '$path' but is not gated on its release"
    fail=1
  fi
done <<<"$rows"

while IFS=$'\t' read -r kind job _; do
  [ "$kind" = any ] || continue
  if ! awk -F'\t' -v j="$job" '$1 == "gated" && $2 == j { found = 1 } END { exit !found }' <<<"$rows"; then
    say "FAIL $job is gated on any release (releases-created); gate it on its package with paths-released"
    fail=1
  fi
done <<<"$rows"

while IFS=$'\t' read -r kind job path; do
  [ "$kind" = gated ] || continue
  if ! jq -e --arg p "$path" 'index($p) != null' <<<"$packages" >/dev/null; then
    say "FAIL $job is gated on '$path', which is not a package of $CONFIG"
    fail=1
  fi
done <<<"$rows"

for path in $(jq -r '.[]' <<<"$packages"); do
  if ! awk -F'\t' -v p="$path" '$1 == "gated" && $3 == p { found = 1 } END { exit !found }' <<<"$rows"; then
    say "FAIL no job of $WORKFLOW is gated on the release of '$path'"
    fail=1
  fi
done

while IFS=$'\t' read -r path file; do
  if [ ! -f "$(dirname "$CONFIG")/$path/$file" ]; then
    say "FAIL '$path' is released as simple but $path/$file does not exist: release-please only updates an existing file, so add it with the version before the first release (0.0.0)"
    fail=1
  fi
done < <(jq -r '.packages | to_entries[] | select(.value["release-type"] == "simple") | [.key, (.value["version-file"] // "version.txt")] | @tsv' "$CONFIG")

[ "$fail" = 0 ] && say "ok   every package release runs only its own jobs and has what its release type updates"
exit "$fail"
