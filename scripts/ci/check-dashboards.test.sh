#!/usr/bin/env bash
# Exercises check-dashboards.sh: provisioned or variable datasources pass,
# a hardcoded uid from another Grafana and invalid JSON fail.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check-dashboards.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

cat >"$work/good.json" <<'EOF'
{"title": "good", "panels": [
  {"datasource": {"type": "prometheus", "uid": "${datasource}"}, "targets": [{"expr": "up"}]},
  {"datasource": {"type": "prometheus", "uid": "prometheus"}},
  {"datasource": "$datasource"},
  {"datasource": {"type": "datasource", "uid": "grafana"}},
  {"datasource": {"type": "prometheus"}},
  {"datasource": null},
  {"datasource": {"type": "loki", "uid": "loki"}},
  {"datasource": {"uid": "-- Grafana --"}},
  {"datasource": {"uid": "__expr__"}}
]}
EOF
cat >"$work/hardcoded.json" <<'EOF'
{"title": "bad", "panels": [{"datasource": {"type": "prometheus", "uid": "P1809F7CD0C75ACF3"}}]}
EOF
printf '{"title": ' >"$work/broken.json"

check() { # $1 = name, $2 = expected exit (0 or nonzero), rest = files
  local name="$1" want="$2" rc=0; shift 2
  "$script" "$@" >/dev/null 2>&1 || rc=$?
  if { [ "$want" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$want" = nonzero ] && [ "$rc" -ne 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $rc, wanted $want)"; failures=$((failures + 1))
  fi
}

check "provisioned and variable datasources pass" 0 "$work/good.json"
check "hardcoded foreign uid fails" nonzero "$work/hardcoded.json"
check "invalid JSON fails" nonzero "$work/broken.json"
check "one bad file fails the run" nonzero "$work/good.json" "$work/hardcoded.json"

exit "$failures"
