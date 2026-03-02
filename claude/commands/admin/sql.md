---
name: admin:sql
description: Manage SQL Server databases — query, deploy, provision, monitor. Works with local and remote instances.
argument-hint: "[connect|deploy|query|status|create-db|backup] [server-name] [options]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Task
  - TodoWrite
  - AskUserQuestion
  - mcp__mssql__query
  - mcp__mssql__execute
  - mcp__mssql__list_tables
  - mcp__mssql__describe_table
  - mcp__mssql__list_schemas
  - mcp__mssql__list_databases
  - mcp__mssql__get_table_indexes
  - mcp__mssql__get_table_constraints
  - mcp__mssql__get_stored_procedures
  - mcp__mssql__get_views
  - mcp__mssql__get_functions
  - mcp__powershell__run_powershell
---
<objective>
Manage SQL Server databases using the mssql MCP server and PowerShell. This skill provides persistent knowledge so Claude does not need to re-learn SQL Server management each session.

Route based on argument:
- **No argument / interactive**: Ask what the user wants to do
- **connect <server>**: Connect/switch to a SQL Server instance
- **deploy <dacpac-path>**: Deploy a DACPAC to a target database
- **query**: Enter interactive query mode
- **status**: Show server status, databases, and health
- **create-db <name>**: Create a new database
- **backup <db-name>**: Backup a database
</objective>

<context>
## MCP Server: mssql (@connorbritain/mssql-mcp-server)

Registered as `mssql` in Claude Code. Provides 20+ tools for schema discovery, data operations, profiling, and administration.

### Environment Variables (set before launching Claude Code or in MCP config)
```
SERVER_NAME=<hostname>           # e.g. localhost, dev-sql-01, server.database.windows.net
DATABASE_NAME=<database>         # e.g. MyApp_Alpha
SQL_AUTH_MODE=<sql|windows>      # sql = username/password, windows = integrated auth
SQL_USERNAME=<username>          # Only for sql auth
SQL_PASSWORD=<password>          # Only for sql auth
```

### Available MCP Tools (mcp__mssql__*)
| Tool | Purpose |
|------|---------|
| `list_databases` | List all databases on the server |
| `list_schemas` | List schemas in current database |
| `list_tables` | List tables (optionally filtered by schema) |
| `describe_table` | Get column definitions, types, nullability |
| `get_table_indexes` | Show indexes on a table |
| `get_table_constraints` | Show PKs, FKs, unique constraints |
| `get_stored_procedures` | List stored procedures |
| `get_views` | List views |
| `get_functions` | List user-defined functions |
| `query` | Execute a SELECT query (read-only) |
| `execute` | Execute INSERT/UPDATE/DELETE/DDL (with preview/confirm) |

### Governance Controls
- **allowedSchemas / deniedSchemas**: Restrict which schemas can be accessed
- **allowedTools / deniedTools**: Restrict which MCP tools are available
- **Audit logging**: All operations logged with session IDs
- **Safe mutations**: UPDATE/DELETE require preview then confirm

## PowerShell Fallback (for operations beyond MCP)

Use `mcp__powershell__run_powershell` for:

### Remote Database Creation
```powershell
Invoke-Sqlcmd -ServerInstance "dev-sql-01" -Query "CREATE DATABASE [MyApp_Alpha]" -TrustServerCertificate
```

### DACPAC Deployment
```powershell
# Deploy schema from DACPAC
SqlPackage /Action:Publish /SourceFile:"C:\deploy\MyApp.dacpac" /TargetServerName:"dev-sql-01" /TargetDatabaseName:"MyApp_Alpha" /p:BlockOnPossibleDataLoss=true
```

### Run SQL Script Files
```powershell
Invoke-Sqlcmd -ServerInstance "dev-sql-01" -Database "MyApp_Alpha" -InputFile "C:\scripts\seed-data.sql" -TrustServerCertificate
```

### Backup Database
```powershell
Invoke-Sqlcmd -ServerInstance "dev-sql-01" -Query "BACKUP DATABASE [MyApp_Alpha] TO DISK = 'C:\backups\MyApp_Alpha.bak' WITH INIT, COMPRESSION" -TrustServerCertificate
```

### Check Server Status
```powershell
# Test connectivity
Test-Connection -ComputerName "dev-sql-01" -TcpPort 1433 -Count 1

# Check database status
Invoke-Sqlcmd -ServerInstance "dev-sql-01" -Query "SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name" -TrustServerCertificate
```

### EF Core Migrations (if project uses Entity Framework)
```powershell
dotnet ef database update --connection "Server=dev-sql-01;Database=MyApp_Alpha;Trusted_Connection=true;TrustServerCertificate=true"
```
</context>

<process>
1. Parse the user's argument to determine the operation
2. If no argument, ask what they want to do using AskUserQuestion
3. For MCP tool operations (query, schema discovery), use the mcp__mssql__* tools directly
4. For provisioning operations (create DB, deploy DACPAC, backup), use mcp__powershell__run_powershell
5. Always confirm before destructive operations (DROP, DELETE, TRUNCATE)
6. Show results in a clean, formatted way
</process>

<critical_rules>
- NEVER drop or delete a production database without explicit user confirmation
- NEVER execute DROP, TRUNCATE, or DELETE without showing a preview first
- Always use TrustServerCertificate when connecting to dev/test servers
- For alpha/test deployments, always verify the target server name before proceeding
- If the MCP server is not connected, guide the user to set environment variables
- Prefer MCP tools over raw PowerShell when the MCP tool can do the job
</critical_rules>
