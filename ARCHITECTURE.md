# ARCHITECTURE — k8s-skirmshop-drive-mirror-pocharlies

Repo: `pocharlies-org/k8s-skirmshop-drive-mirror-pocharlies` · tronco real: `main` (default branch del survey y `targetRevision` de la Application viva `skirmshop-drive-mirror`) · workflows `ci.yml`, `pr-review.yml`.
Almacenamiento de objetos de Skirmshop y espejo de Google Drive: MinIO interno (`skirmshop-drive-s3`) y copia de Drive a disco (la exportación S3 → Drive se retiró el 03-10-2026). Es una carga de infraestructura, no una app con código propio: **no tiene repo de aplicación** (usa imágenes públicas `rclone/rclone`, `minio/minio`, `busybox` y scripts de shell del propio repo).

## Clientes y versiones
- Sin clientes humanos. Clientes del S3: aplicaciones del clúster y adaptadores de Synapse (contrato en `docs/s3-architecture.md`) y operadores por LAN/Tailscale (`https://skirmshop-s3.e-dani.com`, consola `https://skirmshop-s3-console.e-dani.com`).
- Namespace `backup-hub`; PVC `skirmshop-drive-mirror` en StorageClass `nfs-cold` (`sauvage:/srv/nfs/k8s-cold`).
- Imágenes fijadas: `minio/minio:RELEASE.2025-04-22T22-12-26Z`, `rclone/rclone:1.69.0`, `busybox:1.36` (keeper).

## Dependencias en ambos sentidos
- Depende de: Google Drive de `info@skirmshop.es` (OAuth, Secret existente `backup-hub/gmail-backup-secrets`), NFS frío de sauvage, Velero (`backup-hub` está en el schedule `daily-x86-critical` con `defaultVolumesToFsBackup`; por eso existe el `keeper`), Traefik (`s3-lan-ingressroute.yaml`, restringido por `ClientIP` a LAN, Tailscale y CIDRs del clúster), ExternalSecrets y 1Password (`s3-app-externalsecret.yaml`: item `skirmshop-drive-s3-app`, vault `k8s-pocharlies`).
- De él dependen (consumidores del bucket `skirmshop-drive`; verificados en el docs del repo y en el CI de los repos de aplicación): `skirmbooks-gestoria-src` y `skirmbooks-drive-ingest` (S3 `skirmshop-drive-it`, prefijo `skirmbooks/invoicing-it`), el cerebro (`skirmshop-brain-v2/src/artifact_s3.py`), socialmedia, los generadores de imagen/vídeo de DGX (`media/images/...`), catálogo RAG y plugins. `ClusterExternalSecret` reparte el secreto de acceso a `skirmshop`, `whatsapp-mcp` y `skirmshop-brain-prod`.
- Quién escribe el item de 1Password: solo el aprovisionador de MinIO de `k8s-infra`. No editar a mano el Secret.

## Stack con versiones
- Kustomize (`namespace: backup-hub`, `configMapGenerator` con `disableNameSuffixHash: true` para `skirmshop-drive-mirror-scripts` y `skirmshop-drive-s3-policy`), MinIO RELEASE.2025-04-22, rclone 1.69.0, script `drive-sync.sh`. Sin Helm.

## Componentes compartidos
- **El almacén de objetos de Skirmshop** es el componente compartido canónico: endpoint interno `http://skirmshop-drive-s3.backup-hub.svc.cluster.local:9000`, bucket `skirmshop-drive`, región `us-east-1`, path-style, secreto `skirmshop-drive-s3-app`. Estándar de prefijos en `docs/s3-architecture.md` (`skirmbooks/invoicing/`, `invoices/incoming|generated|sii/`, `price-lists/`, `catalog/exports|rag/...`, `media/images|videos|audio/`, `socialmedia/...`, `plugins/<plugin-name>/`).
- Publica: Service `skirmshop-drive-s3` (9000), rutas LAN del S3 y de la consola, reglas de ciclo de vida (`s3-lifecycle.json`: expiran a 7 días los prefijos `media/images/openclaw/ephemeral/`, `media/images/2026-06/openclaw-ephemeral-` y `media/images/studio/ephemeral/`).
- Jobs: `skirmshop-drive-mirror` (CronJob 03:10, Drive → PVC, `RCLONE_MODE=sync` con `--backup-dir` en `/mirror/archive/`, filtra `/Facturas/**` y `/skirmshop/**`). El export `skirmshop-drive-s3-to-drive` (S3 → Drive) se retiró el 03-10-2026.
- Qué NO debe vivir aquí: bases de datos, colas, Redis, NATS ni sesiones de WhatsApp (estado caliente en su almacenamiento nativo).

## Cómo se construye
- Una carga nueva que necesite objetos usa el contrato S3 (variables `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `AWS_*`, `AWS_S3_FORCE_PATH_STYLE=true`), un prefijo del estándar y referencias `s3://skirmshop-drive/<key>` en los payloads de Synapse (no ids de Drive ni rutas locales).
- Cambios de ciclo de vida: `s3-lifecycle.json` + job `s3-bootstrap.yaml` (credenciales root de MinIO); las aplicaciones solo ponen metadatos por objeto.
- Cambiar el alcance del espejo: `DRIVE_SOURCE` o `DRIVE_ROOT_FOLDER_ID` y `RCLONE_FILTER_RULES` en `k8s/configmap.yaml`.

## Tests
- `ci.yml`: renderiza `kubectl kustomize k8s` (kubectl v1.32.5) y valida con `kubeconform v0.6.7 -strict` (ejecuta un contenedor Docker en el runner `arc-k8s`); se dispara en push a `main` y `deploy/prod`, en PR y a mano. No hay pruebas de comportamiento: primer run manual con `kubectl create job --from=cronjob/skirmshop-drive-mirror ...` (README).

## CI/CD y despliegue
- ArgoCD Application `skirmshop-drive-mirror`, **`targetRevision: main`** según el survey, path `k8s`, destino `backup-hub`. El README dice «ArgoCD tracks this repo from `deploy/prod`»: es texto desfasado; la Application viva lee `main` y el PR va contra `main`. El CI aún escucha pushes a `deploy/prod` por herencia.
- Producción se valida con el estado de la Application y `kubectl -n backup-hub get pvc,deploy,svc,job,cronjob -l app.kubernetes.io/name=skirmshop-drive-mirror`.

## Decisiones y trampas
- Evita Longhorn/ks5 a propósito: los datos viven en `nfs-cold` de sauvage, respaldados por Velero con filtrado por FS.
- `README` indica `kubectl apply -k` desde la ruta local: no usarlo para desplegar (ArgoCD es el dueño; un apply manual la pelea con `selfHeal`).
- `.gitignore` solo cubre `.env*`, `rendered.yaml`, `tmp/`; en el clon del x86 hay un directorio `.kube/cache/` sin ignorar: el maker NO debe usar `git add -A` (comitear solo `ARCHITECTURE.md`).
- Los secretos no van en los manifiestos; el Secret de la app S3 es de 1Password/ESO (retirado el `ClusterPushSecret` bajo SC-495): un Secret aplicado a mano se sobrescribe.
- El docs `storage-audit-2026-06-07.md` es una auditoría fechada; no es estado vigente.

## Referencias cruzadas
- Consumidores: `skirmshop-brain-v2` (`src/artifact_s3.py`), `skirmbooks-drive-ingest` (`scripts/s3-artifacts.mjs`), `skirmbooks-gestoria-src`; infra: `k8s-infra-pocharlies` (aprovisionador de MinIO), Velero.
- [DECISION: k8s-skirmshop-drive-mirror-pocharlies: el almacén de objetos canónico de Skirmshop es el MinIO skirmshop-drive-s3 (bucket skirmshop-drive) de este chart]

## Hallazgo C5
- No duplicado ni abandonado. Documentación desfasada (README `deploy/prod`, `kubectl apply -k` local) y posible solape funcional con `skirmbooks-drive-ingest` (que baja Drive por MCP): proponer reconciliar ambos mecanismos de ingesta de Drive en story aparte; no archivar.
