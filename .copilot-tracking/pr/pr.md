---
description: "Pull request description for the Azure Automation owner-notification migration"
---

# ops(workflows): replace GitHub cleanup with owner notifications

This PR replaced GitHub Actions cleanup orchestration with a daily Azure Automation workflow. Lifecycle-managed sandbox owners now receive signed Outlook and direct Teams actions for extending or deleting their resource group, while the repository retains local preview and audit commands for ad hoc use.

## Changes

### Azure Automation

* Removed the GitHub cleanup workflows and their workflow-specific skill.
* Added a managed PowerShell 7.2 Runtime Environment with pinned `Az` and `Az.ResourceGraph` packages.
* Added deployment support for publishing the expiry-notice runbook, associating its runtime, and maintaining the daily schedule.
* Stored the optional Power Automate callback as an encrypted Automation variable.

### Owner notifications

* Routed Outlook and Teams notifications to the UPN in `sandbox-lifecycle_owner`.
* Preserved HMAC-signed `Extend 30 Days` and `Delete Sandbox` actions.
* Rendered Teams actions as clickable green and red images so they match the Outlook message.
* Added Resource Graph pagination, targeted resource-group delivery, and independent Outlook and Teams status reporting.

### Documentation and validation

* Updated the README and architecture artifacts for the Azure Automation and sandbox-owner flow.
* Added regressions for exact action labels and colors, owner-UPN routing, reproducible Teams assets, and isolated resource-group delivery.
* Validated the branch with 29 passing Pester tests, PSScriptAnalyzer, Bicep compilation, VS Code diagnostics, and `git diff --check`.
* Published the tested runbook and completed a targeted notification job for `rg-sbx-demo-exp7d`.

## Related Issues

None

## Notes

* Signed owner action links remain valid until their configured token expiration. Deletion still requires confirmation.
* No credentials, callback URLs, or generated action tokens were committed.
