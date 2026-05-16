#!/bin/bash
# block-dangerous-commands.sh
# PreToolUse hook: blocks dangerous bash commands before execution.
# Exit 2 = block the action (reason sent to Claude via stderr).
# Exit 0 = allow the action to proceed.
#
# This is the security gate — it runs after permission is granted.
# Covers: destructive file ops, disk formatting, chmod 777, curl-to-shell,
# force-push to main/master, git reset --hard, broad sudo, env dumping, etc.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash tool calls
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- Destructive file operations ---
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?(/|~|\$HOME|\.\./)' && \
   ! echo "$COMMAND" | grep -qE 'rm\s+-f\s+/tmp/.+'; then
  echo "BLOCKED: Destructive rm targeting root, home, or parent directory" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f|rm\s+-[a-zA-Z]*f[a-zA-Z]*r'; then
  # Allow rm -rf on clearly scoped paths (tmp, build artifacts, node_modules, etc.)
  if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(\./)?(tmp|dist|build|node_modules|\.next|__pycache__|\.pytest_cache|\.mypy_cache|coverage|\.cache)\b'; then
    exit 0
  fi
  # Block rm -rf without a clearly scoped target
  if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|\*|~|\.\.|\.?\s*$)'; then
    echo "BLOCKED: Broad rm -rf without a scoped target path" >&2
    exit 2
  fi
fi

# --- Destructive system commands ---
if echo "$COMMAND" | grep -qE 'mkfs\.|dd\s+if='; then
  echo "BLOCKED: Disk formatting / raw disk write commands" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'chmod\s+.*777'; then
  echo "BLOCKED: chmod 777 is a security risk" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE '>\s*/dev/sd|>\s*/dev/nvme|>\s*/dev/disk'; then
  echo "BLOCKED: Writing directly to block devices" >&2
  exit 2
fi

# --- Pipe to shell (curl/wget piped to bash/sh) ---
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*(sudo\s+)?(ba)?sh'; then
  echo "BLOCKED: Piping downloaded content directly to shell — download first, review, then execute" >&2
  exit 2
fi

# --- SQL destructive operations ---
if echo "$COMMAND" | grep -qiE '(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b'; then
  echo "BLOCKED: Destructive SQL operation (DROP/TRUNCATE)" >&2
  exit 2
fi

# --- Fork bomb ---
if echo "$COMMAND" | grep -qE ':\(\)\{.*\|.*&\}'; then
  echo "BLOCKED: Fork bomb detected" >&2
  exit 2
fi

# --- Kill all / killall with broad scope ---
if echo "$COMMAND" | grep -qE 'kill\s+-9\s+-1|killall\s+-9'; then
  echo "BLOCKED: Broad kill -9 / killall -9 can terminate critical processes" >&2
  exit 2
fi

# --- Destructive git operations ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force(-with-lease)?\s+.*\b(main|master)\b'; then
  echo "BLOCKED: Force push to main/master — this rewrites shared history" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'git\s+push\s+--force(-with-lease)?\s*$'; then
  echo "BLOCKED: Force push without explicit remote/branch — specify the target" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  echo "BLOCKED: git reset --hard destroys uncommitted work" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
  echo "BLOCKED: git clean -f deletes untracked files permanently" >&2
  exit 2
fi

# --- Broad sudo ---
if echo "$COMMAND" | grep -qE '(^|\||;|&&)\s*sudo\s+'; then
  echo "BLOCKED: sudo from automated agent — run privileged commands manually" >&2
  exit 2
fi

# --- Critical file truncation ---
if echo "$COMMAND" | grep -qE '>\s*(~/|/etc/|/var/|\$HOME/)'; then
  echo "BLOCKED: Truncating/overwriting files in home, /etc, or /var" >&2
  exit 2
fi

# --- Moving/copying over critical dotfiles or system config ---
if echo "$COMMAND" | grep -qE '(mv|cp)\s+.*\s+(~/\.(ssh|gnupg|bashrc|zshrc|gitconfig)|/etc/)'; then
  echo "BLOCKED: Overwriting critical dotfiles or system config" >&2
  exit 2
fi

# --- Reading sensitive credential directories ---
if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|grep|rg|bat|strings|xxd|base64|cp|tar|zip|scp)\s+.*(\$HOME|~|/Users/\w+)/\.(aws|docker|kube|gcloud|ssh|gnupg|config/gh|netrc)'; then
  echo "BLOCKED: Reading from sensitive credential directory" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'ls\s+(-[a-zA-Z]*\s+)*(\$HOME|~|/Users/\w+)/\.(aws|docker|kube|gcloud|ssh|gnupg|config/gh)'; then
  echo "BLOCKED: Listing sensitive credential directory contents" >&2
  exit 2
fi

# --- Dumping environment variables ---
if echo "$COMMAND" | grep -qE '(^|\||;|&&)\s*(env|printenv|export\s*$|export\s+-p|set\s*$)\b'; then
  echo "BLOCKED: Dumping environment variables may expose secrets" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'printenv\s+\w'; then
  echo "BLOCKED: Reading environment variable via printenv" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'echo\s+.*\$(GITHUB_TOKEN|GH_TOKEN|AWS_SECRET|AWS_ACCESS_KEY|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|NPM_TOKEN|DOCKER_PASSWORD|SSH_KEY|SECRET|PASSWORD|CREDENTIAL)'; then
  echo "BLOCKED: Echoing sensitive environment variable" >&2
  exit 2
fi

# --- Reading /proc for environment/secrets ---
if echo "$COMMAND" | grep -qE '/proc/[^/]*/environ|/proc/self/environ|/proc/[^/]*/cmdline|/proc/self/cmdline'; then
  echo "BLOCKED: Reading process environment/cmdline from /proc" >&2
  exit 2
fi

# --- Dumping env via scripting languages ---
if echo "$COMMAND" | grep -qE 'python[23]?\s+.*os\.environ|python[23]?\s+-c\s+.*environ'; then
  echo "BLOCKED: Dumping environment variables via Python" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'node\s+.*process\.env|node\s+-e\s+.*process\.env'; then
  echo "BLOCKED: Dumping environment variables via Node.js" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'ruby\s+.*ENV|ruby\s+-e\s+.*ENV'; then
  echo "BLOCKED: Dumping environment variables via Ruby" >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'perl\s+.*%ENV|perl\s+-e\s+.*%ENV'; then
  echo "BLOCKED: Dumping environment variables via Perl" >&2
  exit 2
fi

# All checks passed
exit 0
