#!/bin/bash

# Function to generate a random password
generate_password() {
  openssl rand -base64 15
}

# Jq commands
merge_json_jq='
  def merge_conditionally(a; b):
    reduce (a | keys_unsorted[]) as $key
    (b; if b[$key] == null or b[$key] == "" then .[$key] = a[$key] else . end);
  def recursive_merge(a; b):
    reduce (a | keys_unsorted[]) as $key
    (b;
      if (a[$key] | type) == "object" and (b[$key] | type) == "object" then
        .[$key] = recursive_merge(a[$key]; b[$key])
      elif b[$key] == null or b[$key] == "" then
        .[$key] = a[$key]
      else
        .
      end
    );
  recursive_merge($data; $current)
'

get_password_path='
  walk(if type == "object" and has("password") and .password == null then .password = "" else . end) |
  paths(.password? | select(. == "")) | map(tostring) | join(".") + ".password"
'

replace_password='
  setpath($path | split("."); $password)
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
