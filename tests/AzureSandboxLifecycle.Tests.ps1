#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/AzureSandboxLifecycle.psm1') -Force
}

Describe 'Get-AzSandbox' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' } }
        } -ModuleName AzureSandboxLifecycle

        Mock Search-AzGraph {
            @(
                [pscustomobject]@{
                    id             = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-sbx-one'
                    name           = 'rg-sbx-one'
                    subscriptionId = '00000000-0000-0000-0000-000000000001'
                    location       = 'centralus'
                    tags           = @{
                        'sandbox-lifecycle_managed'          = 'true'
                        'sandbox-lifecycle_owner'            = 'owner@contoso.com'
                        'sandbox-lifecycle_expiresOn'        = '2099-01-01T00:00:00Z'
                        'sandbox-lifecycle_monthlyBudget'    = '250'
                        'sandbox-lifecycle_allowedLocations' = 'centralus,eastus2'
                    }
                }
            )
        } -ModuleName AzureSandboxLifecycle
    }

    It 'Maps lifecycle tags to a typed inventory record' {
        $Result = Get-AzSandbox

        $Result.Name | Should -Be 'rg-sbx-one'
        $Result.Status | Should -Be 'Active'
        $Result.MonthlyBudget | Should -Be 250
        $Result.AllowedLocations | Should -HaveCount 2
    }
}

Describe 'New-AzSandbox' -Tag 'Unit' {
    BeforeEach {
        $script:CapturedTemplateParameters = $null
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' } }
        } -ModuleName AzureSandboxLifecycle
        Mock New-AzDeployment {
            $script:CapturedTemplateParameters = $TemplateParameterObject
            [pscustomobject]@{ ProvisioningState = 'Succeeded' }
        } -ModuleName AzureSandboxLifecycle
    }

    It 'Passes lifecycle and governance configuration to Bicep' {
        $TemplatePath = Join-Path $PSScriptRoot '../infra/main.bicep'
        $Result = New-AzSandbox -Name 'rg-sbx-one' -Location 'centralus' -Owner 'owner@contoso.com' -ExpiresInDays 14 -MonthlyBudget 300 -TemplateFile $TemplatePath

        $Result.ProvisioningState | Should -Be 'Succeeded'
        Should -Invoke New-AzDeployment -ModuleName AzureSandboxLifecycle -Times 1 -Exactly
        $script:CapturedTemplateParameters.sandbox.name | Should -Be 'rg-sbx-one'
        $script:CapturedTemplateParameters.sandbox.allowedLocations[0] | Should -Be 'centralus'
        $script:CapturedTemplateParameters.sandbox.budget.amount | Should -Be 300
    }
}

Describe 'Set-AzSandboxExpiration' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' } }
        } -ModuleName AzureSandboxLifecycle
        Mock Get-AzResourceGroup {
            [pscustomobject]@{
                ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-sbx-one'
                Tags       = @{
                    'sandbox-lifecycle_managed'   = 'true'
                    'sandbox-lifecycle_expiresOn' = '2099-01-01T00:00:00Z'
                }
            }
        } -ModuleName AzureSandboxLifecycle
        Mock Update-AzTag {} -ModuleName AzureSandboxLifecycle
    }

    It 'Extends the existing expiration and updates lifecycle tags' {
        $Result = Set-AzSandboxExpiration -Name 'rg-sbx-one' -AdditionalDays 7

        $Result.ExpiresOn | Should -Be ([DateTimeOffset]'2099-01-08T00:00:00Z')
        Should -Invoke Update-AzTag -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'Merge' -and $Tag['sandbox-lifecycle_status'] -eq 'Active'
        }
    }
}

Describe 'Set-AzSandboxExpiredByBudget' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' } }
        } -ModuleName AzureSandboxLifecycle
        Mock Update-AzTag {} -ModuleName AzureSandboxLifecycle
    }

    It 'Marks a managed sandbox expired and records the budget reason' {
        Mock Get-AzResourceGroup {
            [pscustomobject]@{
                ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-sbx-one'
                Tags       = @{ 'sandbox-lifecycle_managed' = 'true'; 'sandbox-lifecycle_expiresOn' = '2099-01-01T00:00:00Z' }
            }
        } -ModuleName AzureSandboxLifecycle

        $Result = Set-AzSandboxExpiredByBudget -Name 'rg-sbx-one' -Confirm:$false

        $Result.Status | Should -Be 'Marked'
        $Result.Reason | Should -Be 'budget-exceeded'
        Should -Invoke Update-AzTag -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'Merge' -and
            $Tag['sandbox-lifecycle_status'] -eq 'Expired' -and
            $Tag['sandbox-lifecycle_flaggedReason'] -eq 'budget-exceeded'
        }
    }

    It 'Leaves a non-managed resource group untouched' {
        Mock Get-AzResourceGroup {
            [pscustomobject]@{ ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-other'; Tags = @{} }
        } -ModuleName AzureSandboxLifecycle

        $Result = Set-AzSandboxExpiredByBudget -Name 'rg-other' -Confirm:$false

        $Result.Status | Should -Be 'NotManaged'
        Should -Invoke Update-AzTag -ModuleName AzureSandboxLifecycle -Times 0 -Exactly
    }
}

Describe 'Remove-AzExpiredSandbox' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzSandbox {
            @(
                [pscustomobject]@{ Name = 'expired'; ResourceGroupName = 'expired'; SubscriptionId = 'sub-one'; ExpiresOn = [DateTimeOffset]::UtcNow.AddDays(-2) }
                [pscustomobject]@{ Name = 'active'; ResourceGroupName = 'active'; SubscriptionId = 'sub-one'; ExpiresOn = [DateTimeOffset]::UtcNow.AddDays(2) }
            )
        } -ModuleName AzureSandboxLifecycle
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-one' } }
        } -ModuleName AzureSandboxLifecycle
        Mock Connect-AzAccount {} -ModuleName AzureSandboxLifecycle
        Mock Remove-AzResourceGroup {} -ModuleName AzureSandboxLifecycle
    }

    It 'Deletes only sandboxes beyond the grace period' {
        Remove-AzExpiredSandbox -GracePeriodHours 24 -Confirm:$false

        Should -Invoke Remove-AzResourceGroup -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'expired'
        }
    }

    It 'Authenticates with the user-assigned managed identity when requested' {
        Remove-AzExpiredSandbox -GracePeriodHours 24 -ManagedIdentityClientId '00000000-0000-0000-0000-000000000009' -Confirm:$false

        Should -Invoke Connect-AzAccount -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $true -and $AccountId -eq '00000000-0000-0000-0000-000000000009'
        }
    }
}

Describe 'Export-AzSandboxDashboard' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzSandbox {
            @(
                [pscustomobject]@{
                    Name = 'rg-sbx-one'; SubscriptionId = 'sub-one'; Location = 'centralus'; Owner = 'owner@contoso.com'
                    ExpiresOn = [DateTimeOffset]'2099-01-01T00:00:00Z'; DaysRemaining = 100; Status = 'Active'
                    MonthlyBudget = 250; AllowedLocations = @('centralus')
                }
            )
        } -ModuleName AzureSandboxLifecycle
    }

    It 'Writes a self-contained inventory dashboard' {
        $OutputPath = Join-Path $TestDrive 'inventory.html'
        $Result = Export-AzSandboxDashboard -Path $OutputPath

        $Result.Exists | Should -BeTrue
        $Html = Get-Content -LiteralPath $OutputPath -Raw
        $Html | Should -Match 'Azure sandbox inventory'
        $Html | Should -Match 'scoutTheme'
        $Html | Should -Match '--cp-accent'
    }

    It 'Returns the dashboard HTML as a string' {
        $Html = Get-AzSandboxDashboardHtml

        $Html | Should -BeOfType [string]
        $Html | Should -Match 'Azure sandbox inventory'
        $Html | Should -Match 'id="rows"'
    }
}

Describe 'Connect-AzSandbox' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-one' } }
        } -ModuleName AzureSandboxLifecycle
        Mock Connect-AzAccount {} -ModuleName AzureSandboxLifecycle
    }

    It 'Connects with a user-assigned managed identity client ID' {
        Connect-AzSandbox -ManagedIdentityClientId '00000000-0000-0000-0000-000000000009'

        Should -Invoke Connect-AzAccount -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $true -and $AccountId -eq '00000000-0000-0000-0000-000000000009'
        }
    }

    It 'Reuses the current context when no client ID is supplied' {
        Connect-AzSandbox

        Should -Invoke Connect-AzAccount -ModuleName AzureSandboxLifecycle -Times 0 -Exactly
    }
}

Describe 'Invoke-AzSandboxCleanupAudit' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzSandbox {
            @(
                [pscustomobject]@{ Name = 'expired'; ResourceGroupName = 'expired'; SubscriptionId = 'sub-one'; Owner = 'owner@contoso.com'; ExpiresOn = [DateTimeOffset]::UtcNow.AddDays(-3) }
                [pscustomobject]@{ Name = 'active'; ResourceGroupName = 'active'; SubscriptionId = 'sub-one'; Owner = 'owner@contoso.com'; ExpiresOn = [DateTimeOffset]::UtcNow.AddDays(3) }
            )
        } -ModuleName AzureSandboxLifecycle
        Mock Send-MailMessage {} -ModuleName AzureSandboxLifecycle
        Mock Send-AzSandboxAcsEmail { 'Succeeded' } -ModuleName AzureSandboxLifecycle
        Mock Send-AzSandboxTeamsMessage {} -ModuleName AzureSandboxLifecycle
    }

    It 'Audits only expired candidates and simulates the approval email' {
        $AuditDir = Join-Path $TestDrive 'audit'
        $Result = Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath $AuditDir

        @($Result.Candidates) | Should -HaveCount 1
        $Result.Candidates[0].Name | Should -Be 'expired'
        $Result.PendingApproval | Should -BeTrue
        $Result.Approver | Should -Be 'approver@example.com'
        $Result.NotificationStatus | Should -Be 'Simulated'
        Test-Path -LiteralPath $Result.NotificationPath | Should -BeTrue
        Test-Path -LiteralPath $Result.AuditRecordPath | Should -BeTrue
        Should -Invoke Send-MailMessage -ModuleName AzureSandboxLifecycle -Times 0 -Exactly
    }

    It 'Sends the approval email when an SMTP server is configured' {
        $AuditDir = Join-Path $TestDrive 'audit-smtp'
        $Result = Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath $AuditDir -SmtpServer 'smtp.contoso.com'

        $Result.NotificationStatus | Should -Be 'Sent'
        Should -Invoke Send-MailMessage -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $To -eq 'approver@example.com'
        }
    }

    It 'Sends through Azure Communication Services when a connection string is configured' {
        $AuditDir = Join-Path $TestDrive 'audit-acs'
        $Result = Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath $AuditDir -AcsConnectionString 'endpoint=https://acs.communication.azure.com/;accesskey=Zm9v' -AcsSenderAddress 'donotreply@contoso.azurecomm.net'

        $Result.NotificationStatus | Should -Be 'Sent'
        Should -Invoke Send-AzSandboxAcsEmail -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $ToAddress -eq 'approver@example.com' -and $SenderAddress -eq 'donotreply@contoso.azurecomm.net'
        }
        Should -Invoke Send-MailMessage -ModuleName AzureSandboxLifecycle -Times 0 -Exactly
    }

    It 'Posts to Teams when a webhook URL is configured' {
        $AuditDir = Join-Path $TestDrive 'audit-teams'
        $Result = Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath $AuditDir -TeamsWebhookUrl 'https://example.webhook.office.com/webhookb2/abc'

        $Result.NotificationStatus | Should -Be 'TeamsOnly'
        Should -Invoke Send-AzSandboxTeamsMessage -ModuleName AzureSandboxLifecycle -Times 1 -Exactly
    }

    It 'Generates signed approval links when a base URL and signing secret are configured' {
        $AuditDir = Join-Path $TestDrive 'audit-approval'
        $Result = Invoke-AzSandboxCleanupAudit -GracePeriodHours 24 -AuditPath $AuditDir -TeamsWebhookUrl 'https://example.webhook.office.com/webhookb2/abc' -ApprovalBaseUrl 'https://fn.example.net' -SigningSecret 'shared-secret'

        $Result.ApprovalRequested | Should -BeTrue
        Should -Invoke Send-AzSandboxTeamsMessage -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $ApproveUrl -match '^https://fn\.example\.net/api/approve\?token=' -and $RejectUrl -match '^https://fn\.example\.net/api/approve\?token='
        }
    }
}

Describe 'New-AzSandboxApprovalToken' -Tag 'Unit' {
    It 'Round-trips an approval payload with a matching secret' {
        $Candidate = [pscustomobject]@{ SubscriptionId = 'sub-one'; ResourceGroupName = 'expired' }
        $Token = New-AzSandboxApprovalToken -AuditId 'audit-1' -Action 'approve' -Candidate @($Candidate) -Secret 'shared-secret'
        $Payload = Test-AzSandboxApprovalToken -Token $Token -Secret 'shared-secret'

        $Payload.aud | Should -Be 'sandbox-approval'
        $Payload.act | Should -Be 'approve'
        $Payload.aid | Should -Be 'audit-1'
        @($Payload.rgs).n | Should -Be 'expired'
    }

    It 'Round-trips an extend payload for the owner self-service link' {
        $Candidate = [pscustomobject]@{ SubscriptionId = 'sub-one'; ResourceGroupName = 'rg-sbx-demo' }
        $Token = New-AzSandboxApprovalToken -AuditId 'audit-2' -Action 'extend' -Candidate @($Candidate) -Secret 'shared-secret'
        $Payload = Test-AzSandboxApprovalToken -Token $Token -Secret 'shared-secret'

        $Payload.act | Should -Be 'extend'
        @($Payload.rgs).n | Should -Be 'rg-sbx-demo'
    }

    It 'Rejects a tampered token' {
        $Candidate = [pscustomobject]@{ SubscriptionId = 'sub-one'; ResourceGroupName = 'expired' }
        $Token = New-AzSandboxApprovalToken -AuditId 'audit-1' -Action 'approve' -Candidate @($Candidate) -Secret 'shared-secret'

        { Test-AzSandboxApprovalToken -Token ($Token + 'x') -Secret 'shared-secret' } | Should -Throw
    }

    It 'Rejects a token signed with a different secret' {
        $Candidate = [pscustomobject]@{ SubscriptionId = 'sub-one'; ResourceGroupName = 'expired' }
        $Token = New-AzSandboxApprovalToken -AuditId 'audit-1' -Action 'approve' -Candidate @($Candidate) -Secret 'shared-secret'

        { Test-AzSandboxApprovalToken -Token $Token -Secret 'other-secret' } | Should -Throw
    }

    It 'Rejects an expired token' {
        $Candidate = [pscustomobject]@{ SubscriptionId = 'sub-one'; ResourceGroupName = 'expired' }
        $Past = [DateTimeOffset]::UtcNow.AddHours(-2)
        $Token = New-AzSandboxApprovalToken -AuditId 'audit-1' -Action 'approve' -Candidate @($Candidate) -Secret 'shared-secret' -TtlHours 1 -Now $Past

        { Test-AzSandboxApprovalToken -Token $Token -Secret 'shared-secret' } | Should -Throw '*expired*'
    }
}

Describe 'Invoke-AzSandboxApprovedDeletion' -Tag 'Unit' {
    BeforeEach {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-one' } }
        } -ModuleName AzureSandboxLifecycle
        Mock Set-AzContext {} -ModuleName AzureSandboxLifecycle
        Mock Remove-AzResourceGroup {} -ModuleName AzureSandboxLifecycle
    }

    It 'Deletes only the resource groups named in the token payload' {
        Mock Get-AzResourceGroup {
            [pscustomobject]@{ ResourceGroupName = 'expired'; ResourceId = '/subscriptions/sub-one/resourceGroups/expired'; Tags = @{ 'sandbox-lifecycle_managed' = 'true' } }
        } -ModuleName AzureSandboxLifecycle

        $Payload = [pscustomobject]@{ aud = 'sandbox-approval'; act = 'approve'; aid = 'audit-1'; rgs = @([pscustomobject]@{ s = 'sub-one'; n = 'expired' }) }
        $Result = Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -Confirm:$false

        $Result.Status | Should -Be 'Deleted'
        Should -Invoke Remove-AzResourceGroup -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'expired'
        }
    }

    It 'Skips a resource group that no longer carries the managed tag' {
        Mock Get-AzResourceGroup {
            [pscustomobject]@{ ResourceGroupName = 'expired'; ResourceId = '/subscriptions/sub-one/resourceGroups/expired'; Tags = @{} }
        } -ModuleName AzureSandboxLifecycle

        $Payload = [pscustomobject]@{ aud = 'sandbox-approval'; act = 'approve'; aid = 'audit-1'; rgs = @([pscustomobject]@{ s = 'sub-one'; n = 'expired' }) }
        $Result = Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -Confirm:$false

        $Result.Status | Should -Be 'NotManaged'
        Should -Invoke Remove-AzResourceGroup -ModuleName AzureSandboxLifecycle -Times 0 -Exactly
    }

    It 'Refuses to delete when the token action is not approve' {
        $Payload = [pscustomobject]@{ aud = 'sandbox-approval'; act = 'reject'; aid = 'audit-1'; rgs = @([pscustomobject]@{ s = 'sub-one'; n = 'expired' }) }

        { Invoke-AzSandboxApprovedDeletion -TokenPayload $Payload -Confirm:$false } | Should -Throw
    }
}

Describe 'Send-SandboxExpiryNotice owner actions' -Tag 'Unit' {
    BeforeAll {
        $RunbookPath = Join-Path $PSScriptRoot '../automation/runbooks/Send-SandboxExpiryNotice.ps1'
        $script:RunbookSource = Get-Content -LiteralPath $RunbookPath -Raw
    }

    It 'Uses the approved labels and colors for owner action buttons' {
        $script:RunbookSource.Contains('>Extend $ExtensionDays Days</a>') | Should -BeTrue
        $script:RunbookSource.Contains('>Delete Sandbox</a>') | Should -BeTrue
        $script:RunbookSource.Contains('background:#107c10') | Should -BeTrue
        $script:RunbookSource.Contains('background:#a4262c') | Should -BeTrue
    }

    It 'Routes the Teams card to the owner UPN through the configured workflow' {
        $script:RunbookSource.Contains("VariableName 'SandboxTeamsWorkflowUrl'") | Should -BeTrue
        $script:RunbookSource.Contains('recipientUpn = $OwnerUpn') | Should -BeTrue
        $script:RunbookSource.Contains("type         = 'message'") | Should -BeTrue
        $script:RunbookSource.Contains("contentType = 'application/vnd.microsoft.card.adaptive'") | Should -BeTrue
        $script:RunbookSource.Contains('content     = $adaptiveCard') | Should -BeTrue
        $script:RunbookSource.Contains("TeamsNotificationStatus = $teamsNotificationStatus") | Should -BeTrue
    }

    It 'Uses clickable image buttons with approved Teams owner labels and colors' {
        $script:RunbookSource.Contains("type    = 'ColumnSet'") | Should -BeTrue
        $script:RunbookSource.Contains('altText      = "Extend $ExtensionDays Days"') | Should -BeTrue
        $script:RunbookSource.Contains("altText      = 'Delete Sandbox'") | Should -BeTrue
        $script:RunbookSource.Contains('url          = "data:image/png;base64,$TeamsExtendButtonPng"') | Should -BeTrue
        $script:RunbookSource.Contains('url          = "data:image/png;base64,$TeamsDeleteButtonPng"') | Should -BeTrue
        $script:RunbookSource.Contains('selectAction = [ordered]@{ type = ''Action.OpenUrl''; title = "Extend $ExtensionDays Days"; url = $ExtendUrl }') | Should -BeTrue
        $script:RunbookSource.Contains("selectAction = [ordered]@{ type = 'Action.OpenUrl'; title = 'Delete Sandbox'; url = `$DeleteUrl }") | Should -BeTrue
        $script:RunbookSource.Contains("style = 'positive'") | Should -BeFalse
        $script:RunbookSource.Contains("style = 'destructive'") | Should -BeFalse
    }

    It 'Keeps the owner Teams button assets reproducible' {
        $ButtonGeneratorPath = Join-Path $PSScriptRoot '../scripts/New-TeamsButtonImages.ps1'
        $ButtonGeneratorSource = Get-Content -LiteralPath $ButtonGeneratorPath -Raw

        $ButtonGeneratorSource.Contains("-Text 'Extend 30 Days' -HexColor '#107C10'") | Should -BeTrue
        $ButtonGeneratorSource.Contains("-Text 'Delete Sandbox' -HexColor '#A4262C'") | Should -BeTrue
        $ButtonGeneratorSource.Contains("'btn-extend-30-days.txt'") | Should -BeTrue
        $ButtonGeneratorSource.Contains("'btn-delete-sandbox.txt'") | Should -BeTrue
    }

    It 'Supports isolating delivery to one resource group' {
        $script:RunbookSource.Contains('[string]$ResourceGroupName') | Should -BeTrue
        $script:RunbookSource.Contains('[string]::Equals([string]$sandbox.name, $ResourceGroupName') | Should -BeTrue
    }

    It 'Keeps notifying expired sandboxes without a past-expiry cutoff' {
        $script:RunbookSource.Contains('$expires -gt $now.AddDays($NotifyWithinDays)') | Should -BeTrue
        $script:RunbookSource.Contains('$expires -lt $now.AddDays(-$NotifyWithinDays)') | Should -BeFalse
    }
}

Describe 'Deploy-SandboxAutomation runtime association' -Tag 'Unit' {
    BeforeAll {
        $DeploymentScriptPath = Join-Path $PSScriptRoot '../automation/Deploy-SandboxAutomation.ps1'
        $script:DeploymentScriptSource = Get-Content -LiteralPath $DeploymentScriptPath -Raw
        $AutomationModulePath = Join-Path $PSScriptRoot '../infra/automation/modules/automation-account.bicep'
        $script:AutomationModuleSource = Get-Content -LiteralPath $AutomationModulePath -Raw
    }

    It 'Checks the existing Runtime Environment before applying an association' {
        $script:DeploymentScriptSource.Contains('$runbookResponse = Invoke-AzRestMethod -Path $runbookResourcePath -Method GET') | Should -BeTrue
        $script:DeploymentScriptSource.Contains('if ($runbookResource.properties.runtimeEnvironment -ne $RuntimeEnvironmentName)') | Should -BeTrue
        $script:DeploymentScriptSource.Contains('Invoke-AzRestMethod -Path $runbookResourcePath -Method PATCH -Payload $runtimePayload') | Should -BeTrue
    }

    It 'Clears the Teams workflow variable when Teams delivery is disabled' {
        $script:AutomationModuleSource.Contains("resource teamsWorkflowUrlVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {") | Should -BeTrue
        $script:AutomationModuleSource.Contains("resource teamsWorkflowUrlVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if") | Should -BeFalse
        $script:AutomationModuleSource.Contains('value: ''"${teamsWorkflowUrl ?? ''''}"''') | Should -BeTrue
    }
}

AfterAll {
    Remove-Module AzureSandboxLifecycle -Force -ErrorAction SilentlyContinue
}
