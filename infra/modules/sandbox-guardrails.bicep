targetScope = 'resourceGroup'

metadata name = 'Sandbox Guardrails'
metadata description = 'Applies budget notifications and location restrictions to a sandbox resource group.'

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

@description('Azure regions in which sandbox resources can be deployed.')
param allowedLocations string[]

@description('Monthly budget configuration.')
param budget BudgetConfig

@description('Email address that receives budget notifications.')
param owner string

resource allowedLocationsPolicyDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' existing = {
  scope: tenant()
  name: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
}

resource allowedLocationsPolicyAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'allowed-locations'
  properties: {
    description: 'Restricts resource deployment to the regions approved for this sandbox.'
    displayName: 'Sandbox allowed locations'
    enforcementMode: 'Default'
    policyDefinitionId: allowedLocationsPolicyDefinition.id
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
    }
  }
}

resource monthlyBudget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'sandbox-monthly-budget'
  properties: {
    amount: budget.amount
    category: 'Cost'
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budget.startDate
      endDate: budget.endDate
    }
    notifications: {
      actual80Percent: {
        contactEmails: [
          owner
        ]
        contactGroups: []
        contactRoles: []
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
      }
      forecast100Percent: {
        contactEmails: [
          owner
        ]
        contactGroups: []
        contactRoles: []
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
      }
    }
  }
}

@description('Resource ID of the allowed-locations policy assignment.')
output policyAssignmentId string = allowedLocationsPolicyAssignment.id

@description('Resource ID of the monthly budget.')
output budgetId string = monthlyBudget.id
