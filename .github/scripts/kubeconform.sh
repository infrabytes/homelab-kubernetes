#!/bin/bash
# kubeconform over the datreeio CRD catalog; .kubeconform/<group> dirs are vendored schemas for external-secrets.io and kubebao.org.
set -euo pipefail
command -v kubeconform >/dev/null 2>&1 || {
	echo "kubeconform not found, please install it from https://github.com/yannh/kubeconform/releases/latest" >&2
	exit 1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$(realpath "$SCRIPT_DIR/../../.kubeconform")"
# Cached between runs; the nightly warm wipe of the runner tree is the refresh.
KUBECONFORM_CACHE="${RUNNER_TOOL_CACHE:-$HOME/.cache}/kubeconform"
mkdir -p "$KUBECONFORM_CACHE"

for arg in "$@"; do
	kubeconform -strict -ignore-missing-schemas -summary \
		-cache "$KUBECONFORM_CACHE" \
		-schema-location default \
		-schema-location "$SCHEMA_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		"$arg"
done
