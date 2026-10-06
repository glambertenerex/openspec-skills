---
name: release-configuration-package
description: Use when preparing a release package from origin/test containing changed deployment scripts and newly added Cloud or Background settings since origin/master.
---

# Release Configuration Package

Create a dated release configuration package from the current Git repository.

Run:

```powershell
pwsh -File C:\Users\GabrielLambert\.codex\skills\release-configuration-package\scripts\export-release-configuration.ps1
```

The runner fetches `origin`, compares `origin/master..origin/test`, and writes to:

`C:\Users\GabrielLambert\source\repos\ReleaseConfigurations\yyyy-MM-dd`

It exports:

- SQL and deployment scripts added, modified, or renamed in the range, using their exact `origin/test` content.
- Only JSON properties newly added in changed Cloud and Background settings files.
- A manifest and README that identify the source range and exported artifacts.

Use `-DryRun` to inspect the result without writing files. Use `-Overwrite` only when the user explicitly wants to regenerate that day's package.

Do not include deleted files, settings values that merely changed, unrelated source files, local working-tree content, or secrets from a different branch.
