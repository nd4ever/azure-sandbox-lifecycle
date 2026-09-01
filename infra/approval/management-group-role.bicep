targetScope = 'managementGroup'

metadata name = 'Sandbox Function Management Group Role'
metadata description = 'Grants the approval Function app managed identity a role across every subscription in a management group so it can inventory, extend, and delete sandboxes wherever they live.'

@description('Principal (object) ID of the approval Function app managed identity. Use the functionPrincipalId output from infra/approval/main.bicep.')
param functionPrincipalId string

@description('Role definition ID granted at the management group scope. Defaults to Contributor so button clicks can extend and delete sandboxes in any subscription.')
param roleDefinitionId string = tenantResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource sandboxManagementRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, functionPrincipalId, roleDefinitionId)
  properties: {
    principalId: functionPrincipalId
    roleDefinitionId: roleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the management group role assignment.')
output roleAssignmentId string = sandboxManagementRole.id
