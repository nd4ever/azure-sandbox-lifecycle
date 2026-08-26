# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

using namespace System.Net

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'TriggerMetadata is supplied by the Functions host binding.')]
param($Request, $TriggerMetadata)

# Load the shared module from the packaged Modules folder, or from the repo when
# running locally.
$ModuleCandidates = @(
    (Join-Path $PSScriptRoot '..' 'Modules' 'AzureSandboxLifecycle' 'AzureSandboxLifecycle.psd1'),
    (Join-Path $PSScriptRoot '..' '..' 'src' 'AzureSandboxLifecycle.psd1')
)
foreach ($Candidate in $ModuleCandidates) {
    if (Test-Path -LiteralPath $Candidate) {
        Import-Module $Candidate -Force
        break
    }
}

function Write-SandboxJson {
    param([int]$StatusCode, [hashtable]$Body)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode               = $StatusCode
        ContentType              = 'application/json; charset=utf-8'
        EnableContentNegotiation = $false
        Body                     = ($Body | ConvertTo-Json -Depth 6 -Compress)
    })
}

# Shared-secret gate: the action-group webhook URL carries ?token=<signing secret>.
$Secret = $env:SANDBOX_SIGNING_SECRET
if ([string]::IsNullOrWhiteSpace($Secret)) {
    Write-SandboxJson -StatusCode 500 -Body @{ status = 'error'; message = 'signing secret not configured' }
    return
}
$Token = [string]$Request.Query.token
if ($Token -ne $Secret) {
    Write-SandboxJson -StatusCode 401 -Body @{ status = 'error'; message = 'invalid or missing token' }
    return
}

# Budget alert webhooks post JSON; the worker may hand us a string or an object.
$Payload = $Request.Body
if ($Payload -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Payload)) {
        Write-SandboxJson -StatusCode 400 -Body @{ status = 'error'; message = 'empty request body' }
        return
    }
    try { $Payload = $Payload | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-SandboxJson -StatusCode 400 -Body @{ status = 'error'; message = 'request body is not valid JSON' }
        return
    }
}

# Budget notifications scoped to a resource group include ResourceGroup + SubscriptionId.
$Data = $Payload.data
$ResourceGroupName = [string]$Data.ResourceGroup
$SubscriptionId = [string]$Data.SubscriptionId
if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-SandboxJson -StatusCode 400 -Body @{ status = 'error'; message = 'budget payload is missing ResourceGroup or SubscriptionId' }
    return
}

try {
    $Result = Set-AzSandboxExpiredByBudget -SubscriptionId $SubscriptionId -Name $ResourceGroupName -Confirm:$false
}
catch {
    Write-SandboxJson -StatusCode 500 -Body @{ status = 'error'; message = $_.Exception.Message }
    return
}

Write-SandboxJson -StatusCode 200 -Body @{
    status         = $Result.Status
    resourceGroup  = $Result.Name
    subscriptionId = $Result.SubscriptionId
    reason         = $Result.Reason
}
