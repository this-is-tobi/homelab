#!/usr/bin/env bash
# Exercises the offline half of dashboard-coverage.sh: panel queries are
# found at any nesting depth and template variables become match-all
# values, while variables it cannot substitute stay visible (SKIP later).
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/dashboard-coverage.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/d.json" <<'EOF'
{"title": "Demo", "panels": [
  {"title": "rate", "targets": [{"expr": "rate(foo_total{job=\"$job\"}[$__rate_interval])"}]},
  {"title": "row", "panels": [
    {"title": "neg", "targets": [{"expr": "sum(bar{ns!=\"${ns}\"})"}]},
    {"title": "regex", "targets": [{"expr": "baz{pod=~\"$pod\", le=\"0.5\"}"}]}
  ]},
  {"title": "partial", "targets": [{"expr": "node_load1{instance=~\"$node:9100\"}"}]},
  {"title": "empty", "targets": [{"expr": ""}]}
]}
EOF

got=$("$script" --expressions "$work/d.json" | sort)
want=$(printf '%s\n' \
  $'Demo\tneg\tsum(bar{ns!~"^__none__$"})' \
  $'Demo\tpartial\tnode_load1{instance=~"$node:9100"}' \
  $'Demo\trate\trate(foo_total{job=~".*"}[5m])' \
  $'Demo\tregex\tbaz{pod=~".*", le="0.5"}' | sort)

if [ "$got" = "$want" ]; then
  echo "ok   substitution and nesting"
else
  echo "FAIL substitution and nesting"; diff <(echo "$want") <(echo "$got") || true; exit 1
fi
