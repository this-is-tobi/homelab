#!/usr/bin/env bash
# Lists the dashboard queries that return no data, so a change to scrape or
# drop rules can be checked by diffing two runs: a line present after the
# change but not before is a panel the change blanked.
#
#   kubectl -n prometheus-stack port-forward svc/prometheus-stack-kube-prom-prometheus 9090 &
#   scripts/dashboard-coverage.sh >before.txt     # change, sync, wait
#   scripts/dashboard-coverage.sh >after.txt && diff before.txt after.txt
#
# Template variables in label matchers become match-all values and interval
# variables become 5m; a query still holding a variable after that is
# reported as SKIP instead of being guessed. Without file arguments the
# dashboards are read from every grafana_dashboard=1 ConfigMap.
set -euo pipefail

prom="${PROM_URL:-http://localhost:9090}"

dashboards() {
  if [ "$#" -gt 0 ]; then
    for f in "$@"; do jq -c . "$f"; done
  else
    kubectl get configmaps -A -l grafana_dashboard=1 -o json | jq -c '.items[].data[] | fromjson'
  fi
}

# One JSON object per panel query: {dashboard, panel, expr}.
queries() {
  jq -c '. as $d | .. | objects | select(has("targets")) | . as $p
         | .targets[]? | select((.expr? // "") != "")
         | {dashboard: ($d.title // "-"), panel: ($p.title // "-"), expr: (.expr | gsub("\\s+"; " "))}'
}

substitute() {
  sed -E \
    -e 's/\$\{?(__rate_interval|__interval|__range|interval|resolution)\}?/5m/g' \
    -e 's/(!=|!~)"\$\{?[A-Za-z_][A-Za-z0-9_]*(:[a-z]+)?\}?"/!~"^__none__$"/g' \
    -e 's/(=~|=)"\$\{?[A-Za-z_][A-Za-z0-9_]*(:[a-z]+)?\}?"/=~".*"/g'
}

mode=check
if [ "${1:-}" = "--expressions" ]; then mode=expressions; shift; fi

dashboards "$@" | queries | while read -r line; do
  dash=$(jq -r .dashboard <<<"$line")
  panel=$(jq -r .panel <<<"$line")
  expr=$(jq -r .expr <<<"$line" | substitute)
  if [ "$mode" = expressions ]; then
    printf '%s\t%s\t%s\n' "$dash" "$panel" "$expr"
    continue
  fi
  if [[ "$expr" == *'$'* ]]; then
    printf 'SKIP\t%s\t%s\n' "$dash" "$panel"
    continue
  fi
  if ! res=$(curl -fsS --get "$prom/api/v1/query" --data-urlencode "query=$expr" 2>/dev/null); then
    printf 'ERROR\t%s\t%s\n' "$dash" "$panel"
  elif [ "$(jq '.data.result | length' <<<"$res")" -eq 0 ]; then
    printf 'EMPTY\t%s\t%s\n' "$dash" "$panel"
  fi
done | sort -u
