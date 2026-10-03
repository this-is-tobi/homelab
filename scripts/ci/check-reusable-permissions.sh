#!/usr/bin/env bash
# Check that every job calling a remote reusable workflow grants at least the
# permissions that workflow's jobs declare.
#
#   check-reusable-permissions.sh <workflow.yml>...
#
# GitHub refuses to start a run whose called jobs ask for more than the caller
# grants (a "startup failure", no job runs), and actionlint cannot see remote
# workflows, so without this the mismatch only shows up on main. The called
# workflow is read at the ref the caller pins. Needs gh (GH_TOKEN), yq and jq.
set -euo pipefail

rank() {
  case "$1" in
    write) echo 2 ;;
    read) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Normalize a `permissions:` value (object, read-all, write-all, absent) to an
# object; `*` stands for every scope.
normalize() {
  jq -c 'if . == "write-all" then {"*": "write"} elif . == "read-all" then {"*": "read"} elif . == null then {} else . end'
}

fail=0
for wf in "$@"; do
  top=$(yq -o=json '.permissions' "$wf" | normalize)

  while IFS=$'\t' read -r job uses granted; do
    repo=${uses%%/.github/*}
    ref=${uses##*@}
    path=${uses#"$repo"/}
    path=${path%@*}

    called=$(gh api "repos/$repo/contents/$path?ref=$ref" --jq .content | base64 -d)
    called_top=$(yq -o=json '.permissions' <<<"$called" | normalize)
    # A called job without its own permissions asks for the called workflow's
    # top-level ones.
    needed=$(yq -o=json '.jobs' <<<"$called" | jq -c --argjson top "$called_top" '
      [.[] | (.permissions // $top) | if type == "string" then {} else . end | to_entries[]]
      | group_by(.key)
      | map({(.[0].key): (if any(.[]; .value == "write") then "write" else "read" end)})
      | add // {}')

    for scope in $(jq -r 'keys[]' <<<"$needed"); do
      need=$(jq -r --arg s "$scope" '.[$s]' <<<"$needed")
      have=$(jq -r --arg s "$scope" '.[$s] // .["*"] // "none"' <<<"$granted")
      if [ "$(rank "$have")" -lt "$(rank "$need")" ]; then
        echo "$wf: job '$job' grants $scope: $have, but $uses needs $scope: $need"
        fail=1
      fi
    done
  done < <(yq -o=json '.jobs' "$wf" | jq -r --argjson top "$top" '
    to_entries[]
    | select((.value.uses // "") | test("^[^./][^@]*/\\.github/workflows/[^@]+@"))
    | [.key, .value.uses, ((.value.permissions // $top) | if . == "write-all" then {"*": "write"} elif . == "read-all" then {"*": "read"} else . end | tojson)]
    | @tsv')
done

if [ "$fail" -eq 0 ]; then
  echo "every reusable-workflow call grants what the called jobs declare"
fi
exit "$fail"
