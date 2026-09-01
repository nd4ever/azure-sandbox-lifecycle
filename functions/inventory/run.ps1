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

function Write-SandboxHtml {
    param([int]$StatusCode, [string]$Html)
    # ContentType must be set explicitly; the worker ignores Content-Type in Headers for string bodies.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode               = $StatusCode
        ContentType              = 'text/html; charset=utf-8'
        EnableContentNegotiation = $false
        Headers                  = @{ 'Content-Type' = 'text/html; charset=utf-8' }
        Body                     = $Html
    })
}

# Shared-secret gate so the inventory is not exposed anonymously.
$Secret = $env:SANDBOX_SIGNING_SECRET
if ([string]::IsNullOrWhiteSpace($Secret)) {
    Write-SandboxHtml -StatusCode 500 -Html '<!doctype html><title>Configuration error</title><p>The inventory endpoint is missing its signing secret.</p>'
    return
}
$Token = [string]$Request.Query.token
if ($Token -ne $Secret) {
    Write-SandboxHtml -StatusCode 401 -Html '<!doctype html><title>Unauthorized</title><p>A valid token query parameter is required.</p>'
    return
}

$SubscriptionId = [string]$Request.Query.subscriptionId
$SubscriptionParameter = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { @() } else { @($SubscriptionId) }

try {
    $Html = Get-AzSandboxDashboardHtml -SubscriptionId $SubscriptionParameter -SigningSecret $Secret
}
catch {
    $Message = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
    Write-SandboxHtml -StatusCode 500 -Html "<!doctype html><title>Inventory error</title><p>Could not build the inventory: $Message</p>"
    return
}

Write-SandboxHtml -StatusCode 200 -Html $Html
