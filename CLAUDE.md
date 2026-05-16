# ~/.claude config repo

This is an **example** Claude Code configuration repo showing practical patterns for
auto-approval, tool hooks, multi-environment config, and disaster recovery.

## What's here

| Path | Purpose |
|------|---------|
| `settings.json.example` | Neutral baseline permissions (paths anonymized) |
| `common.jsonnet` | Shared config: hooks, statusLine, plugins, effort settings |
| `settings.work.jsonnet` | Work-specific overlay: Bedrock model, work plugins, marketplace |
| `settings.home.jsonnet` | Home-specific overlay: API key, skip auto-prompt |
| `hooks/` | Shell hooks wired into Claude Code via `settings.json` |
| `scripts/` | `auto-approve.ts`, `sanitize-settings.sh`, `restore-config.sh` |
| `config-mixer.json` | MCP server source definitions |
| `Makefile` | Entry point for safe config push workflow |

## Hook architecture

The hook system has two layers:

### PermissionRequest hooks (auto-approval)
Run when Claude requests a permission. They can auto-approve or let the prompt
fall through to the user.

| Hook | What it approves |
|------|-----------------|
| `auto-approve.ts` | **Two-stage Bash approval.** Stage 1: structural token allowlist. Stage 2: Haiku LLM classifies command categories. |
| `auto-approve-read-structural.sh` | Read/Edit paths with variable slugs (worktrees, generated dirs) |
| `auto-approve-compound-git.sh` | Compound git commands (`cd src && git log`) |
| `auto-approve-compound-go.sh` | Go toolchain compound commands |
| `auto-approve-compound-npm.sh` | npm/npx/node compound commands (excludes publish) |
| `auto-approve-compound-make.sh` | Make with allowlisted targets |
| `auto-approve-compound-awk-sed.sh` | awk/sed in pipelines (sed -i only on safe paths) |
| `auto-approve-haiku-fallback.sh` | Two-stage fallback for anything missed above |
| `log-permission-requests.sh` | Logs every request to `permissionPrompts.jsonl` |

### PreToolUse hooks (security gates)
Run after permission is granted but before execution. These are the actual
security boundary.

| Hook | What it blocks |
|------|---------------|
| `block-dangerous-commands.sh` | rm -rf /, sudo, force-push to main, curl-to-shell, env dumping |
| `block-sensitive-reads.sh` | Reading ~/.ssh, ~/.aws, ~/.gnupg, shell configs, /proc/*/environ |
| `log-tool-executions.sh` | Logs every execution to `toolExecutions.jsonl` |

### Other hooks

| Event | Hook |
|-------|------|
| SessionStart | Shows git branch, status, and recent commits |
| UserPromptSubmit | Updates terminal status line |
| Skill | Updates terminal status line |

## How auto-approve.ts works

The TypeScript hook is the workhorse for Bash commands. It has two stages:

**Stage 1 — Structural (instant, no API call):**
Parse the command into segments, check each command word against a set of ~100
safe tools (git, grep, npm, go, etc.), allow shell control-flow keywords and
variable assignments. curl/wget allowed only for localhost.

**Stage 2 — Haiku classifier (API call):**
If stage 1 can't identify every segment, asks Haiku to classify the command
into categories. Approves if all categories are safe (file-read, build, test,
text-transform, etc.). Tries Anthropic API → Bedrock → CLI fallback.

## Multi-environment setup

The config is split into three layers:

```
settings.json.example     ← neutral baseline (committed)
    + common.jsonnet      ← shared hooks, plugins, settings (committed)
    + settings.work.jsonnet  ← work: Bedrock, work plugins (committed)
    + settings.home.jsonnet  ← home: Anthropic API key (committed)
    = settings.json       ← full config (NEVER committed)
```

### Restore on a new machine

```bash
git clone <repo> ~/.claude
cd ~/.claude
ENVIRONMENT=home make restore-config
# → writes settings.json.recovered.home
# Fill in any <REDACTED> values (API keys, tokens)
mv settings.json.recovered.home settings.json
```

## Setting up hooks

Hooks are wired in `common.jsonnet` under `hooks.*`. Each hook is a
command that receives the tool input on stdin. Exit 0 = allow, exit 2 = block.

To add a new PermissionRequest hook:

1. Create the script in `hooks/`
2. Add it to `common.jsonnet` under `hooks.PermissionRequest[].hooks[]`
3. Run `make`

## Config mixer MCP server

`config-mixer-mcp.py` is an MCP server that lets the agent manage config
sources. Register it:

```bash
claude mcp add config-mixer -- python3 ~/.claude/scripts/config-mixer-mcp.py
```

Sources defined in `config-mixer.json` can be enabled/disabled by the agent.

## What is NOT committed

`settings.json`, history, sessions, cache, plugin runtime state — all in
`.gitignore`. Only the sanitized example and jsonnet overlays are committed.
