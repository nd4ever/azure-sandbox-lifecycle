<#
.SYNOPSIS
    Azure Automation runbook: notifies sandbox owners before expiry with a self-service extension link.
.DESCRIPTION
    Self-contained runbook (no custom module dependency). Authenticates with the
    Automation account's managed identity, finds lifecycle-managed sandboxes at or
    near expiry, and emails each owner an HMAC-signed link that extends the sandbox
    by ExtensionDays via the approval Function app's /api/extend endpoint. It never
    deletes anything.
.PARAMETER SigningSecret
    Shared HMAC secret. Must match the Function app's SANDBOX_SIGNING_SECRET.
.PARAMETER AcsConnectionString
    Azure Communication Services connection string (endpoint + accesskey).
.PARAMETER AcsSenderAddress
    Verified Communication Services sender address.
.PARAMETER ApprovalBaseUrl
    Base URL of the approval Function app, e.g. https://fn-sbx-approval-xxxx.azurewebsites.net.
.PARAMETER NotifyWithinDays
    Notify owners of sandboxes expiring within this many days (includes already-expired).
.PARAMETER ExtensionDays
    Days the extension link grants. Matches the extend endpoint.
.PARAMETER TokenTtlHours
    Lifetime of the signed extension link.
.PARAMETER SubscriptionId
    Optional subscription IDs to scan. Defaults to every subscription the identity can read.
#>
#Requires -Modules Az.Accounts, Az.ResourceGraph
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SigningSecret,

    [Parameter(Mandatory = $false)]
    [string]$AcsConnectionString,

    [Parameter(Mandatory = $false)]
    [string]$AcsSenderAddress,

    [Parameter(Mandatory = $false)]
    [string]$ApprovalBaseUrl,

    [Parameter(Mandatory = $false)]
    [int]$NotifyWithinDays = 7,

    [Parameter(Mandatory = $false)]
    [int]$ExtensionDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$TokenTtlHours = 72,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionId = @()
)

$ErrorActionPreference = 'Stop'

# Prefer an explicit param; otherwise read the encrypted Automation variable of the same name.
function Resolve-Config {
    param([string]$Value, [string]$VariableName, [switch]$Required)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) {
        $fromVar = Get-AutomationVariable -Name $VariableName -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($fromVar)) { return $fromVar }
    }
    if ($Required) { throw "Missing required configuration '$VariableName' (pass the parameter or set the Automation variable)." }
    return $Value
}

$SigningSecret = Resolve-Config -Value $SigningSecret -VariableName 'SandboxSigningSecret' -Required
$AcsConnectionString = Resolve-Config -Value $AcsConnectionString -VariableName 'SandboxAcsConnectionString' -Required
$AcsSenderAddress = Resolve-Config -Value $AcsSenderAddress -VariableName 'SandboxAcsSenderAddress' -Required
$ApprovalBaseUrl = Resolve-Config -Value $ApprovalBaseUrl -VariableName 'SandboxApprovalBaseUrl' -Required

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-ExtendToken {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a token string and performs no state change.')]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$Secret,
        [int]$TtlHours,
        [DateTimeOffset]$Now
    )
    $payload = [ordered]@{
        aud = 'sandbox-approval'
        aid = [guid]::NewGuid().ToString()
        act = 'extend'
        exp = [int64]$Now.AddHours($TtlHours).ToUnixTimeSeconds()
        rgs = @([ordered]@{ s = $SubscriptionId; n = $ResourceGroup })
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $signingInput = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $signature = ConvertTo-Base64Url -Bytes ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($signingInput)))
    }
    finally {
        $hmac.Dispose()
    }
    return "$signingInput.$signature"
}

function Send-AcsEmail {
    param(
        [string]$ConnectionString,
        [string]$SenderAddress,
        [string]$ToAddress,
        [string]$Subject,
        [string]$HtmlBody
    )
    $endpoint = $null
    $accessKey = $null
    foreach ($part in $ConnectionString -split ';') {
        $trimmed = $part.Trim()
        if ($trimmed -imatch '^endpoint=(.+)$') { $endpoint = $Matches[1].TrimEnd('/') }
        elseif ($trimmed -imatch '^accesskey=(.+)$') { $accessKey = $Matches[1] }
    }
    if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($accessKey)) {
        throw 'The Communication Services connection string must include endpoint and accesskey values.'
    }

    $pathAndQuery = '/emails:send?api-version=2023-03-31'
    $hostName = ([Uri]$endpoint).Host
    $bodyJson = [ordered]@{
        senderAddress = $SenderAddress
        content       = [ordered]@{ subject = $Subject; html = $HtmlBody }
        recipients    = [ordered]@{ to = @([ordered]@{ address = $ToAddress }) }
    } | ConvertTo-Json -Depth 6
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $contentHash = [Convert]::ToBase64String($sha.ComputeHash($bodyBytes)) }
    finally { $sha.Dispose() }

    $date = [DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    $stringToSign = "POST`n$pathAndQuery`n$date;$hostName;$contentHash"
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($accessKey))
    try { $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))) }
    finally { $hmac.Dispose() }

    $headers = @{
        'x-ms-date'           = $date
        'x-ms-content-sha256' = $contentHash
        'Authorization'       = "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=$signature"
    }
    Invoke-WebRequest -Uri "$endpoint$pathAndQuery" -Method Post -Headers $headers -Body $bodyBytes -ContentType 'application/json' -ErrorAction Stop | Out-Null
}

Connect-AzAccount -Identity | Out-Null

$query = @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| where tostring(tags['sandbox-lifecycle_managed']) =~ 'true'
| project name, subscriptionId, tags
"@

$graphArgs = @{ Query = $query; First = 1000 }
if ($SubscriptionId.Count -gt 0) { $graphArgs['Subscription'] = $SubscriptionId }
$sandboxes = Search-AzGraph @graphArgs

$now = [DateTimeOffset]::UtcNow
$baseUrl = $ApprovalBaseUrl.TrimEnd('/')
$results = [System.Collections.Generic.List[object]]::new()

foreach ($sandbox in $sandboxes) {
    $owner = [string]$sandbox.tags.'sandbox-lifecycle_owner'
    $expiresRaw = [string]$sandbox.tags.'sandbox-lifecycle_expiresOn'
    $expires = [DateTimeOffset]::MinValue
    $parsed = [DateTimeOffset]::TryParse(
        $expiresRaw,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$expires)

    if (-not $parsed -or [string]::IsNullOrWhiteSpace($owner)) { continue }
    if ($expires -gt $now.AddDays($NotifyWithinDays)) { continue }

    $daysRemaining = [Math]::Ceiling(($expires - $now).TotalDays)
    $token = New-ExtendToken -SubscriptionId ([string]$sandbox.subscriptionId) -ResourceGroup ([string]$sandbox.name) -Secret $SigningSecret -TtlHours $TokenTtlHours -Now $now
    $extendUrl = "$baseUrl/api/extend?token=$([uri]::EscapeDataString($token))"

    $status = if ($daysRemaining -lt 0) { "expired $([math]::Abs($daysRemaining)) day(s) ago" } else { "expiring in $daysRemaining day(s)" }
    $html = @"
<div style="font-family:'Segoe UI',Aptos,sans-serif;color:#242424;max-width:600px;">
  <h2>Your Azure sandbox is $status</h2>
  <p>Sandbox <strong>$([System.Net.WebUtility]::HtmlEncode($sandbox.name))</strong> is scheduled to be cleaned up.</p>
  <p>If you still need it, extend it by <strong>$ExtensionDays days</strong>:</p>
  <p><a href="$extendUrl" style="background:#107c10;color:#fff;padding:12px 22px;border-radius:4px;font-weight:600;text-decoration:none;">Extend $ExtensionDays days</a></p>
  <p style="color:#605e5c;font-size:13px;">If you take no action the sandbox stays flagged for manual cleanup. This link expires in $TokenTtlHours hours.</p>
</div>
"@

    $notificationStatus = 'Sent'
    try {
        Send-AcsEmail -ConnectionString $AcsConnectionString -SenderAddress $AcsSenderAddress -ToAddress $owner -Subject "Action needed: sandbox $($sandbox.name) is $status" -HtmlBody $html
    }
    catch {
        $notificationStatus = "Failed: $($_.Exception.Message)"
    }

    $results.Add([pscustomobject]@{
        Name               = [string]$sandbox.name
        Owner              = $owner
        DaysRemaining      = $daysRemaining
        NotificationStatus = $notificationStatus
    })
}

Write-Output "Notified $($results.Count) sandbox owner(s)."
$results | Format-Table -AutoSize | Out-String | Write-Output
