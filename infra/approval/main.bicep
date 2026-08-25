targetScope = 'subscription'

metadata name = 'Azure Sandbox Approval Endpoint'
metadata description = 'Provisions the approval Function app and grants its managed identity a role on the sandbox subscription so button clicks can delete expired sandboxes.'

@description('Azure region for the approval resources.')
param location string

@description('Resource group that holds the approval Function app.')
param resourceGroupName string = 'rg-sbx-approval'

@description('Globally unique name for the approval Function app.')
param functionAppName string

@description('Shared HMAC secret used to sign and validate approval tokens.')
@secure()
param signingSecret string

@description('Optional Microsoft Teams webhook URL for posting deletion outcomes.')
@secure()
param teamsWebhookUrl string = ''

@description('Role definition ID granted to the Function identity on this subscription. Defaults to Contributor.')
param roleDefinitionId string = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource approvalResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module approvalApp './modules/approval-app.bicep' = {
  scope: approvalResourceGroup
  name: 'approval-app'
  params: {
    location: location
    functionAppName: functionAppName
    signingSecret: signingSecret
    teamsWebhookUrl: teamsWebhookUrl
  }
}

resource deletionRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppName, roleDefinitionId)
  properties: {
    principalId: approvalApp.outputs.principalId
    roleDefinitionId: roleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

@description('Base URL to configure as ApprovalBaseUrl in the audit run.')
output approvalBaseUrl string = 'https://${approvalApp.outputs.defaultHostName}'

@description('Name of the approval Function app.')
output functionAppName string = functionAppName

@description('Principal ID granted the deletion role on this subscription.')
output functionPrincipalId string = approvalApp.outputs.principalId
