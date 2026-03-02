---
name: admin:iis
description: Manage IIS web servers — sites, app pools, deployments. Supports local and remote servers.
argument-hint: "[sites|pools|deploy|create|recycle|start|stop|status] [server-name] [options]"
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
  - mcp__iis__GetWebsites
  - mcp__iis__GetAppPools
  - mcp__iis__GetWorkerProcesses
  - mcp__iis__CreateWebsite
  - mcp__iis__StartWebsite
  - mcp__iis__StopWebsite
  - mcp__iis__StartAppPool
  - mcp__iis__StopAppPool
  - mcp__iis__RecycleIISAppPool
  - mcp__iis__GetProcessMemory
  - mcp__iis__Echo
  - mcp__powershell__run_powershell
---
<objective>
Manage IIS web servers using the custom mcp-server-iis (modified for remote support) and PowerShell. This skill provides persistent knowledge so Claude does not need to re-learn IIS management each session.

Route based on argument:
- **No argument / interactive**: Ask what the user wants to do
- **sites [server]**: List all websites on a server
- **pools [server]**: List all application pools on a server
- **deploy <path> [server]**: Deploy an application to IIS
- **create <site-name>**: Create a new website + app pool
- **recycle <pool-name> [server]**: Recycle an application pool
- **start <site-or-pool> [server]**: Start a website or app pool
- **stop <site-or-pool> [server]**: Stop a website or app pool
- **status [server]**: Show server overview (sites, pools, worker processes)
</objective>

<context>
## MCP Server: iis (mcp-server-iis — modified for remote support)

**Location:** `C:\Users\rjain\repos\mcp-server-iis`
**Transport:** SSE at `http://localhost:5000/sse`
**IMPORTANT:** The IIS MCP server must be running before use:
```bash
dotnet run --project C:\Users\rjain\repos\mcp-server-iis\MCPServerIIS
```

### Available MCP Tools

All tools accept an optional `serverName` parameter. When provided, connects to a remote IIS server. When omitted, targets local IIS.

| Tool | Parameters | Purpose |
|------|-----------|---------|
| `GetWebsites` | `serverName?` | List all sites with bindings, paths, state |
| `GetAppPools` | `serverName?` | List all app pools with state, runtime version |
| `GetWorkerProcesses` | `serverName?` | List w3wp worker processes |
| `CreateWebsite` | `websiteName, physicalPath, port, appPoolName?, serverName?` | Create new site + app pool |
| `StartWebsite` | `websiteName, serverName?` | Start a website |
| `StopWebsite` | `websiteName, serverName?` | Stop a website |
| `StartAppPool` | `appPoolName, serverName?` | Start an application pool |
| `StopAppPool` | `appPoolName, serverName?` | Stop an application pool |
| `RecycleIISAppPool` | `iisAppPoolName, serverName?` | Recycle (restart) an app pool |
| `GetProcessMemory` | `processId` | Get memory usage of a worker process |
| `Echo` | `message` | Test connectivity to MCP server |

### Remote Server Requirements
For remote IIS management to work:
1. **Web Management Service (WMSVC)** must be enabled on the remote server
2. Your account must have admin access on the target server
3. Windows Remote Management (WinRM) must be configured for PowerShell fallback
4. Firewall must allow connections on the management port (default 8172 for WMSVC)

## PowerShell Fallback (for operations beyond MCP tools)

Use `mcp__powershell__run_powershell` for advanced operations:

### Web Deploy (MSDeploy) — Full App Deployment
```powershell
# Deploy a web application package to remote IIS
msdeploy -verb:sync -source:package="C:\builds\MyApp.zip" -dest:auto,computerName="https://dev-web-01:8172/msdeploy.axd",username="admin",password="pass",authType="Basic" -allowUntrusted
```

### Remote IIS Management via PowerShell Remoting
```powershell
# List sites on remote server
Invoke-Command -ComputerName "dev-web-01" -ScriptBlock {
    Import-Module WebAdministration
    Get-Website | Select-Object Name, State, PhysicalPath, @{N='Bindings';E={$_.Bindings.Collection.BindingInformation -join '; '}}
}

# Create a new website remotely
Invoke-Command -ComputerName "dev-web-01" -ScriptBlock {
    Import-Module WebAdministration
    New-WebAppPool -Name "MyApp-Alpha"
    New-Website -Name "MyApp-Alpha" -PhysicalPath "C:\inetpub\myapp" -Port 8080 -ApplicationPool "MyApp-Alpha"
}

# Deploy files to remote server
Copy-Item -Path "C:\builds\MyApp\*" -Destination "\\dev-web-01\c$\inetpub\myapp\" -Recurse -Force

# Restart site after deployment
Invoke-Command -ComputerName "dev-web-01" -ScriptBlock {
    Import-Module WebAdministration
    Restart-WebAppPool -Name "MyApp-Alpha"
}
```

### Check IIS Health
```powershell
# Check if IIS is running on remote server
Invoke-Command -ComputerName "dev-web-01" -ScriptBlock {
    Get-Service W3SVC | Select-Object Name, Status, StartType
}

# Check site response
Invoke-WebRequest -Uri "http://dev-web-01:8080/health" -UseBasicParsing -TimeoutSec 10
```

### SSL Certificate Management
```powershell
Invoke-Command -ComputerName "dev-web-01" -ScriptBlock {
    Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.NotAfter -gt (Get-Date) } | Select-Object Thumbprint, Subject, NotAfter
}
```

## Alpha Deployment Workflow (SQL + IIS Together)

Typical workflow for deploying an alpha environment:
1. `/admin:sql create-db` — Create the alpha database on dev SQL server
2. `/admin:sql deploy` — Deploy DACPAC or run migration scripts
3. `/admin:iis create` — Create IIS website + app pool on dev web server
4. Update `web.config` or `appsettings.json` with database connection string
5. Deploy application files to the IIS physical path
6. `/admin:iis start` — Start the site
7. Verify the application is responding
</context>

<process>
1. Parse the user's argument to determine the operation
2. If no argument, ask what they want to do using AskUserQuestion
3. Check if the IIS MCP server is needed and guide user to start it if not running
4. For MCP tool operations (list sites/pools, create, start/stop, recycle), use mcp__iis__* tools
5. For deployment and advanced operations, use mcp__powershell__run_powershell
6. When targeting remote servers, always include the serverName parameter
7. Always confirm before stopping sites or creating new ones
</process>

<critical_rules>
- NEVER stop a production website without explicit user confirmation
- NEVER delete a website or app pool without explicit user confirmation
- Always verify the target server name before remote operations
- When creating websites, confirm the physical path exists on the target server
- When deploying, always recycle the app pool after file copy to pick up changes
- If the IIS MCP server is not responding, guide the user to start it with: dotnet run --project C:\Users\rjain\repos\mcp-server-iis\MCPServerIIS
- For remote operations, if MCP tools fail, fall back to PowerShell remoting
</critical_rules>
