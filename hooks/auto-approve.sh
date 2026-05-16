#!/usr/bin/env bash
# PermissionRequest hook — delegates to auto-approve.ts via npx tsx
cat | npx --yes tsx ~/.claude/scripts/auto-approve.ts
