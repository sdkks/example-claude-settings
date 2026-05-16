#!/bin/bash
# auto-approve-haiku-fallback.sh — PermissionRequest hook
# Trigger: PermissionRequest
# Matcher: Bash
#
# Two-stage fallback for commands not caught by earlier hooks:
#
# Stage 1 (structural): every segment must be a safe read-only / text-manipulation
#   tool, shell control-flow keyword, variable assignment, or a trusted script.
#   If any segment fails, stage 1 is skipped and we go straight to Haiku.
#
# Stage 2 (Haiku sanity check): asked a narrow question — "any credential/sensitive
#   path reads?" — not a general safety judgement. Responds allow or ask.
#
# The block-dangerous-commands PreToolUse hook is the real security gate and runs
# unconditionally after permission is granted. This hook only reduces friction for
# clearly benign commands.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

HOOK_NAME="auto-approve-haiku-fallback"
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

# --- Stage 1: structural check ---
# Strip redirections before splitting so "2>&1" doesn't produce a bare "1" token
CLEANED=$(echo "$COMMAND" | sed 's/2>&[0-9]//g; s/2>\/dev\/null//g; s/>[^&]*\/dev\/null//g')

STAGE1_PASSED=true
while IFS= read -r part; do
  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$part" ] && continue

  # Allow: bare integers and file descriptors left over from stripped redirections
  if echo "$part" | grep -qE '^[0-9]+$'; then continue; fi

  # Strip leading KEY=val env assignments (e.g. ENV=prod node server.js)
  part=$(echo "$part" | sed 's/^[[:space:]]*\([A-Z_][A-Z_0-9]*=[^[:space:]]*[[:space:]]\)*//')
  [ -z "$part" ] && continue

  # Allow: shell control-flow keywords and constructs
  if echo "$part" | grep -qE '^(do|done|fi|then|else|elif|esac)\b'; then continue; fi
  if echo "$part" | grep -qE '^(for |while |until |if |case )\b'; then continue; fi
  # Allow: array declarations and bare variable assignments
  if echo "$part" | grep -qE '^[a-zA-Z_][a-zA-Z_0-9]*='; then continue; fi
  if echo "$part" | grep -qE '^\)$'; then continue; fi
  # Allow: quoted strings that are array elements
  if echo "$part" | grep -qE '^"[^"]*"$'; then continue; fi

  # Allow: cd
  if echo "$part" | grep -qE '^cd(\s|$)'; then continue; fi

  # Allow: safe read-only / text tools (no write flags checked — block hook handles misuse)
  if echo "$part" | grep -qE '^(cat|head|tail|echo|ls|find|grep|rg|printf|stat|wc|sort|uniq|tee|tr|cut|paste|column|diff|comm|join|expand|unexpand|fold|fmt|nl|od|strings|md5sum|sha256sum|shasum|base64|iconv|file|which|realpath|dirname|basename|du|date|bc|expr|xargs|jq|python3|node|fnm|npx|npm|go|gofmt)\b'; then
    continue
  fi
  # Allow: curl/wget against localhost only
  if echo "$part" | grep -qE '^(curl|wget)\b' && echo "$part" | grep -qE '(https?://localhost|https?://127\.0\.0\.1|https?://\[::1\])'; then
    continue
  fi
  # Allow: natural-language annotation lines (no shell metacharacters — treated as inline comments)
  if echo "$part" | grep -qE '^[A-Z][a-zA-Z0-9 _,.()\-]*$'; then continue; fi

  STAGE1_PASSED=false
  break
done < <(echo "$CLEANED" | tr '&' '\n' | tr ';' '\n' | tr '|' '\n' | tr '\n' '\n')

# --- Stage 2: Haiku narrow sanity check ---
if [ "$STAGE1_PASSED" = "true" ]; then
  CONTEXT="A bash command has been structurally verified: every segment is a safe read-only or text-manipulation tool, shell control-flow keyword (for/while/if/do/done), or variable assignment."
else
  CONTEXT="A bash command could not be fully structurally verified (it contains compound constructs or commands beyond the simple allowlist). Review carefully."
fi

PROMPT="${CONTEXT} Your only task is to check for obviously dangerous patterns such as: writing to or reading from credential files or sensitive paths (~/.ssh, ~/.aws, ~/.gnupg, ~/.docker, ~/.kube, ~/.netrc, ~/.gitconfig, /etc/passwd, /etc/shadow, etc.), executing downloaded content, destructive file operations (rm -rf, overwrite), or privilege escalation. Do NOT refuse benign shell scripts, loops, or conditional logic.

Command: $(printf '%s' "$COMMAND" | head -c 800)

Reply with exactly one word: allow  OR  ask"

DECISION=$(claude -p --model haiku "$PROMPT" 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | grep -oE '\b(allow|ask|deny)\b' \
  | head -1)

if [ "$DECISION" = "allow" ]; then
  jq -nc --arg hook "$HOOK_NAME" --arg cmd "$COMMAND" --arg ts "$(date -u +%FT%TZ)" \
    '{hook:$hook,command:$cmd,ts:$ts}' >> ~/.claude/permissionDecisions.jsonl
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
fi

# ask / deny / empty → exit 0, fall through to user prompt
exit 0
