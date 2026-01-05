#!/bin/bash

# Shell script to create a function key and store it in Key Vault
# This script is executed as a post-provision hook by Azure Developer CLI (azd)

set -e

RESOURCE_GROUP_NAME="${1:-}"
FUNCTION_APP_NAME="${2:-}"
KEY_VAULT_NAME="${3:-}"

echo "Starting function key creation process..."
echo "Resource Group: $RESOURCE_GROUP_NAME"
echo "Function App: $FUNCTION_APP_NAME"
echo "Key Vault: $KEY_VAULT_NAME"

# Load environment variables from .azure folder if parameters not provided
if [ -z "$RESOURCE_GROUP_NAME" ] || [ -z "$FUNCTION_APP_NAME" ] || [ -z "$KEY_VAULT_NAME" ]; then
    echo "Loading parameters from environment..."

    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    ENV_FILE="$SCRIPT_DIR/../.azure/${AZURE_ENV_NAME}/.env"

    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        set -a
        source "$ENV_FILE"
        set +a
    fi

    RESOURCE_GROUP_NAME="${AZURE_RESOURCE_GROUP}"
    FUNCTION_APP_NAME="${AZURE_FUNCTION_NAME}"
    KEY_VAULT_NAME="${AZURE_KEY_VAULT_NAME}"
fi

if [ -z "$FUNCTION_APP_NAME" ]; then
    echo "Error: Function App name not found. Please ensure AZURE_FUNCTION_NAME is set in your environment."
    exit 1
fi

if [ -z "$KEY_VAULT_NAME" ]; then
    echo "Error: Key Vault name not found. Please ensure AZURE_KEY_VAULT_NAME is set in your environment."
    exit 1
fi

if [ -z "$RESOURCE_GROUP_NAME" ]; then
    echo "Error: Resource Group name not found. Please ensure AZURE_RESOURCE_GROUP is set in your environment."
    exit 1
fi

echo "Checking if Azure CLI is logged in..."
if ! ACCOUNT_INFO=$(az account show 2>/dev/null); then
    echo "Error: Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

USER_NAME=$(echo "$ACCOUNT_INFO" | jq -r '.user.name')
SUBSCRIPTION_ID=$(echo "$ACCOUNT_INFO" | jq -r '.id')
echo "Logged in as: $USER_NAME"

# Ensure current user has permission to write secrets to Key Vault
echo "Checking Key Vault permissions..."
if USER_OBJECT_ID=$(az ad signed-in-user show --query id --output tsv 2>/dev/null); then
    if [ -n "$USER_OBJECT_ID" ]; then
        echo "Assigning 'Key Vault Secrets Officer' role to current user..."

        # Assign Key Vault Secrets Officer role to the current user
        if az role assignment create \
            --role "Key Vault Secrets Officer" \
            --assignee "$USER_OBJECT_ID" \
            --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME" \
            --output none 2>&1; then

            # Wait a bit for the role assignment to propagate
            echo "Waiting for role assignment to propagate..."
            sleep 10

            echo "Key Vault permissions configured successfully!"
        else
            echo "Warning: Could not assign Key Vault role. If this fails, you may need to manually assign 'Key Vault Secrets Officer' role."
        fi
    fi
else
    echo "Warning: Could not retrieve user object ID. Attempting to continue..."
fi

# Wait for function app to be ready
echo "Waiting for Function App to be ready..."
MAX_RETRIES=10
RETRY_COUNT=0
FUNCTION_APP_READY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$FUNCTION_APP_READY" = false ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT of $MAX_RETRIES..."

    if FUNCTION_APP=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" 2>/dev/null); then
        STATE=$(echo "$FUNCTION_APP" | jq -r '.state')
        if [ "$STATE" = "Running" ]; then
            FUNCTION_APP_READY=true
            echo "Function App is ready!"
        else
            echo "Function App not ready yet (state: $STATE). Waiting 30 seconds..."
            sleep 30
        fi
    else
        echo "Function App not found or not accessible yet. Waiting 30 seconds..."
        sleep 30
    fi
done

if [ "$FUNCTION_APP_READY" = false ]; then
    echo "Warning: Function App may not be fully ready, but proceeding with key creation..."
fi

# Create the function key using Azure CLI
echo "Creating function key 'clientKey' in Function App..."

if ! az functionapp keys set \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --key-name clientKey \
    --key-type functionKeys \
    --output none 2>&1; then
    echo "Error: Failed to create function key"
    exit 1
fi

echo "Function key created successfully!"

# Retrieve the key value
echo "Retrieving function key value..."
if ! KEY_VALUE=$(az functionapp keys list \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query "functionKeys.clientKey" \
    --output tsv); then
    echo "Error: Failed to retrieve function key value"
    exit 1
fi

if [ -z "$KEY_VALUE" ]; then
    echo "Error: Function key value is empty"
    exit 1
fi

echo "Function key value retrieved successfully!"

# Store the key in Key Vault
echo "Storing function key in Key Vault as 'FUNCTION-KEY'..."

if ! az keyvault secret set \
    --vault-name "$KEY_VAULT_NAME" \
    --name "FUNCTION-KEY" \
    --value "$KEY_VALUE" \
    --output none; then
    echo "Error: Failed to store key in Key Vault"
    exit 1
fi

echo "Function key stored in Key Vault successfully!"

echo ""
echo "✓ Function key creation and storage completed successfully!"
echo "  - Function key 'clientKey' created in Function App: $FUNCTION_APP_NAME"
echo "  - Key stored in Key Vault: $KEY_VAULT_NAME as 'FUNCTION-KEY'"
echo ""
