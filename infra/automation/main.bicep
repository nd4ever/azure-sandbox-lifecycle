targetScope = 'subscription'

metadata name = 'Azure Sandbox Automation'
metadata description = 'Provisions an Automation Account whose managed identity can read the subscription and email sandbox owners a self-service extension link before expiry. Deletes nothing.'

@description('Azure region for the Automation resources.')
param location string

@description('Resource group that holds the Automation Account.')
param resourceGroupName string = 'rg-sbx-automation'

@description('Name of the Automation Account.')
param automationAccountName string

@description('Shared HMAC secret; must match the Function app SANDBOX_SIGNING_SECRET.')
@secure()
param signingSecret string

@description('Communication Services connection string used to email sandbox owners.')
@secure()
param acsConnectionString string

@description('Verified Communication Services sender address.')
param acsSenderAddress string

@description('Base URL of the approval Function app, e.g. https://fn-sbx-approval-xxxx.azurewebsites.net.')
param approvalBaseUrl string

@description('Role granted to the Automation identity on this subscription. Defaults to Reader (read-only; extensions are applied by the Function app).')
param roleDefinitionId string = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')

resource automationResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module automation './modules/automation-account.bicep' = {
  scope: automationResourceGroup
  name: 'automation-account'
  params: {
    location: location
    automationAccountName: automationAccountName
    signingSecret: signingSecret
    acsConnectionString: acsConnectionString
    acsSenderAddress: acsSenderAddress
    approvalBaseUrl: approvalBaseUrl
  }
}

resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, automationAccountName, roleDefinitionId)
  properties: {
    principalId: automation.outputs.principalId
    roleDefinitionId: roleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

@description('Name of the Automation Account.')
output automationAccountName string = automation.outputs.automationAccountName

@description('Name of the daily schedule to link the runbook job to.')
output scheduleName string = automation.outputs.scheduleName

@description('Principal ID granted Reader on this subscription.')
output automationPrincipalId string = automation.outputs.principalId
