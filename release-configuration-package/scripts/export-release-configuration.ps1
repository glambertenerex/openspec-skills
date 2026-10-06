[CmdletBinding()]
param(
  [string]$ReleaseRoot = "C:\Users\GabrielLambert\source\repos\ReleaseConfigurations",
  [string]$BaselineRef = "origin/master",
  [string]$ReleaseRef = "origin/test",
  [string]$ReleaseDate = (Get-Date -Format "yyyy-MM-dd"),
  [switch]$Overwrite,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
  param([string[]]$Arguments)

  $output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Git command failed: git $($Arguments -join ' ')"
  }

  return $output
}

function Test-Map {
  param($Value)
  return $Value -is [System.Collections.IDictionary]
}

function Get-AddedProperties {
  param($Current, $Baseline)

  if (-not (Test-Map $Current)) {
    return $null
  }

  $result = [ordered]@{}
  $baselineMap = if (Test-Map $Baseline) { $Baseline } else { [ordered]@{} }

  foreach ($key in $Current.Keys) {
    if (-not $baselineMap.Contains($key)) {
      $result[$key] = $Current[$key]
      continue
    }

    $nested = Get-AddedProperties -Current $Current[$key] -Baseline $baselineMap[$key]
    if ((Test-Map $nested) -and $nested.Count -gt 0) {
      $result[$key] = $nested
    }
  }

  return $result
}

function Get-GitJson {
  param(
    [string]$RepositoryRoot,
    [string]$Reference,
    [string]$Path,
    [switch]$AllowMissing
  )

  $content = & git -C $RepositoryRoot show "$Reference`:$Path" 2>$null
  if ($LASTEXITCODE -ne 0) {
    if ($AllowMissing) {
      return [ordered]@{}
    }

    throw "Unable to read '$Path' from '$Reference'."
  }

  return (($content -join "`n") | ConvertFrom-Json -AsHashtable)
}

function Export-GitBlob {
  param(
    [string]$RepositoryRoot,
    [string]$Reference,
    [string]$Path,
    [string]$Destination
  )

  $destinationDirectory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = "git"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in @("-C", $RepositoryRoot, "show", "$Reference`:$Path")) {
    [void]$startInfo.ArgumentList.Add($argument)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()

  $stream = [System.IO.File]::Create($Destination)
  try {
    $process.StandardOutput.BaseStream.CopyTo($stream)
  } finally {
    $stream.Dispose()
  }

  $errorOutput = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    throw "Unable to export '$Path' from '$Reference': $errorOutput"
  }
}

function Get-ChangedEntries {
  param(
    [string]$RepositoryRoot,
    [string]$Range
  )

  $lines = Invoke-Git @("-C", $RepositoryRoot, "diff", "--name-status", "--find-renames", $Range, "--")
  $entries = @()

  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $parts = $line -split "`t"
    $status = $parts[0]
    if ($status -match "^[RC]") {
      $entries += [pscustomobject]@{
        Status = $status
        OldPath = $parts[1].Replace("\\", "/")
        Path = $parts[2].Replace("\\", "/")
      }
    } else {
      $entries += [pscustomobject]@{
        Status = $status
        OldPath = $null
        Path = $parts[1].Replace("\\", "/")
      }
    }
  }

  return $entries
}

function Test-DeploymentScript {
  param([string]$Path)
  return $Path -match "(?i)\.(sql|ps1|psm1|sh|cmd|bat)$"
}

function Get-SettingsComponent {
  param([string]$Path)

  if ($Path -match "(?i)^Powermatrix\.Propeller\.Cloud/appsettings(?:\..+)?\.json$") {
    return "Cloud"
  }

  if ($Path -match "(?i)^Powermatrix\.Propeller\.Background/(appsettings(?:\..+)?\.json|local\.settings\.json|host\.json)$") {
    return "Background"
  }

  return $null
}

$repositoryRoot = (Invoke-Git @("rev-parse", "--show-toplevel")).Trim()
Invoke-Git @("-C", $repositoryRoot, "fetch", "origin", "--prune") | Out-Null
foreach ($reference in @($BaselineRef, $ReleaseRef)) {
  Invoke-Git @("-C", $repositoryRoot, "rev-parse", "--verify", "$reference`^{commit}") | Out-Null
}

$range = "$BaselineRef..$ReleaseRef"
$entries = Get-ChangedEntries -RepositoryRoot $repositoryRoot -Range $range
$scriptEntries = @($entries | Where-Object { $_.Status -ne "D" -and (Test-DeploymentScript $_.Path) })
$settingEntries = @($entries | Where-Object { $_.Status -ne "D" -and (Get-SettingsComponent $_.Path) })
$packageRoot = Join-Path $ReleaseRoot $ReleaseDate

if (Test-Path -LiteralPath $packageRoot) {
  if (-not $Overwrite) {
    throw "Release package already exists: $packageRoot. Use -Overwrite only to regenerate it intentionally."
  }

  if (-not $DryRun) {
    foreach ($generatedItem in @("Scripts", "Cloud", "Background", "README.md", "release-manifest.json")) {
      $target = Join-Path $packageRoot $generatedItem
      if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
      }
    }
  }
}

$scriptPlan = foreach ($entry in $scriptEntries) {
  $relativePath = $entry.Path
  if ($relativePath.StartsWith("Powermatrix.Propeller.SQL/", [System.StringComparison]::OrdinalIgnoreCase)) {
    $relativePath = $relativePath.Substring("Powermatrix.Propeller.SQL/".Length)
  }

  [pscustomobject]@{
    Source = $entry.Path
    Status = $entry.Status
    Destination = (Join-Path "Scripts" ($relativePath -replace "/", "\"))
  }
}

$settingsPlan = @()
foreach ($entry in $settingEntries) {
  $component = Get-SettingsComponent $entry.Path
  $baselinePath = if ($entry.OldPath) { $entry.OldPath } else { $entry.Path }
  $current = Get-GitJson -RepositoryRoot $repositoryRoot -Reference $ReleaseRef -Path $entry.Path
  $baseline = Get-GitJson -RepositoryRoot $repositoryRoot -Reference $BaselineRef -Path $baselinePath -AllowMissing
  $added = Get-AddedProperties -Current $current -Baseline $baseline

  if (-not (Test-Map $added) -or $added.Count -eq 0) {
    continue
  }

  $fileName = "{0}.added.json" -f [System.IO.Path]::GetFileNameWithoutExtension($entry.Path)
  $settingsPlan += [pscustomobject]@{
    Source = $entry.Path
    Status = $entry.Status
    Component = $component
    Destination = (Join-Path $component $fileName)
    Added = $added
  }
}

$summary = [pscustomobject]@{
  ReleaseDate = $ReleaseDate
  PackageRoot = $packageRoot
  BaselineRef = $BaselineRef
  BaselineCommit = (Invoke-Git @("-C", $repositoryRoot, "rev-parse", $BaselineRef)).Trim()
  ReleaseRef = $ReleaseRef
  ReleaseCommit = (Invoke-Git @("-C", $repositoryRoot, "rev-parse", $ReleaseRef)).Trim()
  Scripts = $scriptPlan
  Settings = @($settingsPlan | ForEach-Object {
    [pscustomobject]@{
      Source = $_.Source
      Status = $_.Status
      Component = $_.Component
      Destination = $_.Destination
      AddedTopLevelKeys = @($_.Added.Keys)
    }
  })
  Commits = @(Invoke-Git @("-C", $repositoryRoot, "log", "--format=%H%x09%ad%x09%an%x09%s", "--date=short", $range))
}

if ($DryRun) {
  $summary | ConvertTo-Json -Depth 10
  return
}

New-Item -ItemType Directory -Force -Path $packageRoot, (Join-Path $packageRoot "Scripts"), (Join-Path $packageRoot "Cloud"), (Join-Path $packageRoot "Background") | Out-Null
foreach ($script in $scriptPlan) {
  Export-GitBlob -RepositoryRoot $repositoryRoot -Reference $ReleaseRef -Path $script.Source -Destination (Join-Path $packageRoot $script.Destination)
}

foreach ($setting in $settingsPlan) {
  $setting.Added | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packageRoot $setting.Destination) -Encoding utf8
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $packageRoot "release-manifest.json") -Encoding utf8
$readme = @(
  "# Release Configuration Package - $ReleaseDate",
  "",
  "- Baseline: $BaselineRef at $($summary.BaselineCommit)",
  "- Source: $ReleaseRef at $($summary.ReleaseCommit)",
  "- Scripts exported: $($scriptPlan.Count)",
  "- Settings files with added properties: $($settingsPlan.Count)",
  "",
  "Settings files contain only properties added relative to the baseline. Existing values changed in the range are intentionally excluded.",
  "",
  "See release-manifest.json for source files, commit history, and exported paths."
) -join "`n"
$readme | Set-Content -LiteralPath (Join-Path $packageRoot "README.md") -Encoding utf8

Write-Output "Created release configuration package: $packageRoot"
