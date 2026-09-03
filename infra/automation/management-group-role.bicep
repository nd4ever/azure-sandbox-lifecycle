targetScope = 'managementGroup'

metadata name = 'Sandbox Automation Management Group Role'
metadata description = 'Grants the Automation account managed identity read access across every subscription in a management group so it can notify sandbox owners wherever their sandboxes live.'

@description('Principal (object) ID of the Automation account managed identity. Use the automationPrincipalId output from infra/automation/main.bicep.')
param automationPrincipalId string

@description('Role definition ID granted at the management group scope. Defaults to Reader because the runbook only discovers sandboxes and sends notifications.')
param roleDefinitionId string = tenantResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')

resource sandboxNotificationReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, automationPrincipalId, roleDefinitionId)
  properties: {
    principalId: automationPrincipalId
    roleDefinitionId: roleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the management group role assignment.')
output roleAssignmentId string = sandboxNotificationReader.id
