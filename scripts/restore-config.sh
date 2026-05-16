#!/usr/bin/env bash
#
# restore-config.sh
#
# Disaster-recovery restore. Reads ENVIRONMENT, copies settings.json.example to
# settings.json.recovered.work or settings.json.recovered.home, deep-merges the
# matching environment jsonnet on top, then tells you what secrets to fill in manually.
#
# Usage:
#   ENVIRONMENT=work make restore-config   → settings.json.recovered.work
#   ENVIRONMENT=home make restore-config   → settings.json.recovered.home
#
# Never overwrites settings.json.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$REPO_DIR/settings.json.example"
COMMON_JSONNET="$REPO_DIR/common.jsonnet"
WORK_JSONNET="$REPO_DIR/settings.work.jsonnet"
HOME_JSONNET="$REPO_DIR/settings.home.jsonnet"

if [ -z "${ENVIRONMENT:-}" ]; then
    echo "ERROR: ENVIRONMENT is not set. Set ENVIRONMENT=work or ENVIRONMENT=home." >&2
    exit 1
fi

if [ "$ENVIRONMENT" != "work" ] && [ "$ENVIRONMENT" != "home" ]; then
    echo "ERROR: ENVIRONMENT must be 'work' or 'home', got: '$ENVIRONMENT'" >&2
    exit 1
fi

RECOVERED="$REPO_DIR/settings.json.recovered.$ENVIRONMENT"

if [ "$ENVIRONMENT" = "work" ]; then
    JSONNET="$WORK_JSONNET"
else
    JSONNET="$HOME_JSONNET"
fi

if [ ! -f "$COMMON_JSONNET" ]; then
    echo "ERROR: $COMMON_JSONNET not found." >&2
    exit 1
fi

if [ ! -f "$JSONNET" ]; then
    echo "ERROR: $JSONNET not found." >&2
    exit 1
fi

cp "$EXAMPLE" "$RECOVERED"
echo "Copied $EXAMPLE → $RECOVERED"

python3 - "$RECOVERED" "$COMMON_JSONNET" "$JSONNET" "$ENVIRONMENT" <<'PYEOF'
import json, re, sys

REDACTED_PATTERN = re.compile(r'<REDACTED>')

def deep_merge(base, override):
    for k, v in override.items():
        if isinstance(v, dict) and k in base and isinstance(base[k], dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base

def load_jsonnet(path):
    with open(path) as f:
        lines = [line for line in f if not line.strip().startswith('//')]
    return json.loads('\n'.join(lines))

data = json.load(open(sys.argv[1]))
common = load_jsonnet(sys.argv[2])
overlay = load_jsonnet(sys.argv[3])
env = sys.argv[4]

deep_merge(data, common)
print(f'Merged {len(common)} common section(s) into {sys.argv[1]}')

deep_merge(data, overlay)
print(f'Merged {len(overlay)} {env} section(s) into {sys.argv[1]}')

json.dump(data, open(sys.argv[1], 'w'), indent=2)

# Report what still needs manual filling
redacted = []
def find_redacted(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            find_redacted(v, f'{path}.{k}' if path else k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            find_redacted(v, f'{path}[{i}]')
    elif isinstance(obj, str) and REDACTED_PATTERN.search(obj):
        redacted.append(path)

find_redacted(data)
if redacted:
    print()
    print(f'Fill in these redacted values before using {sys.argv[1]}:')
    for r in redacted:
        print(f'  {r}')
PYEOF

echo ""
echo "Review the change with semantic diff (dyff)"
echo "dyff between $REPO_DIR/settings.json $RECOVERED"
echo "Done. Review and rename when ready:"
echo "  mv -iv $RECOVERED $REPO_DIR/settings.json"
