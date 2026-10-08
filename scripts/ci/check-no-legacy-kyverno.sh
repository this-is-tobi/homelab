#!/usr/bin/env bash
# Reads rendered manifests on stdin and fails when one is a legacy Kyverno
# object. Kyverno 1.20 removes ClusterPolicy and Policy (kyverno.io/v1), the
# legacy PolicyException and CleanupPolicy (kyverno.io/v2): the CEL types
# (policies.kyverno.io) replace them, so no chart may render the old ones.
set -euo pipefail

bad=$(yq -N 'select((.apiVersion // "") | test("^kyverno\\.io/v[12]")) | .kind + "/" + .metadata.name' -)
if [ -n "$bad" ]; then
  echo "::error::legacy Kyverno objects rendered (removed in Kyverno 1.20):"
  echo "$bad"
  exit 1
fi
