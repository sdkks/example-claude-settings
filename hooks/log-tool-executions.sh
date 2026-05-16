#!/bin/bash
# log-tool-executions.sh — PreToolUse hook
# Appends every tool execution (permission granted) to ~/.claude/toolExecutions.jsonl
# Cross-reference with permissionPrompts.jsonl to identify denied requests.

INPUT=$(cat)
LOGFILE="$HOME/.claude/toolExecutions.jsonl"

jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {logged_at: $ts}' <<< "$INPUT" >> "$LOGFILE" 2>/dev/null

exit 0
