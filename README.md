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
* Notify owners at 80 percent actual and 100 percent forecasted monthly spend
* Restrict deployments to approved Azure regions with Azure Policy
* Extend active or expired sandboxes without recreating resources
* Delete expired sandboxes after a configurable grace period
* Export a searchable, filterable inventory dashboard with CSV download
* Run hourly cleanup through GitHub Actions and workload identity federation
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

## Schedule cleanup

The workflow in `.github/workflows/sandbox-cleanup.yml` runs at 17 minutes past
each hour. It removes sandboxes after a 24-hour grace period and publishes the
current dashboard as a workflow artifact.

Configure an Entra application with a federated credential for this GitHub
repository, assign the roles listed above, and add these GitHub Actions
repository variables:

* `AZURE_CLIENT_ID`
* `AZURE_TENANT_ID`
* `AZURE_SUBSCRIPTION_ID`

Manual workflow runs default to What-If mode. Scheduled runs perform cleanup.
No client secret is required or stored.

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

## Test

Install Pester 5 once, then run the repository test entry point:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force
npm run test:ps
```

The suite mocks Azure management-plane calls. Running tests does not create or
delete Azure resources.
