#!/usr/bin/env bash
# Exercises test-kyverno-policies.sh against a throwaway chart: a policy whose
# fixtures behave must pass, one whose fixture expects the wrong result must
# fail, and a chart without fixtures is a pass.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/test-kyverno-policies.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

make_chart() { # $1 = chart dir, $2 = expected result for the hostNetwork pod
  local chart="$1"
  mkdir -p "$chart/templates" "$chart/tests/policies/fixture"
  cat >"$chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: fixture
version: 0.1.0
EOF
  cat >"$chart/templates/policy.yaml" <<'EOF'
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: no-host-network
spec:
  validationActions: [Audit]
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
  validations:
  - expression: "!object.spec.?hostNetwork.orValue(false)"
    message: hostNetwork is not allowed
EOF
  cat >"$chart/tests/policies/fixture/resources.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: clean, namespace: demo}
spec: {containers: [{name: a, image: busybox:1}]}
---
apiVersion: v1
kind: Pod
metadata: {name: host, namespace: demo}
spec: {hostNetwork: true, containers: [{name: a, image: busybox:1}]}
EOF
  cat >"$chart/tests/policies/fixture/kyverno-test.yaml" <<EOF
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata: {name: fixture}
policies: [../../rendered/policies.yaml]
resources: [resources.yaml]
results:
- {policy: no-host-network, isValidatingPolicy: true, kind: Pod, resources: [clean], result: pass}
- {policy: no-host-network, isValidatingPolicy: true, kind: Pod, resources: [host], result: $2}
EOF
}

check() { # $1 = name, $2 = expected exit (0 or nonzero), $3 = chart dir
  local rc=0
  "$script" "$3" >/dev/null 2>&1 || rc=$?
  if { [ "$2" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$2" = nonzero ] && [ "$rc" -ne 0 ]; }; then
    echo "ok   $1"
  else
    echo "FAIL $1 (exit $rc, wanted $2)"; failures=$((failures + 1))
  fi
}

make_chart "$work/pass" fail
check "matching fixtures pass" 0 "$work/pass"
make_chart "$work/fail" pass
check "a fixture expecting the wrong result fails" nonzero "$work/fail"
mkdir -p "$work/empty/templates"
printf 'apiVersion: v2\nname: empty\nversion: 0.1.0\n' >"$work/empty/Chart.yaml"
check "no fixtures is a pass" 0 "$work/empty"

exit "$failures"
