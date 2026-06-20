# Skirmshop internal S3 architecture

This repo owns the shared object store used for Skirmshop documents and
generated artifacts that must be durable and visible in Google Drive.

## Topology

```text
cluster apps and Synapse adapters
  -> http://skirmshop-drive-s3.backup-hub.svc.cluster.local:9000
  -> bucket skirmshop-drive
  -> MinIO data on PVC skirmshop-drive-mirror, subPath /mirror/s3-data
  -> nfs-cold on Sauvage
  -> rclone export every 15 minutes
  -> Google Drive info@skirmshop.es/skirmshop/k8s-object-store
```

This is intentionally object storage, not a Kubernetes `StorageClass`.
Workloads use the S3 API. Databases, queues, Redis, NATS, WhatsApp sessions and
other hot state stay in their native storage.

## Endpoints

In-cluster API:

```text
http://skirmshop-drive-s3.backup-hub.svc.cluster.local:9000
```

LAN/Tailscale operator access:

```text
https://skirmshop-s3.lan.e-dani.com
https://skirmshop-s3-console.lan.e-dani.com
```

The LAN routes are limited to the home LAN, Tailscale CGNAT range, and cluster
pod/service CIDRs through Traefik `ClientIP` matching.

## Application contract

Use the app secret already present in `backup-hub` and `skirmshop`:

```text
skirmshop-drive-s3-app
```

Standard environment contract for applications:

```text
S3_ENDPOINT=http://skirmshop-drive-s3.backup-hub.svc.cluster.local:9000
S3_BUCKET=skirmshop-drive
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=<from secret>
AWS_SECRET_ACCESS_KEY=<from secret>
AWS_S3_FORCE_PATH_STYLE=true
```

Synapse payloads should carry durable object references instead of Drive file
ids or local paths:

```text
s3://skirmshop-drive/<key>
```

## Prefix standard

Use stable prefixes so Drive exports remain browsable:

| Domain | Prefix |
| --- | --- |
| Skirmbooks invoices | `skirmbooks/invoicing/` |
| Accounting archive | `skirmbooks/accounting/archive/` |
| Incoming invoices | `invoices/incoming/` |
| Generated invoices | `invoices/generated/` |
| SII XML/PDF artifacts | `invoices/sii/` |
| Price lists | `price-lists/` |
| Catalog exports | `catalog/exports/` |
| Catalog/RAG source files | `catalog/rag/source/` |
| Catalog/RAG reports | `catalog/rag/reports/` |
| Generated images | `media/images/` |
| OpenClaw ephemeral images | `media/images/openclaw/ephemeral/` |
| OpenClaw legacy ephemeral images | `media/images/2026-06/openclaw-ephemeral-` |
| DGX Image Studio ephemeral images | `media/images/studio/ephemeral/` |
| Generated videos | `media/videos/` |
| Generated audio | `media/audio/` |
| Social media attachments | `socialmedia/attachments/` |
| Social media avatars | `socialmedia/avatars/` |
| Plugin-owned artifacts | `plugins/<plugin-name>/` |

## Lifecycle rules

The bootstrap job imports the complete MinIO lifecycle configuration from
`k8s/s3-lifecycle.json`. The following generated-image prefixes expire after 7
days:

| Rule ID | Prefix | Expiry |
| --- | --- | --- |
| `dgx-openclaw-image-ephemeral-7d` | `media/images/openclaw/ephemeral/` | 7 days |
| `dgx-openclaw-image-legacy-ephemeral-2026-06-7d` | `media/images/2026-06/openclaw-ephemeral-` | 7 days |
| `dgx-image-studio-ephemeral-7d` | `media/images/studio/ephemeral/` | 7 days |

Applications use object-level metadata to describe retention, but bucket
lifecycle is owned by this bootstrap job with MinIO root credentials.

## Operator examples

AWS CLI can target an S3-compatible endpoint with `--endpoint-url`:

```sh
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
aws --endpoint-url https://skirmshop-s3.lan.e-dani.com s3 ls s3://skirmshop-drive/
```

Rclone can also use MinIO through the S3 backend:

```sh
rclone config create skirmshop-s3 s3 provider Minio \
  endpoint https://skirmshop-s3.lan.e-dani.com \
  access_key_id "$AWS_ACCESS_KEY_ID" \
  secret_access_key "$AWS_SECRET_ACCESS_KEY"
rclone lsf skirmshop-s3:skirmshop-drive
```

## Reference docs

- MinIO S3 API compatibility: https://minio.community/community/minio-object-store/reference/s3-api-compatibility.html
- MinIO Console: https://docs.min.io/aistor/administration/console/
- MinIO on Kubernetes: https://docs.min.io/aistor/installation/kubernetes/
- rclone S3 backend with MinIO provider: https://rclone.org/s3/
- AWS CLI custom endpoints: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-endpoints.html
