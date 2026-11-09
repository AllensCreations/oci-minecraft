#!/usr/bin/env bash
set -e
mkdir -p ~/.oci
printf '%s\n' "$OCI_KEY" > ~/.oci/key.pem
chmod 600 ~/.oci/key.pem
printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s/.oci/key.pem\n' \
  "$OCI_USER" "$OCI_FINGERPRINT" "$OCI_TENANCY" "$OCI_REGION" "$HOME" > ~/.oci/config
chmod 600 ~/.oci/config
