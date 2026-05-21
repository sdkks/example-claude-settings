#!/usr/bin/env bash
#
# save-common-config.sh
#
# Extracts common settings from the live settings.json into common.jsonnet.
# "Common" = everything that is shared across environments (hooks, statusLine,
# plugins from official marketplace, effort, etc.) — but NOT permissions (those
# stay in settings.json.example) and NOT environment-specific keys.
#
# Usage: make save-common-config  (called by save-config)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$REPO_DIR/settings.json"
OUTPUT="$REPO_DIR/common.jsonnet"

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found." >&2
    exit 1
fi

python3 - "$SETTINGS" "$OUTPUT" <<'PYEOF'
import json, sys

settings = json.load(open(sys.argv[1]))
output_path = sys.argv[2]

# Keys that belong in common.jsonnet (shared across work/home)
COMMON_KEYS = [
    'env',
    'statusLine',
    'awaySummaryEnabled',
    'hooks',
    'skillListingBudgetFraction',
    'effortLevel',
    'autoMemoryEnabled',
    'enabledPlugins',
    'autoUpdatesChannel',
    'extraKnownMarketplaces',
    'syntaxHighlightingDisabled',
]

# env keys that are environment-specific (excluded from common)
WORK_ENV_KEYS = {
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BEDROCK_BASE_URL',
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
}
HOME_ENV_KEYS = {
    'ANTHROPIC_API_KEY',
}

# Plugins that belong in environment overlays, not common
WORK_PLUGIN_PREFIXES = ['zendesk-claude-code-plugins', 'zendesk-claude-code']

common = {}
for key in COMMON_KEYS:
    if key in settings:
        common[key] = settings[key]

# Filter env: remove work/home-specific env vars
if 'env' in common and isinstance(common['env'], dict):
    common['env'] = {
        k: v for k, v in common['env'].items()
        if k not in WORK_ENV_KEYS and k not in HOME_ENV_KEYS
    }

# Filter enabledPlugins: keep only official/common plugins
if 'enabledPlugins' in common and isinstance(common['enabledPlugins'], dict):
    common['enabledPlugins'] = {
        k: v for k, v in common['enabledPlugins'].items()
        if not any(prefix in k for prefix in WORK_PLUGIN_PREFIXES)
    }

# Filter extraKnownMarketplaces: keep only non-work ones
if 'extraKnownMarketplaces' in common and isinstance(common['extraKnownMarketplaces'], dict):
    common['extraKnownMarketplaces'] = {
        k: v for k, v in common['extraKnownMarketplaces'].items()
        if not any(prefix in k for prefix in WORK_PLUGIN_PREFIXES)
    }

header = """\
// Common config shared across environments
// Merge with settings.json.example and your environment jsonnet to build settings.json
// Restore with: make restore-config
"""

with open(output_path, 'w') as f:
    f.write(header + '\n')
    f.write(json.dumps(common, indent=2))
    f.write('\n')

print(f"Wrote {len(common)} keys to {output_path}")
PYEOF
