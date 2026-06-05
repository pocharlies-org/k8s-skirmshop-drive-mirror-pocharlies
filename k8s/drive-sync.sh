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
remote_name="skirmshop-drive"
mirror_root="/mirror"
current_dir="${mirror_root}/current"
archive_root="${mirror_root}/archive"
manifest_root="${mirror_root}/manifests"
log_root="${mirror_root}/logs"
filter_file="/config/rclone/filter.rules"

mkdir -p "${current_dir}" "${archive_root}" "${manifest_root}" "${log_root}" /config/rclone

client_id="$(jq -r '.client_id // empty' "${token_path}")"
client_secret="$(jq -r '.client_secret // empty' "${token_path}")"
refresh_token="$(jq -r '.refresh_token // empty' "${token_path}")"
access_token="$(jq -r '.token // .access_token // empty' "${token_path}")"
expiry="$(jq -r '.expiry // empty' "${token_path}")"

if [ -z "${client_id}" ] || [ -z "${client_secret}" ] || [ -z "${refresh_token}" ]; then
  echo "Google token is missing client_id, client_secret or refresh_token" >&2
  exit 1
fi

token_json="$(jq -cn \
  --arg access_token "${access_token}" \
  --arg refresh_token "${refresh_token}" \
  --arg expiry "${expiry}" \
  '{access_token:$access_token, token_type:"Bearer", refresh_token:$refresh_token, expiry:$expiry}')"

{
  printf '[%s]\n' "${remote_name}"
  printf 'type = drive\n'
  printf 'scope = drive\n'
  printf 'client_id = %s\n' "${client_id}"
  printf 'client_secret = %s\n' "${client_secret}"
  if [ -n "${DRIVE_ROOT_FOLDER_ID:-}" ]; then
    printf 'root_folder_id = %s\n' "${DRIVE_ROOT_FOLDER_ID}"
  fi
  printf 'token = %s\n' "${token_json}"
} > "${config_path}"
chmod 0600 "${config_path}"

source_path="${DRIVE_SOURCE:-}"
remote="${remote_name}:"
if [ -n "${source_path}" ]; then
  remote="${remote_name}:${source_path}"
fi

started="$(date -u +%Y%m%dT%H%M%SZ)"
archive_dir="${archive_root}/${started}"
log_file="${log_root}/rclone-${started}.log"
manifest_file="${manifest_root}/drive-files-${started}.txt"
mode="${RCLONE_MODE:-sync}"

case "${mode}" in
  copy|sync) ;;
  *)
    echo "RCLONE_MODE must be copy or sync, got: ${mode}" >&2
    exit 1
    ;;
esac

dry_run_args=""
if [ "${RCLONE_DRY_RUN:-false}" = "true" ]; then
  dry_run_args="--dry-run"
fi

common_args="
  --config ${config_path}
  --fast-list
  --drive-export-formats docx,xlsx,pptx,pdf
  --transfers ${RCLONE_TRANSFERS:-8}
  --checkers ${RCLONE_CHECKERS:-16}
  --bwlimit ${RCLONE_BWLIMIT:-off}
  --stats 60s
  --stats-one-line
  --log-file ${log_file}
  --log-level INFO
"

if [ -n "${RCLONE_FILTER_RULES:-}" ]; then
  printf '%s\n' "${RCLONE_FILTER_RULES}" > "${filter_file}"
  common_args="${common_args} --filter-from ${filter_file}"
fi

echo "event=start mode=${mode} remote=${remote} destination=${current_dir} dry_run=${RCLONE_DRY_RUN:-false}"

# shellcheck disable=SC2086
rclone ${mode} "${remote}" "${current_dir}" \
  ${common_args} \
  ${dry_run_args} \
  --backup-dir "${archive_dir}"

# shellcheck disable=SC2086
rclone lsf "${remote}" \
  ${common_args} \
  --recursive \
  --files-only \
  --format "pst" \
  > "${manifest_file}"

find "${archive_dir}" -type d -empty -delete 2>/dev/null || true

echo "event=complete manifest=${manifest_file} log=${log_file}"
