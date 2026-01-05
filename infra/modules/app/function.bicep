@description('Required. Name of the function app.')
param name string = 'fntestcwyd36'

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Tags of the resource.')
param tags object = {}

@description('Required. The resource ID of the app service plan to use for the function app.')
param serverFarmResourceId string = '/subscriptions/1d5876cd-7603-407a-96d2-ae5ca9a9c5f3/resourceGroups/rg-cwydpocabps13/providers/Microsoft.Web/serverFarms/asp-cwydpocabps13llxlz'

@description('Optional. The name of the storage account to use for the function app.')
param storageAccountName string = 'stcwydpocabps13llxlz'

@description('Optional. The name of the application insights instance to use with the function app.')
param applicationInsightsName string = ''

@description('Optional. Runtime name to use for the function app. Defaults to python.')
@allowed([
  'dotnet'
  'dotnetcore'
  'dotnet-isolated'
  'node'
  'python'
  'java'
  'powershell'
  'custom'
])
param runtimeName string = 'python'

@description('Optional. Runtime version to use for the function app.')
param runtimeVersion string = ''

@description('Optional. Docker image name to use for container function apps.')
param dockerFullImageName string = ''

@description('Optional. The resource ID of the user assigned identity for the function app.')
param userAssignedIdentityResourceId string = ''

@description('Optional. The client ID of the user assigned identity for the function app. This is required to set the AZURE_CLIENT_ID app setting so the function app can authenticate with the user assigned managed identity.')
param userAssignedIdentityClientId string = ''

@description('Optional. Settings for the function app.')
@secure()
param appSettings object = {}

@description('Optional. The client key to use for the function app.')
@secure()
param clientKey string = 'default-test-key-${uniqueString(resourceGroup().id)}'

@description('Optional. Determines if HTTPS is required for the function app. When true, HTTP requests are redirected to HTTPS.')
param httpsOnly bool = true

@description('Optional. Determines if the function app can integrate with a virtual network.')
param virtualNetworkSubnetId string = ''

@description('Optional. To enable accessing content over virtual network.')
param vnetContentShareEnabled bool = false

@description('Optional. To enable pulling image over Virtual Network.')
param vnetImagePullEnabled bool = false

@description('Optional. Virtual Network Route All enabled. This causes all outbound traffic to have Virtual Network Security Groups and User Defined Routes applied.')
param vnetRouteAllEnabled bool = false

@description('Optional. Configuration details for private endpoints. For security reasons, it is recommended to use private endpoints whenever possible.')
param privateEndpoints array = []

@description('Optional. The diagnostic settings of the service.')
param diagnosticSettings array = []

@description('Optional. Whether or not public network access is allowed for this resource. For security reasons it should be disabled when using private endpoints.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string?

var useDocker = !empty(dockerFullImageName)
var kind = useDocker ? 'functionapp,linux,container' : 'functionapp,linux'

module function '../core/host/functions.bicep' = {
  name: '${name}-app-module'
  params: {
    name: name
    location: location
    tags: tags
    kind: kind
    serverFarmResourceId: serverFarmResourceId
    storageAccountName: storageAccountName
    applicationInsightsName: applicationInsightsName
    runtimeName: runtimeName
    runtimeVersion: runtimeVersion
    dockerFullImageName: dockerFullImageName
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    userAssignedIdentityClientId: userAssignedIdentityClientId
    appSettings: union(appSettings, {
      WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
    })
    httpsOnly: httpsOnly
    virtualNetworkSubnetId: virtualNetworkSubnetId
    vnetContentShareEnabled: vnetContentShareEnabled
    vnetImagePullEnabled: vnetImagePullEnabled
    vnetRouteAllEnabled: vnetRouteAllEnabled
    privateEndpoints: privateEndpoints
    diagnosticSettings: diagnosticSettings
    publicNetworkAccess: empty(publicNetworkAccess) ? null : publicNetworkAccess
  }
}

// Always wait for the function app runtime to be ready (checks every ~30 seconds)
// This ensures we wait even if the app shows as Running, until the host runtime is responsive
@waitUntil(
  func =>
    func.properties.state == 'Running' && func.properties.availabilityState == 'Normal' && func.properties.hostNamesDisabled == false,
  '10m'
)
resource functionAppWait 'Microsoft.Web/sites@2023-01-01' existing = {
  name: name
  dependsOn: [
    function
  ]
}

@waitUntil(cluster => contains(['Succeeded', 'Failed', 'Canceled'], cluster.properties.provisioningState), '10m')
@retryOn(['ResourceNotFound', 'ResourceConflict', 'InternalServerError', 'BadRequest', 'ServiceUnavailable'], 5)
resource functionNameDefaultClientKey 'Microsoft.Web/sites/host/functionKeys@2024-04-01' = {
  name: '${name}/default/clientKey'
  properties: {
    name: 'ClientKey'
    value: clientKey
  }
  dependsOn: [
    function
    functionAppWait // Wait for function app to be Running
  ]
}

@description('The name of the function app.')
output functionName string = function.outputs.name

@description('The Azure Web Jobs Storage connection string.')
output AzureWebJobsStorage string = function.outputs.azureWebJobsStorage
