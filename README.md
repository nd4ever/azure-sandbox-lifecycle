---
title: Azure Sandbox Lifecycle
description: PowerShell and Bicep automation for governed, time-bound Azure sandbox resource groups
ms.date: 2026-08-26
ms.topic: overview
---

## Overview

Azure Sandbox Lifecycle creates temporary Azure resource groups with ownership,
expiration, budget, and allowed-location controls. The PowerShell module also
supports inventory, expiration extensions, expired-sandbox cleanup, and a
self-contained HTML dashboard.

## Capabilities

* Provision lifecycle-tagged resource groups through subscription-scoped Bicep
* Give every sandbox a default 30-day lifecycle
* Notify owners at 80 percent actual and 100 percent forecasted monthly spend
* Restrict deployments to approved Azure regions with Azure Policy
* Extend active or expired sandboxes without recreating resources
* Email owners a self-service extension link before expiry via an Azure Automation runbook
* Send owner-targeted Teams actions through a Power Automate Flow bot
* Delete expired sandboxes after a configurable grace period
* Export a searchable, filterable inventory dashboard with CSV download
* Serve the inventory dashboard live from the approval Function app (optional)
* Run owner notifications daily through Azure Automation with managed identity
* Mark a sandbox for cleanup when its actual spend reaches its budget (optional)
* Simulate deletion, email an approver, and delete with a managed identity

## Prerequisites

Use PowerShell 7 and install the required Azure modules:

```powershell
Install-Module -Name Az.Accounts, Az.Automation, Az.ResourceGraph, Az.Resources -Scope CurrentUser
```

The deployment identity needs these roles at the target subscription scope:

| Role                                    | Purpose                                             |
|-----------------------------------------|-----------------------------------------------------|
| Contributor                             | Create and remove sandbox resource groups           |
| Resource Policy Contributor             | Create resource-group policy assignments            |
| Cost Management Contributor             | Create and update resource-group budgets            |
| Role Based Access Control Administrator | Assign Reader to the Automation managed identity    |

Use narrower custom roles before operating this project in a shared production
subscription.

## Configuration

This project ships with no subscription-specific values hardcoded. Replace the
placeholders below with your own values. Names such as `rg-sbx-notifications`,
`acs-sbx`, and `rg-sbx-approval` in the examples are illustrative — rename them
freely.

Local commands and module parameters:

| Placeholder                                | Where it is used                                         |
|--------------------------------------------|----------------------------------------------------------|
| `<subscription-id>`                        | `Set-AzContext` / `-SubscriptionId`                      |
| `<owner-email>`                            | `New-AzSandbox -Owner`                                    |
| `<approver-email>`                         | `Invoke-AzSandboxCleanupAudit -ApproverEmail`            |
| `<acs-connection-string>`                  | `-AcsConnectionString`                                   |
| `<managed-domain>.azurecomm.net`           | `-AcsSenderAddress`                                       |
| `<teams-webhook-url>`                       | `-TeamsWebhookUrl`                                        |
| `<teams-workflow-url>`                      | `-TeamsWorkflowUrl` for direct owner notifications        |
| `<STRONG_SHARED_SECRET>`                    | `-SigningSecret` and the Function `SANDBOX_SIGNING_SECRET`|
| `<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>`       | Function app name and `-ApprovalBaseUrl`                 |
| `<BUDGET_WEBHOOK_URL>`                      | `New-AzSandbox -BudgetWebhookUrl`                        |
| `<managed-identity-client-id>`             | `Remove-AzExpiredSandbox -ManagedIdentityClientId`       |

Approval infrastructure — replace the placeholders in
[infra/approval/main.sample.bicepparam](infra/approval/main.sample.bicepparam)
before deploying (`location`, `functionAppName`, `signingSecret`,
`teamsWebhookUrl`).

## Start locally

```powershell
Import-Module ./src/AzureSandboxLifecycle.psd1 -Force
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'
```

Provision a seven-day sandbox in Central US:

```powershell
New-AzSandbox `
  -Name 'rg-sbx-api-001' `
  -Location 'centralus' `
  -Owner 'owner@contoso.com' `
  -ExpiresInDays 7 `
  -MonthlyBudget 250
```

Pass `-AllowedLocation` when a sandbox needs more than its primary region:

```powershell
New-AzSandbox `
  -Name 'rg-sbx-data-001' `
  -Location 'centralus' `
  -AllowedLocation 'centralus', 'eastus2' `
  -Owner 'owner@contoso.com'
```

## Manage the lifecycle

List managed sandboxes by urgency:

```powershell
Get-AzSandbox | Sort-Object DaysRemaining
```

Extend a sandbox by seven days:

```powershell
Set-AzSandboxExpiration -Name 'rg-sbx-api-001' -AdditionalDays 7
```

Preview cleanup, then remove sandboxes that expired more than 24 hours ago:

```powershell
Remove-AzExpiredSandbox -GracePeriodHours 24 -WhatIf
Remove-AzExpiredSandbox -GracePeriodHours 24 -Confirm:$false
```

Export and open the local inventory dashboard:

```powershell
Export-AzSandboxDashboard -Path ./out/sandbox-inventory.html
Invoke-Item ./out/sandbox-inventory.html
```

## Preview cleanup locally

Run an ad hoc audit to list expired sandboxes, write an audit record, and
generate an approval message without deleting any resources:

```powershell
Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath ./out/audit
```

The email is simulated to disk unless you supply a delivery channel. The daily
production path uses the Azure Automation runbook described below.

### Notifications with Azure Communication Services

Azure Communication Services Email is the recommended Azure-native delivery
channel. Provision it once with the Azure CLI (a free Azure-managed domain needs
no DNS setup):

```bash
az extension add --name communication
az group create --name rg-sbx-notifications --location centralus
az communication email create --name acs-email-sbx --resource-group rg-sbx-notifications --location Global --data-location UnitedStates
az communication email domain create --domain-name AzureManagedDomain --email-service-name acs-email-sbx --resource-group rg-sbx-notifications --location Global --domain-management AzureManaged
az communication create --name acs-sbx --resource-group rg-sbx-notifications --location Global --data-location UnitedStates --linked-domains "$(az communication email domain list --email-service-name acs-email-sbx --resource-group rg-sbx-notifications --query '[0].id' -o tsv)"
```

Send the approval email through Communication Services, and optionally post an
approval card to a Microsoft Teams channel webhook:

```powershell
$acs = az communication list-key --name acs-sbx --resource-group rg-sbx-notifications --query primaryConnectionString -o tsv
Invoke-AzSandboxCleanupAudit `
  -GracePeriodHours 24 `
  -AcsConnectionString $acs `
  -AcsSenderAddress 'donotreply@<managed-domain>.azurecomm.net' `
  -TeamsWebhookUrl '<teams-webhook-url>'
```

The audit prefers Communication Services when a connection string is present,
falls back to SMTP when an SMTP server is supplied, and otherwise writes the
email to disk. A Teams webhook URL is optional and posts an adaptive card in
addition to the email.

## Button-triggered deletion

An approval Function app lets an owner delete expired sandboxes by clicking a
button in the Outlook email. An ad hoc audit can also post the action to Teams.
The button opens a confirmation page, and only the confirming click runs the
deletion. The Function authenticates with its own system-assigned managed
identity, so no credentials are shared.

How it works:

1. The Azure Automation runbook signs a short-lived HMAC token for each owner
  action. An ad hoc audit creates the same token when `-ApprovalBaseUrl` and
  `-SigningSecret` are supplied.
2. The email link and Teams button open `/api/approve` on the Function app. A
   `GET` shows a confirmation page; the `POST` validates the token and deletes.
3. `Invoke-AzSandboxApprovedDeletion` deletes only the resource groups named in
   the token and re-verifies each still carries the managed tag before removal.

The token is signed and time-limited but replayable until it expires. Automation
owner links default to 72 hours. Ad hoc audit links default to 8 hours.

Provision the Function app, storage, and the managed identity role assignment
with Bicep. Everything environment-specific is a parameter — copy the sample and
replace the placeholders:

```bash
az deployment sub create \
  --location <AZURE_LOCATION> \
  --template-file infra/approval/main.bicep \
  --parameters infra/approval/main.sample.bicepparam
```

Package and publish the Function code (copies the module into the app):

```powershell
./scripts/Build-FunctionPackage.ps1
az functionapp deployment source config-zip `
  --name <GLOBALLY_UNIQUE_FUNCTION_APP_NAME> `
  --resource-group rg-sbx-approval `
  --src ./out/functions/approval-functions.zip
```

The approval app runs on the Azure Functions **Flex Consumption** plan (Linux,
PowerShell 7.4) with identity-based storage, so it works in subscriptions that
forbid storage account keys. In hardened subscriptions that also block public
network access to storage, the Bicep tags the storage account with
`security = exception` and `securitycontrol = ignore` and enables public network
access so the platform can reach the deployment container. Remove those tags if
your environment does not use that exception convention.

Use the `approvalBaseUrl` output for the `SandboxApprovalBaseUrl` Automation
variable. Use the same `signingSecret` value for the Function app setting
`SANDBOX_SIGNING_SECRET`, the encrypted `SandboxSigningSecret` Automation
variable, and any ad hoc audit. A signed local audit looks like:

```powershell
Invoke-AzSandboxCleanupAudit `
  -GracePeriodHours 24 `
  -AcsConnectionString $acs `
  -AcsSenderAddress 'donotreply@<managed-domain>.azurecomm.net' `
  -TeamsWebhookUrl '<teams-webhook-url>' `
  -ApprovalBaseUrl 'https://<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>.azurewebsites.net' `
  -SigningSecret '<STRONG_SHARED_SECRET>'
```

## Budget-triggered cleanup

By default a budget breach only emails the owner. To also mark a sandbox for
deletion when its **actual** spend reaches 100 percent of its budget, pass the
approval Function app's budget hook to `New-AzSandbox`:

```powershell
New-AzSandbox `
  -Name 'rg-sbx-api-001' `
  -Location 'centralus' `
  -Owner 'owner@contoso.com' `
  -MonthlyBudget 250 `
  -BudgetWebhookUrl 'https://<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>.azurewebsites.net/api/budgethook?token=<STRONG_SHARED_SECRET>'
```

This provisions an Azure Monitor action group on the budget. When actual spend
crosses 100 percent, the action group calls the `budgethook` Function, which
sets `sandbox-lifecycle_expiresOn` to now and records
`sandbox-lifecycle_flaggedReason = budget-exceeded`. The sandbox then flows
through the normal owner notification, confirmation, and deletion path, so a
cost overage never deletes anything on its own. The `token` query value must
equal the Function app's
`SANDBOX_SIGNING_SECRET`. Omit `-BudgetWebhookUrl` to keep budget alerts
email-only.

## Hosted inventory page

The approval Function app also serves the inventory dashboard live at
`GET /api/inventory`, so the same view opens in a browser without running the
export locally. It reuses the app's managed identity to query Azure Resource
Graph, so the page is always current. The endpoint requires the signing secret,
so the inventory is not exposed anonymously:

```text
https://<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>.azurewebsites.net/api/inventory?token=<STRONG_SHARED_SECRET>
```

Add an optional `&subscriptionId=<id>` to target a specific subscription; by
default it uses the Function identity's subscription context. The `token` must
equal the Function app's `SANDBOX_SIGNING_SECRET`.

## Owner self-service extension with Azure Automation

Sandboxes are created with a default 30-day lifecycle and are never deleted
automatically. An Azure Automation runbook,
[automation/runbooks/Send-SandboxExpiryNotice.ps1](automation/runbooks/Send-SandboxExpiryNotice.ps1),
runs on a daily schedule, finds sandboxes at or near expiry, and emails each
owner a signed link that extends their sandbox by 30 days. If no one acts, the
sandbox simply stays flagged on the dashboard for a human to review — nothing is
deleted on a timer. Reminders begin within the configured lead time before expiry
(seven days by default) and continue every day the sandbox stays expired, until an
owner extends or deletes it.

The owner notice offers two signed choices: a green **Extend 30 Days** action
(`GET /api/extend`) and a red **Delete Sandbox** action (`GET /api/approve`).
Delete opens a confirmation page warning that all resources in the resource
group will be removed, and only the confirming click deletes anything.

The runbook has no repository module dependency. The Automation template creates
a custom PowerShell 7.2 Runtime Environment with `Az 11.2.0` and
`Az.ResourceGraph 0.13.0`, and the deployment script associates the runbook with
that environment. The runbook authenticates with the account's managed
identity, queries Azure Resource Graph, mints the same HMAC-signed token the
Function app validates, and sends the email through Azure Communication
Services. When `SandboxTeamsWorkflowUrl` is configured, the runbook also sends
an Adaptive Card to a Power Automate HTTP trigger. The payload supplies
`recipientUpn` from `sandbox-lifecycle_owner` and the card as the first item in
`attachments`. Configure the Microsoft Teams action as **Flow bot**, **Chat with
Flow bot**, with `recipientUpn` as the recipient and the first attachment's
`content` as the Adaptive Card. The owner's click lands on the Function app's
`GET /api/extend` endpoint, which validates the token and adds 30 days to
`sandbox-lifecycle_expiresOn`.

Provision the Automation Account in the same resource group as the Function
app, its Reader role, encrypted configuration variables, Runtime Environment,
and daily schedule, then publish the runbook:

```powershell
./automation/Deploy-SandboxAutomation.ps1 `
  -SubscriptionId '<SUBSCRIPTION_ID>' `
  -Location '<AZURE_REGION>' `
  -AutomationAccountName '<AUTOMATION_ACCOUNT_NAME>' `
  -SigningSecret (Read-Host -AsSecureString 'Signing secret') `
  -AcsConnectionString (Read-Host -AsSecureString 'ACS connection string') `
  -AcsSenderAddress 'donotreply@<your-domain>.azurecomm.net' `
  -ApprovalBaseUrl 'https://<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>.azurewebsites.net' `
  -TeamsWorkflowUrl (Read-Host -AsSecureString 'Power Automate workflow URL')
```

The default resource group is `rg-sbx-approval`. Override `-ResourceGroupName`
when the solution uses a different resource group. The default Runtime
Environment name is `sandbox-powershell-7-2`; override
`-RuntimeEnvironmentName` when needed. `-TeamsWorkflowUrl` is optional and is
stored as the encrypted `SandboxTeamsWorkflowUrl` Automation variable.

The Automation identity only needs **Reader** on the subscription; the extension
tag write is performed by the Function app's identity, not the runbook.

## Deployed Azure resources

This solution deploys resources across three resource groups. The names below
are the defaults; rename them freely with the parameters and module inputs noted
earlier. The sandbox resource groups are created on demand, one per sandbox,
while the approval and notification groups are shared platform infrastructure.

### Sandbox resource groups (one per sandbox)

Created by `New-AzSandbox` through [infra/main.bicep](infra/main.bicep). The
resource group name is whatever you pass to `-Name` (for example
`rg-sbx-api-001`).

| Resource                     | Azure resource type                         | Resource group      | Notes                                              |
|------------------------------|---------------------------------------------|---------------------|----------------------------------------------------|
| Sandbox resource group       | `Microsoft.Resources/resourceGroups`        | (the group itself)  | Carries the `sandbox-lifecycle_*` lifecycle tags   |
| Allowed-locations assignment | `Microsoft.Authorization/policyAssignments` | the sandbox group   | Restricts deployments to the approved regions      |
| Monthly budget               | `Microsoft.Consumption/budgets`             | the sandbox group   | Emails the owner at 80% actual and 100% forecast   |
| Budget cleanup action group  | `Microsoft.Insights/actionGroups`           | the sandbox group   | Only when `-BudgetWebhookUrl` is supplied          |

### Approval and automation resource group (`rg-sbx-approval`)

Shared infrastructure created by [infra/approval/main.bicep](infra/approval/main.bicep)
and [infra/automation/main.bicep](infra/automation/main.bicep). Both templates
default to `rg-sbx-approval`.

| Resource                      | Azure resource type                                   | Resource group   | Notes                                                     |
|-------------------------------|-------------------------------------------------------|------------------|-----------------------------------------------------------|
| Approval resource group       | `Microsoft.Resources/resourceGroups`                  | `rg-sbx-approval`| Holds the Function app and Automation account             |
| Storage account               | `Microsoft.Storage/storageAccounts`                   | `rg-sbx-approval`| Identity-based host storage (`stsbxappr*` by default)     |
| Deployment blob container     | `Microsoft.Storage/storageAccounts/blobServices/containers` | `rg-sbx-approval`| `app-package` container for the Function code       |
| Function hosting plan         | `Microsoft.Web/serverfarms`                           | `rg-sbx-approval`| Flex Consumption (FC1), Linux                             |
| Approval Function app         | `Microsoft.Web/sites`                                 | `rg-sbx-approval`| PowerShell 7.4; signs and validates owner actions         |
| Automation account            | `Microsoft.Automation/automationAccounts`             | `rg-sbx-approval`| Runs the daily owner-notification runbook                 |
| Runtime environment           | `Microsoft.Automation/automationAccounts/runtimeEnvironments` | `rg-sbx-approval`| `sandbox-powershell-7-2` with pinned `Az`         |
| Runtime package               | `Microsoft.Automation/automationAccounts/runtimeEnvironments/packages` | `rg-sbx-approval`| `Az.ResourceGraph`                       |
| Automation variables          | `Microsoft.Automation/automationAccounts/variables`   | `rg-sbx-approval`| Encrypted signing secret, ACS, base URL, Teams URL        |
| Daily schedule                | `Microsoft.Automation/automationAccounts/schedules`   | `rg-sbx-approval`| `daily-expiry-notice`                                     |

### Notification resource group (`rg-sbx-notifications`)

Provisioned once with the Azure CLI (see the notifications setup earlier), not
through the Bicep templates.

| Resource                     | Azure resource type                              | Resource group         | Notes                                    |
|------------------------------|--------------------------------------------------|------------------------|------------------------------------------|
| Notification resource group  | `Microsoft.Resources/resourceGroups`             | `rg-sbx-notifications` | Holds the Communication Services setup   |
| Communication Services       | `Microsoft.Communication/communicationServices`  | `rg-sbx-notifications` | Sends owner email                        |
| Email Communication Services | `Microsoft.Communication/emailServices`          | `rg-sbx-notifications` | Parent for the managed email domain      |
| Azure-managed email domain   | `Microsoft.Communication/emailServices/domains`  | `rg-sbx-notifications` | Free managed domain, no DNS setup        |

### Role assignments

| Identity                      | Role                    | Scope                | Resource type                                |
|-------------------------------|-------------------------|----------------------|----------------------------------------------|
| Function app managed identity | Storage Blob Data Owner | Approval storage     | `Microsoft.Authorization/roleAssignments`    |
| Function app managed identity | Contributor             | Target subscription  | `Microsoft.Authorization/roleAssignments`    |
| Automation managed identity   | Reader                  | Target subscription  | `Microsoft.Authorization/roleAssignments`    |

## Lifecycle metadata

The resource group is the source of truth for lifecycle state:

| Tag                                  | Meaning                              |
|--------------------------------------|--------------------------------------|
| `sandbox-lifecycle_managed`          | Marks groups owned by this project   |
| `sandbox-lifecycle_owner`            | Owner and budget notification email  |
| `sandbox-lifecycle_expiresOn`        | UTC expiration timestamp             |
| `sandbox-lifecycle_status`           | Persisted lifecycle state            |
| `sandbox-lifecycle_monthlyBudget`    | Monthly budget amount                |
| `sandbox-lifecycle_allowedLocations` | Comma-separated Azure region list    |
| `sandbox-lifecycle_flaggedReason`    | Why a sandbox was flagged (e.g. budget) |

## Test

Install Pester 5 once, then run the repository test entry point:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force
npm run test:ps
```

The suite mocks Azure management-plane calls. Running tests does not create or
delete Azure resources.
