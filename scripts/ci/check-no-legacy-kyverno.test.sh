#!/usr/bin/env bash
# Exercises check-no-legacy-kyverno.sh: rendered manifests holding a
# kyverno.io/v1 or v2 object fail, CEL-only manifests pass.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-no-legacy-kyverno.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failures=0

printf 'apiVersion: policies.kyverno.io/v1\nkind: ValidatingPolicy\nmetadata: {name: a}\n' >"$work/cel.yaml"
printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata: {name: a}\n' >"$work/v1.yaml"
printf 'apiVersion: kyverno.io/v1\nkind: Policy\nmetadata: {name: a, namespace: b}\n' >"$work/policy.yaml"
printf 'apiVersion: kyverno.io/v2\nkind: PolicyException\nmetadata: {name: a}\n' >"$work/v2.yaml"
printf 'apiVersion: kyverno.io/v2\nkind: CleanupPolicy\nmetadata: {name: a}\n' >"$work/cleanup.yaml"
printf 'apiVersion: kyverno.io/v2beta1\nkind: ClusterPolicy\nmetadata: {name: a}\n' >"$work/v2beta1.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: kyverno.io/v1}\n' >"$work/lookalike.yaml"
printf 'apiVersion: policies.kyverno.io/v1\nkind: ValidatingPolicy\nmetadata: {name: a}\n---\napiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata: {name: b}\n' >"$work/mixed.yaml"
printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata: {name: a}\n---\napiVersion: kyverno.io/v2\nkind: PolicyException\nmetadata: {name: b}\n---\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\n' >"$work/two.yaml"
: >"$work/empty.yaml"

check() { # check <name> <want: 0|nonzero> <file> [pattern in the output]
  local rc=0 out
  out=$("$script" <"$3" 2>&1) || rc=$?
  if { [ "$2" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$2" = nonzero ] && [ "$rc" -eq 0 ]; }; then
    echo "FAIL $1 (exit $rc)"; failures=$((failures + 1))
  elif [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$out"; then
    echo "FAIL $1: no '$4' in: $out"; failures=$((failures + 1))
  else
    echo "ok   $1"
  fi
}

check "CEL-only passes" 0 "$work/cel.yaml"
check "an empty render passes" 0 "$work/empty.yaml"
check "a name that looks like a legacy apiVersion passes" 0 "$work/lookalike.yaml"
check "a ClusterPolicy fails and is named" nonzero "$work/v1.yaml" "ClusterPolicy/a"
check "a namespaced Policy fails" nonzero "$work/policy.yaml" "Policy/a"
check "a legacy PolicyException fails" nonzero "$work/v2.yaml" "PolicyException/a"
check "a CleanupPolicy fails" nonzero "$work/cleanup.yaml" "CleanupPolicy/a"
check "a beta apiVersion fails" nonzero "$work/v2beta1.yaml" "ClusterPolicy/a"
check "a legacy object among CEL ones fails and only it is named" nonzero "$work/mixed.yaml" "ClusterPolicy/b"

# Each object is named once with its own kind, whatever else the render holds.
want=$'::error::legacy Kyverno objects rendered (removed in Kyverno 1.20):\nClusterPolicy/a\nPolicyException/b'
got=$("$script" <"$work/two.yaml" 2>&1 || true)
if [ "$got" = "$want" ]; then echo "ok   every legacy object is named once, with its own kind"; else echo "FAIL every legacy object is named once, with its own kind: $got"; failures=$((failures + 1)); fi
exit "$failures"
