---
description: "Verified analysis of the Azure Automation migration pull request"
---

# PR Reference Analysis

## Summary

The branch replaced GitHub Actions cleanup orchestration with an Azure Automation owner-notification workflow. It provisioned a managed PowerShell 7.2 runtime, published a daily expiry-notice runbook, routed email and Teams notices to each tagged owner, preserved signed extend and delete actions, and updated documentation and architecture artifacts.

## Changes by Significance

### Azure Automation orchestration

* Deleted the two GitHub Actions cleanup workflows and their workflow-specific skill.
* Added Azure Automation deployment infrastructure with a system-assigned managed identity, a daily schedule, and pinned `Az` and `Az.ResourceGraph` Runtime Environment packages.
* Added a deployment script that imports the runbook, associates its Runtime Environment, and updates the schedule only when its notification window changes.

### Owner notification workflow

* Updated `Send-SandboxExpiryNotice.ps1` to page through Resource Graph results and notify eligible lifecycle-managed sandbox owners.
* Added an optional case-insensitive resource-group filter for isolated delivery tests.
* Reported Outlook and Teams delivery independently so one channel failure does not hide the other channel's result.
* Routed Teams Adaptive Cards through an encrypted Automation workflow URL to the UPN stored in `sandbox-lifecycle_owner`.
* Kept extend and delete links HMAC-signed and generated only at run time.

### Owner actions and visual consistency

* Preserved the exact `Extend 30 Days` and `Delete Sandbox` labels in Outlook and Teams.
* Replaced Teams action styles, which rendered the positive action blue, with clickable PNG image buttons using the Outlook green `#107C10` and red `#A4262C` colors.
* Extended the existing image generator so the owner-specific Teams assets are reproducible.

### Documentation, architecture, and tests

* Updated the README to describe Azure Automation deployment, direct-owner notification routing, signed owner actions, and the optional Teams workflow configuration.
* Updated the architecture source, rendered HTML, and PNG to remove GitHub Actions and show the Automation and sandbox-owner flow.
* Added Pester regressions for owner action labels and colors, owner-UPN Teams routing, image actions, asset generation, and targeted resource-group filtering.

## Issue References

None

## Security Analysis

* No credential values, Power Automate callback URLs, or generated action tokens were committed.
* The Teams workflow URL is accepted as a secure Bicep parameter and stored as an encrypted Automation variable.
* The runbook uses the Automation Account managed identity for Azure access.
* Signed owner links remain replayable until their configured expiration, as documented. Delete still requires confirmation before the Function app removes resources.
* No new dependencies were added to the repository package manifest.

## Verification Notes

* The branch was current with `origin/main` before PR generation: zero commits behind and three commits ahead after the final change.
* Pester passed 29 of 29 tests.
* PSScriptAnalyzer passed for all changed PowerShell files.
* The Automation Bicep entry point compiled successfully.
* VS Code diagnostics reported no errors in the changed files.
* `git diff --check` passed.
* The updated runbook was published to `aa-sbx-lifecycle-h27x5qf6` and retained the `sandbox-powershell-7-2` Runtime Environment.
* A targeted Automation job for `rg-sbx-demo-exp7d` completed successfully without opening or printing signed owner action links.
