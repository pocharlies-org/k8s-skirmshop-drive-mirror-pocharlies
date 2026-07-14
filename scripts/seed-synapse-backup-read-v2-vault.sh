#!/bin/sh
set -eu

# Creates a new, versioned MinIO identity in Vault without placing either
# credential in argv, stdout, Git, or a Kubernetes manifest. This script is an
# explicit operator step; GitOps/ESO only reads the resulting Vault object.

VAULT_MOUNT="${VAULT_MOUNT:-secret}"
VAULT_KEY="${VAULT_KEY:-skirmshop-drive/synapse-backup-read-v2}"

for command in vault jq openssl mktemp; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "missing required command: ${command}" >&2
    exit 1
  }
done

umask 077
payload="$(mktemp)"
trap 'rm -f "${payload}"' EXIT HUP INT TERM

# MinIO access keys are kept at the AWS-compatible 20-character size.
access_key="synbkpv2$(openssl rand -hex 6)"
secret_key="$(openssl rand -hex 24)"

jq -n \
  --arg access_key "${access_key}" \
  --arg secret_key "${secret_key}" \
  '{AWS_ACCESS_KEY_ID:$access_key,AWS_SECRET_ACCESS_KEY:$secret_key}' >"${payload}"
unset access_key secret_key

# CAS=0 refuses to overwrite an existing generation. A later rotation must use
# a new versioned path instead of mutating credentials under a running consumer.
vault kv put -mount="${VAULT_MOUNT}" -cas=0 "${VAULT_KEY}" @"${payload}" >/dev/null
echo "created Vault credential generation at ${VAULT_MOUNT}/${VAULT_KEY}"
