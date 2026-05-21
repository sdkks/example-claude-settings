#!/usr/bin/env bash
#
# save-work-config.sh
#
# Extracts work-specific settings from the live settings.json into
# settings.work.jsonnet: work plugins, work marketplace, Bedrock env vars,
# and the Bedrock model.
#
# Usage: make save-work-config  (called by save-config when ENVIRONMENT=work)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$REPO_DIR/settings.json"
OUTPUT="$REPO_DIR/settings.work.jsonnet"

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found." >&2
    exit 1
fi

python3 - "$SETTINGS" "$OUTPUT" <<'PYEOF'
import json, re, sys

settings = json.load(open(sys.argv[1]))
output_path = sys.argv[2]

SENSITIVE_PATTERN = re.compile(r'TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL', re.IGNORECASE)

WORK_ENV_KEYS = {
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BEDROCK_BASE_URL',
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
}

# Plugin namespaces that are work-specific
WORK_PLUGIN_PREFIXES = ['zendesk-claude-code-plugins', 'zendesk-claude-code']

work = {}

# Extract work plugins
if 'enabledPlugins' in settings:
    work_plugins = {
        k: v for k, v in settings['enabledPlugins'].items()
        if any(prefix in k for prefix in WORK_PLUGIN_PREFIXES)
    }
    if work_plugins:
        work['enabledPlugins'] = work_plugins

# Extract work marketplaces
if 'extraKnownMarketplaces' in settings:
    work_markets = {
        k: v for k, v in settings['extraKnownMarketplaces'].items()
        if any(prefix in k for prefix in WORK_PLUGIN_PREFIXES)
    }
    if work_markets:
        work['extraKnownMarketplaces'] = work_markets

# Extract work env vars (redact sensitive ones)
if 'env' in settings:
    work_env = {}
    for k, v in settings['env'].items():
        if k in WORK_ENV_KEYS:
            if SENSITIVE_PATTERN.search(k):
                work_env[k] = '<REDACTED>'
            else:
                work_env[k] = v
    if work_env:
        work['env'] = work_env

# Extract Bedrock model
if 'model' in settings and isinstance(settings['model'], str):
    if re.match(r'^us\.anthropic\.', settings['model']):
        work['model'] = settings['model']

header = """\
// Work-specific config example
// Restore with: make restore-config  (requires ENVIRONMENT=work)
// Shows how to add work-specific plugins, marketplaces, and Bedrock config.
// Replace <REDACTED> values with your actual credentials.
"""

with open(output_path, 'w') as f:
    f.write(header + '\n')
    f.write(json.dumps(work, indent=2))
    f.write('\n')

print(f"Wrote {len(work)} keys to {output_path}")
PYEOF
