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
.PARAMETER TeamsWorkflowUrl
    Optional Power Automate HTTP trigger URL that posts an Adaptive Card to recipientUpn.
.PARAMETER NotifyWithinDays
    Start notifying owners this many days before expiry. Already-expired sandboxes are
    always notified until they are extended or deleted.
.PARAMETER ExtensionDays
    Days the extension link grants. Matches the extend endpoint.
.PARAMETER TokenTtlHours
    Lifetime of the signed extension link.
.PARAMETER SubscriptionId
    Optional subscription IDs to scan. Defaults to every subscription the identity can read.
.PARAMETER ResourceGroupName
    Optional resource group name to notify. Defaults to every eligible managed sandbox.
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
    [string]$TeamsWorkflowUrl,

    [Parameter(Mandatory = $false)]
    [int]$NotifyWithinDays = 7,

    [Parameter(Mandatory = $false)]
    [int]$ExtensionDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$TokenTtlHours = 72,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionId = @(),

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

# Base64 PNG buttons use the same green and red colors as the owner email.
# Regenerate with scripts/New-TeamsButtonImages.ps1.
$TeamsExtendButtonPng = 'iVBORw0KGgoAAAANSUhEUgAAARgAAAA4CAYAAAAmVecOAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAUQSURBVHhe7dsvj9tIGMfxwLKZrFTp2N5LKCzcF7DgYGFhYVlOcU4pO1hUHcvBkpXuJTRacrCwsGELCgoX+jR2HM8884z/Tby9Kt9H+lTdeOJ/zfPbsZ0uFgPran310hTmxmzMa1OYdwAuTN37N47Mh0nlQsX+Yf+2hf1uN7YEgEphH21hP5qN+U3mRm893z7/xRb2n2ilABD7ZNbmhcwRtapZS2EflJUAgK6wj8vN8pXMk6DctVX0RgAYKBkyZmt+ZeYCIEthH9XLJe65ADiTz0G4cGkE4JzcI21/9vJRDgCADP9W4XK9vX5WPdOOBwDAZO6+bv1YWlkIADmqJ0rum3hyAQDkMmvzduH+kAsAIJf7/0vuCdI7uQAAchEwAGZDwACYDQEDYDYEDIDZEDAAZkPAAJgNAQNgNgQMSvthVx7Kug73t/FyYCICJtPqy7EzldrfxeM7HRt99PtyjQkYb+ypvqzicerYQ7n7oIwTus5p+W1X3irvwf8TAZOpqxlGBcXdftr7zmFEwNzeR/FSl2z8KFya6g+ZrnPa1JOfI0xCwGRqm2FfrpTlg/00AbMPAqI9fj84bsvdt9PR1OfFD5zUjCdaZ3hOw3DrDyr8eARMplQzxMv95vUb8FAeTn8PKwiaaEbgb89bn5tJiLFRYHlhVjXq3fCAkdqm9xo+EVh952rIuCBkvKBSZ1anWZUSeNH7mtdXpX92quoJRKQRMJm6mqGmfLjFbCV1SXAKhiAQ/Gqa2t+GVu2+qY3o1biAEcHWvJ6YjalhpOg+p14AeNtMncNmjH/c7T55++9CJArxYxEwkxEwmZIfbL85vIY73K/CD7UyJpxxtA2lzYDq18IZUdO8/r7V6+xvzv6AUcJM3H9JBUnqdak7YJTAVkTb0mZV3mvu/ETvqda1KvcEzGQETKZBAaOOE82RCpjk7OVY1Yd/4ExC/tyM05ovSQkY8T69UdOvS4MDRt5YTuxbc6yn9Uazmnhm6ar/XKAPAZOpuxl84tpe/lZMNX9fwFTNkmg6uU75czNuVMCE4llSejtnCRj/Mka9xxJXvF/19pvt6PeJ2hp7TtAiYDJ1NoM6rinRZImmTL4e+HEBo17CJdYnZxDxusQ45Zz691JO6/aOS3utPVb/0nJ33G897MJ/L30M+hEwmbqa4SRogOaDLRot0ZSp+yb1tpttDgyYAb/9uwMmvh+hNry2z8nji6XOadD03nFGlzqpmZV2k1usRx9LwExFwGSKZyZt1Y0UN5v+RCN+PNosi5riVCMDpmd/XXU3f7yPbaXvKYXVEcRHffsYrSO5rbpSszVX+r0jUT0zLqQRMJm6miF4YpQME++3o2iU1KVSU21zDA+YeJ/35WrS7MIreT9J2X5VAxtV3caxUpeJQTi47SSOPVx/6ia0V6ljwyAEDC5MIowxCwIGl6VjZoPzI2BwEaLLLi59ngQBg4sQBAzh8mQIGACzIWAAzIaAATAbAgbAbAgYALOpAmZZLH+XCwAgVx0wm+UruQAAcrnJi7tEupELACCX2ZjXC7M1Vi4AgFxmbV4sXNmN/SQXAkCGr1W4uFqul2+UAQAw1Z+ngDnOYj4rgwBgnMI+XG+vnwUBw81eAOdQ3dzVyqzNWzkYAEZ4L3MlKL54B2Civ2SeqFVdLhX2QVkBAIQK+909KJI50lnuJs1xNvM1WiEA1JOQ9+67dDI/RpX7wowLG/d/CwDgan31UuaEVv8BLv99g3fFVHIAAAAASUVORK5CYII='
$TeamsDeleteButtonPng = 'iVBORw0KGgoAAAANSUhEUgAAARgAAAA4CAYAAAAmVecOAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAATcSURBVHhe7dsvb9xIGMfxhYUHy7YgdqTYqxYW5iUUtlJBYGHhwZUCCgsPrhQ7CjxSXmKpsCAvoFJIYBUU6NPY3nr+PDM7Hq+rq/J9pE+lxB6v7fr57di7Wa0iqzrZvK5Oi/M621xUWbEF8LR0vX9anCt2PiSVCpXrvNzVefGzzssWAAaPdV7eXOXlGzs3Dtbu7Ox5nRX/ChsFANvXOjt7ZeeIWGrWUmflvbARAPB5vMqKt3aeGNU9Y3EHAkAUb8jcnL58wcwFwEyP4u0Sz1wAHEOVl9+NcOHWCMBRZZuLcfaSlzfOCgCQrPjWhctuvX42fKYtrAQAadRz3f5jaWEhAMzRfaKkvolnLwCAuaq8+LhS/9gLAGAu9fdLq+6PmISFADAHAQNgMQQMgMUQMAAWQ8AAWAwBA2AxBAyAxRAwABZDwPyvvG9v79q+7q7bL87yJ+rddfswnJaH+v3we87Vn4CASdQ0w8UtVfIFP7Nphka82wrLUm3lAx0b/TcgYP5YBEyiYMAMNb3RZzSNFgTTX1cWOkYCBjEImERj8zVto/3+S72/6rsrv7195471m9E0xw4Yramdfdk2BAyiEDCJfAGjGCHTXJpj9cbtV9DGB5omMM430zCCJjBepK9vH4PFDNWhjP23jsvaFycQjduyu/Z2GxEw1q2cs037mPalHZt+HsXXmfyGAQImUShg6vyyHa9JrdE8zzPGC9cTMAfGHQyYA+PtY+vYzRgIGd/rj8egN6lU4zkUw0orufHlMkLGew58+zns07Fnhk8MAZMoHDDChaqFjtQk/e+kgIkZF2qEyPECsdntmZVgHCcEpxZqejD1+ywH8+GZhXbM4sxL3q5+fFIYP9SX42sEAhZ+BEyi6IDZX9Chd1BV3QWcOi4QMLHjfeyZTFfSzEeeUfT7IhyXtM/2z8I+iAETuh2TXufXulrweG6VhoXC/zFiEDCJggEjPSA91OjdeuHmEEtYb1LARMxIelaAiLcVbv2WgLFC0vm/8W3Xuw0teJxlmIKASeRcxBp96n34FkYnNGLUuMB6vt8n0cPEbV7/sQrHJa1n/7xfb1LACK/l2270DEaasSEGAZPIFzDGxWnMDuTnAP2Y/TaE5oga52vCCeNtanv2O7cwMxvDdNyW+2xFOi6h8YXt2zMkMWD0AJACz3MODj+DuRbHIR4Bk8h9l7PLbV7xoWlXoYCJGadY03qtaeLGW8RnL2NJDSnVpICJOK9ywEhlHpv/HOizFzeIxBBCNAImUagRghei0JBi09jvmMFx8jq+W6V9OeMNbmD15YaS0bxqv53g8ByXs17PPLdN24izM3ObjREg7j52hNAUt2fsj34euFWaioABsBgCBsBiCBgAiyFgACyGgAGwGAIGwGIIGACLIWAALIaAAbCYPmDy8m97AQDM1QXMVVa8tRcAwFxq8rKqTotzewEAzJZtLla79cu/nAUAMFd29mqlqs7Lr85CAEiVlT+6cOkC5qT84KwAAKmy4tOvgFFV5eV3ZyUAmCor73fr9TMzYHjYC+AY1MNdqaq8+OisDACxsvKznStG8cU7ACmqvPjHzhOxutulrLy3NwAAruKn+qDIzpFgqYc03WwmK3+4GwTw5KlJSFZ+Vt+ls/NjUqkvzKiwUX9bAADVyea1nRNS/QetKDW7VSs+RAAAAABJRU5ErkJggg=='

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
$TeamsWorkflowUrl = Resolve-Config -Value $TeamsWorkflowUrl -VariableName 'SandboxTeamsWorkflowUrl'

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-SandboxToken {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a token string and performs no state change.')]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$Action,
        [string]$Secret,
        [int]$TtlHours,
        [DateTimeOffset]$Now
    )
    $payload = [ordered]@{
        aud = 'sandbox-approval'
        aid = [guid]::NewGuid().ToString()
        act = $Action
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

function Send-TeamsOwnerNotification {
    param(
        [string]$WorkflowUrl,
        [string]$OwnerUpn,
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$Status,
        [DateTimeOffset]$ExpiresOn,
        [int]$ExtensionDays,
        [string]$ExtendUrl,
        [string]$DeleteUrl
    )

    $adaptiveCard = [ordered]@{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.4'
        body      = @(
            [ordered]@{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; wrap = $true; text = "Your Azure sandbox is $Status" }
            [ordered]@{ type = 'TextBlock'; wrap = $true; text = "Sandbox **$ResourceGroup** is scheduled to be cleaned up." }
            [ordered]@{
                type  = 'FactSet'
                facts = @(
                    [ordered]@{ title = 'Resource group'; value = $ResourceGroup }
                    [ordered]@{ title = 'Subscription'; value = $SubscriptionId }
                    [ordered]@{ title = 'Expires'; value = $ExpiresOn.UtcDateTime.ToString('u') }
                )
            }
            [ordered]@{ type = 'TextBlock'; wrap = $true; spacing = 'Medium'; text = "Extend it by **$ExtensionDays days** if you still need it, or delete it now if you are done." }
            [ordered]@{
                type    = 'ColumnSet'
                spacing = 'Medium'
                columns = @(
                    [ordered]@{
                        type  = 'Column'
                        width = 'auto'
                        items = @(
                            [ordered]@{
                                type         = 'Image'
                                altText      = "Extend $ExtensionDays Days"
                                url          = "data:image/png;base64,$TeamsExtendButtonPng"
                                selectAction = [ordered]@{ type = 'Action.OpenUrl'; title = "Extend $ExtensionDays Days"; url = $ExtendUrl }
                            }
                        )
                    }
                    [ordered]@{
                        type  = 'Column'
                        width = 'auto'
                        items = @(
                            [ordered]@{
                                type         = 'Image'
                                altText      = 'Delete Sandbox'
                                url          = "data:image/png;base64,$TeamsDeleteButtonPng"
                                selectAction = [ordered]@{ type = 'Action.OpenUrl'; title = 'Delete Sandbox'; url = $DeleteUrl }
                            }
                        )
                    }
                )
            }
        )
    }

    $payload = [ordered]@{
        recipientUpn = $OwnerUpn
        type         = 'message'
        attachments  = @(
            [ordered]@{
                contentType = 'application/vnd.microsoft.card.adaptive'
                content     = $adaptiveCard
            }
        )
    } | ConvertTo-Json -Depth 20

    Invoke-RestMethod -Uri $WorkflowUrl -Method Post -Body $payload -ContentType 'application/json' -ErrorAction Stop | Out-Null
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
$sandboxes = [System.Collections.Generic.List[object]]::new()
do {
    $page = Search-AzGraph @graphArgs
    foreach ($sandbox in $page) { $sandboxes.Add($sandbox) }
    $graphArgs['SkipToken'] = $page.SkipToken
} while (-not [string]::IsNullOrWhiteSpace($page.SkipToken))

$now = [DateTimeOffset]::UtcNow
$baseUrl = $ApprovalBaseUrl.TrimEnd('/')
$results = [System.Collections.Generic.List[object]]::new()

foreach ($sandbox in $sandboxes) {
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName) -and -not [string]::Equals([string]$sandbox.name, $ResourceGroupName, [StringComparison]::OrdinalIgnoreCase)) { continue }

    $owner = [string]$sandbox.tags.'sandbox-lifecycle_owner'
    $expiresRaw = [string]$sandbox.tags.'sandbox-lifecycle_expiresOn'
    $expires = [DateTimeOffset]::MinValue
    $parsed = [DateTimeOffset]::TryParse(
        $expiresRaw,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$expires)

    if (-not $parsed -or [string]::IsNullOrWhiteSpace($owner)) { continue }
    # Notify within the pre-expiry lead time and keep notifying for as long as it stays expired.
    if ($expires -gt $now.AddDays($NotifyWithinDays)) { continue }

    $daysRemaining = [Math]::Ceiling(($expires - $now).TotalDays)
    $extendToken = New-SandboxToken -SubscriptionId ([string]$sandbox.subscriptionId) -ResourceGroup ([string]$sandbox.name) -Action 'extend' -Secret $SigningSecret -TtlHours $TokenTtlHours -Now $now
    $deleteToken = New-SandboxToken -SubscriptionId ([string]$sandbox.subscriptionId) -ResourceGroup ([string]$sandbox.name) -Action 'approve' -Secret $SigningSecret -TtlHours $TokenTtlHours -Now $now
    $extendUrl = "$baseUrl/api/extend?token=$([uri]::EscapeDataString($extendToken))"
    $deleteUrl = "$baseUrl/api/approve?token=$([uri]::EscapeDataString($deleteToken))"

    $status = if ($daysRemaining -lt 0) { "expired $([math]::Abs($daysRemaining)) day(s) ago" } else { "expiring in $daysRemaining day(s)" }
    $html = @"
<div style="font-family:'Segoe UI',Aptos,sans-serif;color:#242424;max-width:600px;">
  <h2>Your Azure sandbox is $status</h2>
  <p>Sandbox <strong>$([System.Net.WebUtility]::HtmlEncode($sandbox.name))</strong> is scheduled to be cleaned up.</p>
  <p>Extend it by <strong>$ExtensionDays days</strong> if you still need it, or delete it now if you are done:</p>
  <p>
    <a href="$extendUrl" style="background:#107c10;color:#fff;padding:12px 22px;border-radius:4px;font-weight:600;text-decoration:none;">Extend $ExtensionDays Days</a>
    &nbsp;&nbsp;
    <a href="$deleteUrl" style="background:#a4262c;color:#fff;padding:12px 22px;border-radius:4px;font-weight:600;text-decoration:none;">Delete Sandbox</a>
  </p>
  <p style="color:#605e5c;font-size:13px;">Delete asks you to confirm and will remove all resources in the resource group. If you take no action the sandbox stays flagged for manual cleanup. These links expire in $TokenTtlHours hours.</p>
</div>
"@

    $notificationStatus = 'Sent'
    try {
        Send-AcsEmail -ConnectionString $AcsConnectionString -SenderAddress $AcsSenderAddress -ToAddress $owner -Subject "Action needed: sandbox $($sandbox.name) is $status" -HtmlBody $html
    }
    catch {
        $notificationStatus = "Failed: $($_.Exception.Message)"
    }

    $teamsNotificationStatus = 'NotConfigured'
    if (-not [string]::IsNullOrWhiteSpace($TeamsWorkflowUrl)) {
        try {
            Send-TeamsOwnerNotification -WorkflowUrl $TeamsWorkflowUrl -OwnerUpn $owner -SubscriptionId ([string]$sandbox.subscriptionId) -ResourceGroup ([string]$sandbox.name) -Status $status -ExpiresOn $expires -ExtensionDays $ExtensionDays -ExtendUrl $extendUrl -DeleteUrl $deleteUrl
            $teamsNotificationStatus = 'Sent'
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode
            $teamsNotificationStatus = if ($statusCode) { "Failed: HTTP $([int]$statusCode)" } else { 'Failed' }
        }
    }

    $results.Add([pscustomobject]@{
        Name                    = [string]$sandbox.name
        Owner                   = $owner
        DaysRemaining           = $daysRemaining
        NotificationStatus      = $notificationStatus
        TeamsNotificationStatus = $teamsNotificationStatus
    })
}

Write-Output "Notified $($results.Count) sandbox owner(s)."
$results | Format-Table -AutoSize | Out-String | Write-Output
