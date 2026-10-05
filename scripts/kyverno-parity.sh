#!/usr/bin/env bash
# Compares the legacy ClusterPolicies and the CEL ValidatingPolicies on the
# resources running in the cluster the current kubectl context points at
# (read-only). Needs the kyverno CLI 1.19.1 on PATH. The live manifests are
# written to a temp dir that is removed on exit and must never be committed.
set -euo pipefail

chart="${1:-argo-cd/apps/kyverno}"
values="${2:-argo-cd/instances/homelab/values/core/kyverno.yaml}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One JSON file per resource: the CLI rejects a JSON array or a kind: List,
# and converting to YAML turns strings such as "no" or "on" into YAML 1.1
# booleans that the legacy podSecurity evaluation then fails to decode.
mkdir -p "$work/res"
kubectl get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json \
  | jq -c '.items[] | del(.metadata.managedFields, .status)' >"$work/live.ndjson"
split -l 1 -a 5 "$work/live.ndjson" "$work/res/r-"
res=()
for f in "$work"/res/r-*; do mv "$f" "$f.json"; res+=(--resource "$f.json"); done

helm template ci "$chart" -n kyverno -f "$values" >"$work/all.yaml"
yq ea 'select(.kind == "ClusterPolicy")' "$work/all.yaml" >"$work/legacy-policies.yaml"
yq ea 'select(.kind == "PolicyException" and .apiVersion == "kyverno.io/v2")' "$work/all.yaml" >"$work/legacy-exceptions.yaml"
yq ea 'select(.kind == "ValidatingPolicy")' "$work/all.yaml" >"$work/cel-policies.yaml"
yq ea 'select(.kind == "PolicyException" and (.apiVersion | test("^policies\\.kyverno\\.io/")))' "$work/all.yaml" >"$work/cel-exceptions.yaml"

report() { # $1 = policies file, $2 = exceptions file
  # kyverno apply exits 1 when any resource fails a policy; that is data here.
  { kyverno apply "$1" "${res[@]}" --exception "$2" --policy-report 2>/dev/null || true; } \
    | sed -n '/^apiVersion/,$p' \
    | yq -o=tsv '.results[]? | [.policy, (.resources[0].namespace // "-") + "/" + .resources[0].kind + "/" + .resources[0].name, .result]' \
    | sort
}
report "$work/legacy-policies.yaml" "$work/legacy-exceptions.yaml" >"$work/legacy.tsv"
report "$work/cel-policies.yaml" "$work/cel-exceptions.yaml" >"$work/cel.tsv"

tally() { # $1 = results file: "policy result" counts, to read a clean run against
  cut -f1,3 "$1" | sort | uniq -c | awk '{printf "  %-28s %-6s %s\n", $2, $3, $1}' >&2
}
echo "legacy:" >&2; tally "$work/legacy.tsv"
echo "CEL:" >&2; tally "$work/cel.tsv"

join -t$'\t' -a1 -a2 -e MISSING -o 0,1.2,2.2 \
  <(awk -F'\t' '{print $1 "|" $2 "\t" $3}' "$work/legacy.tsv" | sort -t$'\t' -k1,1) \
  <(awk -F'\t' '{print $1 "|" $2 "\t" $3}' "$work/cel.tsv" | sort -t$'\t' -k1,1) \
  | awk -F'\t' '$2 != $3 {split($1, k, "|"); print "DIFF\t" k[1] "\t" k[2] "\t" $2 "\t" $3; n++} END {printf "%d legacy results, %d CEL results, %d differences\n", '"$(wc -l <"$work/legacy.tsv")"', '"$(wc -l <"$work/cel.tsv")"', n + 0 > "/dev/stderr"; exit n > 0}'
