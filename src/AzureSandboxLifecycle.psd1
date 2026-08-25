# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

@{
    RootModule        = 'AzureSandboxLifecycle.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '68d7285e-fc5b-41f7-9bb2-a4ea35dc4c67'
    Author            = 'Microsoft'
    CompanyName       = 'Microsoft Corporation'
    Copyright         = '(c) Microsoft Corporation. All rights reserved.'
    Description       = 'PowerShell automation for governed, time-bound Azure sandbox resource groups.'
    PowerShellVersion = '7.0'
    RequiredModules   = @(
        'Az.Accounts'
        'Az.ResourceGraph'
        'Az.Resources'
    )
    FunctionsToExport = @(
        'Export-AzSandboxDashboard'
        'Get-AzSandbox'
        'New-AzSandbox'
        'Remove-AzExpiredSandbox'
        'Set-AzSandboxExpiration'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Azure', 'Sandbox', 'Lifecycle', 'Governance', 'Bicep')
        }
    }
}
