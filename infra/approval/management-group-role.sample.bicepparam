using './management-group-role.bicep'

// Replace the placeholder with the approval Function app managed identity principal ID
// (the functionPrincipalId output from infra/approval/main.bicep), then deploy:
//   az deployment mg create --management-group-id <MANAGEMENT_GROUP_ID> \
//     --location <AZURE_LOCATION> \
//     --template-file infra/approval/management-group-role.bicep \
//     --parameters infra/approval/management-group-role.sample.bicepparam

param functionPrincipalId = '<FUNCTION_APP_PRINCIPAL_ID>'
