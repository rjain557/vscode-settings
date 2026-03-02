---
name: admin:help
description: Show available admin commands and usage guide
---
<objective>
Display the complete admin command reference.

Output ONLY the reference content below. Do NOT add:
- Project-specific analysis
- Git status or file context
- Next-step suggestions
- Any commentary beyond the reference
</objective>

<process>
Output the following reference exactly:

# Admin Commands Reference

## Available Commands

| Command | Description |
|---------|-------------|
| `/admin:sql` | Manage SQL Server databases — query, deploy, provision, monitor |
| `/admin:iis` | Manage IIS web servers — sites, app pools, deployments |
| `/admin:m365` | Manage Microsoft 365 — users, groups, SharePoint, Teams, Entra ID |
| `/admin:help` | Show this reference |

## Quick Examples

### SQL Server
```
/admin:sql connect dev-sql-01        # Connect to a SQL Server
/admin:sql status                    # Show databases and health
/admin:sql create-db MyApp_Alpha     # Create a new database
/admin:sql deploy MyApp.dacpac       # Deploy a DACPAC
/admin:sql query                     # Interactive query mode
```

### IIS
```
/admin:iis sites dev-web-01          # List sites on remote server
/admin:iis pools dev-web-01          # List app pools on remote server
/admin:iis create MyApp-Alpha        # Create a new website
/admin:iis deploy ./build dev-web-01 # Deploy app to remote IIS
/admin:iis recycle MyApp-Alpha       # Recycle an app pool
/admin:iis status dev-web-01         # Show server overview
```

### Microsoft 365
```
/admin:m365 login                    # Authenticate to M365 tenant
/admin:m365 status                   # Check login and tenant info
/admin:m365 users                    # User management
/admin:m365 groups                   # Group management
/admin:m365 sharepoint               # SharePoint administration
/admin:m365 teams                    # Teams administration
/admin:m365 entra                    # Entra ID / Azure AD admin
```

## Alpha Deployment Workflow

For deploying an alpha test environment (SQL + IIS):

1. `/admin:sql create-db` — Create the alpha database
2. `/admin:sql deploy` — Deploy schema (DACPAC or migrations)
3. `/admin:iis create` — Create IIS website + app pool
4. `/admin:iis deploy` — Deploy application files
5. `/admin:iis start` — Start the website

## MCP Servers Used

| Server | Package | Transport |
|--------|---------|-----------|
| `mssql` | @connorbritain/mssql-mcp-server | stdio |
| `iis` | mcp-server-iis (custom, remote-enabled) | SSE (localhost:5000) |
| `m365` | @pnp/cli-microsoft365-mcp-server | stdio |
| `powershell` | mcp-powershell-exec | stdio |

## Prerequisites

- **SQL**: Set SERVER_NAME, DATABASE_NAME, SQL_AUTH_MODE env vars
- **IIS**: Start the IIS MCP server: `dotnet run --project C:\Users\rjain\repos\mcp-server-iis\MCPServerIIS`
- **M365**: Run `m365 login` to authenticate first
</process>
