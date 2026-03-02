#!/usr/bin/env python3
"""RTK PreToolUse hook - rewrites CLI commands to use rtk for token savings."""
import json
import sys
import os

# Add rtk to PATH
os.environ["PATH"] = os.environ.get("PATH", "") + os.pathsep + os.path.join(os.path.expanduser("~"), ".cargo", "bin")

# Commands RTK can optimize
RTK_COMMANDS = {
    "git", "ls", "find", "grep", "cat", "head", "tail", "wc", "diff",
    "cargo", "npm", "npx", "pnpm", "node", "python", "pip", "pytest",
    "ruff", "dotnet", "go", "golangci-lint", "docker", "kubectl",
}

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if input_data.get("tool_name") != "Bash":
    sys.exit(0)

command = input_data.get("tool_input", {}).get("command", "")

# Skip if already using rtk, is a heredoc, or is empty
if not command or command.startswith("rtk ") or "<<" in command:
    sys.exit(0)

# Get the first word of the command (handle pipes, semicolons, etc.)
first_word = command.strip().split()[0] if command.strip() else ""

# Strip any path prefix (e.g., /usr/bin/git -> git)
base_cmd = first_word.rsplit("/", 1)[-1] if "/" in first_word else first_word

if base_cmd in RTK_COMMANDS:
    new_command = "rtk " + command
    result = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"RTK rewrite: {base_cmd} -> rtk {base_cmd}",
            "updatedInput": {
                "command": new_command
            }
        }
    }
    print(json.dumps(result))
    sys.exit(0)

# Not an RTK command, pass through
sys.exit(0)