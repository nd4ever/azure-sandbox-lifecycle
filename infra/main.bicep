targetScope = 'subscription'

metadata name = 'Azure Sandbox Lifecycle'
metadata description = 'Creates a lifecycle-managed Azure sandbox resource group with budget and policy guardrails.'

@sealed()
@description('Monthly budget configuration for the sandbox.')
type BudgetConfig = {
  @description('Monthly budget amount in the subscription billing currency.')
  amount: int

  @description('Budget tracking start date in ISO 8601 format.')
  startDate: string

  @description('Budget tracking end date in ISO 8601 format.')
  endDate: string
}

@sealed()
@description('Lifecycle and governance configuration for the sandbox.')
type SandboxConfig = {
  @description('Resource group name for the sandbox.')
  name: string

  @description('Azure region for the resource group.')
  location: string

  @description('Email address of the sandbox owner.')
  owner: string

  @description('Expiration timestamp in ISO 8601 format.')
  expiresOn: string

  @description('Azure regions in which sandbox resources can be deployed.')
  allowedLocations: string[]

  @description('Monthly budget configuration.')
  budget: BudgetConfig
}

@description('Lifecycle and governance configuration for the sandbox.')
param sandbox SandboxConfig

resource sandboxResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: sandbox.name
  location: sandbox.location
  tags: {
    'sandbox-lifecycle_allowedLocations': join(sandbox.allowedLocations, ',')
    'sandbox-lifecycle_managed': 'true'
    'sandbox-lifecycle_monthlyBudget': string(sandbox.budget.amount)
    'sandbox-lifecycle_owner': sandbox.owner
    'sandbox-lifecycle_expiresOn': sandbox.expiresOn
    'sandbox-lifecycle_status': 'Active'
  }
}

module guardrails './modules/sandbox-guardrails.bicep' = {
  scope: sandboxResourceGroup
  params: {
    allowedLocations: sandbox.allowedLocations
    budget: sandbox.budget
    owner: sandbox.owner
  }
}

@description('Name of the sandbox resource group.')
output resourceGroupName string = sandboxResourceGroup.name

@description('Resource ID of the sandbox resource group.')
output resourceGroupId string = sandboxResourceGroup.id
