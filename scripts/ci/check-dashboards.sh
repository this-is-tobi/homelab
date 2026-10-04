#!/usr/bin/env bash
# Every dashboard shipped from the repo must parse and reference only
# datasources every Grafana here provisions: a template variable, a Grafana
# built-in, or the fixed uids prometheus / loki / alertmanager. A uid copied
# from another Grafana renders every panel as "datasource not found".
set -euo pipefail

allowed='^(\$\{?[A-Za-z_][A-Za-z0-9_]*(:[a-z]+)?\}?|-- Grafana --|-- Mixed --|-- Dashboard --|grafana|__expr__|prometheus|loki|alertmanager)$'
failures=0

for f in "$@"; do
  if ! jq empty "$f" 2>/dev/null; then
    echo "::error file=$f::not valid JSON"
    failures=$((failures + 1))
    continue
  fi
  bad=$(jq -r '[.. | objects | select(has("datasource")) | .datasource
                | if type == "object" then .uid elif type == "string" then . else empty end
                | select(. != null)] | unique[]' "$f" | grep -vE "$allowed" || true)
  if [ -n "$bad" ]; then
    echo "::error file=$f::unknown datasource uid(s): $(echo "$bad" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
done

exit "$failures"
