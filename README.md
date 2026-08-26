---
title: Azure Sandbox Lifecycle
description: PowerShell and Bicep automation for governed, time-bound Azure sandbox resource groups
ms.date: 2026-08-25
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
* Delete expired sandboxes after a configurable grace period
* Export a searchable, filterable inventory dashboard with CSV download
* Serve the inventory dashboard live from the approval Function app (optional)
* Run cleanup through GitHub Actions with workload identity federation (manual dispatch; add a cron schedule to automate)
* Mark a sandbox for cleanup when its actual spend reaches its budget (optional)
* Simulate deletion, email an approver, and delete with a managed identity

## Prerequisites

Use PowerShell 7 and install the required Azure modules:

```powershell
Install-Module -Name Az.Accounts, Az.ResourceGraph, Az.Resources -Scope CurrentUser
```

The deployment identity needs these roles at the target subscription scope:

| Role                        | Purpose                                      |
|-----------------------------|----------------------------------------------|
| Contributor                 | Create and remove sandbox resource groups    |
| Resource Policy Contributor | Create resource-group policy assignments     |
| Cost Management Contributor | Create and update resource-group budgets     |

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
| `<STRONG_SHARED_SECRET>`                    | `-SigningSecret` and the Function `SANDBOX_SIGNING_SECRET`|
| `<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>`       | Function app name and `-ApprovalBaseUrl`                 |
| `<BUDGET_WEBHOOK_URL>`                      | `New-AzSandbox -BudgetWebhookUrl`                        |
| `<managed-identity-client-id>`             | `Remove-AzExpiredSandbox -ManagedIdentityClientId`       |

GitHub Actions — set these under **Settings → Secrets and variables → Actions**:

| Name                             | Type     | Purpose                                    |
|----------------------------------|----------|--------------------------------------------|
| `AZURE_CLIENT_ID`                | Variable | OIDC app (client) ID for `azure/login`     |
| `AZURE_TENANT_ID`                | Variable | Entra tenant ID for `azure/login`          |
| `AZURE_SUBSCRIPTION_ID`          | Variable | Target subscription for audit and cleanup  |
| `SANDBOX_ACS_SENDER`             | Variable | Communication Services sender address      |
| `SANDBOX_APPROVAL_BASE_URL`      | Variable | Approval Function app base URL             |
| `AZURE_DELETE_IDENTITY_CLIENT_ID`| Variable | Managed identity client ID for deletion    |
| `SANDBOX_ACS_CONNECTION_STRING`  | Secret   | Communication Services connection string   |
| `SANDBOX_TEAMS_WEBHOOK_URL`      | Secret   | Teams channel webhook URL                  |
| `SANDBOX_SIGNING_SECRET`         | Secret   | Shared HMAC secret for approval tokens     |

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

## Run cleanup in GitHub Actions

The workflow in `.github/workflows/sandbox-cleanup.yml` is triggered manually
(`workflow_dispatch`). It removes sandboxes after a 24-hour grace period and
publishes the current dashboard as a workflow artifact. Manual runs default to
What-If mode; set the **what_if** input to `false` to perform cleanup.

Configure an Entra application with a federated credential for this GitHub
repository, assign the roles listed above, and add these GitHub Actions
repository variables:

* `AZURE_CLIENT_ID`
* `AZURE_TENANT_ID`
* `AZURE_SUBSCRIPTION_ID`

No client secret is required or stored. To run cleanup automatically, add a
schedule trigger to the workflow, for example:

```yaml
on:
  schedule:
    - cron: '17 * * * *'  # 17 minutes past every hour
```

## Audited cleanup with approval

The `sandbox-cleanup-audit` skill adds an approval gate in front of deletion. The
workflow in `.github/workflows/sandbox-cleanup-audit.yml` runs a simulation that
lists expired sandboxes, writes an audit record, and emails an approver before
any resource is removed.

Preview the audit and generate the approval email locally without deleting:

```powershell
Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath ./out/audit
```

The email is simulated to disk unless you supply a delivery channel. Approved
deletions authenticate with a user-assigned managed identity:

```powershell
Remove-AzExpiredSandbox `
  -GracePeriodHours 24 `
  -ManagedIdentityClientId '<managed-identity-client-id>' `
  -Confirm:$false
```

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

The audit workflow gates its delete job behind the `sandbox-deletion-approval`
GitHub environment, which emails the required reviewers when it pauses. The
delete job runs on a self-hosted runner labeled `azure` because a user-assigned
managed identity is only available on Azure-hosted compute. In addition to the
variables above, configure `AZURE_DELETE_IDENTITY_CLIENT_ID`. For real email
delivery, add the `SANDBOX_ACS_CONNECTION_STRING` secret and the
`SANDBOX_ACS_SENDER` variable (or the `SANDBOX_SMTP_SERVER` variable with
`SANDBOX_SMTP_USERNAME` and `SANDBOX_SMTP_PASSWORD` secrets). For Teams, add the
`SANDBOX_TEAMS_WEBHOOK_URL` secret. See the skill at
`.github/skills/sandbox-cleanup-audit/SKILL.md` for details.

## Button-triggered deletion

An approval Function app lets an approver delete expired sandboxes by clicking a
button in the Outlook email or Teams card. The button opens a confirmation page,
and only the confirming click runs the deletion. The Function authenticates with
its own system-assigned managed identity, so no credentials are shared.

How it works:

1. The audit signs a short-lived HMAC token per approval that encodes the exact
   resource groups, an action (`approve` or `reject`), and an expiry. Supply
   `-ApprovalBaseUrl` and `-SigningSecret` to embed signed links in the email and
   Teams card.
2. The email link and Teams button open `/api/approve` on the Function app. A
   `GET` shows a confirmation page; the `POST` validates the token and deletes.
3. `Invoke-AzSandboxApprovedDeletion` deletes only the resource groups named in
   the token and re-verifies each still carries the managed tag before removal.

The token is signed and time-limited but replayable until it expires, so keep the
TTL short (`-ApprovalTtlHours`, default 8).

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

Use the `approvalBaseUrl` output as `SANDBOX_APPROVAL_BASE_URL`, and use the same
`signingSecret` value for both the Function app setting `SANDBOX_SIGNING_SECRET`
and the audit's `-SigningSecret`. Then a signed run looks like:

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
through the normal cleanup audit, approval, and deletion path, so the human
approval gate still applies and a cost overage never deletes anything on its
own. The `token` query value must equal the Function app's
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
deleted on a timer.

The runbook is self-contained (no custom-module dependency): it authenticates
with the Automation account's managed identity, queries Azure Resource Graph,
mints the same HMAC-signed token the Function app validates, and sends the email
through Azure Communication Services. The owner's click lands on the Function
app's `GET /api/extend` endpoint, which validates the token and adds 30 days to
`sandbox-lifecycle_expiresOn`.

Provision the Automation Account, its Reader role, encrypted configuration
variables, and daily schedule, then publish the runbook:

```powershell
./automation/Deploy-SandboxAutomation.ps1 `
  -SubscriptionId '<SUBSCRIPTION_ID>' `
  -Location '<AZURE_REGION>' `
  -AutomationAccountName '<AUTOMATION_ACCOUNT_NAME>' `
  -SigningSecret (Read-Host -AsSecureString 'Signing secret') `
  -AcsConnectionString (Read-Host -AsSecureString 'ACS connection string') `
  -AcsSenderAddress 'donotreply@<your-domain>.azurecomm.net' `
  -ApprovalBaseUrl 'https://<GLOBALLY_UNIQUE_FUNCTION_APP_NAME>.azurewebsites.net'
```

The Automation identity only needs **Reader** on the subscription; the extension
tag write is performed by the Function app's identity, not the runbook.

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
