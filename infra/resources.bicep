param name string
param location string
param resourceToken string
param principalId string
@secure()
param databasePassword string
param existingVnetRgName string
param existingVnetName string
@description('Subnet used for App Service outbound VNet integration')
param appSubnetName string = 'Combine-Customer-B'
@description('Subnet used for Azure SQL private endpoint')
param dbSubnetName string = 'Combine-Customer-A'
@description('Subnet used for Key Vault private endpoint')
param vaultSubnetName string = 'Combine-Customer-D'
@description('Subnet used for Redis private endpoint')
param cacheSubnetName string = 'Combine-Customer-C'

var sqlAdminLogin = 'sqladminuser'

var appName = '${name}-${resourceToken}'
// Reuse an existing VNET and named subnets supplied via parameters
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  scope: resourceGroup(existingVnetRgName)
  name: existingVnetName
}
resource subnetForDb 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: virtualNetwork
  name: dbSubnetName
}
resource subnetForVault 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: virtualNetwork
  name: vaultSubnetName
}
resource subnetForApp 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: virtualNetwork
  name: appSubnetName
}
resource subnetForCache 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: virtualNetwork
  name: cacheSubnetName
}

// Resources needed to secure Key Vault behind a private endpoint
resource privateDnsZoneKeyVault 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  resource vnetLink 'virtualNetworkLinks@2020-06-01' = {
    location: 'global'
    name: '${appName}-vaultlink'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}
resource vaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${appName}-vault-privateEndpoint'
  location: location
  properties: {
    subnet: {
      id: subnetForVault.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appName}-vault-privateEndpoint'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
  resource privateDnsZoneGroup 'privateDnsZoneGroups@2024-01-01' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'vault-config'
          properties: {
            privateDnsZoneId: privateDnsZoneKeyVault.id
          }
        }
      ]
    }
  }
}

// Resources needed to secure Azure SQL DB with private DNS zone integration
resource privateDnsZoneSql 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  // disable-next-line no-hardcoded-env-urls
  name: 'privatelink.database.windows.net'
  location: 'global'
  resource privateDnsZoneLinkSql 'virtualNetworkLinks@2020-06-01' = {
    name: '${appName}-sqllink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

// Resources needed to secure Redis Cache behind a private endpoint
resource cachePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${appName}-cache-privateEndpoint'
  location: location
  properties: {
    subnet: {
      id: subnetForCache.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appName}-cache-privateEndpoint'
        properties: {
          privateLinkServiceId: redisCache.id
          groupIds: ['redisCache']
        }
      }
    ]
  }
  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'cache-config'
          properties: {
            privateDnsZoneId: privateDnsZoneCache.id
          }
        }
      ]
    }
  }
}
resource privateDnsZoneCache 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
  resource privateDnsZoneLinkCache 'virtualNetworkLinks@2020-06-01' = {
    name: '${appName}-cachelink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }  
}

// The Key Vault is used to manage SQL database and redis secrets.
// Current user has the admin permissions to configure key vault secrets, but by default doesn't have the permissions to read them.
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${take(replace(appName, '-', ''), 17)}-vault'
  location: location
  properties: {
    enableRbacAuthorization: true
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    // Only allow requests from the private endpoint in the VNET.
    publicNetworkAccess: 'Disabled' // To see the secret in the portal, change to 'Enabled' 
    networkAcls: {
      defaultAction: 'Deny' // To see the secret in the portal, change to 'Allow' 
      bypass: 'None' 
    }
  }
}

// Grant the current user with key vault secret user role permissions over the key vault. This lets you inspect the secrets, such as in the portal
// If you remove this section, you can't read the key vault secrets, but the app still has access with its managed identity.
resource keyVaultSecretUserRoleRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: '4633458b-17de-408a-b874-0445c86b69e6' // The built-in Key Vault Secret User role
}
resource keyVaultSecretUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  scope: keyVault
  name: guid(resourceGroup().id, principalId, keyVaultSecretUserRoleRoleDefinition.id)
  properties: {
    roleDefinitionId: keyVaultSecretUserRoleRoleDefinition.id
    principalId: principalId
    principalType: 'User'
  }
}

// Azure SQL logical server + database
resource sqlServer 'Microsoft.Sql/servers@2021-11-01-preview' = {
  name: '${appName}-sql'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: databasePassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
  identity: {
    type: 'SystemAssigned'
  }

  resource sqlDb 'databases' = {
    name: '${appName}-sqldb'
    location: location
    sku: {
      name: 'S0'
      tier: 'Standard'
    }
    properties: {
      collation: 'SQL_Latin1_General_CP1_CI_AS'
      zoneRedundant: false
    }
  }
}

// Private endpoint for Azure SQL with private DNS integration
resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${appName}-sql-privateEndpoint'
  location: location
  properties: {
    subnet: {
      id: subnetForDb.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appName}-sql-privateEndpoint'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
  resource privateDnsZoneGroup 'privateDnsZoneGroups@2024-01-01' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'sql-config'
          properties: {
            privateDnsZoneId: privateDnsZoneSql.id
          }
        }
      ]
    }
  }
  dependsOn: [
    privateDnsZoneSql::privateDnsZoneLinkSql
  ]
}



// The Redis cache is configured to the minimum pricing tier
resource redisCache 'Microsoft.Cache/Redis@2023-08-01' = {
  name: '${appName}-cache'
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    redisConfiguration: {}
    enableNonSslPort: false
    redisVersion: '6'
    publicNetworkAccess: 'Disabled'
  }
}

// The App Service plan is configured to the B1 pricing tier
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${appName}-plan'
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    name: 'B1'
  }
}

resource web 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  tags: {'azd-service-name': 'web'} // Needed by AZD
  properties: {
    siteConfig: {
      linuxFxVersion: 'TOMCAT|10.1-java21' // Set to Java 21, Tomcat 10.1
      vnetRouteAllEnabled: true // Route outbound traffic to the VNET
      ftpsState: 'Disabled'
    }
    serverFarmId: appServicePlan.id
    httpsOnly: true
  }

  // Disable basic authentication for FTP and SCM
  resource ftp 'basicPublishingCredentialsPolicies@2023-12-01' = {
    name: 'ftp'
    properties: {
      allow: false
    }
  }
  resource scm 'basicPublishingCredentialsPolicies@2023-12-01' = {
    name: 'scm'
    properties: {
      allow: false
    }
  }

  // Enable App Service native logs
  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Information'
        }
      }
      detailedErrorMessages: {
        enabled: true
      }
      failedRequestsTracing: {
        enabled: true
      }
      httpLogs: {
        fileSystem: {
          enabled: true
          retentionInDays: 1
          retentionInMb: 35
        }
      }
    }
  }

  // Enable VNET integration
  resource webappVnetConfig 'networkConfig' = {
    name: 'virtualNetwork'
    properties: {
      subnetResourceId: subnetForApp.id
    }
  }
}

// Service Connector from the app to the key vault, which generates the connection settings for the App Service app
// The application code doesn't make any direct connections to the key vault, but the setup expedites the managed identity access
// so that the cache connector can be configured with key vault references.
resource vaultConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'vaultConnector'
  properties: {
    clientType: 'java'
    targetService: {
      type: 'AzureResource'
      id: keyVault.id
    }
    authInfo: {
      authType: 'systemAssignedIdentity' // Use a system-assigned managed identity. No password is used.
    }
    vNetSolution: {
      type: 'privateLink'
    }
  }
  dependsOn: [
    vaultPrivateEndpoint
  ]
}

// Connector to the Azure SQL database, which generates the connection setting for the App Service app
resource dbConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'defaultConnector'
  properties: {
    targetService: {
      type: 'AzureResource'
      id: sqlServer::sqlDb.id
    }
    authInfo: {
      authType: 'systemAssignedIdentity' // Use app's managed identity for Azure SQL.
    }
    clientType: 'java'
    vNetSolution: {
      type: 'privateLink'
    }
  }
  dependsOn: [
    sqlPrivateEndpoint
  ]
}

// Service Connector from the app to the cache, which generates an app setting for the ASP.NET Core application
resource cacheConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'RedisConnector'
  properties: {
    clientType: 'dotnet'
    targetService: {
      type: 'AzureResource'
      id:  resourceId('Microsoft.Cache/Redis/Databases', redisCache.name, '0')
    }
    authInfo: {
      authType: 'accessKey'
    }
    secretStore: {
      keyVaultId: keyVault.id // Configure secrets as key vault references. No secret is exposed in App Service.
    }
    vNetSolution: {
      type: 'privateLink'
    }
  }
  dependsOn: [
    cachePrivateEndpoint
  ]
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${appName}-workspace'
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

// Enable log shipping from the App Service app to the Log Analytics workspace.
resource webdiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'AllLogs'
  scope: web
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
      {
        category: 'AppServiceIPSecAuditLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output WEB_URI string = 'https://${web.properties.defaultHostName}'

// disable-next-line outputs-should-not-contain-secrets
// Only emits configuration names (no values) from service connectors.
output CONNECTION_SETTINGS array = map(concat(dbConnector.listConfigurations().configurations, cacheConnector.listConfigurations().configurations, vaultConnector.listConfigurations().configurations), config => config.name)
output WEB_APP_LOG_STREAM string = format('https://portal.azure.com/#@/resource{0}/logStream', web.id)
output WEB_APP_SSH string = format('https://{0}.scm.azurewebsites.net/webssh/host', web.name)
output WEB_APP_CONFIG string = format('https://portal.azure.com/#@/resource{0}/environmentVariablesAppSettings', web.id)
