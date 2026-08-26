metadata name = 'Sandbox Automation Account'
metadata description = 'Automation Account, encrypted configuration variables, and a daily schedule for the sandbox expiry-notice runbook.'

@description('Azure region for the Automation resources.')
param location string

@description('Name of the Automation Account.')
param automationAccountName string

@description('Name of the PowerShell 7.2 Runtime Environment used by the expiry-notice runbook.')
param runtimeEnvironmentName string

@description('Version of the default Az package in the Runtime Environment.')
param azModuleVersion string

@description('PowerShell Gallery version of Az.ResourceGraph to install in the Runtime Environment.')
param resourceGraphModuleVersion string

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

@description('First run time for the daily schedule (UTC, ISO 8601). Defaults to one hour after deployment.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT1H')

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automationAccount
  name: runtimeEnvironmentName
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.2'
    }
    defaultPackages: {
      Az: azModuleVersion
    }
    description: 'Pinned runtime for sandbox expiry notices.'
  }
}

resource resourceGraphPackage 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  parent: runtimeEnvironment
  name: 'Az.ResourceGraph'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.ResourceGraph/${resourceGraphModuleVersion}'
      version: resourceGraphModuleVersion
    }
  }
}

resource signingSecretVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SandboxSigningSecret'
  properties: {
    isEncrypted: true
    value: '"${signingSecret}"'
  }
}

resource acsConnectionVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SandboxAcsConnectionString'
  properties: {
    isEncrypted: true
    value: '"${acsConnectionString}"'
  }
}

resource acsSenderVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SandboxAcsSenderAddress'
  properties: {
    isEncrypted: false
    value: '"${acsSenderAddress}"'
  }
}

resource approvalBaseUrlVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SandboxApprovalBaseUrl'
  properties: {
    isEncrypted: false
    value: '"${approvalBaseUrl}"'
  }
}

resource dailySchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'daily-expiry-notice'
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: scheduleStartTime
    timeZone: 'UTC'
  }
}

@description('Principal ID of the Automation Account managed identity.')
output principalId string = automationAccount.identity.principalId

@description('Name of the Automation Account.')
output automationAccountName string = automationAccount.name

@description('Name of the daily schedule for linking the runbook job.')
output scheduleName string = dailySchedule.name

@description('Name of the Runtime Environment for the expiry-notice runbook.')
output runtimeEnvironmentName string = runtimeEnvironment.name
