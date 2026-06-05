#!/bin/sh
set -eu

if ! command -v jq >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null
  else
    echo "jq is required to convert the Google OAuth token into rclone config" >&2
    exit 1
  fi
fi

token_path="/var/run/google/token.json"
config_path="/config/rclone/rclone.conf"
drive_remote_name="skirmshop-drive"
s3_remote_name="skirmshop-s3"
mirror_root="/mirror"
log_root="${mirror_root}/s3-sync-logs"
manifest_root="${mirror_root}/s3-sync-manifests"

mkdir -p "${log_root}" "${manifest_root}" /config/rclone

client_id="$(jq -r '.client_id // empty' "${token_path}")"
client_secret="$(jq -r '.client_secret // empty' "${token_path}")"
refresh_token="$(jq -r '.refresh_token // empty' "${token_path}")"
access_token="$(jq -r '.token // .access_token // empty' "${token_path}")"
expiry="$(jq -r '.expiry // empty' "${token_path}")"

if [ -z "${client_id}" ] || [ -z "${client_secret}" ] || [ -z "${refresh_token}" ]; then
  echo "Google token is missing client_id, client_secret or refresh_token" >&2
  exit 1
fi

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "S3 credentials are missing AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY" >&2
  exit 1
fi

if [ -z "${S3_BUCKET:-}" ] || [ -z "${S3_ENDPOINT:-}" ]; then
  echo "S3_BUCKET and S3_ENDPOINT are required" >&2
  exit 1
fi

token_json="$(jq -cn \
  --arg access_token "${access_token}" \
  --arg refresh_token "${refresh_token}" \
  --arg expiry "${expiry}" \
  '{access_token:$access_token, token_type:"Bearer", refresh_token:$refresh_token, expiry:$expiry}')"

{
  printf '[%s]\n' "${drive_remote_name}"
  printf 'type = drive\n'
  printf 'scope = drive\n'
  printf 'client_id = %s\n' "${client_id}"
  printf 'client_secret = %s\n' "${client_secret}"
  printf 'token = %s\n\n' "${token_json}"

  printf '[%s]\n' "${s3_remote_name}"
  printf 'type = s3\n'
  printf 'provider = Minio\n'
  printf 'env_auth = false\n'
  printf 'access_key_id = %s\n' "${AWS_ACCESS_KEY_ID}"
  printf 'secret_access_key = %s\n' "${AWS_SECRET_ACCESS_KEY}"
  printf 'endpoint = %s\n' "${S3_ENDPOINT}"
  printf 'region = %s\n' "${S3_REGION:-us-east-1}"
  printf 'acl = private\n'
} > "${config_path}"
chmod 0600 "${config_path}"

started="$(date -u +%Y%m%dT%H%M%SZ)"
source_remote="${s3_remote_name}:${S3_BUCKET}"
dest_remote="${drive_remote_name}:${S3_TO_DRIVE_DEST:-skirmshop/k8s-object-store}"
archive_remote="${drive_remote_name}:${S3_TO_DRIVE_ARCHIVE:-skirmshop/k8s-object-store-archive}/${started}"
log_file="${log_root}/s3-to-drive-${started}.log"
manifest_file="${manifest_root}/s3-objects-${started}.txt"
mode="${S3_TO_DRIVE_MODE:-copy}"

case "${mode}" in
  copy|sync) ;;
  *)
    echo "S3_TO_DRIVE_MODE must be copy or sync, got: ${mode}" >&2
    exit 1
    ;;
esac

common_args="
  --config ${config_path}
  --fast-list
  --transfers ${S3_TO_DRIVE_TRANSFERS:-4}
  --checkers ${S3_TO_DRIVE_CHECKERS:-8}
  --bwlimit ${S3_TO_DRIVE_BWLIMIT:-8M}
  --stats 60s
  --stats-one-line
  --log-file ${log_file}
  --log-level INFO
"

echo "event=start mode=${mode} source=${source_remote} destination=${dest_remote}"

# shellcheck disable=SC2086
rclone ${mode} "${source_remote}" "${dest_remote}" \
  ${common_args} \
  --backup-dir "${archive_remote}"

# shellcheck disable=SC2086
rclone lsf "${source_remote}" \
  ${common_args} \
  --recursive \
  --files-only \
  --format "pst" \
  > "${manifest_file}"

echo "event=complete manifest=${manifest_file} log=${log_file}"
