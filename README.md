# VSCode, Claude Code & Codex Settings

Personal development environment configuration for VSCode, Claude Code, OpenAI Codex, and the GSD (Get Shit Done) workflow framework.

## Structure

```
claude/                          # ~/.claude/ global settings
  CLAUDE.md                      # Global Claude Code instructions (RTK)
  settings.json                  # Permissions, hooks, plugins, MCP servers
  settings.local.json            # Project-local permission overrides
  gsd-file-manifest.json         # GSD plugin manifest
  agents/                        # 21 custom agent definitions
  commands/
    gsd/                         # 57 GSD slash commands
    admin/                       # 4 admin commands (IIS, SQL, M365)
  hooks/                         # Session hooks (RTK rewrite, GSD statusline)
  scripts/                       # PowerShell automation (gsd-runner)
  get-shit-done/                 # GSD framework
    bin/                         # CLI tools
    references/                  # Reference docs (git, checkpoints, TDD)
    templates/                   # Project/phase/summary templates
    workflows/                   # Workflow definitions (50+ workflows)
    VERSION                      # GSD version

codex/                           # ~/.codex/ global settings
  config.toml                    # Model, personality, MCP servers, trust
  instructions.md                # Global instructions (GSD convergence engine)
  version.json                   # Codex version info
  agents/                        # 10 agent definitions (GSD + SDLC)
  commands/gsd/                  # 55 GSD slash commands
  rules/                         # Default rules (project patterns, compliance)
  skills/                        # 68 skills (GSD, SDLC, Playwright)
  scripts/                       # PowerShell automation (runners, watchdogs)
  get-shit-done/workflows/       # 17 GSD workflow definitions

vscode/                          # %APPDATA%/Code/User/ settings
  settings.json                  # VSCode user settings
  keybindings.json               # Custom keybindings
  tasks.json                     # Task runner configuration
  mcp.json                       # MCP server configuration
```

## Installation

Copy files to their respective locations:

```powershell
# Claude Code settings
Copy-Item -Recurse claude/* ~/.claude/

# Codex settings
Copy-Item -Recurse codex/* ~/.codex/

# VSCode settings
Copy-Item -Recurse vscode/* "$env:APPDATA/Code/User/"
```

## Key Components

- **GSD Framework**: Project management workflow with research, planning, and execution phases
- **RTK (Rust Token Killer)**: Token optimization for Claude Code CLI commands
- **SDLC v6.0**: AI-native software development lifecycle agents and validators
- **Admin Commands**: IIS, SQL Server, and M365 management via Claude Code
- **Codex Integration**: OpenAI Codex CLI with GSD skills, agents, and convergence engine
