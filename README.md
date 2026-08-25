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

The email is simulated to disk unless you supply SMTP settings. Approved
deletions authenticate with a user-assigned managed identity:

```powershell
Remove-AzExpiredSandbox `
  -GracePeriodHours 24 `
  -ManagedIdentityClientId '<managed-identity-client-id>' `
  -Confirm:$false
```

The audit workflow gates its delete job behind the `sandbox-deletion-approval`
GitHub environment, which emails the required reviewers when it pauses. The
delete job runs on a self-hosted runner labeled `azure` because a user-assigned
managed identity is only available on Azure-hosted compute. In addition to the
variables above, configure `AZURE_DELETE_IDENTITY_CLIENT_ID` and, for real email
delivery, `SANDBOX_SMTP_SERVER` with the `SANDBOX_SMTP_USERNAME` and
`SANDBOX_SMTP_PASSWORD` secrets. See the skill at
`.github/skills/sandbox-cleanup-audit/SKILL.md` for details.

## Lifecycle metadata

The resource group is the source of truth for lifecycle state:

| Tag                                  | Meaning                              |
|--------------------------------------|--------------------------------------|
| `sandbox-lifecycle/managed`          | Marks groups owned by this project   |
| `sandbox-lifecycle/owner`            | Owner and budget notification email  |
| `sandbox-lifecycle/expiresOn`        | UTC expiration timestamp             |
| `sandbox-lifecycle/status`           | Persisted lifecycle state            |
| `sandbox-lifecycle/monthlyBudget`    | Monthly budget amount                |
| `sandbox-lifecycle/allowedLocations` | Comma-separated Azure region list    |

## Test

Install Pester 5 once, then run the repository test entry point:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force
npm run test:ps
```

The suite mocks Azure management-plane calls. Running tests does not create or
delete Azure resources.
