---
name: sandbox-cleanup-audit
description: Generate an audited sandbox cleanup workflow that simulates deletion, emails an approver, and deletes with a managed identity - Brought to you by nd4ever/azure-sandbox-lifecycle
---

# Sandbox Cleanup Audit

## Overview

This skill generates and runs an audited cleanup workflow for lifecycle-managed
Azure sandboxes. The workflow simulates the deletion process, records an audit
trail, and emails an approver before any resource is removed. Approved deletions
run under an Azure user-assigned managed identity, so no client secret is stored.

The skill combines three capabilities from the `AzureSandboxLifecycle` module:

* `Invoke-AzSandboxCleanupAudit` finds expired sandboxes, writes an audit record,
  and sends an approval email (simulated unless SMTP settings are supplied).
* A GitHub Actions workflow gates deletion behind a protected environment so a
  human approves before cleanup proceeds.
* `Remove-AzExpiredSandbox -ManagedIdentityClientId` deletes approved sandboxes
  using a user-assigned managed identity.

## Prerequisites

Use PowerShell 7 and install the Azure modules the lifecycle module depends on:

```powershell
Install-Module -Name Az.Accounts, Az.ResourceGraph, Az.Resources -Scope CurrentUser
```

For scheduled runs, configure these GitHub Actions repository settings:

| Setting                                    | Type     | Purpose                                          |
|--------------------------------------------|----------|--------------------------------------------------|
| `AZURE_CLIENT_ID`                          | Variable | Federated identity for read-only inventory       |
| `AZURE_TENANT_ID`                          | Variable | Azure tenant for sign-in                         |
| `AZURE_SUBSCRIPTION_ID`                    | Variable | Target subscription                              |
| `AZURE_DELETE_IDENTITY_CLIENT_ID`          | Variable | Client ID of the deletion managed identity       |
| `SANDBOX_SMTP_SERVER`                      | Variable | SMTP host for real approval email (optional)     |
| `SANDBOX_SMTP_USERNAME`                    | Secret   | SMTP user for authenticated delivery (optional)  |
| `SANDBOX_SMTP_PASSWORD`                    | Secret   | SMTP password for authenticated delivery         |

Create a GitHub environment named `sandbox-deletion-approval` with required
reviewers. GitHub emails the reviewers when the delete job pauses for approval.

The delete job runs on a self-hosted runner labeled `azure` because a
user-assigned managed identity is only available on Azure-hosted compute. Assign
the managed identity to that runner and grant it Contributor on the target scope.

## Quick Start

Run the audit simulation locally to preview deletions and produce the approval
email without deleting anything:

```powershell
Import-Module ./src/AzureSandboxLifecycle.psd1 -Force
Connect-AzAccount
Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath ./out/audit
```

The command writes an audit record and an approval email to the audit path and
returns a summary that lists every sandbox pending deletion.

## Parameters Reference

Parameters for `Invoke-AzSandboxCleanupAudit`:

| Parameter          | Default                             | Description                                        |
|--------------------|-------------------------------------|----------------------------------------------------|
| `SubscriptionId`   | Active Azure context                | Subscriptions to inspect                           |
| `GracePeriodHours` | `24`                                | Hours after expiration before a sandbox qualifies  |
| `ApproverEmail`    | `nd4ever@hotmail.com`               | Address that receives the approval request         |
| `FromAddress`      | `sandbox-lifecycle@no-reply.local`  | Sender address for the approval email              |
| `AuditPath`        | `out/audit`                         | Directory for the audit record and email           |
| `SmtpServer`       | None                                | SMTP host; when omitted the email is simulated     |
| `SmtpPort`         | `587`                               | SMTP port                                          |
| `SmtpCredential`   | None                                | Credential for authenticated SMTP delivery         |

Deletion parameter added to `Remove-AzExpiredSandbox`:

| Parameter                 | Default | Description                                             |
|---------------------------|---------|---------------------------------------------------------|
| `ManagedIdentityClientId` | None    | Client ID of the user-assigned managed identity to use  |

## Script Reference

Send a real approval email through an authenticated SMTP relay:

```powershell
$Credential = Get-Credential
Invoke-AzSandboxCleanupAudit `
  -GracePeriodHours 24 `
  -ApproverEmail 'nd4ever@hotmail.com' `
  -SmtpServer 'smtp.example.com' `
  -SmtpCredential $Credential
```

Delete approved sandboxes using the user-assigned managed identity:

```powershell
Remove-AzExpiredSandbox `
  -GracePeriodHours 24 `
  -ManagedIdentityClientId '00000000-0000-0000-0000-000000000000' `
  -Confirm:$false
```

The generated workflow lives at
[.github/workflows/sandbox-cleanup-audit.yml](../../workflows/sandbox-cleanup-audit.yml).
The `audit` job runs the simulation and uploads the audit artifact. The `delete`
job waits for approval in the `sandbox-deletion-approval` environment, then runs
the deletion under the managed identity.

## Troubleshooting

| Symptom                                    | Cause and resolution                                                        |
|--------------------------------------------|------------------------------------------------------------------------------|
| Notification status stays `Simulated`      | No SMTP server was supplied. Set `SmtpServer` or `SANDBOX_SMTP_SERVER`.       |
| Delete job cannot acquire a token          | The managed identity is not attached to the runner. Assign it to Azure compute. |
| Delete job never starts                    | No reviewer approved the `sandbox-deletion-approval` environment.            |
| `Send-MailMessage` warns about obsolescence | Expected on PowerShell 7. For production, use Azure Communication Services Email or Microsoft Graph. |

> Brought to you by nd4ever/azure-sandbox-lifecycle
