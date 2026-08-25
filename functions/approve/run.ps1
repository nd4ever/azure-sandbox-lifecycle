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

function Format-SandboxPage {
    param([string]$Title, [string]$Heading, [string]$BodyHtml)
    return @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$Title</title></head>
<body style="font-family:'Segoe UI',Aptos,sans-serif;color:#242424;max-width:720px;margin:40px auto;padding:0 16px;">
  <h2>$Heading</h2>
  $BodyHtml
</body>
</html>
"@
}

$Encode = { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }

$Secret = $env:SANDBOX_SIGNING_SECRET
if ([string]::IsNullOrWhiteSpace($Secret)) {
    Write-SandboxHtml -StatusCode 500 -Html (Format-SandboxPage -Title 'Configuration error' -Heading 'Configuration error' -BodyHtml '<p>The approval endpoint is missing its signing secret.</p>')
    return
}

$Token = [string]$Request.Query.token
if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-SandboxHtml -StatusCode 400 -Html (Format-SandboxPage -Title 'Missing token' -Heading 'Missing token' -BodyHtml '<p>No approval token was supplied.</p>')
    return
}

try {
    $Payload = Test-AzSandboxApprovalToken -Token $Token -Secret $Secret
}
catch {
    $Message = & $Encode $_.Exception.Message
    Write-SandboxHtml -StatusCode 401 -Html (Format-SandboxPage -Title 'Invalid token' -Heading 'Invalid or expired token' -BodyHtml "<p>$Message</p>")
    return
}

$Action = [string]$Payload.act
$EncodedToken = & $Encode $Token
$RgListItems = (@($Payload.rgs) | ForEach-Object {
    "<li>$(& $Encode $_.n) <span style='color:#605e5c'>(subscription $(& $Encode $_.s))</span></li>"
}) -join "`n"

if ($Request.Method -eq 'GET') {
    if ($Action -eq 'reject') {
        $Body = @"
<p>You are about to <strong>reject</strong> deletion for audit <strong>$(& $Encode $Payload.aid)</strong>. No resources will be deleted.</p>
<ul>$RgListItems</ul>
<form method="post" action="?token=$EncodedToken">
  <button type="submit" style="background:#a4262c;color:#fff;border:0;padding:10px 18px;border-radius:4px;font-weight:600;cursor:pointer;">Confirm rejection</button>
</form>
"@
        Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Confirm rejection' -Heading 'Confirm sandbox deletion rejection' -BodyHtml $Body)
    }
    else {
        # Mint a matching reject token so the confirmation page can offer a red failsafe.
        $RejectCandidates = @($Payload.rgs | ForEach-Object {
            [pscustomobject]@{ SubscriptionId = [string]$_.s; ResourceGroupName = [string]$_.n }
        })
        $RemainingHours = [int][math]::Ceiling(($Payload.exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 3600)
        if ($RemainingHours -lt 1) { $RemainingHours = 1 } elseif ($RemainingHours -gt 168) { $RemainingHours = 168 }
        $RejectToken = New-AzSandboxApprovalToken -AuditId ([string]$Payload.aid) -Action 'reject' -Candidate $RejectCandidates -Secret $Secret -TtlHours $RemainingHours
        $RejectEncoded = & $Encode $RejectToken
        $Body = @"
<p>You are about to <strong>permanently delete</strong> the following resource group(s) for audit <strong>$(& $Encode $Payload.aid)</strong>:</p>
<ul>$RgListItems</ul>
<p style="color:#a4262c;font-weight:600;">This action cannot be undone.</p>
<form method="post" action="?token=$EncodedToken" style="display:inline;">
  <button type="submit" style="background:#107c10;color:#fff;border:0;padding:10px 18px;border-radius:4px;font-weight:600;cursor:pointer;">Confirm deletion</button>
</form>
<a href="?token=$RejectEncoded" style="display:inline-block;background:#a4262c;color:#fff;padding:10px 18px;border-radius:4px;font-weight:600;text-decoration:none;margin-left:8px;">Reject instead</a>
"@
        Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Confirm deletion' -Heading 'Confirm sandbox deletion' -BodyHtml $Body)
    }
    return
}

if ($Action -eq 'reject') {
    $Body = "<p>Deletion for audit <strong>$(& $Encode $Payload.aid)</strong> was rejected. No resources were deleted.</p>"
    Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Rejected' -Heading 'Deletion rejected' -BodyHtml $Body)
    return
}

try {
    $Results = @(Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -Confirm:$false)
    $Rows = ($Results | ForEach-Object { "<li>$(& $Encode $_.Name): <strong>$(& $Encode $_.Status)</strong></li>" }) -join "`n"
    $Body = "<p>Audit <strong>$(& $Encode $Payload.aid)</strong> processed.</p><ul>$Rows</ul>"
    Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Deletion complete' -Heading 'Sandbox deletion complete' -BodyHtml $Body)
}
catch {
    $Message = & $Encode $_.Exception.Message
    Write-SandboxHtml -StatusCode 500 -Html (Format-SandboxPage -Title 'Deletion failed' -Heading 'Deletion failed' -BodyHtml "<p>$Message</p>")
}
