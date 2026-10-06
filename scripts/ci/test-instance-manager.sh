#!/usr/bin/env bash
# Evaluates the child ApplicationSet templates of the instance-manager chart
# for hand-written catalogue entries and checks the chart source each
# generated Application gets. Argo CD renders these templates with Go
# templates plus the sprig functions, the same engine Helm's `tpl` uses, so
# the placeholders can be evaluated offline. Needs helm, yq and jq.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="${1:-$ROOT/argo-cd/apps/instance-manager}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

GIT=https://git.example/repo.git
REGISTRY=ghcr.io/example/charts

# render_sources <scope> <elements-json> -> one compact JSON object per
# element: the first source of the Application it generates, without the
# empty fields (an empty field is the same as an unset one to Argo CD).
render_sources() {
  local scope="$1" elements="$2"
  helm template t "$CHART" --set instance.name=t --set "repoURL=$GIT" \
    --set-json "catalogs={\"ohmlab\":\"$REGISTRY\"}" >"$work/appsets.yaml" || return 1
  yq ea "select(.kind == \"ApplicationSet\" and .metadata.name == \"$scope-t\")" "$work/appsets.yaml" >"$work/appset.yaml"
  rm -rf "$work/eval" && mkdir -p "$work/eval/templates"
  printf 'apiVersion: v2\nname: eval\nversion: 0.1.0\n' >"$work/eval/Chart.yaml"
  sed -n '/^  template:$/,/^  templatePatch:/p' "$work/appset.yaml" | sed '1d;$d' | sed 's/^    //' >"$work/eval/app.tpl"
  cat >"$work/eval/templates/out.yaml" <<'EOF'
{{- range .Values.elements }}
---
{{ tpl ($.Files.Get "app.tpl") . }}
{{- end }}
EOF
  # Helm's tpl evaluates a missing nested key (.destination.server) to an error
  # where Argo CD's renderer prints nothing, so every element gets an empty
  # destination, the one nested key the templates read.
  elements=$(jq -c 'map(. + {destination: (.destination // {})})' <<<"$elements")
  helm template eval "$work/eval" --set-json "elements=$elements" 2>"$work/eval.err" \
    | yq ea -o=json -I=0 '[.spec.sources[0]]' - 2>/dev/null \
    | jq -c '.[] | to_entries | map(select(.value != "")) | sort_by(.key) | from_entries' 2>/dev/null
  [ -s "$work/eval.err" ] && head -c 400 "$work/eval.err" >&2
  return 0
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    fail=1
  fi
}


for scope in core tenant; do
  elements='[
    {"app":"plain"},
    {"app":"alias","chart":"other","releaseName":"rel"},
    {"app":"inrepo","chartPath":"utils/helm","targetRevision":"v1"},
    {"app":"ohmlab","catalog":"ohmlab","targetRevision":"0.1.3"},
    {"app":"renamed","catalog":"ohmlab","chart":"ohmlab","targetRevision":"0.1.3","releaseName":"ohmlab"},
    {"app":"unpinned","catalog":"ohmlab"},
    {"app":"stray","catalog":"nope","targetRevision":"1.0.0"}
  ]'
  out=$(render_sources "$scope" "$elements")
  line() { printf '%s\n' "$out" | sed -n "${1}p"; }

  check "$scope: plain entry keeps the git path source" \
    '{"helm":{"releaseName":"plain","valueFiles":["$values/argo-cd/instances/t/values/'"$scope"'/plain.yaml"]},"path":"argo-cd/apps/plain","repoURL":"'"$GIT"'","targetRevision":"main"}' "$(line 1)"
  check "$scope: chart override keeps the git path source" \
    '{"helm":{"releaseName":"rel","valueFiles":["$values/argo-cd/instances/t/values/'"$scope"'/alias.yaml"]},"path":"argo-cd/apps/other","repoURL":"'"$GIT"'","targetRevision":"main"}' "$(line 2)"
  check "$scope: chartPath and targetRevision overrides keep the git source" \
    '{"helm":{"releaseName":"inrepo","valueFiles":["$values/argo-cd/instances/t/values/'"$scope"'/inrepo.yaml"]},"path":"utils/helm","repoURL":"'"$GIT"'","targetRevision":"v1"}' "$(line 3)"
  check "$scope: catalog entry becomes an OCI chart source" \
    '{"chart":"ohmlab","helm":{"releaseName":"ohmlab","valueFiles":["$values/argo-cd/instances/t/values/'"$scope"'/ohmlab.yaml"]},"repoURL":"'"$REGISTRY"'","targetRevision":"0.1.3"}' "$(line 4)"
  check "$scope: catalog entry with an explicit chart name" \
    '{"chart":"ohmlab","helm":{"releaseName":"ohmlab","valueFiles":["$values/argo-cd/instances/t/values/'"$scope"'/renamed.yaml"]},"repoURL":"'"$REGISTRY"'","targetRevision":"0.1.3"}' "$(line 5)"

  unpinned=$(line 6 | jq -r '.targetRevision')
  case "$unpinned" in
    ""|main|latest|"*") echo "FAIL $scope: a catalog entry without targetRevision must not resolve to '$unpinned'"; fail=1 ;;
    *) echo "ok   $scope: catalog entry without targetRevision fails closed ('$unpinned')" ;;
  esac
  check "$scope: unknown catalog gives no repository" "" "$(line 7 | jq -r ".repoURL // \"\"")"
done

exit "$fail"
