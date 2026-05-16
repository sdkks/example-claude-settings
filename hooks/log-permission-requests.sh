#!/bin/bash
# log-permission-requests.sh — PermissionRequest hook
# Appends every permission request to ~/.claude/permissionPrompts.jsonl
# for later analysis. Always exits 0 (no approval decision).

INPUT=$(cat)
LOGFILE="$HOME/.claude/permissionPrompts.jsonl"

jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {logged_at: $ts}' <<< "$INPUT" >> "$LOGFILE" 2>/dev/null

exit 0
