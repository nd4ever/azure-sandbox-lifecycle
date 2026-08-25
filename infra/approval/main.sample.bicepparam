using './main.bicep'

// Replace every placeholder below with values for your environment, then deploy:
//   az deployment sub create --location <AZURE_LOCATION> \
//     --template-file infra/approval/main.bicep \
//     --parameters infra/approval/main.sample.bicepparam

param location = '<AZURE_LOCATION>'
param resourceGroupName = 'rg-sbx-approval'
param functionAppName = '<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>'
param signingSecret = '<STRONG_SHARED_SECRET>'
param teamsWebhookUrl = '<OPTIONAL_TEAMS_WEBHOOK_URL_OR_EMPTY>'
