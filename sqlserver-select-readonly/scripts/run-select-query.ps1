[CmdletBinding(DefaultParameterSetName = "ConnectionString")]
param(
  [Parameter(ParameterSetName = "ConnectionString")]
  [string]$ConnectionString,

  [Parameter(ParameterSetName = "Explicit")]
  [string]$Server,

  [Parameter(ParameterSetName = "Explicit")]
  [string]$Database,

  [Parameter(ParameterSetName = "Explicit")]
  [string]$Username,

  [Parameter(ParameterSetName = "Explicit")]
  [string]$Password,

  [Parameter(ParameterSetName = "Explicit")]
  [switch]$UseIntegratedSecurity,

  [Parameter()]
  [string]$Query,

  [Parameter()]
  [string]$QueryFile,

  [Parameter()]
  [int]$TimeoutSeconds = 30,

  [Parameter()]
  [switch]$AsJson,

  [Parameter()]
  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-QueryText {
  if ([string]::IsNullOrWhiteSpace($Query) -eq [string]::IsNullOrWhiteSpace($QueryFile)) {
    throw "Specify exactly one of -Query or -QueryFile."
  }

  if ($QueryFile) {
    if (-not (Test-Path -LiteralPath $QueryFile)) {
      throw "Query file not found: $QueryFile"
    }

    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $QueryFile))
  }

  return $Query
}

function Remove-SqlCommentsAndLiterals {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )

  $builder = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $Text.Length) {
    $char = $Text[$i]
    $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

    if ($char -eq '-' -and $next -eq '-') {
      $i += 2
      while ($i -lt $Text.Length -and $Text[$i] -ne "`n") {
        $i++
      }
      continue
    }

    if ($char -eq '/' -and $next -eq '*') {
      $i += 2
      while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) {
        $i++
      }
      $i += 2
      continue
    }

    if ($char -eq '''') {
      [void]$builder.Append(' ')
      $i++
      while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '''') {
          if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '''') {
            $i += 2
            continue
          }
          $i++
          break
        }
        $i++
      }
      continue
    }

    if ($char -eq '[') {
      [void]$builder.Append($char)
      $i++
      while ($i -lt $Text.Length) {
        [void]$builder.Append($Text[$i])
        if ($Text[$i] -eq ']') {
          $i++
          break
        }
        $i++
      }
      continue
    }

    [void]$builder.Append($char)
    $i++
  }

  return $builder.ToString()
}

function Test-SelectOnlyQuery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SqlText
  )

  $normalized = Remove-SqlCommentsAndLiterals -Text $SqlText
  $normalized = $normalized -replace '\s+', ' '
  $normalized = $normalized.Trim()

  if ([string]::IsNullOrWhiteSpace($normalized)) {
    throw "Query is empty after normalization."
  }

  if ($normalized -match ';') {
    throw "Multiple statements or statement terminators are not allowed."
  }

  if ($normalized -notmatch '^(?i)(select|with)\b') {
    throw "Only SELECT statements or CTEs that lead into SELECT are allowed."
  }

  $blockedKeywords = @(
    'insert', 'update', 'delete', 'drop', 'alter', 'create', 'merge',
    'truncate', 'exec', 'execute', 'grant', 'revoke', 'deny', 'backup',
    'restore', 'dbcc', 'use', 'upsert'
  )

  foreach ($keyword in $blockedKeywords) {
    if ($normalized -match ("(?i)\b{0}\b" -f [Regex]::Escape($keyword))) {
      throw "Blocked SQL keyword detected: $keyword"
    }
  }

  if ($normalized -match '(?i)\bselect\b.*\binto\b') {
    throw "SELECT INTO is not allowed."
  }

  return $true
}

function Get-ValidatedConnectionString {
  if (-not $ValidateOnly) {
    if ($PSCmdlet.ParameterSetName -eq "ConnectionString" -and [string]::IsNullOrWhiteSpace($ConnectionString)) {
      throw "Specify -ConnectionString or use -Server/-Database with authentication parameters."
    }

    if ($PSCmdlet.ParameterSetName -eq "Explicit" -and ([string]::IsNullOrWhiteSpace($Server) -or [string]::IsNullOrWhiteSpace($Database))) {
      throw "Specify -Server and -Database when not using -ConnectionString."
    }
  }

  if ($PSCmdlet.ParameterSetName -eq "ConnectionString") {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($ConnectionString)
  } else {
    if (-not $UseIntegratedSecurity.IsPresent -and [string]::IsNullOrWhiteSpace($Username)) {
      throw "Specify -Username/-Password or -UseIntegratedSecurity."
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $Server
    $builder["Initial Catalog"] = $Database
    $builder["Integrated Security"] = $UseIntegratedSecurity.IsPresent

    if (-not $UseIntegratedSecurity.IsPresent) {
      $builder["User ID"] = $Username
      $builder["Password"] = $Password
    }
  }

  $builder["Application Name"] = "CodexSqlServerSelectReadonly"
  $builder["ApplicationIntent"] = "ReadOnly"

  if (-not $builder.ContainsKey("Encrypt")) {
    $builder["Encrypt"] = $true
  }

  return $builder.ConnectionString
}

$sqlText = Get-QueryText
[void](Test-SelectOnlyQuery -SqlText $sqlText)

if ($ValidateOnly) {
  [PSCustomObject]@{
    valid = $true
    message = "Query passed SELECT-only validation."
  } | ConvertTo-Json -Depth 3
  exit 0
}

$validatedConnectionString = Get-ValidatedConnectionString
$connection = New-Object System.Data.SqlClient.SqlConnection($validatedConnectionString)

try {
  $connection.Open()
  $command = $connection.CreateCommand()
  $command.CommandText = $sqlText
  $command.CommandTimeout = $TimeoutSeconds

  $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
  $dataSet = New-Object System.Data.DataSet
  [void]$adapter.Fill($dataSet)

  if ($dataSet.Tables.Count -eq 0) {
    if ($AsJson) {
      '[]'
    } else {
      Write-Output "Query returned no result set."
    }
    exit 0
  }

  $table = $dataSet.Tables[0]

  if ($AsJson) {
    $rows = foreach ($row in $table.Rows) {
      $object = [ordered]@{}
      foreach ($column in $table.Columns) {
        $value = $row[$column.ColumnName]
        $object[$column.ColumnName] = if ($value -eq [System.DBNull]::Value) { $null } else { $value }
      }
      [PSCustomObject]$object
    }
    $rows | ConvertTo-Json -Depth 5
    exit 0
  }

  $table
} finally {
  if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
    $connection.Close()
  }
  $connection.Dispose()
}
