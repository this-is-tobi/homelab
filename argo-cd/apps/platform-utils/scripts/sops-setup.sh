#!/bin/bash

# Retrieve Vault path
VAULT_PATH="{{ .Values.sops.setup.vaultSecretsPath }}"

# Fetch current data from Vault KV
CURRENT_VAULT_DATA=$(curl -fsSL \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH" | jq -c ".data.data" 2>/dev/null || echo "{}")

if [ -z "$(echo "$CURRENT_VAULT_DATA" | jq -r '.keys // empty')" ]; then
  # Generate age keys
  KEYS="$(age-keygen)"
  PUBLIC_KEY="$(echo $KEYS | grep 'public key:' | sed 's/^# public key: //')"
  KEYS_B64="$(echo $KEYS | base64)"

  DATA="{\"keys\":\"$KEYS_B64\",\"publicKey\":\"$PUBLIC_KEY\"}"

  # Prepare JSON payload
  JSON_PAYLOAD=$(printf '{"data":%s}' "$DATA")

  # Write the updated data to Vault
  echo "Updating secret at $VAULT_PATH in Vault..."
  curl -fsSL \
    --header "Content-Type: application/json" \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data "$JSON_PAYLOAD" \
    "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH"
else
  echo "No changes for secret at $VAULT_PATH."
fi
