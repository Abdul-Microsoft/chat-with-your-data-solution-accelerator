#!/usr/bin/env pwsh

# PowerShell script to create a function key and store it in Key Vault
# This script is executed as a post-provision hook by Azure Developer CLI (azd)

param(
    [string]$ResourceGroupName,
    [string]$FunctionAppName,
    [string]$KeyVaultName
)

Write-Host "Starting function key creation process..."
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "Function App: $FunctionAppName"
Write-Host "Key Vault: $KeyVaultName"

# Load environment variables from .azure folder if parameters not provided
if ([string]::IsNullOrEmpty($ResourceGroupName) -or [string]::IsNullOrEmpty($FunctionAppName) -or [string]::IsNullOrEmpty($KeyVaultName)) {
    Write-Host "Loading parameters from environment..."

    $envPath = Join-Path $PSScriptRoot ".." ".azure" $env:AZURE_ENV_NAME ".env"
    if (Test-Path $envPath) {
        Get-Content $envPath | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                $key = $matches[1]
                $value = $matches[2].Trim('"')
                Set-Item -Path "env:$key" -Value $value
            }
        }
    }

    $ResourceGroupName = $env:AZURE_RESOURCE_GROUP
    $FunctionAppName = $env:AZURE_FUNCTION_NAME
    $KeyVaultName = $env:AZURE_KEY_VAULT_NAME
}

if ([string]::IsNullOrEmpty($FunctionAppName)) {
    Write-Error "Function App name not found. Please ensure AZURE_FUNCTION_NAME is set in your environment."
    exit 1
}

if ([string]::IsNullOrEmpty($KeyVaultName)) {
    Write-Error "Key Vault name not found. Please ensure AZURE_KEY_VAULT_NAME is set in your environment."
    exit 1
}

if ([string]::IsNullOrEmpty($ResourceGroupName)) {
    Write-Error "Resource Group name not found. Please ensure AZURE_RESOURCE_GROUP is set in your environment."
    exit 1
}

Write-Host "Checking if Azure CLI is logged in..."
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Error "Not logged in to Azure. Please run 'az login' first."
    exit 1
}

Write-Host "Logged in as: $($accountInfo.user.name)"

# Ensure current user has permission to write secrets to Key Vault
Write-Host "Checking Key Vault permissions..."
try {
    # Get the current user's object ID
    $currentUserId = $accountInfo.user.name
    $userObjectId = az ad signed-in-user show --query id --output tsv 2>$null

    if ([string]::IsNullOrEmpty($userObjectId)) {
        Write-Warning "Could not retrieve user object ID. Attempting to continue..."
    } else {
        Write-Host "Assigning 'Key Vault Secrets Officer' role to current user..."

        # Assign Key Vault Secrets Officer role to the current user
        az role assignment create `
            --role "Key Vault Secrets Officer" `
            --assignee $userObjectId `
            --scope "/subscriptions/$($accountInfo.id)/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName" `
            --output none 2>&1 | Out-Null

        # Wait a bit for the role assignment to propagate
        Write-Host "Waiting for role assignment to propagate..."
        Start-Sleep -Seconds 10

        Write-Host "Key Vault permissions configured successfully!"
    }
} catch {
    Write-Warning "Could not assign Key Vault role. If this fails, you may need to manually assign 'Key Vault Secrets Officer' role."
}

# Wait for function app to be ready
Write-Host "Waiting for Function App to be ready..."
$maxRetries = 10
$retryCount = 0
$functionAppReady = $false

while ($retryCount -lt $maxRetries -and -not $functionAppReady) {
    $retryCount++
    Write-Host "Attempt $retryCount of $maxRetries..."

    $functionApp = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json

    if ($functionApp -and $functionApp.state -eq "Running") {
        $functionAppReady = $true
        Write-Host "Function App is ready!"
    } else {
        Write-Host "Function App not ready yet. Waiting 30 seconds..."
        Start-Sleep -Seconds 30
    }
}

if (-not $functionAppReady) {
    Write-Warning "Function App may not be fully ready, but proceeding with key creation..."
}

# Create the function key using Azure CLI
Write-Host "Creating function key 'clientKey' in Function App..."

try {
    az functionapp keys set `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --key-name clientKey `
        --key-type functionKeys `
        --output none 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create function key"
        exit 1
    }

    Write-Host "Function key created successfully!"
} catch {
    Write-Error "Error creating function key: $_"
    exit 1
}

# Retrieve the key value
Write-Host "Retrieving function key value..."
try {
    $keyValue = az functionapp keys list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query "functionKeys.clientKey" `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($keyValue)) {
        Write-Error "Failed to retrieve function key value"
        exit 1
    }

    Write-Host "Function key value retrieved successfully!"
} catch {
    Write-Error "Error retrieving function key: $_"
    exit 1
}

# Store the key in Key Vault
Write-Host "Storing function key in Key Vault as 'FUNCTION_KEY'..."

try {
    az keyvault secret set `
        --vault-name $KeyVaultName `
        --name "FUNCTION-KEY" `
        --value $keyValue `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to store key in Key Vault"
        exit 1
    }

    Write-Host "Function key stored in Key Vault successfully!"
} catch {
    Write-Error "Error storing key in Key Vault: $_"
    exit 1
}

Write-Host ""
Write-Host "✓ Function key creation and storage completed successfully!" -ForegroundColor Green
Write-Host "  - Function key 'clientKey' created in Function App: $FunctionAppName"
Write-Host "  - Key stored in Key Vault: $KeyVaultName as 'FUNCTION-KEY'"
Write-Host ""
