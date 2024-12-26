#!/bin/bash

SECRETS={{ .Values.vault.setupSecrets | toJson }}

for SECRET in $(echo "$SECRETS" | jq -c '.[]'); do
  VAULT_PATH=$(echo "$SECRET" | jq -r '.path')
  VAULT_DATA=$(echo "$SECRET" | jq -c '.data')

  echo "Writing secret to $VAULT_ADDR/v1/$VAULT_PATH using Vault API..."

  curl -fsSLk \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data "{ \"data\": $VAULT_DATA }" \
    "$VAULT_ADDR/v1/$VAULT_PATH"
done
