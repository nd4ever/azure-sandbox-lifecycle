# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Local dev harness for the approval-driven deletion flow.
.DESCRIPTION
    Exercises the same module functions the approval Function app uses: mints a
    signed approval token for expired sandboxes (or a named group), prints the
    approval URL, validates the token, and performs a dry-run deletion. Nothing
    is deleted unless -Execute is supplied. Paste your own values as parameters;
    no Azure resources need to be provisioned.
.PARAMETER SigningSecret
    Shared HMAC secret. Use the same value you set as the Function app's
    SANDBOX_SIGNING_SECRET when you later deploy.
.PARAMETER SubscriptionId
    Subscriptions to inspect for expired sandboxes. Defaults to every accessible subscription.
.PARAMETER ResourceGroupName
    Target a specific resource group instead of scanning for expired sandboxes.
.PARAMETER Action
    Token action to simulate: approve or reject.
.PARAMETER BaseUrl
    Approval endpoint base URL. Defaults to the local Functions host.
.PARAMETER TtlHours
    Hours before the generated token expires.
.PARAMETER GracePeriodHours
    Hours after expiration before a sandbox is treated as a deletion candidate.
.PARAMETER Execute
    Actually perform the deletion instead of a dry run.
.EXAMPLE
    ./scripts/Test-ApprovalFlow.ps1 -SigningSecret 'paste-secret'
.EXAMPLE
    ./scripts/Test-ApprovalFlow.ps1 -SigningSecret 'paste-secret' -ResourceGroupName 'rg-sbx-sim-001' -Execute
.OUTPUTS
    System.String
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SigningSecret,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionId = @(),

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('approve', 'reject')]
    [string]$Action = 'approve',

    [Parameter(Mandatory = $false)]
    [string]$BaseUrl = 'http://localhost:7071',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 168)]
    [int]$TtlHours = 8,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 720)]
    [int]$GracePeriodHours = 24,

    [Parameter(Mandatory = $false)]
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $RepoRoot 'src/AzureSandboxLifecycle.psd1') -Force

if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $TargetSubscription = if ($SubscriptionId.Count -gt 0) { $SubscriptionId[0] } else { (Get-AzContext).Subscription.Id }
    $Candidates = @([pscustomobject]@{ SubscriptionId = $TargetSubscription; ResourceGroupName = $ResourceGroupName })
}
else {
    $DeletionCutoff = [DateTimeOffset]::UtcNow.AddHours(-$GracePeriodHours)
    $Candidates = @(Get-AzSandbox -SubscriptionId $SubscriptionId | Where-Object {
        $null -ne $_.ExpiresOn -and $_.ExpiresOn -le $DeletionCutoff
    })
}

if ($Candidates.Count -eq 0) {
    Write-Information 'No deletion candidates found.' -InformationAction Continue
    return $null
}

Write-Information "Candidates:" -InformationAction Continue
$Candidates | ForEach-Object { Write-Information "  - $($_.ResourceGroupName) (sub $($_.SubscriptionId))" -InformationAction Continue }

$AuditId = [guid]::NewGuid().ToString()
$Token = New-AzSandboxApprovalToken -AuditId $AuditId -Action $Action -Candidate $Candidates -Secret $SigningSecret -TtlHours $TtlHours
$Url = "$($BaseUrl.TrimEnd('/'))/api/approve?token=$([uri]::EscapeDataString($Token))"

Write-Information "`nApproval URL (open this once the Function app is running):" -InformationAction Continue
Write-Information $Url -InformationAction Continue

$Payload = Test-AzSandboxApprovalToken -Token $Token -Secret $SigningSecret
Write-Information "`nToken validated: action=$($Payload.act) audit=$($Payload.aid)" -InformationAction Continue

if ($Action -eq 'reject') {
    Write-Information 'Reject token generated. No deletion is performed.' -InformationAction Continue
    return $Url
}

if ($Execute) {
    Write-Information "`nExecuting deletion..." -InformationAction Continue
    Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -Confirm:$false | Format-Table Name, SubscriptionId, Status -AutoSize | Out-String | Write-Information -InformationAction Continue
}
else {
    Write-Information "`nDry run (add -Execute to delete):" -InformationAction Continue
    Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -WhatIf
}

return $Url
