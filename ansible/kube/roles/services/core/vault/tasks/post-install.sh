#!/bin/bash
# post-install.sh: Vault bootstrap script for Kubernetes (to be run inside the cluster)
# Requirements: kubectl, jq, vault CLI, base64

set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault-system}"
VAULT_PODS=(vault-system-0 vault-system-1 vault-system-2)
SECRET_NAME="vault-admin"
KEY_SHARES=3
KEY_THRESHOLD=2

wait_for_pod() {
  local pod="$1"
  echo "Waiting for pod $pod to be ready..."
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/$pod --timeout=600s
}

get_vault_status() {
  local pod="$1"
  kubectl -n "$NAMESPACE" exec "$pod" -c vault -- vault status -format=json
}

init_vault() {
  local pod="$1"
  echo "Initializing Vault on $pod..."
  kubectl -n "$NAMESPACE" exec "$pod" -c vault -- vault operator init -key-shares=$KEY_SHARES -key-threshold=$KEY_THRESHOLD -format=json
}

store_vault_keys() {
  local json="$1"
  echo "Storing Vault keys in Kubernetes secret $SECRET_NAME..."
  kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-literal=unsealKey1="$(echo "$json" | jq -r '.unseal_keys_b64[0]' | base64)" \
    --from-literal=unsealKey2="$(echo "$json" | jq -r '.unseal_keys_b64[1]' | base64)" \
    --from-literal=unsealKey3="$(echo "$json" | jq -r '.unseal_keys_b64[2]' | base64)" \
    --from-literal=rootToken="$(echo "$json" | jq -r '.root_token' | base64)" \
    --from-literal=initConfig="$(echo "$json" | base64)"
}

get_secret_data() {
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o json | jq -r '.data'
}

unseal_vault() {
  local pod="$1"
  local key1="$2"
  local key2="$3"
  echo "Unsealing Vault on $pod..."
  kubectl -n "$NAMESPACE" exec "$pod" -c vault -- vault operator unseal "$key1"
  kubectl -n "$NAMESPACE" exec "$pod" -c vault -- vault operator unseal "$key2"
}

join_raft() {
  local pod="$1"
  local leader_pod="$2"
  echo "Joining $pod to raft cluster via $leader_pod..."
  kubectl -n "$NAMESPACE" exec "$pod" -c vault -- vault operator raft join "http://$leader_pod.vault-system-internal:8200"
}

# Main logic
main() {
  for pod in "${VAULT_PODS[@]}"; do
    wait_for_pod "$pod"
  done

  # Check if Vault is initialized
  status_json=$(get_vault_status "${VAULT_PODS[0]}")
  initialized=$(echo "$status_json" | jq -r '.initialized')

  if [[ "$initialized" == "false" ]]; then
    # Not initialized, check for existing secret
    if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" &>/dev/null; then
      echo "Vault not initialized but secret $SECRET_NAME exists. Exiting for safety."
      exit 1
    fi
    init_json=$(init_vault "${VAULT_PODS[0]}")
    store_vault_keys "$init_json"
    root_token=$(echo "$init_json" | jq -r '.root_token')
  else
    # Already initialized, get root token from secret
    secret_data=$(get_secret_data)
    root_token=$(echo "$secret_data" | jq -r '.rootToken' | base64 -d)
  fi

  # Unseal all pods
  secret_data=$(get_secret_data)
  key1=$(echo "$secret_data" | jq -r '.unsealKey1' | base64 -d)
  key2=$(echo "$secret_data" | jq -r '.unsealKey2' | base64 -d)

  for pod in "${VAULT_PODS[@]}"; do
    status_json=$(get_vault_status "$pod")
    sealed=$(echo "$status_json" | jq -r '.sealed')
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
  kv_status=$(kubectl -n "$NAMESPACE" exec "${VAULT_PODS[0]}" -c vault -- sh -c "VAULT_TOKEN=$root_token vault secrets list -format=json" | jq -r '.["secret/"] // empty')
  if [[ -z "$kv_status" ]]; then
    echo "Enabling KV engine..."
    kubectl -n "$NAMESPACE" exec "${VAULT_PODS[0]}" -c vault -- sh -c "VAULT_TOKEN=$root_token vault secrets enable -path=secret kv-v2"
  else
    echo "KV engine already enabled."
  fi

  echo "Vault post-install bootstrap complete."
}

main
