#!/bin/bash
# auto-approve-read-structural.sh — PermissionRequest hook
# Trigger: PermissionRequest
# Matcher: Read, Edit
#
# Approves Read/Edit calls whose file_path matches structurally predictable
# patterns that can't be expressed as static globs — specifically paths
# with variable slugs/hashes in intermediate segments:
#
#   ~/.ocak/worktree/<date-slug>/...          ocak worktree content
#   <project>/.claude/worktrees/agent-<hex>/  Claude-native agent worktrees
#   <project>/generated/(sdlc|layer0)/...     generated SDLC/layer0 dirs
#   ~/.ocak/archived_worktrees/<slug>/...      archived worktrees

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Expand ~ if present
FILE_PATH="${FILE_PATH/#\~/$HOME}"

HOOK_NAME="auto-approve-read-structural"
HASH=$(printf '%s' "$FILE_PATH" | sha256sum | cut -c1-16)
_HASHES="$HOME/.claude/permissionRequestHashes"
_LOCKD="$HOME/.claude/permissionRequestHashes.lock.d"
_NOW=$(date +%s)
_SEEN=false
if mkdir "$_LOCKD" 2>/dev/null; then
  awk -v h="$HASH" -v now="$_NOW" \
    'BEGIN{r=1} $1==h && (now-$2)<=5{r=0;exit} END{exit r}' \
    "$_HASHES" 2>/dev/null && _SEEN=true
  [ "$_SEEN" = "false" ] && printf '%s %s\n' "$HASH" "$_NOW" >> "$_HASHES"
  rmdir "$_LOCKD"
else
  _i=0
  while [ -d "$_LOCKD" ] && [ $_i -lt 10 ]; do sleep 0.01; _i=$((_i+1)); done
  awk -v h="$HASH" -v now="$_NOW" \
    'BEGIN{r=1} $1==h && (now-$2)<=5{r=0;exit} END{exit r}' \
    "$_HASHES" 2>/dev/null && _SEEN=true
fi
[ "$_SEEN" = "true" ] && exit 0

approve() {
  jq -nc --arg hook "$HOOK_NAME" --arg path "$FILE_PATH" --arg ts "$(date -u +%FT%TZ)" \
    '{hook:$hook,file_path:$path,ts:$ts}' >> ~/.claude/permissionDecisions.jsonl
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
  exit 0
}

# ocak worktree content — slug is YYYY-MM-DD-<name> or bare name like "adhoc"
# Covers: CLAUDE.md, sdlc/, misc/, assets/, session-reports/, scratch/
if echo "$FILE_PATH" | grep -qE "^$HOME/\.ocak/worktree/[^/]+/"; then
  approve "Allowed: ocak worktree file (variable date-slug prefix)"
fi

# ocak archived worktrees
if echo "$FILE_PATH" | grep -qE "^$HOME/\.ocak/archived_worktrees/[^/]+/"; then
  approve "Allowed: ocak archived worktree file"
fi

# Claude-native agent worktrees: <repo>/.claude/worktrees/agent-<hex>/...
# The agent hash is assigned at spawn time and not statically enumerable.
if echo "$FILE_PATH" | grep -qE "/.claude/worktrees/agent-[a-f0-9]+/"; then
  approve "Allowed: Claude-native agent worktree file (variable agent-hash prefix)"
fi

# Generated SDLC and layer0 dirs inside any project under ~/Dev
if echo "$FILE_PATH" | grep -qE "^$HOME/Dev/[^/]+/[^/]+/generated/(sdlc|layer0)/"; then
  approve "Allowed: generated SDLC/layer0 artifact (structural path)"
fi

# Nested generated dirs (one level deeper)
if echo "$FILE_PATH" | grep -qE "^$HOME/Dev/[^/]+/[^/]+/[^/]+/generated/(sdlc|layer0)/"; then
  approve "Allowed: generated SDLC/layer0 artifact (nested structural path)"
fi

exit 0
