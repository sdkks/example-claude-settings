#!/usr/bin/env bash
#
# save-home-config.sh
#
# Extracts home-specific settings from the live settings.json into
# settings.home.jsonnet: API key, skipAutoPermissionPrompt, non-Bedrock model.
#
# Usage: make save-home-config  (called by save-config when ENVIRONMENT=home)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$REPO_DIR/settings.json"
OUTPUT="$REPO_DIR/settings.home.jsonnet"

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found." >&2
    exit 1
fi

python3 - "$SETTINGS" "$OUTPUT" <<'PYEOF'
import json, re, sys

settings = json.load(open(sys.argv[1]))
output_path = sys.argv[2]

HOME_ENV_KEYS = {
    'ANTHROPIC_API_KEY',
}

home = {}

# skipAutoPermissionPrompt (home-only convenience)
if settings.get('skipAutoPermissionPrompt'):
    home['skipAutoPermissionPrompt'] = True

# Extract home env vars (redacted)
if 'env' in settings:
    home_env = {}
    for k, v in settings['env'].items():
        if k in HOME_ENV_KEYS:
            home_env[k] = '<REDACTED>'
    if home_env:
        home['env'] = home_env

# Non-Bedrock model (e.g. "sonnet")
if 'model' in settings and isinstance(settings['model'], str):
    if not re.match(r'^us\.anthropic\.', settings['model']):
        home['model'] = settings['model']

header = """\
// Home-specific config
// Restore with: make restore-config  (requires ENVIRONMENT=home)
// Fill in your API key before using.
"""

with open(output_path, 'w') as f:
    f.write(header + '\n')
    f.write(json.dumps(home, indent=2))
    f.write('\n')

print(f"Wrote {len(home)} keys to {output_path}")
PYEOF
