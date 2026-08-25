# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

# Runs on cold start. Authenticates the Function app's system-assigned managed
# identity so downstream Azure cmdlets operate under that identity. Set
# FUNCTIONS_SANDBOX_SKIP_LOGIN=true for local development without an identity.
if ($env:FUNCTIONS_SANDBOX_SKIP_LOGIN -ne 'true' -and (Get-Command Connect-AzAccount -ErrorAction SilentlyContinue)) {
    try {
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Managed identity sign-in failed: $($_.Exception.Message)"
    }
}
