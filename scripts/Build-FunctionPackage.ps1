# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Stages the approval Function app into a deployable package.
.DESCRIPTION
    Copies the functions/ content and the AzureSandboxLifecycle module into a
    staging folder under out/, then produces a zip suitable for
    'az functionapp deployment source config-zip'. Keeps a single source of
    truth by copying src/ into Modules/AzureSandboxLifecycle.
.PARAMETER OutputPath
    Directory that receives the staging folder and zip. Defaults to out/functions.
.PARAMETER SkipAzModules
    Skips bundling the Az modules. The Flex Consumption plan does not support
    managed dependencies, so the Az modules must ship in the package.
.EXAMPLE
    ./scripts/Build-FunctionPackage.ps1
.OUTPUTS
    System.String
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path (Get-Location) 'out/functions'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipAzModules
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$FunctionsSource = Join-Path $RepoRoot 'functions'
$ModuleSource = Join-Path $RepoRoot 'src'

$StagePath = Join-Path $OutputPath 'stage'
if (Test-Path -LiteralPath $StagePath) {
    Remove-Item -LiteralPath $StagePath -Recurse -Force
}
New-Item -ItemType Directory -Path $StagePath -Force | Out-Null

Copy-Item -Path (Join-Path $FunctionsSource '*') -Destination $StagePath -Recurse -Force -Exclude 'local.settings.json'

$ModuleTarget = Join-Path $StagePath 'Modules/AzureSandboxLifecycle'
New-Item -ItemType Directory -Path $ModuleTarget -Force | Out-Null
Copy-Item -Path (Join-Path $ModuleSource 'AzureSandboxLifecycle.ps*1') -Destination $ModuleTarget -Force

if (-not $SkipAzModules) {
    $ModulesRoot = Join-Path $StagePath 'Modules'
    Write-Information 'Bundling Az modules (Flex Consumption has no managed dependencies)...' -InformationAction Continue
    Save-Module -Name 'Az.Accounts', 'Az.Resources', 'Az.ResourceGraph' -Path $ModulesRoot -Repository PSGallery -Force
}

$ZipPath = Join-Path $OutputPath 'approval-functions.zip'
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -Path (Join-Path $StagePath '*') -DestinationPath $ZipPath -Force

Write-Information "Function package created: $ZipPath" -InformationAction Continue
return $ZipPath
