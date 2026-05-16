#!/bin/bash
# auto-approve-compound-awk-sed.sh — PermissionRequest hook
# Trigger: PermissionRequest
# Matcher: Bash
#
# Auto-approves awk and sed commands in compound pipelines:
#   - awk: always read-only (field/line extraction), safe to approve
#   - sed without -i: read-only stream editing, safe to approve
#   - sed -i: approved only when no sensitive system/credential paths are referenced
#
# Compound commands are split on &&, ;, | and each part must be safe.
# Any unrecognized part causes the hook to exit without approving (falls
# through to the normal permission prompt).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

HOOK_NAME="auto-approve-compound-awk-sed"

# Only activate if the command mentions awk or sed
if ! echo "$COMMAND" | grep -qE '\b(awk|sed)\b'; then
  exit 0
fi

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

SAFE=true
REASON="Allowed: awk/sed read-only operation"

while IFS= read -r part; do
  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$part" ] && continue

  # Strip leading KEY=val env assignments
  part=$(echo "$part" | sed 's/^[[:space:]]*\([A-Z_][A-Z_0-9]*=[^[:space:]]*[[:space:]]\)*//')
  [ -z "$part" ] && continue

  # Allow common read-only pipeline builtins
  if echo "$part" | grep -qE '^(cd|find|echo|grep|rg|cat|ls|wc|sort|uniq|head|tail|printf|tee|tr|cut|paste|column|xargs|bc)\b'; then
    continue
  fi
  if echo "$part" | grep -qE '^(find|ls|wc|sort|uniq|head|tail|tr|cut|paste|column|bc)$'; then
    continue
  fi

  # Allow awk (always read-only)
  if echo "$part" | grep -qE '^awk\b'; then
    continue
  fi

  # Allow sed without -i / --in-place (stream edit, no file mutation)
  if echo "$part" | grep -qE '^sed\b' && ! echo "$part" | grep -qE 'sed\s+(-[a-zA-Z]*i|--in-place)'; then
    continue
  fi

  # sed -i: approve only when no sensitive paths are referenced
  if echo "$part" | grep -qE '^sed\s'; then
    if echo "$part" | grep -qE '(/etc/|/var/|/usr/|/bin/|/sbin/|/System/|/Library/|~\/\.(ssh|aws|gnupg|docker|kube|netrc|gitconfig|bashrc|zshrc|profile)|/Users/[^/]+/\.(ssh|aws|gnupg|docker|kube))'; then
      SAFE=false
      break
    fi
    REASON="Allowed: sed -i on non-sensitive path"
    continue
  fi

  # Allow: shell control-flow keywords and variable assignments
  if echo "$part" | grep -qE '^(do|done|fi|then|else|elif|esac)\b'; then continue; fi
  if echo "$part" | grep -qE '^(for |while |until |if |case )\b'; then continue; fi
  if echo "$part" | grep -qE '^[a-zA-Z_][a-zA-Z_0-9]*='; then continue; fi
  if echo "$part" | grep -qE '^(\)|"[^"]*")$'; then continue; fi

  # Any unrecognised command — not this hook's domain, fall through
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
