targetScope = 'subscription'

metadata name = 'Azure Sandbox Automation'
metadata description = 'Provisions an Automation Account whose managed identity can read the subscription and email sandbox owners a self-service extension link before expiry. Deletes nothing.'

@description('Azure region for the Automation resources.')
param location string

@description('Resource group that holds the sandbox lifecycle solution.')
param resourceGroupName string = 'rg-sbx-approval'

@description('Name of the Automation Account.')
param automationAccountName string

@description('Name of the PowerShell 7.2 Runtime Environment used by the expiry-notice runbook.')
param runtimeEnvironmentName string = 'sandbox-powershell-7-2'

@description('Version of the default Az package in the Runtime Environment.')
param azModuleVersion string = '11.2.0'

@description('PowerShell Gallery version of Az.ResourceGraph to install in the Runtime Environment.')
param resourceGraphModuleVersion string = '0.13.0'

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

@description('Optional Power Automate HTTP trigger URL used to send owner-specific Teams notifications.')
@secure()
param teamsWorkflowUrl string?

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
    runtimeEnvironmentName: runtimeEnvironmentName
    azModuleVersion: azModuleVersion
    resourceGraphModuleVersion: resourceGraphModuleVersion
    signingSecret: signingSecret
    acsConnectionString: acsConnectionString
    acsSenderAddress: acsSenderAddress
    approvalBaseUrl: approvalBaseUrl
    teamsWorkflowUrl: teamsWorkflowUrl
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

@description('Name of the Runtime Environment for the expiry-notice runbook.')
output runtimeEnvironmentName string = automation.outputs.runtimeEnvironmentName

@description('Principal ID granted Reader on this subscription.')
output automationPrincipalId string = automation.outputs.principalId
