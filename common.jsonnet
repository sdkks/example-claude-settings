// Common config shared across environments
// Merge with settings.json.example and your environment jsonnet to build settings.json
// Restore with: make restore-config

{
  "env": {
    "DISABLE_PROMPT_CACHING": "false"
  },
  "statusLine": {
    "type": "command",
    "command": "npx -y ccstatusline@2.2.12",
    "padding": 0
  },
  "awaySummaryEnabled": false,
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-permission-requests.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/auto-approve-read-structural.sh"
          }
        ]
      },
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-permission-requests.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/auto-approve-read-structural.sh"
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-permission-requests.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-permission-requests.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/scripts/auto-approve.ts"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-tool-executions.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/block-dangerous-commands.sh"
          }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-tool-executions.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/block-sensitive-reads.sh"
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-tool-executions.sh"
          }
        ]
      },
      {
        "matcher": "Skill",
        "hooks": [
          {
            "type": "command",
            "command": "npx -y ccstatusline@2.2.12 --hook"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo '=== Branch ===' && git branch --show-current && echo '=== Status ===' && git status -sb && echo '=== Recent Commits ===' && git log --oneline -5"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "npx -y ccstatusline@2.2.12 --hook"
          }
        ]
      }
    ]
  },
  "skillListingBudgetFraction": 0.03,
  "effortLevel": "high",
  "autoMemoryEnabled": false,
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "gopls-lsp@claude-plugins-official": true,
    "ruby-lsp@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true,
    "rust-analyzer-lsp@claude-plugins-official": true
  },
  "autoUpdatesChannel": "stable",
  "extraKnownMarketplaces": {},
  "syntaxHighlightingDisabled": false
}
