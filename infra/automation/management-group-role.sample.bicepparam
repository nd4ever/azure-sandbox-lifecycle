using './management-group-role.bicep'

// Replace the placeholder with the Automation account managed identity principal ID
// (the automationPrincipalId output from infra/automation/main.bicep), then deploy:
//   az deployment mg create --management-group-id <MANAGEMENT_GROUP_ID> \
//     --location <AZURE_LOCATION> \
//     --template-file infra/automation/management-group-role.bicep \
//     --parameters infra/automation/management-group-role.sample.bicepparam

param automationPrincipalId = '<AUTOMATION_ACCOUNT_PRINCIPAL_ID>'
