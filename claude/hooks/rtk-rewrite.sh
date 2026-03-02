#!/bin/bash
export PATH="$PATH:/c/Users/rjain/.cargo/bin"

# RTK PreToolUse hook — rewrites CLI commands to use rtk
# Read the input JSON from stdin
input=$(cat)

# Extract the command from the tool input
command=$(echo "$input" | sed -n 's/.*"command"\s*:\s*"\(.*\)".*/\1/p' | head -1)

# List of commands RTK can optimize
RTK_COMMANDS="git ls find grep cat head tail wc diff cargo npm npx pnpm node python pip pytest ruff dotnet go"

# Get the first word of the command
first_word=$(echo "$command" | awk '{print $1}')

# Check if this command should be rewritten
should_rewrite=false
for cmd in $RTK_COMMANDS; do
    if [ "$first_word" = "$cmd" ]; then
        should_rewrite=true
        break
    fi
done

if [ "$should_rewrite" = "true" ]; then
    # Output JSON that rewrites the command to use rtk
    new_command="rtk $command"
    cat << EOF
{"result":"replace","command":"$new_command"}
EOF
else
    # Pass through unchanged
    echo '{"result":"passthrough"}'
fi