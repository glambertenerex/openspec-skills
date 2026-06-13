---
name: compare-branch
description: Compare the current Git branch against a specified target branch before opening a pull request. Use when the user asks to compare branches, run a pre-PR branch check, inspect desynchronization, inspect drift, or estimate whether a PR to another branch may conflict.
---

# Compare Branch

Run a deterministic pre-pull-request comparison between the current branch and a target branch.

## Workflow

1. Confirm the target branch name if the user did not specify it.
2. Run `scripts/check-pre-pr.ps1 -TargetBranch <branch>` from the repository root.
3. By default, let the script fetch the target branch from `origin`.
4. Read the report and summarize:
   - current branch
   - resolved target branch
   - commits unique to the compared source ref
   - commits present in the compared target ref but missing from the source ref
   - whether the current working tree is dirty
   - whether a temporary merge test predicts conflicts
   - which files would likely conflict, when detected
   - always list commit details for both sides when commits exist, using:
     - commit subject
     - author name
     - author date
   - when the comparison is requested against `origin/...`, report only the commits from the compared remote refs and do not mix in unrelated local branch names or local-only refs
5. If the user asks for a machine-readable result, run the script with `-Json`.

## Script

Use:

```powershell
pwsh -File scripts/check-pre-pr.ps1 -TargetBranch dev
```

Optional flags:

```powershell
pwsh -File scripts/check-pre-pr.ps1 -TargetBranch test -Remote origin
pwsh -File scripts/check-pre-pr.ps1 -TargetBranch dev -NoFetch
pwsh -File scripts/check-pre-pr.ps1 -TargetBranch dev -Json
```

## Guardrails

- Do not guess the target branch when the user did not provide one.
- Do not modify the current branch or current working tree to test mergeability.
- Use the temporary worktree merge test from the script instead of a live merge in the active worktree.
- Report that the result is a preflight estimate, not a substitute for the platform's final mergeability check.
- Prefer `origin/<branch>` inputs when the user wants a remote-to-remote comparison.
