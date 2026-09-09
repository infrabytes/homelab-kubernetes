#!/bin/bash
# kubeconform over the datreeio CRD catalog, with repo-vendored
# external-secrets.io schemas first: the catalog's SecretStore schemas
# predate the OpenBao provider, so the vendored copies (generated from the
# ESO chart CRDs) win for those kinds and everything else falls through.
set -euo pipefail
command -v kubeconform >/dev/null 2>&1 || { echo "kubeconform not found, please install it from https://github.com/yannh/kubeconform/releases/latest" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$(realpath "$SCRIPT_DIR/../../.kubeconform")"

for arg in "$@"; do
  kubeconform -strict -ignore-missing-schemas -summary \
    -schema-location default \
    -schema-location "$SCHEMA_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$arg"
done
