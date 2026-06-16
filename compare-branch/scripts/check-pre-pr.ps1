[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TargetBranch,
  [string]$Remote = "origin",
  [switch]$NoFetch,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-ProcessArgumentString {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $escaped = foreach ($argument in $Arguments) {
    if ($argument -notmatch '[\s"]') {
      $argument
      continue
    }

    '"' + ($argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
  }

  return ($escaped -join " ")
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "git"
  $psi.Arguments = ConvertTo-ProcessArgumentString -Arguments $Arguments
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = (Get-Location).Path

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()

  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  $exitCode = $process.ExitCode
  $output = @()
  if ($stdout) {
    $output += ($stdout -split "`r?`n")
  }
  if ($stderr) {
    $output += ($stderr -split "`r?`n")
  }
  $output = @($output | Where-Object { $_ -ne "" })

  if (-not $AllowFailure -and $exitCode -ne 0) {
    $joined = $Arguments -join " "
    $message = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    throw "git $joined failed.`n$message"
  }

  return [PSCustomObject]@{
    ExitCode = $exitCode
    Output = @($output)
  }
}

function Test-GitRef {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Ref
  )

  $result = Invoke-Git -Arguments @("rev-parse", "--verify", "--quiet", $Ref) -AllowFailure
  return $result.ExitCode -eq 0
}

function Get-TrimmedGitOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $result = Invoke-Git -Arguments $Arguments
  return (($result.Output -join "`n").Trim())
}

function Get-CommitInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Commit
  )

  $format = "%H|%h|%an|%ae|%ad|%s"
  $line = Get-TrimmedGitOutput -Arguments @("log", "-1", "--date=short", "--format=$format", $Commit)
  $parts = $line -split "\|", 6

  [PSCustomObject]@{
    fullSha = $parts[0]
    shortSha = $parts[1]
    authorName = $parts[2]
    authorEmail = $parts[3]
    authorDate = $parts[4]
    subject = $parts[5]
  }
}

function Test-ReportedMergeCommit {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$CommitInfo
  )

  if ($CommitInfo.subject -like "Merge*" -or $CommitInfo.subject -like "Merged PR*") {
    return $true
  }

  $parentLine = Get-TrimmedGitOutput -Arguments @("rev-list", "--parents", "-n", "1", $CommitInfo.fullSha)
  $parentParts = @($parentLine -split "\s+")
  return $parentParts.Count -gt 2
}

function Get-CherryComparison {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetRef,
    [Parameter(Mandatory = $true)]
    [string]$SourceRef
  )

  $lines = @(
    (Invoke-Git -Arguments @("cherry", "-v", $TargetRef, $SourceRef)).Output
  ) | Where-Object { $_ -and $_.Trim() }

  $equivalent = @()
  $missing = @()

  foreach ($line in $lines) {
    if ($line -notmatch '^([+-])\s+([0-9a-fA-F]+)\s+') {
      continue
    }

    $status = $Matches[1]
    $sha = $Matches[2]
    $info = Get-CommitInfo -Commit $sha

    if ($status -eq '-') {
      $equivalent += $info
      continue
    }

    $missing += $info
  }

  return [PSCustomObject]@{
    equivalentCommits = @($equivalent)
    missingCommits = @($missing)
  }
}

function Resolve-TargetRefs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$RemoteName
  )

  $branchName = $null
  $localHeadRef = $null
  $remoteRef = $null
  $exactRef = $null

  if ($Target -match "^refs/heads/(.+)$") {
    $branchName = $Matches[1]
    $localHeadRef = "refs/heads/$branchName"
    $remoteRef = "refs/remotes/$RemoteName/$branchName"
  } elseif ($Target -match "^refs/remotes/$([Regex]::Escape($RemoteName))/(.+)$") {
    $branchName = $Matches[2]
    $localHeadRef = "refs/heads/$branchName"
    $remoteRef = "refs/remotes/$RemoteName/$branchName"
  } elseif ($Target -match "^$([Regex]::Escape($RemoteName))/(.+)$") {
    $branchName = $Matches[1]
    $localHeadRef = "refs/heads/$branchName"
    $remoteRef = "refs/remotes/$RemoteName/$branchName"
  } elseif ($Target -like "refs/*") {
    $exactRef = $Target
  } else {
    $branchName = $Target
    $localHeadRef = "refs/heads/$branchName"
    $remoteRef = "refs/remotes/$RemoteName/$branchName"
  }

  [PSCustomObject]@{
    BranchName = $branchName
    LocalHeadRef = $localHeadRef
    RemoteRef = $remoteRef
    ExactRef = $exactRef
  }
}

function Resolve-ExistingTargetRef {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Refs,
    [Parameter(Mandatory = $true)]
    [string]$OriginalTarget
  )

  $candidates = @()
  if ($Refs.RemoteRef) { $candidates += $Refs.RemoteRef }
  if ($Refs.LocalHeadRef) { $candidates += $Refs.LocalHeadRef }
  if ($Refs.ExactRef) { $candidates += $Refs.ExactRef }
  if (-not $Refs.ExactRef) { $candidates += $OriginalTarget }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-GitRef -Ref $candidate)) {
      return $candidate
    }
  }

  throw "Target branch '$TargetBranch' could not be resolved to an existing Git ref."
}

function Format-CommitLines {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Commits
  )

  if (-not $Commits -or $Commits.Count -eq 0) {
    return @()
  }

  return $Commits | ForEach-Object {
    "- $($_.subject) | $($_.authorDate) | $($_.authorName)"
  }
}

function Test-MergeConflicts {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetRef,
    [Parameter(Mandatory = $true)]
    [string]$SourceSha
  )

  $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-pre-pr-" + [Guid]::NewGuid().ToString("N"))
  $pushEntered = $false

  try {
    Invoke-Git -Arguments @("worktree", "add", "--quiet", "--detach", $tempDir, $TargetRef) | Out-Null
    Push-Location $tempDir
    $pushEntered = $true

    $mergeResult = Invoke-Git -Arguments @("merge", "--no-commit", "--no-ff", $SourceSha) -AllowFailure
    $conflictedFiles = @()
    $mergeable = $mergeResult.ExitCode -eq 0

    if (-not $mergeable) {
      $conflictedFiles = @(
        Get-TrimmedGitOutput -Arguments @("diff", "--name-only", "--diff-filter=U")
      ) | Where-Object { $_ -and $_.Trim() }
    }

    $mergeHeadExists = Test-Path (Join-Path $tempDir ".git\MERGE_HEAD")
    if ($mergeHeadExists) {
      Invoke-Git -Arguments @("merge", "--abort") -AllowFailure | Out-Null
    }

    return [PSCustomObject]@{
      mergeable = $mergeable
      conflictedFiles = @($conflictedFiles)
      mergeOutput = @($mergeResult.Output)
    }
  } finally {
    if ($pushEntered) {
      Pop-Location
    }

    if (Test-Path $tempDir) {
      Invoke-Git -Arguments @("worktree", "remove", "--force", $tempDir) -AllowFailure | Out-Null
    }
  }
}

$repoRoot = Get-TrimmedGitOutput -Arguments @("rev-parse", "--show-toplevel")
$currentBranch = Get-TrimmedGitOutput -Arguments @("branch", "--show-current")
$sourceSha = Get-TrimmedGitOutput -Arguments @("rev-parse", "HEAD")
$workingTreeDirty = (Get-TrimmedGitOutput -Arguments @("status", "--porcelain")) -ne ""

$targetRefs = Resolve-TargetRefs -Target $TargetBranch -RemoteName $Remote
if (-not $NoFetch -and $targetRefs.BranchName) {
  Invoke-Git -Arguments @(
    "fetch",
    $Remote,
    "+refs/heads/$($targetRefs.BranchName):$($targetRefs.RemoteRef)",
    "--prune"
  ) | Out-Null
}

$resolvedTargetRef = Resolve-ExistingTargetRef -Refs $targetRefs -OriginalTarget $TargetBranch
$mergeBase = Get-TrimmedGitOutput -Arguments @("merge-base", "HEAD", $resolvedTargetRef)
$aheadBehind = (Get-TrimmedGitOutput -Arguments @("rev-list", "--left-right", "--count", "$resolvedTargetRef...HEAD")) -split "\s+"

$sourceOnlyShas = @(
  (Invoke-Git -Arguments @("rev-list", "--reverse", "$resolvedTargetRef..HEAD")).Output
) | Where-Object { $_ -and $_.Trim() }

$targetOnlyShas = @(
  (Invoke-Git -Arguments @("rev-list", "--reverse", "HEAD..$resolvedTargetRef")).Output
) | Where-Object { $_ -and $_.Trim() }

$sourceOnlyCommits = @($sourceOnlyShas | ForEach-Object { Get-CommitInfo -Commit $_ })
$targetOnlyCommits = @($targetOnlyShas | ForEach-Object { Get-CommitInfo -Commit $_ })
$cherryComparison = Get-CherryComparison -TargetRef $resolvedTargetRef -SourceRef "HEAD"
$sourceOnlyMergeCommits = @($sourceOnlyCommits | Where-Object { Test-ReportedMergeCommit -CommitInfo $_ })
$targetOnlyMergeCommits = @($targetOnlyCommits | Where-Object { Test-ReportedMergeCommit -CommitInfo $_ })
$sourcePatchEquivalentCommits = @($cherryComparison.equivalentCommits | Where-Object { -not (Test-ReportedMergeCommit -CommitInfo $_) })
$sourcePatchMissingCommits = @($cherryComparison.missingCommits | Where-Object { -not (Test-ReportedMergeCommit -CommitInfo $_) })
$sourceOnlyDisplayCommits = @($sourceOnlyCommits | Where-Object { -not (Test-ReportedMergeCommit -CommitInfo $_) })
$targetOnlyDisplayCommits = @($targetOnlyCommits | Where-Object { -not (Test-ReportedMergeCommit -CommitInfo $_) })
$mergeCheck = Test-MergeConflicts -TargetRef $resolvedTargetRef -SourceSha $sourceSha

$result = [PSCustomObject]@{
  repositoryRoot = $repoRoot
  currentBranch = if ($currentBranch) { $currentBranch } else { "(detached HEAD)" }
  sourceSha = $sourceSha
  targetBranchInput = $TargetBranch
  resolvedTargetRef = $resolvedTargetRef
  remote = $Remote
  fetched = (-not $NoFetch.IsPresent)
  workingTreeDirty = $workingTreeDirty
  mergeBase = $mergeBase
  sourceOnlyCount = $sourceOnlyDisplayCommits.Count
  targetOnlyCount = $targetOnlyDisplayCommits.Count
  sourceOnlyCommits = $sourceOnlyDisplayCommits
  targetOnlyCommits = $targetOnlyDisplayCommits
  sourceOnlyMergeCommitCount = $sourceOnlyMergeCommits.Count
  sourceOnlyMergeCommits = @($sourceOnlyMergeCommits)
  targetOnlyMergeCommitCount = $targetOnlyMergeCommits.Count
  targetOnlyMergeCommits = @($targetOnlyMergeCommits)
  sourcePatchEquivalentCount = $sourcePatchEquivalentCommits.Count
  sourcePatchEquivalentCommits = @($sourcePatchEquivalentCommits)
  sourcePatchMissingCount = $sourcePatchMissingCommits.Count
  sourcePatchMissingCommits = @($sourcePatchMissingCommits)
  likelyMergeConflicts = (-not $mergeCheck.mergeable)
  conflictedFiles = @($mergeCheck.conflictedFiles)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  exit 0
}

Write-Host "Pre-PR branch comparison"
Write-Host "Repository root: $($result.repositoryRoot)"
Write-Host "Current branch: $($result.currentBranch)"
Write-Host "Source SHA: $($result.sourceSha)"
Write-Host "Target branch input: $($result.targetBranchInput)"
Write-Host "Resolved target ref: $($result.resolvedTargetRef)"
Write-Host "Working tree dirty: $($result.workingTreeDirty)"
Write-Host "Merge base: $($result.mergeBase)"
Write-Host "Commits only in current branch by SHA/history (excluding merge commits): $($result.sourceOnlyCount)"
Write-Host "Commits only in target branch by SHA/history (excluding merge commits): $($result.targetOnlyCount)"
Write-Host "Current-branch commits already present in target by patch: $($result.sourcePatchEquivalentCount)"
Write-Host "Current-branch commits missing from target by patch: $($result.sourcePatchMissingCount)"
Write-Host "Likely merge conflicts if PR targets this branch: $($result.likelyMergeConflicts)"
Write-Host "Note: merge commits are excluded from the reported commit lists."

if ($result.sourceOnlyCommits.Count -gt 0) {
  Write-Host ""
  Write-Host "Commits unique to current branch by SHA/history (excluding merge commits):"
  Format-CommitLines -Commits $result.sourceOnlyCommits | ForEach-Object { Write-Host $_ }
}

if ($result.targetOnlyCommits.Count -gt 0) {
  Write-Host ""
  Write-Host "Commits present in target branch but missing from current branch by SHA/history (excluding merge commits):"
  Format-CommitLines -Commits $result.targetOnlyCommits | ForEach-Object { Write-Host $_ }
}

if ($result.sourcePatchEquivalentCount -gt 0) {
  Write-Host ""
  Write-Host "Current-branch commits already present in target by patch equivalence:"
  Format-CommitLines -Commits $result.sourcePatchEquivalentCommits | ForEach-Object { Write-Host $_ }
}

if ($result.sourcePatchMissingCount -gt 0) {
  Write-Host ""
  Write-Host "Current-branch commits still missing from target by patch equivalence (these would likely drive the PR):"
  Format-CommitLines -Commits $result.sourcePatchMissingCommits | ForEach-Object { Write-Host $_ }
}

if ($mergeCheck.conflictedFiles.Count -gt 0) {
  Write-Host ""
  Write-Host "Files likely to conflict in merge:"
  $mergeCheck.conflictedFiles | ForEach-Object { Write-Host "- $_" }
}

if ($workingTreeDirty) {
  Write-Host ""
  Write-Host "Warning: working tree has uncommitted changes. They are not part of the PR comparison."
}
