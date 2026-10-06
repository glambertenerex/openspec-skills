---
name: sqlserver-select-readonly
description: Safely query Microsoft SQL Server with strict read-only guardrails. Use when Codex needs to inspect SQL Server data, validate assumptions against live records, compare configuration rows, or investigate schema/data issues without modifying the database. This skill is only for SELECT-style reads and must reject INSERT, UPDATE, DELETE, DROP, ALTER, CREATE, MERGE, EXEC, TRUNCATE, and other non-read operations.
---

# SQL Server Select Readonly

## Overview

Use this skill when Codex needs read-only access to SQL Server data during investigation, debugging, or implementation support. The bundled script validates the SQL before execution, forces `ApplicationIntent=ReadOnly`, and should be used with a SQL login that also has database-level read-only permissions.

## Workflow

1. Confirm the query is genuinely investigative and does not need writes.
2. Prefer a dedicated read-only login or a non-production environment.
3. Run `scripts/run-select-query.ps1` with either:
   - `-ConnectionString`, or
   - `-Server`, `-Database`, and authentication parameters.
4. Pass the SQL with `-Query` or `-QueryFile`.
5. Use `-ValidateOnly` first when the query is new or risky.
6. If the script rejects the query, do not weaken the guardrail. Rewrite the query as a pure read.

## Quick Start

Validate a query without connecting:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-select-query.ps1 `
  -Query "SELECT TOP (10) * FROM dbo.Users" `
  -ValidateOnly
```

Run a query with a connection string:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-select-query.ps1 `
  -ConnectionString "Server=sql01;Database=AppDb;User Id=readonly_user;Password=***;Encrypt=True;TrustServerCertificate=True" `
  -Query "SELECT TOP (10) Id, Name FROM dbo.Users ORDER BY Id DESC" `
  -AsJson
```

Run with explicit parameters:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-select-query.ps1 `
  -Server "sql01" `
  -Database "AppDb" `
  -Username "readonly_user" `
  -Password "***" `
  -QueryFile ".\\query.sql"
```

## Guardrails

- Only run this skill for read-only investigation.
- Do not bypass the validator with ad hoc SQL tools when this skill is the chosen path.
- Do not use privileged SQL logins. The script validation is defense in depth, not the primary security boundary.
- Do not allow multi-statement batches.
- Do not allow `SELECT INTO`.
- Reject any query containing write or DDL verbs after normalization.
- If the environment blocks `System.Data.SqlClient`, stop and report the blocker instead of improvising a less safe path.

## Script

Use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-select-query.ps1 ...
```

Parameters:

- `-Query` or `-QueryFile`: required, exactly one
- `-ConnectionString`: optional, mutually exclusive with explicit server/auth parameters
- `-Server`, `-Database`: required when `-ConnectionString` is not used
- `-Username`, `-Password`: SQL authentication
- `-UseIntegratedSecurity`: Windows auth
- `-AsJson`: output rows as JSON
- `-TimeoutSeconds`: command timeout
- `-ValidateOnly`: validate SQL without connecting

## Output Expectations

- Return query results only after validation passes.
- Prefer `-AsJson` when the result will be consumed by other automation.
- Keep result sets small with `TOP`, selective columns, and predicates whenever practical.
