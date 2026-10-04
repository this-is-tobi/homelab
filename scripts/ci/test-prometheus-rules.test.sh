#!/usr/bin/env bash
# Exercises test-prometheus-rules.sh against a throwaway chart: a rule
# file whose test matches must pass, one whose test expects an alert the
# chart does not define must fail.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/test-prometheus-rules.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

make_chart() { # $1 = apps root, $2 = expected alert name in the test file
  local chart="$1/fixture"
  mkdir -p "$chart/templates" "$chart/tests"
  cat >"$chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: fixture
version: 0.1.0
EOF
  cat >"$chart/templates/rule.yaml" <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: fixture
  namespace: {{ .Release.Namespace }}
spec:
  groups:
  - name: fixture
    rules:
    - alert: FixtureUp
      expr: up{namespace="{{ .Release.Namespace }}"} == 0
      labels:
        severity: warning
      annotations:
        summary: fixture down
EOF
  cat >"$chart/tests/prometheusrules.test.yaml" <<EOF
rule_files: [rules.yaml]
evaluation_interval: 1m
tests:
- interval: 1m
  input_series:
  - series: 'up{namespace="test", job="x"}'
    values: '0x5'
  alert_rule_test:
  - eval_time: 2m
    alertname: $2
    exp_alerts:
    - exp_labels: {severity: warning, namespace: test, job: x}
      exp_annotations: {summary: fixture down}
EOF
}

check() { # $1 = name, $2 = expected exit (0 or nonzero), $3 = apps root
  local rc=0
  (cd "$work" && "$script" "$3" >/dev/null 2>&1) || rc=$?
  if { [ "$2" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$2" = nonzero ] && [ "$rc" -ne 0 ]; }; then
    echo "ok   $1"
  else
    echo "FAIL $1 (exit $rc, wanted $2)"; failures=$((failures + 1))
  fi
}

make_chart "$work/pass" FixtureUp
check "matching test passes" 0 "$work/pass"
make_chart "$work/fail" FixtureMissing
check "test for an undefined alert fails" nonzero "$work/fail"
mkdir -p "$work/empty"
check "no test files is a pass" 0 "$work/empty"

exit "$failures"
