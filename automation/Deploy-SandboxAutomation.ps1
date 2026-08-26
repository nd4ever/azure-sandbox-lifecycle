<#
.SYNOPSIS
    Deploys the sandbox Automation Account and publishes the expiry-notice runbook.
.DESCRIPTION
    Deploys infra/automation/main.bicep, then imports and publishes the self-contained
    Send-SandboxExpiryNotice runbook and links it to the daily schedule created by the
    template. Secrets are stored as encrypted Automation variables by the template; the
    runbook reads them at run time.
.PARAMETER SubscriptionId
    Target subscription for the deployment.
.PARAMETER Location
    Azure region for the Automation resources.
.PARAMETER AutomationAccountName
    Name of the Automation Account to create.
.PARAMETER SigningSecret
    Shared HMAC secret; must match the Function app SANDBOX_SIGNING_SECRET.
.PARAMETER AcsConnectionString
    Communication Services connection string used to email sandbox owners.
.PARAMETER AcsSenderAddress
    Verified Communication Services sender address.
.PARAMETER ApprovalBaseUrl
    Base URL of the approval Function app.
.PARAMETER ResourceGroupName
    Resource group for the Automation Account.
.PARAMETER NotifyWithinDays
    Notify owners of sandboxes expiring within this many days.
#>
#Requires -Modules Az.Accounts, Az.Resources, Az.Automation
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$Location,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][securestring]$SigningSecret,
    [Parameter(Mandatory = $true)][securestring]$AcsConnectionString,
    [Parameter(Mandatory = $true)][string]$AcsSenderAddress,
    [Parameter(Mandatory = $true)][string]$ApprovalBaseUrl,
    [Parameter(Mandatory = $false)][string]$ResourceGroupName = 'rg-sbx-automation',
    [Parameter(Mandatory = $false)][int]$NotifyWithinDays = 7
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot 'infra/automation/main.bicep'
$runbookPath = Join-Path $PSScriptRoot 'runbooks/Send-SandboxExpiryNotice.ps1'
$runbookName = 'Send-SandboxExpiryNotice'

Set-AzContext -Subscription $SubscriptionId | Out-Null

if ($PSCmdlet.ShouldProcess($AutomationAccountName, 'Deploy Automation Account and publish runbook')) {
    New-AzSubscriptionDeployment -Name "sbx-automation-$(Get-Date -Format 'yyyyMMddHHmmss')" -Location $Location -TemplateFile $templateFile -TemplateParameterObject @{
        location             = $Location
        resourceGroupName    = $ResourceGroupName
        automationAccountName = $AutomationAccountName
        signingSecret        = $SigningSecret
        acsConnectionString  = $AcsConnectionString
        acsSenderAddress     = $AcsSenderAddress
        approvalBaseUrl      = $ApprovalBaseUrl
    } -ErrorAction Stop | Out-Null

    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Type PowerShell72 -Path $runbookPath -Force -Published | Out-Null

    $scheduleName = 'daily-expiry-notice'
    Register-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -RunbookName $runbookName -ScheduleName $scheduleName -Parameters @{ NotifyWithinDays = $NotifyWithinDays } | Out-Null

    Write-Output "Published '$runbookName' and linked schedule '$scheduleName'."
}
