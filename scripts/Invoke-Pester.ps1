#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Runs the repository Pester test suite.
.PARAMETER TestPath
    Test file or directory to run.
.EXAMPLE
    ./scripts/Invoke-Pester.ps1 -TestPath ./tests
.OUTPUTS
    None
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TestPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests')
)

$ErrorActionPreference = 'Stop'

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $Configuration = New-PesterConfiguration
        $Configuration.Run.Path = $TestPath
        $Configuration.Run.PassThru = $true
        $Configuration.Output.Verbosity = 'Detailed'
        $Result = Invoke-Pester -Configuration $Configuration

        if ($Result.FailedCount -gt 0) {
            exit 1
        }

        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Pester execution failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
