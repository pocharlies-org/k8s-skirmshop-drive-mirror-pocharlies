#!/bin/sh
set -eu

# Campos de cadena de token.json, extraídos con sed: sin dependencias externas.
# El 25-10-2026 el job murió ANTES de rclone porque `apk add jq` no alcanzó la CDN
# de Alpine (sin log ni manifiesto en /mirror). token.json son campos de cadena
# OAuth/timestamps (sin comillas ni barras invertidas), sed es suficiente.
json_field() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${token_path}" | head -n 1
}

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

client_id="$(json_field client_id)"
client_secret="$(json_field client_secret)"
refresh_token="$(json_field refresh_token)"
access_token="$(json_field token)"
[ -n "${access_token}" ] || access_token="$(json_field access_token)"
expiry="$(json_field expiry)"

if [ -z "${client_id}" ] || [ -z "${client_secret}" ] || [ -z "${refresh_token}" ]; then
  echo "Google token is missing client_id, client_secret or refresh_token" >&2
  exit 1
fi

token_json="{\"access_token\":\"${access_token}\",\"token_type\":\"Bearer\",\"refresh_token\":\"${refresh_token}\",\"expiry\":\"${expiry}\"}"

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
