#!/bin/bash
# auto-approve-compound-git.sh — PermissionRequest hook
# Trigger: PermissionRequest
# Matcher: Bash
#
# Auto-approves compound git commands that the built-in permission
# system fails to match. The wildcard pattern Bash(git *) only matches
# simple commands like "git status" but not "cd src && git log" or
# "git add file.txt && git commit -m 'fix'".

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Must contain git to be relevant
echo "$COMMAND" | grep -qE '\bgit\b' || exit 0

HOOK_NAME="auto-approve-compound-git"
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

# Split on && ; || and check each part
# Only approve if EVERY component is a safe git command or cd
SAFE=true
while IFS= read -r part; do
  # Trim whitespace
  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$part" ] && continue

  # Strip leading KEY=val env assignments (e.g. GIT_DIR=/tmp git log)
  part=$(echo "$part" | sed 's/^[[:space:]]*\([A-Z_][A-Z_0-9]*=[^[:space:]]*[[:space:]]\)*//')
  [ -z "$part" ] && continue

  # Allow: cd, git (read ops), git add, git commit, git stash, git branch
  # git -C <dir> <cmd> form is also allowed
  if echo "$part" | grep -qE '^(cd |git (-C [^ ]+ )?(status|log|diff|show|branch|tag|stash|add|commit|fetch|pull|checkout|switch|restore|rebase|merge|cherry-pick|remote|config)( |$))'; then
    continue
  fi
  # Allow bare git with -C
  if echo "$part" | grep -qE '^git -C [^ ]+ (status|log|diff|show|branch|tag|stash|fetch|pull)$'; then
    continue
  fi
  # Allow simple git commands without args
  if echo "$part" | grep -qE '^git (status|log|diff|show|branch|tag|stash|fetch|pull)$'; then
    continue
  fi
  # Allow common output helpers used after pipes (head, tail, grep, wc, etc.)
  if echo "$part" | grep -qE '^(head|tail|grep|wc|sort|uniq|cat|echo|ls|awk|sed|cut|tr|column|jq)\b'; then
    continue
  fi
  # Allow: shell control-flow keywords and variable assignments
  if echo "$part" | grep -qE '^(do|done|fi|then|else|elif|esac)\b'; then continue; fi
  if echo "$part" | grep -qE '^(for |while |until |if |case )\b'; then continue; fi
  if echo "$part" | grep -qE '^[a-zA-Z_][a-zA-Z_0-9]*='; then continue; fi
  if echo "$part" | grep -qE '^(\)|"[^"]*")$'; then continue; fi
  # Any unrecognised command = not safe
  SAFE=false
  break
done < <(echo "$COMMAND" | tr '&' '\n' | tr ';' '\n' | tr '|' '\n')

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
