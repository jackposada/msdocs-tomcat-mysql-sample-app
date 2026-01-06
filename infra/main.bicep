targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name which is used to generate a short unique hash for each resource')
param name string

@minLength(1)
@description('Primary location for all resources')
param location string

@secure()
@description('Azure SQL administrator password')
param databasePassword string

@description('Existing virtual network resource ID for web app integration. Leave empty to disable VNet integration.')
param existingVnetResourceId string = ''

@description('Subnet name within the existing virtual network for web app integration. Ignored if no VNet ID provided.')
param appSubnetName string = ''

@description('Subnet name within the existing virtual network for SQL service endpoint allowlist. Ignored if no VNet ID provided.')
param sqlSubnetName string = ''

var resourceToken = toLower(uniqueString(subscription().id, name, location))

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${name}_group'
  location: location
  tags: { 'azd-env-name': name }
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: resourceGroup
  params: {
    name: name
    location: location
    resourceToken: resourceToken
    databasePassword: databasePassword
    existingVnetResourceId: existingVnetResourceId
    appSubnetName: appSubnetName
    sqlSubnetName: sqlSubnetName
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = resourceGroup.name
output WEB_URI string = resources.outputs.WEB_URI
output CONNECTION_SETTINGS array = resources.outputs.CONNECTION_SETTINGS
output WEB_APP_CONFIG string = resources.outputs.WEB_APP_CONFIG
