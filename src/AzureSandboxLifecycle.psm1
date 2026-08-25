# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

# AzureSandboxLifecycle.psm1
# Purpose: Provision, inventory, extend, clean up, and report on lifecycle-managed Azure sandboxes.

#Requires -Version 7.0

$script:AllowedLocationsTag = 'sandbox-lifecycle/allowedLocations'
$script:ExpirationTag = 'sandbox-lifecycle/expiresOn'
$script:ManagedTag = 'sandbox-lifecycle/managed'
$script:MonthlyBudgetTag = 'sandbox-lifecycle/monthlyBudget'
$script:OwnerTag = 'sandbox-lifecycle/owner'
$script:StatusTag = 'sandbox-lifecycle/status'

function Get-AzSandboxTagValue {
    <#
    .SYNOPSIS
        Retrieves a lifecycle tag value from an Azure tag collection.
    .PARAMETER Tags
        Azure resource tags.
    .PARAMETER Name
        Tag name to retrieve.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Tags,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ($null -eq $Tags) {
        return $null
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        return [string]$Tags[$Name]
    }

    $TagProperty = $Tags.PSObject.Properties[$Name]
    if ($null -eq $TagProperty) {
        return $null
    }

    return [string]$TagProperty.Value
}

function Select-AzSandboxSubscriptionContext {
    <#
    .SYNOPSIS
        Verifies Azure authentication and selects an optional subscription.
    .PARAMETER SubscriptionId
        Azure subscription ID to select.
    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )

    $Context = Get-AzContext -ErrorAction Stop
    if ($null -eq $Context -or $null -eq $Context.Subscription) {
        throw 'No Azure context is available. Run Connect-AzAccount before using this module.'
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and $Context.Subscription.Id -ne $SubscriptionId) {
        $Context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    return $Context
}

function Connect-AzSandbox {
    <#
    .SYNOPSIS
        Establishes an Azure session for sandbox lifecycle operations.
    .DESCRIPTION
        Authenticates with a user-assigned managed identity when a client ID is
        provided, which is the supported identity for automated resource deletion.
        Without a client ID, the current Azure context is reused.
    .PARAMETER ManagedIdentityClientId
        Client ID of the user-assigned managed identity used for authentication.
    .PARAMETER SubscriptionId
        Azure subscription ID to select after authentication.
    .EXAMPLE
        Connect-AzSandbox -ManagedIdentityClientId '00000000-0000-0000-0000-000000000000'
    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$ManagedIdentityClientId,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )

    if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
        $ConnectParameters = @{
            Identity    = $true
            AccountId   = $ManagedIdentityClientId
            ErrorAction = 'Stop'
        }

        if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
            $ConnectParameters['Subscription'] = $SubscriptionId
        }

        Connect-AzAccount @ConnectParameters | Out-Null
    }

    return Select-AzSandboxSubscriptionContext -SubscriptionId $SubscriptionId
}

function Get-AzSandboxStatus {
    <#
    .SYNOPSIS
        Calculates lifecycle status from an expiration timestamp.
    .PARAMETER ExpiresOn
        Parsed expiration timestamp, or null when the tag is invalid.
    .PARAMETER Now
        Timestamp used for status calculation.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$ExpiresOn,

        [Parameter(Mandatory = $false)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ($null -eq $ExpiresOn) {
        return 'Invalid'
    }

    if ($ExpiresOn -le $Now) {
        return 'Expired'
    }

    if ($ExpiresOn -le $Now.AddDays(2)) {
        return 'Expiring'
    }

    return 'Active'
}

function ConvertTo-AzSandboxRecord {
    <#
    .SYNOPSIS
        Converts an Azure Resource Graph row to a sandbox inventory record.
    .PARAMETER Resource
        Azure Resource Graph row.
    .PARAMETER Now
        Timestamp used for lifecycle calculations.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Resource,

        [Parameter(Mandatory = $false)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $ExpirationValue = Get-AzSandboxTagValue -Tags $Resource.tags -Name $script:ExpirationTag
    $Expiration = [DateTimeOffset]::MinValue
    $HasValidExpiration = [DateTimeOffset]::TryParse(
        $ExpirationValue,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$Expiration
    )

    $ParsedExpiration = if ($HasValidExpiration) { $Expiration.ToUniversalTime() } else { $null }
    $DaysRemaining = if ($HasValidExpiration) {
        [Math]::Ceiling(($ParsedExpiration - $Now).TotalDays)
    }
    else {
        $null
    }

    $BudgetValue = Get-AzSandboxTagValue -Tags $Resource.tags -Name $script:MonthlyBudgetTag
    $MonthlyBudget = [decimal]0
    $HasValidBudget = [decimal]::TryParse(
        $BudgetValue,
        [System.Globalization.NumberStyles]::Number,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$MonthlyBudget
    )

    $AllowedLocationsValue = Get-AzSandboxTagValue -Tags $Resource.tags -Name $script:AllowedLocationsTag
    $AllowedLocations = if ([string]::IsNullOrWhiteSpace($AllowedLocationsValue)) {
        @()
    }
    else {
        @($AllowedLocationsValue -split ',' | ForEach-Object { $_.Trim() })
    }

    return [pscustomobject]@{
        Name             = [string]$Resource.name
        ResourceGroupName = [string]$Resource.name
        SubscriptionId   = [string]$Resource.subscriptionId
        Location         = [string]$Resource.location
        Owner            = Get-AzSandboxTagValue -Tags $Resource.tags -Name $script:OwnerTag
        ExpiresOn        = $ParsedExpiration
        DaysRemaining    = $DaysRemaining
        Status           = Get-AzSandboxStatus -ExpiresOn $ParsedExpiration -Now $Now
        MonthlyBudget    = if ($HasValidBudget) { $MonthlyBudget } else { $null }
        AllowedLocations = $AllowedLocations
        ResourceId       = [string]$Resource.id
    }
}

function New-AzSandbox {
    <#
    .SYNOPSIS
        Provisions a lifecycle-managed Azure sandbox resource group.
    .DESCRIPTION
        Deploys the subscription-scoped Bicep template that creates the resource group,
        lifecycle tags, monthly budget notifications, and allowed-location policy.
    .PARAMETER Name
        Resource group name for the sandbox.
    .PARAMETER Location
        Azure region for the resource group and subscription deployment record.
    .PARAMETER Owner
        Email address of the sandbox owner and budget notification recipient.
    .PARAMETER ExpiresInDays
        Number of days until the sandbox expires.
    .PARAMETER MonthlyBudget
        Monthly budget amount in the subscription billing currency.
    .PARAMETER AllowedLocation
        Azure regions in which resources can be deployed. Defaults to Location.
    .PARAMETER SubscriptionId
        Azure subscription ID. Defaults to the active Azure context.
    .PARAMETER TemplateFile
        Path to the subscription-scoped Bicep template.
    .EXAMPLE
        New-AzSandbox -Name 'rg-sbx-api-001' -Location 'centralus' -Owner 'owner@contoso.com'
    .OUTPUTS
        System.Object
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z0-9._()-]{1,90}$')]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [ValidateScript({
            try {
                $ParsedAddress = [System.Net.Mail.MailAddress]::new($_)
                return $ParsedAddress.Address -eq $_
            }
            catch {
                return $false
            }
        })]
        [string]$Owner,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$ExpiresInDays = 7,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000000)]
        [int]$MonthlyBudget = 100,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedLocation = @(),

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TemplateFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra/main.bicep')
    )

    $Context = Select-AzSandboxSubscriptionContext -SubscriptionId $SubscriptionId
    $Now = [DateTimeOffset]::UtcNow
    $BudgetStartDate = [DateTimeOffset]::new($Now.Year, $Now.Month, 1, 0, 0, 0, [TimeSpan]::Zero)
    $EffectiveAllowedLocations = @(
        if ($AllowedLocation.Count -eq 0) {
            $Location
        }
        else {
            $AllowedLocation | Sort-Object -Unique
        }
    )

    $SandboxConfiguration = @{
        name             = $Name
        location         = $Location
        owner            = $Owner
        expiresOn        = $Now.AddDays($ExpiresInDays).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        allowedLocations = $EffectiveAllowedLocations
        budget           = @{
            amount    = $MonthlyBudget
            startDate = $BudgetStartDate.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            endDate   = $BudgetStartDate.AddYears(5).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }

    $SafeName = $Name -replace '[^a-zA-Z0-9-]', '-'
    if ($SafeName.Length -gt 40) {
        $SafeName = $SafeName.Substring(0, 40)
    }

    $DeploymentParameters = @{
        Name                    = "sbx-$SafeName-$($Now.ToString('yyyyMMddHHmmss'))"
        Location                = $Location
        TemplateFile            = (Resolve-Path -LiteralPath $TemplateFile).Path
        TemplateParameterObject = @{ sandbox = $SandboxConfiguration }
        ErrorAction             = 'Stop'
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create lifecycle-managed sandbox in subscription $($Context.Subscription.Id)")) {
        return New-AzDeployment @DeploymentParameters
    }
}

function Get-AzSandbox {
    <#
    .SYNOPSIS
        Retrieves lifecycle-managed Azure sandboxes.
    .DESCRIPTION
        Queries Azure Resource Graph for resource groups managed by this module and adds
        calculated lifecycle status and days remaining.
    .PARAMETER SubscriptionId
        Azure subscription IDs to query. Defaults to the active Azure context.
    .EXAMPLE
        Get-AzSandbox | Sort-Object DaysRemaining
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId = @()
    )

    $Context = Select-AzSandboxSubscriptionContext
    $TargetSubscriptions = if ($SubscriptionId.Count -eq 0) {
        @([string]$Context.Subscription.Id)
    }
    else {
        $SubscriptionId
    }

    $Query = @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| where tostring(tags['$script:ManagedTag']) =~ 'true'
| project id, name, subscriptionId, location, tags
| order by name asc
"@

    $Resources = Search-AzGraph -Query $Query -Subscription $TargetSubscriptions -First 1000 -ErrorAction Stop
    foreach ($Resource in $Resources) {
        ConvertTo-AzSandboxRecord -Resource $Resource
    }
}

function Set-AzSandboxExpiration {
    <#
    .SYNOPSIS
        Extends the expiration of a lifecycle-managed Azure sandbox.
    .PARAMETER Name
        Sandbox resource group name.
    .PARAMETER AdditionalDays
        Number of days to add to the later of the current expiration or current time.
    .PARAMETER SubscriptionId
        Azure subscription ID. Defaults to the active Azure context.
    .EXAMPLE
        Set-AzSandboxExpiration -Name 'rg-sbx-api-001' -AdditionalDays 7
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$AdditionalDays = 7,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )

    $Context = Select-AzSandboxSubscriptionContext -SubscriptionId $SubscriptionId
    $ResourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction Stop
    $ManagedValue = Get-AzSandboxTagValue -Tags $ResourceGroup.Tags -Name $script:ManagedTag
    if ($ManagedValue -ne 'true') {
        throw "Resource group '$Name' is not managed by Azure Sandbox Lifecycle."
    }

    $CurrentExpirationValue = Get-AzSandboxTagValue -Tags $ResourceGroup.Tags -Name $script:ExpirationTag
    $CurrentExpiration = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($CurrentExpirationValue, [ref]$CurrentExpiration)) {
        throw "Resource group '$Name' has an invalid expiration tag."
    }

    $Now = [DateTimeOffset]::UtcNow
    $ExtensionBase = if ($CurrentExpiration -gt $Now) { $CurrentExpiration } else { $Now }
    $NewExpiration = $ExtensionBase.AddDays($AdditionalDays).ToUniversalTime()

    if ($PSCmdlet.ShouldProcess($Name, "Set sandbox expiration to $($NewExpiration.ToString('u'))")) {
        Update-AzTag -ResourceId $ResourceGroup.ResourceId -Tag @{
            $script:ExpirationTag = $NewExpiration.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            $script:StatusTag     = 'Active'
        } -Operation Merge -ErrorAction Stop | Out-Null
    }

    return [pscustomobject]@{
        Name          = $Name
        SubscriptionId = [string]$Context.Subscription.Id
        ExpiresOn     = $NewExpiration
        AdditionalDays = $AdditionalDays
    }
}

function Remove-AzExpiredSandbox {
    <#
    .SYNOPSIS
        Removes lifecycle-managed Azure sandboxes that have expired.
    .PARAMETER SubscriptionId
        Azure subscription IDs to inspect. Defaults to the active Azure context.
    .PARAMETER GracePeriodHours
        Number of hours to wait after expiration before deletion is allowed.
    .PARAMETER ManagedIdentityClientId
        Client ID of the user-assigned managed identity used to authenticate deletion.
    .PARAMETER PassThru
        Returns a deletion record for each removed sandbox.
    .EXAMPLE
        Remove-AzExpiredSandbox -GracePeriodHours 24 -WhatIf
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId = @(),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 720)]
        [int]$GracePeriodHours = 24,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$ManagedIdentityClientId,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
        Connect-AzSandbox -ManagedIdentityClientId $ManagedIdentityClientId | Out-Null
    }

    $DeletionCutoff = [DateTimeOffset]::UtcNow.AddHours(-$GracePeriodHours)
    $ExpiredSandboxes = Get-AzSandbox -SubscriptionId $SubscriptionId | Where-Object {
        $null -ne $_.ExpiresOn -and $_.ExpiresOn -le $DeletionCutoff
    }

    foreach ($Sandbox in $ExpiredSandboxes) {
        Select-AzSandboxSubscriptionContext -SubscriptionId $Sandbox.SubscriptionId | Out-Null
        if ($PSCmdlet.ShouldProcess($Sandbox.ResourceGroupName, "Permanently delete expired sandbox from subscription $($Sandbox.SubscriptionId)")) {
            Remove-AzResourceGroup -Name $Sandbox.ResourceGroupName -Force -ErrorAction Stop | Out-Null

            if ($PassThru) {
                [pscustomobject]@{
                    Name           = $Sandbox.Name
                    SubscriptionId = $Sandbox.SubscriptionId
                    ExpiresOn      = $Sandbox.ExpiresOn
                    RemovedOn      = [DateTimeOffset]::UtcNow
                }
            }
        }
    }
}

function ConvertTo-AzSandboxDashboardHtml {
    <#
    .SYNOPSIS
        Converts sandbox inventory records to a self-contained HTML dashboard.
    .PARAMETER Inventory
        Sandbox inventory records.
    .PARAMETER GeneratedOn
        Timestamp displayed in the dashboard.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Inventory,

        [Parameter(Mandatory = $false)]
        [DateTimeOffset]$GeneratedOn = [DateTimeOffset]::UtcNow
    )

    $DashboardRows = @($Inventory | ForEach-Object {
        [ordered]@{
            name             = [string]$_.Name
            subscriptionId   = [string]$_.SubscriptionId
            location         = [string]$_.Location
            owner            = [string]$_.Owner
            expiresOn        = if ($null -eq $_.ExpiresOn) { $null } else { $_.ExpiresOn.ToString('o') }
            daysRemaining    = $_.DaysRemaining
            status           = [string]$_.Status
            monthlyBudget    = $_.MonthlyBudget
            allowedLocations = @($_.AllowedLocations)
        }
    })

    $InventoryJson = ConvertTo-Json -InputObject $DashboardRows -Depth 5 -Compress
    $InventoryBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($InventoryJson))
    $GeneratedLabel = $GeneratedOn.ToUniversalTime().ToString('yyyy-MM-dd HH:mm ''UTC''')

    $Html = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Azure sandbox inventory</title>
    <script>
        (() => {
            const param = new URLSearchParams(window.location.search).get("scoutTheme");
            const theme =
                param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
            document.documentElement.setAttribute("data-theme", theme);
        })();
    </script>
  <style>
        :root {
            color-scheme: light;
            --cp-bg: #f7f4ef;
            --cp-bg-elevated: #fcfbf8;
            --cp-surface: #ffffff;
            --cp-surface-soft: #f5f5f5;
            --cp-border: #dedede;
            --cp-border-strong: #919191;
            --cp-text: #242424;
            --cp-text-muted: #5c5c5c;
            --cp-text-soft: #6f6f6f;
            --cp-accent: #b11f4b;
            --cp-accent-hover: #9a1a41;
            --cp-accent-soft: rgba(177, 31, 75, 0.08);
            --cp-accent-fg: #ffffff;
            --cp-success: #16a34a;
            --cp-danger: #dc2626;
            --cp-warning: #f59e0b;
            --cp-link: #0078d4;
            --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
            --cp-overlay: rgba(255, 255, 255, 0.8);
            --cp-panel: rgba(255, 255, 255, 0.86);
            --cp-panel-strong: rgba(255, 255, 255, 0.96);
            --cp-sheen: rgba(255, 255, 255, 0.55);
            --cp-highlight: rgba(177, 31, 75, 0.12);
        }
        html[data-theme="dark"] {
            color-scheme: dark;
            --cp-bg: #3d3b3a;
            --cp-bg-elevated: #343231;
            --cp-surface: #292929;
            --cp-surface-soft: #2e2e2e;
            --cp-border: #474747;
            --cp-border-strong: #5f5f5f;
            --cp-text: #dedede;
            --cp-text-muted: #919191;
            --cp-text-soft: #b0b0b0;
            --cp-accent: #fd8ea1;
            --cp-accent-hover: #fb7b91;
            --cp-accent-soft: rgba(253, 142, 161, 0.14);
            --cp-accent-fg: #1a1a1a;
            --cp-success: #4ade80;
            --cp-danger: #f87171;
            --cp-warning: #fbbf24;
            --cp-link: #4da6ff;
            --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
            --cp-overlay: rgba(41, 41, 41, 0.88);
            --cp-panel: rgba(41, 41, 41, 0.72);
            --cp-panel-strong: rgba(41, 41, 41, 0.96);
            --cp-sheen: rgba(255, 255, 255, 0.04);
            --cp-highlight: rgba(253, 142, 161, 0.12);
        }
    * { box-sizing: border-box; }
        body { margin: 0; min-width: 320px; color: var(--cp-text); background: var(--cp-bg); font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif; letter-spacing: 0; }
        header { padding: 40px clamp(20px, 5vw, 72px) 28px; border-bottom: 1px solid var(--cp-border); background: var(--cp-bg-elevated); }
        h1 { margin: 0; max-width: 900px; font-size: clamp(32px, 5vw, 58px); font-weight: 650; letter-spacing: 0; }
        .stamp { margin: 10px 0 0; color: var(--cp-text-muted); font-size: 14px; }
    main { width: min(1480px, 100%); margin: 0 auto; padding: 28px clamp(16px, 4vw, 56px) 56px; }
    .metrics { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin-bottom: 18px; }
        .metric { min-height: 98px; padding: 18px; border: 1px solid var(--cp-border); border-radius: 16px; background: var(--cp-surface); }
        .metric strong { display: block; font-size: 34px; font-weight: 650; }
        .metric span { color: var(--cp-text-muted); font-size: 13px; text-transform: uppercase; }
    .toolbar { display: flex; gap: 10px; align-items: center; margin: 18px 0 12px; }
        input, select, button { min-height: 42px; border: 1px solid var(--cp-border); border-radius: 0.625rem; background: var(--cp-surface); color: var(--cp-text); font: inherit; }
    input { flex: 1; min-width: 160px; padding: 0 13px; }
    select { padding: 0 34px 0 12px; }
    button { padding: 0 15px; cursor: pointer; font-weight: 600; }
        button:hover { border-color: var(--cp-accent-hover); color: var(--cp-accent-hover); }
        input:focus, select:focus, button:focus { outline: 3px solid var(--cp-highlight); outline-offset: 1px; }
        .table-wrap { overflow-x: auto; border: 1px solid var(--cp-border); border-radius: 0.625rem; background: var(--cp-surface); }
    table { width: 100%; min-width: 1000px; border-collapse: collapse; table-layout: fixed; }
        th, td { padding: 13px 14px; border-bottom: 1px solid var(--cp-border); text-align: left; vertical-align: middle; overflow-wrap: anywhere; }
        th { color: var(--cp-text-muted); background: var(--cp-surface-soft); font-size: 12px; font-weight: 700; text-transform: uppercase; }
    tbody tr:last-child td { border-bottom: 0; }
        tbody tr:hover { background: var(--cp-accent-soft); }
    .name { font-weight: 700; }
    .status { display: inline-block; min-width: 76px; padding: 4px 8px; border: 1px solid currentColor; border-radius: 999px; text-align: center; font-size: 12px; font-weight: 700; }
        .active { color: var(--cp-success); } .expiring { color: var(--cp-warning); } .expired { color: var(--cp-danger); } .invalid { color: var(--cp-text-soft); }
        .empty { padding: 32px; color: var(--cp-text-muted); text-align: center; }
    @media (max-width: 760px) { header { padding-top: 28px; } .metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); } .toolbar { align-items: stretch; flex-direction: column; } input, select, button { width: 100%; } }
  </style>
</head>
<body>
  <header>
    <h1>Azure sandbox inventory</h1>
    <p class="stamp">Generated __GENERATED_ON__</p>
  </header>
  <main>
    <section class="metrics" aria-label="Inventory totals">
      <div class="metric"><strong id="total-count">0</strong><span>Total</span></div>
      <div class="metric"><strong id="active-count">0</strong><span>Active</span></div>
      <div class="metric"><strong id="expiring-count">0</strong><span>Expiring</span></div>
      <div class="metric"><strong id="expired-count">0</strong><span>Expired</span></div>
    </section>
    <div class="toolbar">
      <input id="search" type="search" aria-label="Filter inventory" placeholder="Filter by name, owner, or location">
      <select id="status-filter" aria-label="Filter by status">
        <option value="all">All statuses</option><option value="Active">Active</option><option value="Expiring">Expiring</option><option value="Expired">Expired</option><option value="Invalid">Invalid</option>
      </select>
      <button id="export" type="button">Export CSV</button>
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr><th style="width:18%">Sandbox</th><th style="width:11%">Status</th><th style="width:18%">Owner</th><th style="width:11%">Location</th><th style="width:17%">Expires</th><th style="width:10%">Days</th><th style="width:15%">Budget</th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
      <div id="empty" class="empty" hidden>No sandboxes match the current filter.</div>
    </div>
  </main>
  <script>
    const inventory = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__INVENTORY_BASE64__'), character => character.charCodeAt(0))));
    const search = document.querySelector('#search');
    const statusFilter = document.querySelector('#status-filter');
    const rows = document.querySelector('#rows');
    const empty = document.querySelector('#empty');
    const escapeHtml = value => String(value ?? '').replace(/[&<>'"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[character]);
    const formatDate = value => value ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : 'Invalid tag';
    const visibleRows = () => inventory.filter(item => {
      const query = search.value.trim().toLowerCase();
      const matchesQuery = !query || [item.name, item.owner, item.location, item.subscriptionId].some(value => String(value ?? '').toLowerCase().includes(query));
      return matchesQuery && (statusFilter.value === 'all' || item.status === statusFilter.value);
    });
    function render() {
      const items = visibleRows();
      rows.innerHTML = items.map(item => `<tr><td class="name">${escapeHtml(item.name)}</td><td><span class="status ${escapeHtml(item.status.toLowerCase())}">${escapeHtml(item.status)}</span></td><td>${escapeHtml(item.owner)}</td><td>${escapeHtml(item.location)}</td><td>${escapeHtml(formatDate(item.expiresOn))}</td><td>${escapeHtml(item.daysRemaining ?? '-')}</td><td>${item.monthlyBudget == null ? '-' : escapeHtml(Number(item.monthlyBudget).toLocaleString())}</td></tr>`).join('');
      empty.hidden = items.length !== 0;
    }
    function updateMetrics() {
      document.querySelector('#total-count').textContent = inventory.length;
      for (const status of ['Active', 'Expiring', 'Expired']) document.querySelector(`#${status.toLowerCase()}-count`).textContent = inventory.filter(item => item.status === status).length;
    }
    function exportCsv() {
      const fields = ['name', 'status', 'owner', 'location', 'expiresOn', 'daysRemaining', 'monthlyBudget', 'subscriptionId'];
      const quote = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
      const csv = [fields.join(','), ...visibleRows().map(item => fields.map(field => quote(item[field])).join(','))].join('\r\n');
      const link = document.createElement('a');
      link.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
      link.download = 'azure-sandbox-inventory.csv';
      link.click();
      URL.revokeObjectURL(link.href);
    }
    search.addEventListener('input', render); statusFilter.addEventListener('change', render); document.querySelector('#export').addEventListener('click', exportCsv);
    updateMetrics(); render();
  </script>
</body>
</html>
'@

    return $Html.Replace('__INVENTORY_BASE64__', $InventoryBase64).Replace('__GENERATED_ON__', $GeneratedLabel)
}

function Export-AzSandboxDashboard {
    <#
    .SYNOPSIS
        Exports a self-contained HTML sandbox inventory dashboard.
    .PARAMETER Path
        Destination HTML file path.
    .PARAMETER SubscriptionId
        Azure subscription IDs to include. Defaults to the active Azure context.
    .EXAMPLE
        Export-AzSandboxDashboard -Path './out/sandboxes.html'
    .OUTPUTS
        System.IO.FileInfo
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Path = (Join-Path (Get-Location) 'sandbox-inventory.html'),

        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId = @()
    )

    $Inventory = @(Get-AzSandbox -SubscriptionId $SubscriptionId)
    $Html = ConvertTo-AzSandboxDashboardHtml -Inventory $Inventory
    $ParentPath = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($ParentPath)) {
        New-Item -ItemType Directory -Path $ParentPath -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Html -Encoding utf8NoBOM
    return Get-Item -LiteralPath $Path
}

function ConvertTo-AzSandboxApprovalEmail {
    <#
    .SYNOPSIS
        Builds the approval email for a sandbox deletion audit.
    .PARAMETER Candidate
        Sandbox records proposed for deletion.
    .PARAMETER ApproverEmail
        Approver notification address.
    .PARAMETER FromAddress
        Sender address.
    .PARAMETER AuditId
        Audit correlation identifier.
    .PARAMETER GeneratedOn
        Audit timestamp.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Candidate,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApproverEmail,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FromAddress,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AuditId,

        [Parameter(Mandatory = $false)]
        [DateTimeOffset]$GeneratedOn = [DateTimeOffset]::UtcNow
    )

    $Escape = {
        param($Value)
        [string]$Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    }

    $Rows = if ($Candidate.Count -eq 0) {
        '<tr><td colspan="4">No sandboxes require deletion.</td></tr>'
    }
    else {
        ($Candidate | ForEach-Object {
            $ExpiresLabel = if ($null -eq $_.ExpiresOn) { 'Invalid tag' } else { $_.ExpiresOn.ToString('u') }
            '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f @(
                (& $Escape $_.Name),
                (& $Escape $_.Owner),
                (& $Escape $_.SubscriptionId),
                (& $Escape $ExpiresLabel)
            )
        }) -join "`n"
    }

    $Subject = "[Approval required] $($Candidate.Count) Azure sandbox(es) pending deletion"
    $BodyHtml = @"
<!doctype html>
<html lang="en">
<body style="font-family: 'Segoe UI', Aptos, sans-serif; color: #242424;">
  <h2>Azure sandbox deletion approval</h2>
  <p>Audit <strong>$AuditId</strong> generated $($GeneratedOn.ToString('u')).</p>
  <p>The following expired sandboxes are queued for deletion. Approve or reject before automated cleanup proceeds.</p>
  <table border="1" cellpadding="6" cellspacing="0" style="border-collapse: collapse;">
    <thead><tr><th>Sandbox</th><th>Owner</th><th>Subscription</th><th>Expired (UTC)</th></tr></thead>
    <tbody>
$Rows
    </tbody>
  </table>
  <p>Approver: $ApproverEmail</p>
</body>
</html>
"@

    return @{
        To       = $ApproverEmail
        From     = $FromAddress
        Subject  = $Subject
        BodyHtml = $BodyHtml
    }
}

function Invoke-AzSandboxCleanupAudit {
    <#
    .SYNOPSIS
        Simulates expired-sandbox cleanup and requests deletion approval.
    .DESCRIPTION
        Identifies expired sandboxes past the grace period without deleting them,
        writes an audit record and approval email to disk, and notifies the approver.
        The email is simulated unless SMTP settings are supplied.
    .PARAMETER SubscriptionId
        Azure subscription IDs to inspect. Defaults to the active Azure context.
    .PARAMETER GracePeriodHours
        Number of hours after expiration before a sandbox becomes a deletion candidate.
    .PARAMETER ApproverEmail
        Address that receives the deletion approval request.
    .PARAMETER FromAddress
        Sender address for the approval email.
    .PARAMETER AuditPath
        Directory that receives the audit record and approval email.
    .PARAMETER SmtpServer
        SMTP host used to send the approval email. When omitted, the email is simulated.
    .PARAMETER SmtpPort
        SMTP port used to send the approval email.
    .PARAMETER SmtpCredential
        Optional credential for authenticated SMTP delivery.
    .EXAMPLE
        Invoke-AzSandboxCleanupAudit -GracePeriodHours 24
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId = @(),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 720)]
        [int]$GracePeriodHours = 24,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ApproverEmail = 'nd4ever@hotmail.com',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$FromAddress = 'sandbox-lifecycle@no-reply.local',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$AuditPath = (Join-Path (Get-Location) 'out/audit'),

        [Parameter(Mandatory = $false)]
        [string]$SmtpServer,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$SmtpPort = 587,

        [Parameter(Mandatory = $false)]
        [pscredential]$SmtpCredential
    )

    $Now = [DateTimeOffset]::UtcNow
    $AuditId = [guid]::NewGuid().ToString()
    $DeletionCutoff = $Now.AddHours(-$GracePeriodHours)

    $Candidates = @(Get-AzSandbox -SubscriptionId $SubscriptionId | Where-Object {
        $null -ne $_.ExpiresOn -and $_.ExpiresOn -le $DeletionCutoff
    })

    New-Item -ItemType Directory -Path $AuditPath -Force | Out-Null

    $Email = ConvertTo-AzSandboxApprovalEmail -Candidate $Candidates -ApproverEmail $ApproverEmail -FromAddress $FromAddress -AuditId $AuditId -GeneratedOn $Now
    $EmailPath = Join-Path $AuditPath "approval-$AuditId.html"
    Set-Content -LiteralPath $EmailPath -Value $Email.BodyHtml -Encoding utf8NoBOM

    $NotificationStatus = 'Simulated'
    if (-not [string]::IsNullOrWhiteSpace($SmtpServer) -and $Candidates.Count -gt 0) {
        $MailParameters = @{
            To            = $ApproverEmail
            From          = $FromAddress
            Subject       = $Email.Subject
            Body          = $Email.BodyHtml
            BodyAsHtml    = $true
            SmtpServer    = $SmtpServer
            Port          = $SmtpPort
            UseSsl        = $true
            WarningAction = 'SilentlyContinue'
            ErrorAction   = 'Stop'
        }

        if ($null -ne $SmtpCredential) {
            $MailParameters['Credential'] = $SmtpCredential
        }

        Send-MailMessage @MailParameters
        $NotificationStatus = 'Sent'
    }

    $Audit = [pscustomobject]@{
        AuditId            = $AuditId
        GeneratedOn        = $Now
        Approver           = $ApproverEmail
        GracePeriodHours   = $GracePeriodHours
        Simulation         = $true
        PendingApproval    = $Candidates.Count -gt 0
        NotificationStatus = $NotificationStatus
        NotificationPath   = $EmailPath
        Candidates         = $Candidates
    }

    $AuditRecordPath = Join-Path $AuditPath "audit-$AuditId.json"
    $Audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $AuditRecordPath -Encoding utf8NoBOM

    return ($Audit | Add-Member -NotePropertyName 'AuditRecordPath' -NotePropertyValue $AuditRecordPath -PassThru)
}

Export-ModuleMember -Function @(
    'Connect-AzSandbox'
    'Export-AzSandboxDashboard'
    'Get-AzSandbox'
    'Invoke-AzSandboxCleanupAudit'
    'New-AzSandbox'
    'Remove-AzExpiredSandbox'
    'Set-AzSandboxExpiration'
)
