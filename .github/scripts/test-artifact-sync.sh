#!/usr/bin/env bash
# Asserts root.hcl hook wiring + script key-set vs the local_sensitive_file filenames, then a live PUT/GET round-trip under a disposable test prefix (keys idempotent, no delete).
# Skips without the SOPS age key, mirroring terragrunt-validate.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
age_key_file="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [[ -z "${SOPS_AGE_KEY:-}" && ! -f "$age_key_file" ]]; then
  echo "test-artifact-sync: no SOPS age key available, skipping (set SOPS_AGE_KEY to enable)"
  exit 0
fi

fail() {
  echo "test-artifact-sync: FAIL: $*" >&2
  exit 1
}

root_hcl="$root/infra/root.hcl"
sync_script="$root/infra/scripts/sync-artifacts.sh"

[[ -f "$sync_script" ]] || fail "missing $sync_script"

grep -q 'before_hook "sync_artifacts_download"' "$root_hcl" ||
  fail "download before_hook missing from root.hcl"
grep -A2 'before_hook "sync_artifacts_download"' "$root_hcl" |
  grep -q 'commands = \["plan", "apply"\]' ||
  fail "download hook must run for both plan and apply"
grep -q 'after_hook "sync_artifacts_upload"' "$root_hcl" ||
  fail "upload after_hook missing from root.hcl"
grep -A2 'after_hook "sync_artifacts_upload"' "$root_hcl" |
  grep -q 'commands = \["apply"\]' ||
  fail "upload hook must run only after apply"
grep -q 'sync-artifacts.sh", "download"' "$root_hcl" ||
  fail "download hook does not execute sync-artifacts.sh"
grep -q 'sync-artifacts.sh", "upload"' "$root_hcl" ||
  fail "upload hook does not execute sync-artifacts.sh"
if grep -E 'commands = \[[^]]*(init|validate)' "$root_hcl" | grep -q sync-artifacts; then
  fail "sync hooks must not run on init/validate (network on validate breaks pre-commit)"
fi

script_keys="$(sed -n 's/^FILES=(\(.*\))$/\1/p' "$sync_script" | tr ' ' '\n' | sort | xargs)"
tf_keys="$(grep -ohE '\$\{var\.(credentials_dir|artifacts_dir)\}/[a-z-]+' \
  "$root/infra/cluster/modules/talos-cluster/artifacts.tf" \
  "$root/infra/viewer-kubeconfig/main.tf" |
  sed 's|.*/||' | sort | xargs)"
[[ -n "$script_keys" ]] || fail "could not parse FILES from sync-artifacts.sh"
[[ "$script_keys" == "$tf_keys" ]] ||
  fail "key set mismatch: script=[$script_keys] tf=[$tf_keys]"

env_cred="$(sed -n 's/^  credentials_dir = "\(.*\)"$/\1/p' "$root/infra/env.hcl")"
script_cred="$(sed -n 's/^CREDENTIALS_DIR="\(.*\)"$/\1/p' "$sync_script")"
[[ -n "$env_cred" && -n "$script_cred" && "$env_cred" == "$script_cred" ]] ||
  fail "credentials_dir mismatch: env.hcl=[$env_cred] script=[$script_cred]"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC1090,SC2034,SC2154 # variables defined by the sourced sync script
if ! (
  source "$sync_script"
  load_credentials
  PREFIX="artifact-sync-test"
  credentials_dir="$tmp/creds"
  artifacts_dir="$tmp/artifacts"
  mkdir -p "$credentials_dir" "$artifacts_dir"

  printf 'canary-roundtrip-%s\n' "$(date +%s%N)" >"$artifacts_dir/canary"
  adopt_and_link canary
  [[ -L "$artifacts_dir/canary" && -f "$credentials_dir/canary" ]] || exit 1

  rm -f "$artifacts_dir/canary"
  printf 'stale-legacy-%s\n' "$(date +%s%N)" >"$artifacts_dir/canary"
  adopt_and_link canary
  [[ -L "$artifacts_dir/canary" ]] || exit 1
  grep -q '^canary-roundtrip-' "$credentials_dir/canary" || exit 1

  upload_one canary
  rm -f "$artifacts_dir/canary" "$credentials_dir/canary"
  download_one canary
  adopt_and_link canary
  grep -q '^canary-roundtrip-' "$credentials_dir/canary" || exit 1
  [[ -L "$artifacts_dir/canary" ]] || exit 1

  printf 'canary-overwrite-%s\n' "$(date +%s%N)" >"$credentials_dir/canary"
  upload_one canary
  [[ "$(cat "$credentials_dir/canary")" == "$(curl_config | curl -sS -K - --url \
    "${endpoint}/homelab-kubernetes/${PREFIX}/canary")" ]] || exit 1
  rm -f "$artifacts_dir/canary" "$credentials_dir/canary"
  download_one canary
  grep -q '^canary-overwrite-' "$credentials_dir/canary" || exit 1

  download_one definitely-absent-object
  [[ ! -e "$credentials_dir/definitely-absent-object" ]] || exit 1
); then
  fail "bucket round-trip under test prefix failed"
fi

echo "test-artifact-sync: all checks passed"
