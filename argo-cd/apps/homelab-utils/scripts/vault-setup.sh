#!/bin/bash

# Function to generate a random password
generate_password() {
  echo "$(openssl rand -base64 16)" # Customize password length and complexity here
}

# Recursive jq filter for processing data
process_data_jq='
  def process(data; current):
    data as $d
    | to_entries
    | map(
        if .value | type == "object" then
          # Recursively process nested objects
          .value = process(.value; current[.key] // {})
        elif .key == "password" then
          # Generate password if value is null or empty in both current and new data
          if ((current[.key] == null or current[.key] == "") and ($d[.key] == null or $d[.key] == "")) then
            .value = "'$(generate_password)'"
          else
            .value = (current[.key] // $d[.key])
          end
        else
          .
        end
      )
    | from_entries;
  process(.data; .current)
'

SECRETS="{{ .Values.vault.setupSecrets | toJson | b64enc }}"

for SECRET in $(echo "$SECRETS" | base64 -d | jq -c ".[]"); do
  VAULT_PATH=$(echo "$SECRET" | jq -r ".path")
  VAULT_DATA=$(echo "$SECRET" | jq -c ".data")

  # Fetch current data from Vault KV
  CURRENT_VAULT_DATA=$(curl -fsSL \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH" | jq -c ".data.data" 2>/dev/null || echo "{}")

  # Process the new data with recursive password handling in jq
  UPDATED_DATA=$(jq -n \
    --argjson data "$VAULT_DATA" \
    --argjson current "$CURRENT_VAULT_DATA" \
    "$process_data_jq")

  # Compare the current Vault data with the updated data
  if [[ "$CURRENT_VAULT_DATA" != "$UPDATED_DATA" ]]; then
    echo "Updating secret at $VAULT_PATH in Vault..."

    # Write the updated data to Vault
    curl -fsSL \
      --header "Content-Type: application/json" \
      --header "X-Vault-Token: $VAULT_TOKEN" \
      --request POST \
      --data "{ \"data\": $UPDATED_DATA }" \
      "$VAULT_ADDR/v1/$VAULT_KV/data/$VAULT_PATH"
  else
    echo "No changes for secret at $VAULT_PATH."
  fi
done
