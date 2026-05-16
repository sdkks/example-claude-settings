#!/usr/bin/env bash
#
# sanitize-settings.sh
#
# Reads settings.json from STDIN and writes a neutral settings.json.example to STDOUT.
# Strips ALL environment-specific items (both work and home) so the example is a
# clean shared baseline safe to commit publicly.
#
# Stripped:
#   work: work-specific plugins, work marketplace, Bedrock env vars
#         (ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BEDROCK_BASE_URL,
#          CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_SKIP_BEDROCK_AUTH),
#         Bedrock model (us.anthropic.*)
#   home: ANTHROPIC_API_KEY, skipAutoPermissionPrompt, model "sonnet"
#   common: hooks, statusLine, skillListingBudgetFraction, syntaxHighlightingDisabled,
#           effortLevel, awaySummaryEnabled, autoUpdatesChannel, autoMemoryEnabled,
#           env, enabledPlugins, extraKnownMarketplaces
#
# Redacts values for TOKEN/KEY/SECRET/PASSWORD/CREDENTIAL keys.
#
# Called from: make sanitize
# See also: save-work-config.sh, save-home-config.sh, restore-config.sh

set -euo pipefail

python3 -c "
import json, sys, re

data = json.load(sys.stdin)

SENSITIVE_PATTERN = re.compile(r'TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL', re.IGNORECASE)
BEDROCK_MODEL_PATTERN = re.compile(r'^us\.anthropic\.')

WORK_ENV_KEYS = {
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BEDROCK_BASE_URL',
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
}
HOME_ENV_KEYS = {
    'ANTHROPIC_API_KEY',
}

COMMON_KEYS = {
    'hooks',
    'statusLine',
    'skillListingBudgetFraction',
    'syntaxHighlightingDisabled',
    'effortLevel',
    'awaySummaryEnabled',
    'autoUpdatesChannel',
    'autoMemoryEnabled',
    'env',
    'enabledPlugins',
    'extraKnownMarketplaces',
}

def redact(obj, parent_key=None):
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            # Strip work-specific plugins (customize this for your org)
            if k == 'enabledPlugins' and isinstance(v, dict):
                v = {pk: pv for pk, pv in v.items() if 'work-prefix' not in pk.lower()}
            # Strip work-specific marketplaces
            elif k == 'extraKnownMarketplaces' and isinstance(v, dict):
                v = {mk: mv for mk, mv in v.items() if 'work-prefix' not in mk.lower()}
            # Strip work + home env vars
            elif k == 'env' and isinstance(v, dict):
                v = {ek: ev for ek, ev in v.items()
                     if ek not in WORK_ENV_KEYS and ek not in HOME_ENV_KEYS}
            # Strip skipAutoPermissionPrompt (home)
            if k == 'skipAutoPermissionPrompt':
                continue
            # Strip Bedrock model (work)
            if k == 'model' and isinstance(v, str) and BEDROCK_MODEL_PATTERN.match(v):
                continue
            # Strip home model (sonnet)
            if k == 'model' and v == 'sonnet':
                continue
            # Strip common keys (now in common.jsonnet)
            if k in COMMON_KEYS:
                continue
            # Redact sensitive values
            if isinstance(v, str) and SENSITIVE_PATTERN.search(k):
                result[k] = '<REDACTED>'
            else:
                result[k] = redact(v, k)
        return result
    if isinstance(obj, list):
        return [redact(item) for item in obj]
    return obj

print(json.dumps(redact(data), indent=2))
"
