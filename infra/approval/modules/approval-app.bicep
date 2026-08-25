metadata name = 'Azure Sandbox Approval Function App'
metadata description = 'Deploys the PowerShell Function app, storage, and system-assigned managed identity that performs approval-driven sandbox deletion.'

@description('Azure region for the Function app and storage account.')
param location string = resourceGroup().location

@description('Globally unique name for the Function app.')
param functionAppName string

@description('Storage account name (3-24 lowercase alphanumeric). Defaults to a unique name.')
@minLength(3)
@maxLength(24)
param storageAccountName string = take('stsbxappr${uniqueString(resourceGroup().id)}', 24)

@description('Shared HMAC secret used to validate approval tokens. Must match the audit signer.')
@secure()
param signingSecret string

@description('Optional Microsoft Teams webhook URL for posting deletion outcomes.')
@secure()
param teamsWebhookUrl string = ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  // Exempts the account from the subscription's network policy so the platform can reach it.
  tags: {
    security: 'exception'
    securitycontrol: 'ignore'
  }
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'app-package'
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}app-package'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 512
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'SANDBOX_SIGNING_SECRET'
          value: signingSecret
        }
        {
          name: 'SANDBOX_TEAMS_WEBHOOK_URL'
          value: teamsWebhookUrl
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// Storage Blob Data Owner lets the Function identity use identity-based host storage and the deployment container.
resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppName, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  properties: {
    principalId: functionApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalType: 'ServicePrincipal'
  }
}

@description('Principal ID of the Function app system-assigned managed identity.')
output principalId string = functionApp.identity.principalId

@description('Default host name of the Function app.')
output defaultHostName string = functionApp.properties.defaultHostName
