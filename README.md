# Example Claude Code Configuration

**This is an example repository — not a drop-in solution.** It demonstrates patterns
for auto-approval hooks, security gates, multi-environment config management, and
disaster recovery in Claude Code. You must review, customize, and test everything
before use.

> **⚠️ Use at your own risk.** These hooks execute arbitrary shell commands on your
> machine. They work in the author's environment but may not work in yours. Read every
> script before deploying it. No warranty, express or implied.

---

## Philosophy

Claude Code permission prompts are a speed bump. Every "allow this command?" dialog
breaks flow. The goal here is to eliminate prompts for safe operations while
maintaining a hard security boundary for dangerous ones.

The architecture has two layers:

1. **PermissionRequest hooks** — run first, can auto-approve or let the prompt fall
   through to the user. These reduce friction. They are NOT security boundaries.
2. **PreToolUse hooks** — run after permission is granted but before execution. These
   ARE the security boundary. They can block commands with exit code 2.

A command must survive both layers: be approved by a PermissionRequest hook AND not
blocked by a PreToolUse hook. This means we can be aggressive with auto-approval
knowing the PreToolUse gates will catch anything truly dangerous.

```
User asks Claude → Claude picks a tool call
                         │
                  PermissionRequest hooks
                   (can auto-approve or
                    let prompt through)
                         │
                    User prompt?
                   ┌─yes──┴──no──┐
               User decides   Auto-approved
                   │              │
                   └──────┬───────┘
                          │
                   PreToolUse hooks
                 (can block with exit 2
                  or allow with exit 0)
                          │
                   Tool executes
```

---

## What each file does

### Configuration

| File | Role |
|------|------|
| `settings.json.example` | Neutral permissions baseline. Paths use `/Users/macosuser/` placeholder — replace with your username. Grants broad `Bash`, `Read`, `Write`, `Edit` permissions in scoped directories. |
| `common.jsonnet` | Shared config merged into every environment: hooks, status line, plugins, effort settings. This is where you add new hooks. |
| `settings.work.jsonnet` | Work-specific overlay: Bedrock model, work plugins, work marketplace. Keep API tokens redacted. |
| `settings.home.jsonnet` | Home-specific overlay: Anthropic API key setup, `skipAutoPermissionPrompt`. |
| `config-mixer.json` | MCP server source definitions. The agent can enable/disable these at runtime via the config-mixer MCP server. |

### Hooks — PermissionRequest (auto-approval)

These run in sequence. The first one to output `hookSpecificOutput` with `decision: allow`
wins. If none output a decision, the user gets a prompt.

| Hook | What it approves | When it kicks in |
|------|-----------------|-----------------|
| `auto-approve.sh` | Delegates to `scripts/auto-approve.ts` | Every Bash request |
| `auto-approve-read-structural.sh` | Read/Edit paths with variable segments (worktrees, generated dirs) | Every Read/Edit request |
| `auto-approve-compound-git.sh` | Compound git commands (`cd src && git log`, `git add . && git commit`) | Commands containing `git` |
| `auto-approve-compound-go.sh` | Go toolchain compound commands | Commands containing `go`/`gofmt`/`golangci-lint` |
| `auto-approve-compound-npm.sh` | npm/npx/node commands (not publish/unpublish) | Commands containing `npm`/`npx`/`node` |
| `auto-approve-compound-make.sh` | Make with known-safe targets (build, test, lint, etc.) | Commands containing `make` |
| `auto-approve-compound-awk-sed.sh` | awk and sed in pipelines (sed -i only on safe paths) | Commands containing `awk`/`sed` |
| `auto-approve-haiku-fallback.sh` | Two-stage: structural check then Haiku LLM sanity check | Commands missed by all other hooks |
| `log-permission-requests.sh` | Logs every request to `permissionPrompts.jsonl` | Always (never approves, just logs) |

### `auto-approve.ts` in detail

This is the main Bash auto-approval engine. It has two stages:

**Stage 1 — Structural (instant, no API call):**
1. Parse the command into segments split by `&&`, `;`, `|`, `\n`
2. Strip `source .env` prefixes, redirections, heredocs
3. Check each segment's command word against a set of ~100 known-safe tools
4. Allow all shell control-flow keywords, variable assignments, local script paths
5. `curl`/`wget` only allowed for `localhost`/`127.0.0.1`/`[::1]`

If every segment passes → auto-approve. Otherwise → Stage 2.

**Stage 2 — Haiku classifier (API call, ~300ms):**
1. Send the command to a Haiku model with a classification prompt
2. Haiku returns categories like `["file-read", "text-transform"]`
3. If ALL categories are in the safe set → auto-approve
4. If any category is unsafe (`destructive`, `credential-access`, `privilege-escalation`, etc.) → skip (user gets prompted)

Tries three backends in order: Anthropic API → Bedrock (work) → `claude` CLI fallback.

**Deduplication:** A file-based sentinel (`permissionRequestHashes`) prevents
parallel hook invocations from calling Haiku for the same command. The first
instance claims the hash via `mkdir` lock, runs classification, and caches the
result. Other instances see the hash and skip.

### Hooks — PreToolUse (security gates)

These run AFTER permission is granted. They cannot auto-approve — they can only
allow (exit 0) or block (exit 2). Blocked commands return the reason to Claude
via stderr, and Claude can try a different approach.

| Hook | What it blocks | Trigger |
|------|---------------|---------|
| `block-dangerous-commands.sh` | rm -rf /, sudo, force-push to main, curl-to-shell, SQL DROP/TRUNCATE, fork bombs, chmod 777, env dumping via Python/Node/Ruby/Perl, reading credential dirs, disk formatting | Every Bash call |
| `block-sensitive-reads.sh` | Reading ~/.ssh, ~/.aws, ~/.gnupg, ~/.docker, ~/.kube, shell configs (bashrc, zshrc), /proc/*/environ, .npmrc, .pypirc | Every Read call |
| `log-tool-executions.sh` | Nothing (always passes) — logs every execution to `toolExecutions.jsonl` | Every Bash/Read/Write call |

### Hooks — Session lifecycle

| Hook | Event | What it does |
|------|-------|-------------|
| SessionStart | When a Claude Code session starts | Prints git branch, status, and last 5 commits |
| UserPromptSubmit | Before each user prompt is processed | Updates terminal status line via `ccstatusline` |
| Skill | When a skill is invoked | Updates terminal status line |

### Scripts

| Script | Purpose |
|--------|---------|
| `auto-approve.ts` | Bash auto-approval engine (described above) |
| `sanitize-settings.sh` | Reads `settings.json`, strips secrets/work/home sections, writes clean `settings.json.example` |
| `restore-config.sh` | Disaster recovery: merges `settings.json.example` + `common.jsonnet` + environment jsonnet → `settings.json.recovered.{work,home}` |

### Makefile

| Target | What it does |
|--------|-------------|
| `make commit-push` | Save config → sanitize → commit → push. Requires `ENVIRONMENT=work` or `ENVIRONMENT=home`. |
| `make sanitize` | Regenerate `settings.json.example` from live `settings.json` |
| `make restore-config` | Rebuild `settings.json.recovered.{ENVIRONMENT}` from committed layers |
| `make save-config` | Extract work or home config into the matching jsonnet file |

---

## How to use this (if you want to)

### 1. Read everything first

Every `.sh` and `.ts` file. Some have assumptions about directory layout
(`~/Dev/`, `~/.ocak/`) that won't match your setup.

### 2. Customize the paths

- `settings.json.example`: replace `/Users/macosuser/` with your username
- `auto-approve-read-structural.sh`: update or remove path patterns that don't apply
- `auto-approve-haiku-fallback.sh`: remove project-specific path references
- `settings.work.jsonnet`: replace example company plugins/marketplace with yours

### 3. Wire up the hooks

Hooks are configured in `common.jsonnet`. The structure is:

```json
"hooks": {
  "PermissionRequest": [
    {
      "matcher": "Bash",
      "hooks": [
        { "type": "command", "command": "~/.claude/hooks/some-hook.sh" }
      ]
    }
  ]
}
```

A `matcher` of `""` or `"*"` matches all tool types. Order matters — hooks run
in sequence for PermissionRequest (first approval wins) but all PreToolUse hooks
run and any can block.

### 4. Install the TypeScript dependency

```bash
npm install shell-quote
```

The `auto-approve.ts` script runs via `npx tsx`, which auto-installs if needed,
but `shell-quote` must be available.

### 5. Set up your environment

```bash
# In your shell profile (.zshrc / .bashrc):
export ENVIRONMENT=home   # or work
```

### 6. Restore and test

```bash
make restore-config
# Fill in any <REDACTED> values
mv settings.json.recovered.home settings.json
# Start Claude Code and watch the logs
tail -f ~/.claude/permissionDecisions.jsonl
```

---

## Safety properties

What this setup guarantees (if configured correctly):

- **Destructive commands are blocked** before execution, regardless of auto-approval
- **Credential files cannot be read** by the agent (shell configs, SSH keys, cloud creds)
- **Environment variables cannot be dumped** through any scripting language
- **Force-push to main/master is blocked**
- **curl/wget to external hosts must go through user prompt** (localhost only in structural stage)
- **sudo commands are blocked** from automated execution
- **Every tool call is logged** to `toolExecutions.jsonl` and `permissionPrompts.jsonl`
- **Auto-approval decisions are logged** with reason to `permissionDecisions.jsonl`

What this setup does NOT guarantee:

- **The agent can still `cat` any non-credential file on your system** (by design — it needs to read code)
- **The agent can still write to `~/Dev/` and `/tmp/`** (by design — it needs to edit code)
- **Haiku classification can have false positives** — a novel dangerous command might get approved
- **The compound hooks have gaps** — commands combining tools across domains may fall through to user prompt
- **This is not a sandbox** — the agent has the same filesystem access as your user account

---

## Customizing for your workflow

### Adding a new safe make target

Edit `auto-approve-compound-make.sh` and add your target to the allowlist:

```bash
if echo "$part" | grep -qE '^make (build|lint|test|your-target-here)(\s|$)'; then continue; fi
```

### Adding a new safe tool to structural approval

Edit `auto-approve.ts` and add the binary name to the `SAFE_TOOLS` Set.

### Adding a new structural read path

Edit `auto-approve-read-structural.sh` and add a new pattern block:

```bash
if echo "$FILE_PATH" | grep -qE "^$HOME/my-tool/data/[^/]+/"; then
  approve "Allowed: my-tool data files"
fi
```

### Blocking additional dangerous patterns

Edit `block-dangerous-commands.sh` and add a new check block following the
existing pattern. Use exit 2 to block, echo the reason to stderr.

---

## Logs and debugging

All logs are in `~/.claude/`:

| File | Contents |
|------|----------|
| `permissionPrompts.jsonl` | Every permission request (including those auto-approved) |
| `permissionDecisions.jsonl` | Which hook approved what, and why |
| `toolExecutions.jsonl` | Every tool call that executed |
| `permissionRequestHashes` | Deduplication sentinels for parallel hooks |

Watch decisions in real time:

```bash
tail -f ~/.claude/permissionDecisions.jsonl | jq '.'
```

## Self-auditing with Claude Code

The logging isn't just for manual inspection — you can ask Claude Code itself to
analyze the logs and suggest improvements. This is one of the best parts of the
setup: the agent audits its own permission system.

### Sample prompts

Copy and paste these into Claude Code after you've been using it for a few days:

**Audit auto-approval hit rate:**

> Read `~/.claude/permissionPrompts.jsonl` and `~/.claude/permissionDecisions.jsonl`
> from the last 3 days. Calculate: what percentage of Bash permission requests were
> auto-approved? What percentage went to user prompt? Break it down by hook — which
> hooks are doing the most work? Show the top 10 most common commands that fell
> through to user prompt (weren't auto-approved), and recommend whether any of them
> should be added to the structural allowlist in `scripts/auto-approve.ts` or
> covered by a new compound hook.

**Find approval gaps:**

> Analyze `~/.claude/permissionPrompts.jsonl` for the past week. Find all Bash
> commands that the user manually approved. For each one, classify whether it could
> have been auto-approved safely. Which commands repeat often? Suggest specific
> changes to the hooks — new safe tools to add, new compound patterns, or new
> structural paths — that would increase the auto-approval rate without weakening
> security.

**Review blocked commands:**

> Read `~/.claude/toolExecutions.jsonl` and grep stderr from recent sessions for
> "BLOCKED" messages from `block-dangerous-commands.sh`. Were any legitimate
> commands blocked? Are the block rules too aggressive or not aggressive enough?
> Also check `block-sensitive-reads.sh` blocks — did any block on a path that
> turned out to be safe? Recommend adjustments.

**Check for dangerous patterns that slipped through:**

> Cross-reference `~/.claude/toolExecutions.jsonl` against the block rules in
> `hooks/block-dangerous-commands.sh`. Find any executed Bash commands that
> matched patterns the block hook SHOULD have caught but didn't (maybe due to
> unexpected quoting, subshells, or command variants). Are there gaps in the
> regex patterns?

**Haiku classifier accuracy:**

> Read `~/.claude/permissionDecisions.jsonl` and filter for stage2 decisions
> (Haiku classifier). What categories does Haiku most often return? Are there
> commands where Haiku classified something as safe that you think is borderline?
> Are there commands Haiku refused that stage1 would have also refused (wasted
> API calls)? Recommend category additions or removals from the `SAFE_CATEGORIES`
> set in `auto-approve.ts`.

**Optimize the hook pipeline:**

> Look at all the compound auto-approve hooks (git, go, npm, make, awk-sed) and
> the haiku-fallback hook. Is there overlap? Could some hooks be merged? Are there
> hooks that never fire and can be removed? Check `permissionDecisions.jsonl` to
> see which hooks actually contribute approvals. Recommend a cleaner hook ordering.

### What this feedback loop looks like

```
    ┌──────────────────────────────┐
    │  Claude Code does work       │
    │  Hooks log every decision    │
    └──────────┬───────────────────┘
               │
    ┌──────────▼───────────────────┐
    │  Logs accumulate:            │
    │  - What was auto-approved    │
    │  - What needed user prompt   │
    │  - What was blocked          │
    └──────────┬───────────────────┘
               │
    ┌──────────▼───────────────────┐
    │  You ask Claude to audit     │
    │  the logs and suggest        │
    │  improvements                │
    └──────────┬───────────────────┘
               │
    ┌──────────▼───────────────────┐
    │  Claude edits the hooks      │
    │  - Adds safe tools           │
    │  - Tightens block patterns   │
    │  - Removes dead rules        │
    └──────────┬───────────────────┘
               │
               └──────→ back to work, fewer prompts
```

Over a few weeks of this cycle, the auto-approval rate should converge above 95%
for routine development work.

---

## License

MIT — see [LICENSE](./LICENSE) file.
