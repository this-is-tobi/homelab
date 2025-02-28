#!/bin/bash

# Retrieve Vault path
VAULT_PATH="{{ .Values.keycloak.setup.vaultSecretsPath }}"
CLIENTS="{{ .Values.keycloak.setup.keycloakClients | toJson }}"

# Fetch current data from Vault KV
CURRENT_VAULT_DATA=$(curl -fsSL \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH" | jq -c ".data.data" 2>/dev/null || echo "{}")

# Get Keycloak  token
ACCESS_TOKEN=$(curl -fsSL \
  -X POST "$KC_HOST/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$KC_USERNAME" \
  -d "password=$KC_PASSWORD" \
  -d "grant_type=password" | jq -r '.access_token')

for CLIENT in $(echo "$CLIENTS" | base64 -d | jq -c ".[]"); do
  VAULT_PATH=$(echo "$SECRET" | jq -r ".path")
  VAULT_DATA=$(echo "$SECRET" | jq -c ".data")

  # Fetch current data from Vault KV
  CURRENT_VAULT_DATA=$(curl -fsSL \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH" | jq -c ".data.data" 2>/dev/null || echo "{}")

  # Process the new data with recursive password handling in jq
  MERGED_DATA=$(jq -nc \
    --argjson data "$VAULT_DATA" \
    --argjson current "$CURRENT_VAULT_DATA" \
    "$merge_json_jq")

  UPDATED_DATA=$MERGED_DATA
  for PASSWORD_PATH in $(echo "$MERGED_DATA" | jq -r "$get_password_path"); do
    UPDATED_DATA=$(echo "$UPDATED_DATA" | jq -c \
      --arg path "$PASSWORD_PATH" \
      --arg password "$(generate_password)" \
      "$replace_password")
  done

  # Prepare JSON payload
  JSON_PAYLOAD=$(printf '{"data":%s}' "$UPDATED_DATA")

  # Compare the current Vault data with the updated data
  if [[ "$CURRENT_VAULT_DATA" != "$UPDATED_DATA" ]]; then
    echo "Updating secret at $VAULT_PATH in Vault..."

    # Write the updated data to Vault
    curl -fsSL \
      --header "Content-Type: application/json" \
      --header "X-Vault-Token: $VAULT_TOKEN" \
      --request POST \
      --data "$JSON_PAYLOAD" \
      "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH"
  else
    echo "No changes for secret at $VAULT_PATH."
  fi
done
