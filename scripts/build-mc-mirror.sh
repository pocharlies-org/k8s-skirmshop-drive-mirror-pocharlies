#!/usr/bin/env bash
# Espejo de minio/mc en Harbor (INFRA-691). minio/mc y minio/minio fueron
# retirados de Docker Hub (pull 401) y dl.min.io responde 410; el binario
# oficial vive solo en los releases de GitHub. Reconstruir cuando toque subir
# mc: docker build + push a harbor.e-dani.com/homelab/mc con credenciales de
# push (robot homelab+push; las mismas que usa el CI de buildkit).
set -euo pipefail
TAG="${1:-RELEASE.2025-08-13T08-35-41Z}"
DEST="harbor.e-dani.com/homelab/mc:${TAG}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
URL=$(curl -fsSL "https://api.github.com/repos/minio/mc/releases/tags/${TAG}" \
  | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name']=='mc.linux-amd64.${TAG}'][0])")
curl -fsSL -o "$TMP/mc" "$URL"
chmod +x "$TMP/mc"
printf 'FROM busybox:1.36\nCOPY mc /usr/bin/mc\nRUN chmod 0755 /usr/bin/mc\nENTRYPOINT ["/usr/bin/mc"]\n' > "$TMP/Dockerfile"
docker build -t "$DEST" "$TMP"
docker push "$DEST"
docker inspect --format='{{index .RepoDigests 0}}' "$DEST"
