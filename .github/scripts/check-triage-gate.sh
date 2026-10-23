#!/usr/bin/env bash
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "check-triage-gate: node not found, skipping (install node to run platform/alert-triage/gate.test.mjs)"
  exit 0
fi

cd "$(dirname "$0")/../.."
exec node --test platform/alert-triage/gate.test.mjs
