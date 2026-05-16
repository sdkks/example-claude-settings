#!/bin/bash
# block-sensitive-reads.sh
# PreToolUse hook for Read tool: blocks reads of sensitive credential files.
# Exit 2 = block the action (reason sent to Claude via stderr).
# Exit 0 = allow the action to proceed.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Read" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if echo "$FILE_PATH" | grep -qE '(^|/)\.(aws|docker|kube|gcloud|ssh|gnupg|config/gh|netrc)(/|$)'; then
  echo "BLOCKED: Reading file from sensitive credential directory" >&2
  exit 2
fi

if echo "$FILE_PATH" | grep -qE '^/proc/[^/]*/environ$|^/proc/self/environ$|^/proc/[^/]*/cmdline$|^/proc/self/cmdline$'; then
  echo "BLOCKED: Reading process environment/cmdline from /proc" >&2
  exit 2
fi

if echo "$FILE_PATH" | grep -qE '(^|/)\.(zshenv|zshrc|bash_profile|bashrc|profile|config/fish)(/|$)'; then
  echo "BLOCKED: Reading shell config (may contain exported secrets)" >&2
  exit 2
fi

if echo "$FILE_PATH" | grep -qE '(^|/)\.(npmrc|pypirc)$'; then
  echo "BLOCKED: Reading package registry credential file" >&2
  exit 2
fi

exit 0
