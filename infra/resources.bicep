param name string
param location string
param resourceToken string
@secure()
param databasePassword string

@description('Existing virtual network resource ID for web app integration. Leave empty to disable VNet integration.')
param existingVnetResourceId string = ''

@description('Subnet name within the existing virtual network for web app integration. Ignored if no VNet ID provided.')
param appSubnetName string = ''

@description('Subnet name within the existing virtual network for SQL service endpoint allowlist. Ignored if no VNet ID provided.')
param sqlSubnetName string = ''

var sqlAdminLogin = 'adminlogin'
var appName = '${name}-${resourceToken}'
var storageAccountName = toLower(take(replace(appName, '-', ''), 24))
var sqlDatabaseName = '${appName}-database'
var sqlConnectionString = 'jdbc:sqlserver://${sqlServer.name}.database.windows.net:1433;database=${sqlDatabaseName};encrypt=true;trustServerCertificate=false;loginTimeout=30;user=${sqlAdminLogin};password=${databasePassword}'
var appSubnetResourceId = empty(existingVnetResourceId) ? '' : '${existingVnetResourceId}/subnets/${appSubnetName}'
var sqlSubnetResourceId = empty(existingVnetResourceId) ? '' : '${existingVnetResourceId}/subnets/${sqlSubnetName}'
// Build list of subnets to allow for SQL: explicit sqlSubnetName plus the app subnet if provided
var sqlVnetSubnetIds = union(
  empty(sqlSubnetResourceId) ? [] : [sqlSubnetResourceId],
  empty(appSubnetResourceId) ? [] : [appSubnetResourceId]
)
var trustedCaThumbprint = '3AA47D96BF925400CD5DC5287AE62EF2AA770162'

// Key Vault (RBAC, public network enabled to match reference)
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${take(replace(appName, '-', ''), 17)}-vault'
  location: location
  properties: {
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
    sku: { family: 'A', name: 'standard' }
    softDeleteRetentionInDays: 90
    tenantId: subscription().tenantId
  }
}

// Store JDBC connection string in Key Vault
resource sqlJdbcSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  parent: keyVault
  name: 'sql-jdbc-connstring'
  properties: {
    value: sqlConnectionString
  }
}

// Azure SQL logical server + database (serverless GP_S_Gen5_1 to mirror reference)
resource sqlServer 'Microsoft.Sql/servers@2021-11-01-preview' = {
  name: '${appName}-server'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: databasePassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
    version: '12.0'
  }

  resource sqlDb 'databases' = {
    name: sqlDatabaseName
    location: location
    kind: 'v12.0,user,vcore,serverless'
    sku: {
      name: 'GP_S_Gen5'
      tier: 'GeneralPurpose'
      family: 'Gen5'
      capacity: 1
    }
    properties: {
      autoPauseDelay: 60
      catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
      collation: 'SQL_Latin1_General_CP1_CI_AS'
      maintenanceConfigurationId: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Maintenance/publicMaintenanceConfigurations/SQL_Default'
      maxSizeBytes: 34359738368
      minCapacity: json('0.5')
      readScale: 'Disabled'
      requestedBackupStorageRedundancy: 'Local'
      zoneRedundant: false
    }
  }

    // Allow specified subnets via service endpoint to access SQL (handles app subnet and optional sql subnet)
    resource sqlVnetRules 'virtualNetworkRules' = [for (subnetId, i) in sqlVnetSubnetIds: {
      name: 'vnetrule-${i}'
      properties: {
        virtualNetworkSubnetId: subnetId
        ignoreMissingVnetServiceEndpoint: false
      }
    }]
}

// Storage account and background-images container
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
      }
    }
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource backgroundImagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'background-images'
  properties: {
    publicAccess: 'None'
  }
}

// App Service plan (S1 to mirror reference)
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${appName}-plan'
  location: location
  kind: 'linux'
  sku: {
    name: 'S1'
    tier: 'Standard'
    size: 'S1'
    family: 'S'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

// Web App with app settings from reference
resource web 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  tags: {
    'azd-env-name': name
    'azd-service-name': 'web'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: appServicePlan.id
    clientAffinityEnabled: false
    clientCertEnabled: false
    clientCertMode: 'Required'
    virtualNetworkSubnetId: empty(appSubnetResourceId) ? null : appSubnetResourceId
    siteConfig: {
      linuxFxVersion: 'TOMCAT|10.1-java17'
      alwaysOn: true
      ftpsState: 'FtpsOnly'
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'BACKGROUND_STORAGE_ENDPOINT'
          // Emulator uses alternate DNS suffix
          value: format('https://{0}.blob.core.scombine.scloud/', storageAccountName)
        }
        {
          name: 'BACKGROUND_STORAGE_ENDPOINT_ENABLED'
          value: 'true'
        }
        {
          name: 'AZURE_SQL_CONNECTIONSTRING'
          value: format('@Microsoft.KeyVault(SecretUri={0}secrets/sql-jdbc-connstring)', keyVault.properties.vaultUri)
        }
        {
          name: 'WEBSITE_AUTOCONFIGURE_DATABASE'
          value: 'true'
        }
        {
          name: 'WEBSITE_LOAD_ROOT_CERTIFICATES'
          value: trustedCaThumbprint
        }
      ]
    }
  }
}

// Upload trusted public CA chain and expose thumbprint to load into trust store
resource trustedCa 'Microsoft.Web/sites/publicCertificates@2022-09-01' = {
  name: 'ca-chain.cer'
  parent: web
  properties: {
    blob: loadFileAsBase64('certs/ca-chain.cer')
    publicCertificateLocation: 'CurrentUserMy'
  }
}

// Grant the web app managed identity access to blobs
resource webBlobContributor 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(storageAccount.id, 'blob-contributor', web.name)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: web.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Allow web app managed identity to read secrets from Key Vault
resource webKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(keyVault.id, 'kv-secrets-user', web.name)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets User
    principalId: web.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output WEB_URI string = 'https://${web.properties.defaultHostName}'
output CONNECTION_SETTINGS array = [
  'AZURE_SQL_CONNECTIONSTRING'
  'BACKGROUND_STORAGE_ENDPOINT'
  'BACKGROUND_STORAGE_ENDPOINT_ENABLED'
  'WEBSITE_AUTOCONFIGURE_DATABASE'
]
output WEB_APP_CONFIG string = format('https://portal.azure.com/#@/resource{0}/environmentVariablesAppSettings', web.id)
