#!/usr/bin/env bash
set -u
failed=0
for f in "$@"; do
  if ! grep -q '^sops:' "$f" || ! grep -q 'ENC\[' "$f"; then
    echo "ERROR: $f looks UNENCRYPTED; re-encrypt before committing (sops -e -i $f)"
    failed=1
  fi
done
exit $failed
