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

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {}
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      powerShellVersion: '7.4'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
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
}

@description('Principal ID of the Function app system-assigned managed identity.')
output principalId string = functionApp.identity.principalId

@description('Default host name of the Function app.')
output defaultHostName string = functionApp.properties.defaultHostName
