#!/bin/bash
# post-install-api.sh: Vault bootstrap using only API calls (curl), for use inside Kubernetes
# Requirements: curl, jq, base64

set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault-system}"
VAULT_PODS=(vault-system-0 vault-system-1 vault-system-2)
SECRET_NAME="vault-admin"
KEY_SHARES=3
KEY_THRESHOLD=2
KUBE_API="https://kubernetes.default.svc"
TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
SA_TOKEN=$(cat "$TOKEN_PATH")

vault_api() {
  local pod="$1"
  local path="$2"
  local method="${3:-GET}"
  local data="${4:-}"
  local token="${5:-}"
  local url="http://$pod.$NAMESPACE.svc.cluster.local:8200$path"
  local headers=("-H" "Content-Type: application/json")
  if [[ -n "$token" ]]; then
    headers+=("-H" "X-Vault-Token: $token")
  fi
  if [[ "$method" == "GET" ]]; then
    curl -sS "${headers[@]}" "$url"
  else
    curl -sS -X "$method" "${headers[@]}" -d "$data" "$url"
  fi
}

kube_api() {
  local path="$1"
  local method="${2:-GET}"
  local data="${3:-}"
  local url="$KUBE_API$path"
  local headers=("-H" "Authorization: Bearer $SA_TOKEN" "--cacert" "$CA_PATH" "-H" "Content-Type: application/json")
  if [[ "$method" == "GET" ]]; then
    curl -sS "${headers[@]}" "$url"
  else
    curl -sS -X "$method" "${headers[@]}" -d "$data" "$url"
  fi
}

wait_for_vault() {
  local pod="$1"
  for i in {1..60}; do
    if vault_api "$pod" "/v1/sys/health" GET | jq .; then
      return 0
    fi
    sleep 10
  done
  echo "Vault pod $pod not ready after timeout" >&2
  exit 1
}

get_vault_status() {
  local pod="$1"
  vault_api "$pod" "/v1/sys/init" GET
}

init_vault() {
  local pod="$1"
  local data="{\"secret_shares\":$KEY_SHARES,\"secret_threshold\":$KEY_THRESHOLD}"
  vault_api "$pod" "/v1/sys/init" POST "$data"
}

get_secret() {
  kube_api "/api/v1/namespaces/$NAMESPACE/secrets/$SECRET_NAME"
}

create_secret() {
  local json="$1"
  local unseal1=$(echo "$json" | jq -r '.unseal_keys_b64[0]' | base64 | tr -d '\n')
  local unseal2=$(echo "$json" | jq -r '.unseal_keys_b64[1]' | base64 | tr -d '\n')
  local unseal3=$(echo "$json" | jq -r '.unseal_keys_b64[2]' | base64 | tr -d '\n')
  local root=$(echo "$json" | jq -r '.root_token' | base64 | tr -d '\n')
  local init=$(echo "$json" | base64 | tr -d '\n')
  local body='{
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "'$SECRET_NAME'", "namespace": "'$NAMESPACE'"},
    "data": {
      "unsealKey1": "'$unseal1'",
      "unsealKey2": "'$unseal2'",
      "unsealKey3": "'$unseal3'",
      "rootToken": "'$root'",
      "initConfig": "'$init'"
    }
  }'
  kube_api "/api/v1/namespaces/$NAMESPACE/secrets" POST "$body"
}

unseal_vault() {
  local pod="$1"
  local key1="$2"
  local key2="$3"
  vault_api "$pod" "/v1/sys/unseal" PUT '{"key":"'$key1'"}'
  vault_api "$pod" "/v1/sys/unseal" PUT '{"key":"'$key2'"}'
}

join_raft() {
  local pod="$1"
  local leader_pod="$2"
  vault_api "$pod" "/v1/sys/raft/join" POST '{"leader_api_addr":"http://'$leader_pod'.'$NAMESPACE'.svc.cluster.local:8200"}'
}

# Main logic
main() {
  for pod in "${VAULT_PODS[@]}"; do
    wait_for_vault "$pod"
  done

  status_json=$(get_vault_status "${VAULT_PODS[0]}")
  initialized=$(echo "$status_json" | jq -r '.initialized')

  if [[ "$initialized" == "false" ]]; then
    if get_secret | jq -e .metadata &>/dev/null; then
      echo "Vault not initialized but secret $SECRET_NAME exists. Exiting for safety."
      exit 1
    fi
    init_json=$(init_vault "${VAULT_PODS[0]}")
    create_secret "$init_json"
    root_token=$(echo "$init_json" | jq -r '.root_token')
  else
    secret_json=$(get_secret)
    root_token=$(echo "$secret_json" | jq -r '.data.rootToken' | base64 -d)
  fi

  # Unseal all pods
  secret_json=$(get_secret)
  key1=$(echo "$secret_json" | jq -r '.data.unsealKey1' | base64 -d)
  key2=$(echo "$secret_json" | jq -r '.data.unsealKey2' | base64 -d)

  for pod in "${VAULT_PODS[@]}"; do
    health=$(vault_api "$pod" "/v1/sys/health" GET)
    sealed=$(echo "$health" | jq -r '.sealed')
    if [[ "$sealed" == "true" ]]; then
      unseal_vault "$pod" "$key1" "$key2"
    fi
  done

  # Join raft for pods 1 and 2 (if not initialized)
  for i in 1 2; do
    pod="${VAULT_PODS[$i]}"
    status_json=$(get_vault_status "$pod")
    initialized=$(echo "$status_json" | jq -r '.initialized')
    if [[ "$initialized" == "false" ]]; then
      join_raft "$pod" "${VAULT_PODS[0]}"
    fi
  done

  # Enable KV engine if not present
  kv_status=$(vault_api "${VAULT_PODS[0]}" "/v1/sys/mounts/secret" GET "" "$root_token" | jq -r '.data.type // empty')
  if [[ -z "$kv_status" ]]; then
    echo "Enabling KV engine..."
    vault_api "${VAULT_PODS[0]}" "/v1/sys/mounts/secret" POST '{"type":"kv","options":{"version":2}}' "$root_token"
  else
    echo "KV engine already enabled."
  fi

  echo "Vault post-install bootstrap complete (API-only)."
}

main
