# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

using namespace System.Net

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'TriggerMetadata is supplied by the Functions host binding.')]
param($Request, $TriggerMetadata)

# Days added per approved extension. The owner self-service link never grants more.
$ExtensionDays = 30

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
    Write-SandboxHtml -StatusCode 500 -Html (Format-SandboxPage -Title 'Configuration error' -Heading 'Configuration error' -BodyHtml '<p>The extension endpoint is missing its signing secret.</p>')
    return
}

$Token = [string]$Request.Query.token
if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-SandboxHtml -StatusCode 400 -Html (Format-SandboxPage -Title 'Missing token' -Heading 'Missing token' -BodyHtml '<p>No extension token was supplied.</p>')
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

if ([string]$Payload.act -ne 'extend') {
    Write-SandboxHtml -StatusCode 400 -Html (Format-SandboxPage -Title 'Wrong token' -Heading 'Wrong token type' -BodyHtml '<p>This link is not an extension request.</p>')
    return
}

$EncodedToken = & $Encode $Token
$RgListItems = (@($Payload.rgs) | ForEach-Object {
    "<li>$(& $Encode $_.n) <span style='color:#605e5c'>(subscription $(& $Encode $_.s))</span></li>"
}) -join "`n"

if ($Request.Method -eq 'GET') {
    $Body = @"
<p>You are about to <strong>extend</strong> the following sandbox(es) by <strong>$ExtensionDays days</strong>:</p>
<ul>$RgListItems</ul>
<form method="post" action="?token=$EncodedToken">
  <button type="submit" style="background:#107c10;color:#fff;border:0;padding:10px 18px;border-radius:4px;font-weight:600;cursor:pointer;">Confirm extension</button>
</form>
"@
    Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Confirm extension' -Heading "Extend sandbox by $ExtensionDays days" -BodyHtml $Body)
    return
}

try {
    $Rows = foreach ($Rg in @($Payload.rgs)) {
        $Result = Set-AzSandboxExpiration -Name ([string]$Rg.n) -SubscriptionId ([string]$Rg.s) -AdditionalDays $ExtensionDays -Confirm:$false
        $NewExpiry = $Result.ExpiresOn.ToString('yyyy-MM-dd')
        "<li>$(& $Encode $Rg.n): new expiration <strong>$(& $Encode $NewExpiry)</strong></li>"
    }
    $Body = "<p>Extended by <strong>$ExtensionDays days</strong> for audit <strong>$(& $Encode $Payload.aid)</strong>.</p><ul>$($Rows -join "`n")</ul>"
    Write-SandboxHtml -StatusCode 200 -Html (Format-SandboxPage -Title 'Extension complete' -Heading 'Sandbox extension complete' -BodyHtml $Body)
}
catch {
    $Message = & $Encode $_.Exception.Message
    Write-SandboxHtml -StatusCode 500 -Html (Format-SandboxPage -Title 'Extension failed' -Heading 'Extension failed' -BodyHtml "<p>$Message</p>")
}
