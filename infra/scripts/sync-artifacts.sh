#!/usr/bin/env bash
# Syncs kubeconfig/talosconfig/viewer-kubeconfig with the shared S3 bucket (Terragrunt hooks): real files live in the machine-invariant CREDENTIALS_DIR (state stores these filenames — a checkout path differs per machine/Atlantis workspace and plans creates everywhere else); artifacts/ holds symlinks the script manages.
# A download 404 is a cache miss (exit 0): apply regenerates, after_hook re-uploads. Credentials come from sops and reach curl via a stdin config (-K -), never argv, never echoed; silent on success, errors to stderr, no `set -x`.
set -euo pipefail

BUCKET="homelab-kubernetes"
PREFIX="artifacts"
REGION="us-east-1"
FILES=(kubeconfig talosconfig viewer-kubeconfig)
# Must match credentials_dir in infra/env.hcl.
CREDENTIALS_DIR="/var/tmp/homelab-artifacts"

infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
credentials_dir="$CREDENTIALS_DIR"
artifacts_dir="${infra_dir}/cluster/artifacts"
secrets_file="${infra_dir}/secrets.sops.yaml"

usage() {
  echo "usage: $(basename "$0") download|upload" >&2
  exit 2
}

load_credentials() {
  endpoint="$(sops -d --extract '["seaweedfs_endpoint"]' "$secrets_file")"
  access_key="$(sops -d --extract '["seaweedfs_access_key"]' "$secrets_file")"
  secret_key="$(sops -d --extract '["seaweedfs_secret_key"]' "$secrets_file")"
  endpoint="${endpoint%/}"
}

curl_config() {
  printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' \
    "$access_key" "$secret_key" "$REGION"
}

curl_s3() {
  curl_config | curl -sS -K - "$@"
}

adopt_and_link() {
  # Orphan legacy files move up (canonical wins when both exist); artifacts/ becomes symlinks so kubectl/provider paths keep working.
  local name="$1"
  local link="${artifacts_dir}/${name}"
  local canonical="${credentials_dir}/${name}"

  if [[ -f "$link" && ! -L "$link" ]]; then
    if [[ -f "$canonical" ]]; then
      rm -f "$link"
    else
      mv "$link" "$canonical"
      chmod 666 "$canonical" 2>/dev/null || true
    fi
  fi

  if [[ -f "$canonical" ]]; then
    ln -sfn "$canonical" "$link"
  fi
}

download_one() {
  local name="$1"
  local url="${endpoint}/${BUCKET}/${PREFIX}/${name}"
  local tmp
  tmp="$(mktemp "${credentials_dir}/.${name}.XXXXXX")"

  local code
  code="$(curl_s3 -o "$tmp" -w '%{http_code}' --url "$url")" || {
    rm -f "$tmp"
    echo "sync-artifacts: download failed for ${name}" >&2
    return 1
  }

  case "$code" in
    200)
      chmod 666 "$tmp"
      mv "$tmp" "${credentials_dir}/${name}"
      ;;
    404)
      rm -f "$tmp"
      ;;
    *)
      rm -f "$tmp"
      echo "sync-artifacts: unexpected HTTP ${code} for ${name}" >&2
      return 1
      ;;
  esac
}

upload_one() {
  local name="$1"
  local file="${credentials_dir}/${name}"
  [[ -f "$file" ]] || return 0

  local url="${endpoint}/${BUCKET}/${PREFIX}/${name}"
  local code
  code="$(curl_s3 -o /dev/null -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@${file}" --url "$url")" || {
    echo "sync-artifacts: upload failed for ${name}" >&2
    return 1
  }

  case "$code" in
    200 | 204) ;;
    *)
      echo "sync-artifacts: unexpected HTTP ${code} for ${name}" >&2
      return 1
      ;;
  esac
}

sync_main() {
  [[ $# -eq 1 ]] || usage
  local action="$1"
  case "$action" in
    download | upload) ;;
    *) usage ;;
  esac

  load_credentials
  if ! mkdir -p "$credentials_dir" 2>/dev/null; then
    echo "sync-artifacts: cannot create ${credentials_dir}" >&2
    return 1
  fi
  chmod 777 "$credentials_dir" 2>/dev/null || true
  mkdir -p "$artifacts_dir"

  local name
  for name in "${FILES[@]}"; do
    adopt_and_link "$name"
    "${action}_one" "$name"
    adopt_and_link "$name"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sync_main "$@"
fi
