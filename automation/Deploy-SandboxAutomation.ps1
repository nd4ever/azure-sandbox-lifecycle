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
.PARAMETER TeamsWorkflowUrl
    Optional Power Automate HTTP trigger URL used to send owner-specific Teams notifications.
.PARAMETER ResourceGroupName
    Resource group for the Automation Account.
.PARAMETER RuntimeEnvironmentName
    PowerShell 7.2 Runtime Environment associated with the runbook.
.PARAMETER NotifyWithinDays
    Notify owners of sandboxes expiring within this many days.
#>
#Requires -Version 7.0
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
    [Parameter(Mandatory = $false)][securestring]$TeamsWorkflowUrl,
    [Parameter(Mandatory = $false)][string]$ResourceGroupName = 'rg-sbx-approval',
    [Parameter(Mandatory = $false)][string]$RuntimeEnvironmentName = 'sandbox-powershell-7-2',
    [Parameter(Mandatory = $false)][int]$NotifyWithinDays = 7
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot 'infra/automation/main.bicep'
$runbookPath = Join-Path $PSScriptRoot 'runbooks/Send-SandboxExpiryNotice.ps1'
$runbookName = 'Send-SandboxExpiryNotice'

Set-AzContext -Subscription $SubscriptionId | Out-Null

if ($PSCmdlet.ShouldProcess($AutomationAccountName, 'Deploy Automation Account and publish runbook')) {
    $signingSecretValue = ConvertFrom-SecureString -SecureString $SigningSecret -AsPlainText
    $acsConnectionStringValue = ConvertFrom-SecureString -SecureString $AcsConnectionString -AsPlainText

    $templateParameters = @{
        location             = $Location
        resourceGroupName    = $ResourceGroupName
        automationAccountName = $AutomationAccountName
        runtimeEnvironmentName = $RuntimeEnvironmentName
        signingSecret        = $signingSecretValue
        acsConnectionString  = $acsConnectionStringValue
        acsSenderAddress     = $AcsSenderAddress
        approvalBaseUrl      = $ApprovalBaseUrl
    }
    if ($null -ne $TeamsWorkflowUrl) {
        $teamsWorkflowUrlValue = ConvertFrom-SecureString -SecureString $TeamsWorkflowUrl -AsPlainText
        if (-not [string]::IsNullOrWhiteSpace($teamsWorkflowUrlValue)) {
            $templateParameters['teamsWorkflowUrl'] = $teamsWorkflowUrlValue
        }
    }

    New-AzDeployment -Name "sbx-automation-$(Get-Date -Format 'yyyyMMddHHmmss')" -Location $Location -TemplateFile $templateFile -TemplateParameterObject $templateParameters -ErrorAction Stop | Out-Null

    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Type PowerShell72 -Path $runbookPath -Force -Published | Out-Null

    $runbookResourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$runbookName?api-version=2024-10-23"
    $runtimePayload = @{ properties = @{ runbookType = 'PowerShell'; runtimeEnvironment = $RuntimeEnvironmentName } } | ConvertTo-Json -Depth 3 -Compress
    $runtimeAssociationResponse = $null
    foreach ($attempt in 1..5) {
        $runtimeAssociationResponse = Invoke-AzRestMethod -Path $runbookResourcePath -Method PATCH -Payload $runtimePayload
        if ($runtimeAssociationResponse.StatusCode -in 200, 201) { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
    }
    if ($runtimeAssociationResponse.StatusCode -notin 200, 201) {
        throw "Runtime Environment association failed with HTTP $($runtimeAssociationResponse.StatusCode): $($runtimeAssociationResponse.Content)"
    }

    $scheduleName = 'daily-expiry-notice'
    $scheduleLink = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -RunbookName $runbookName -ScheduleName $scheduleName -ErrorAction SilentlyContinue
    $registerSchedule = -not $scheduleLink
    if ($scheduleLink) {
        $scheduleLink = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -JobScheduleId $scheduleLink.JobScheduleId
        $scheduledNotifyWithinDays = $scheduleLink.Parameters['NotifyWithinDays']
        if ($null -eq $scheduledNotifyWithinDays -or [int]$scheduledNotifyWithinDays -ne $NotifyWithinDays) {
            Unregister-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -JobScheduleId $scheduleLink.JobScheduleId -Force
            $registerSchedule = $true
        }
    }

    if ($registerSchedule) {
        Register-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -RunbookName $runbookName -ScheduleName $scheduleName -Parameters @{ NotifyWithinDays = $NotifyWithinDays } | Out-Null
    }

    Write-Output "Published '$runbookName' and linked schedule '$scheduleName'."
}
