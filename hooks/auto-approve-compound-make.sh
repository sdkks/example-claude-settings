#!/bin/bash
# auto-approve-compound-make.sh — PermissionRequest hook
# Trigger: PermissionRequest
# Matcher: Bash
#
# Approves compound commands containing make with known-safe targets.
# Allowlisted targets only — bare "make" and destructive targets are excluded.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

HOOK_NAME="auto-approve-compound-make"

# Must actually contain make to be relevant
echo "$COMMAND" | grep -qE '\bmake\b' || exit 0

HASH=$(printf '%s' "$COMMAND" | sha256sum | cut -c1-16)
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

# Reject if heredoc or rm present anywhere
echo "$COMMAND" | grep -qE '<<|[[:space:]]rm[[:space:]]|[[:space:]]rm$|\brm -' && exit 0

# Strip common redirections before splitting
CLEANED=$(echo "$COMMAND" | sed 's/2>&[0-9]//g; s/2>\/dev\/null//g; s/>[^&]*\/dev\/null//g')

SAFE=true
while IFS= read -r part; do
  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$part" ] && continue

  # Strip leading KEY=val env assignments (e.g. DEBUG=1 make test)
  part=$(echo "$part" | sed 's/^[[:space:]]*\([A-Z_][A-Z_0-9]*=[^[:space:]]*[[:space:]]\)*//')
  [ -z "$part" ] && continue

  # Allow: cd, allowlisted make targets, git read-ops, output helpers
  if echo "$part" | grep -qE '^cd '; then continue; fi
  if echo "$part" | grep -qE '^make (build|lint|test|test-all|test-e2e|test-unit|test-integration|docs|run|check|sanitize|check-pins|site|clean-scratch|generate|fmt|vet|tidy|install|deps|vendor)(\s|$)'; then continue; fi
  if echo "$part" | grep -qE '^git (status|log|diff|show|stash)(\s|$)'; then continue; fi
  if echo "$part" | grep -qE '^(echo |ls |head |tail |grep |cat |wc |true$|false$|[0-9]+$)'; then continue; fi
  if echo "$part" | grep -qE '^(true|false|echo|ls|head|tail|grep|wc)$'; then continue; fi
  # Allow: shell control-flow keywords and variable assignments
  if echo "$part" | grep -qE '^(do|done|fi|then|else|elif|esac)\b'; then continue; fi
  if echo "$part" | grep -qE '^(for |while |until |if |case )\b'; then continue; fi
  if echo "$part" | grep -qE '^[a-zA-Z_][a-zA-Z_0-9]*='; then continue; fi
  if echo "$part" | grep -qE '^(\)|"[^"]*")$'; then continue; fi

  SAFE=false
  break
done < <(echo "$CLEANED" | tr '&' '\n' | tr ';' '\n' | tr '|' '\n')

if [ "$SAFE" = "true" ]; then
  jq -nc --arg hook "$HOOK_NAME" --arg cmd "$COMMAND" --arg ts "$(date -u +%FT%TZ)" \
    '{hook:$hook,command:$cmd,ts:$ts}' >> ~/.claude/permissionDecisions.jsonl
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
fi

exit 0
