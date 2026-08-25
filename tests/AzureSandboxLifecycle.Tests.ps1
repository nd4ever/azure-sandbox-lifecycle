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
                        'sandbox-lifecycle/managed'          = 'true'
                        'sandbox-lifecycle/owner'            = 'owner@contoso.com'
                        'sandbox-lifecycle/expiresOn'        = '2099-01-01T00:00:00Z'
                        'sandbox-lifecycle/monthlyBudget'    = '250'
                        'sandbox-lifecycle/allowedLocations' = 'centralus,eastus2'
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
                    'sandbox-lifecycle/managed'   = 'true'
                    'sandbox-lifecycle/expiresOn' = '2099-01-01T00:00:00Z'
                }
            }
        } -ModuleName AzureSandboxLifecycle
        Mock Update-AzTag {} -ModuleName AzureSandboxLifecycle
    }

    It 'Extends the existing expiration and updates lifecycle tags' {
        $Result = Set-AzSandboxExpiration -Name 'rg-sbx-one' -AdditionalDays 7

        $Result.ExpiresOn | Should -Be ([DateTimeOffset]'2099-01-08T00:00:00Z')
        Should -Invoke Update-AzTag -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'Merge' -and $Tag['sandbox-lifecycle/status'] -eq 'Active'
        }
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
        Mock Remove-AzResourceGroup {} -ModuleName AzureSandboxLifecycle
    }

    It 'Deletes only sandboxes beyond the grace period' {
        Remove-AzExpiredSandbox -GracePeriodHours 24 -Confirm:$false

        Should -Invoke Remove-AzResourceGroup -ModuleName AzureSandboxLifecycle -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'expired'
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
}

AfterAll {
    Remove-Module AzureSandboxLifecycle -Force -ErrorAction SilentlyContinue
}
