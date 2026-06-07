# Skirmshop storage audit - 2026-06-07

Scope: first pass over k8s repos that showed Drive, MinIO, S3, media, file,
invoice, price list, catalog or local filesystem usage.

## Decisions

- Shared durable artifact target: bucket `skirmshop-drive`.
- Shared API: `skirmshop-drive-s3.backup-hub.svc.cluster.local:9000`.
- Human/operator access: `skirmshop-s3.lan.e-dani.com` and
  `skirmshop-s3-console.lan.e-dani.com`.
- Synapse events should pass `s3://skirmshop-drive/<key>` references.
- Hot databases, queue journals, sessions and caches do not move to this bucket.

## Audit

| System | Current storage | Finding | Target |
| --- | --- | --- | --- |
| `k8s-skirmbooks-pocharlies` UI | PostgreSQL and AMQP; no invoice artifact volume in UI manifest | UI is already wired to Synapse/RabbitMQ and LiteLLM. Artifact persistence is in backend adapters, not the UI pod. | Keep UI stateless; read/write invoice objects by Synapse ids and S3 refs. |
| `skirmbooks-invoicing` backend | `storage.root: /var/lib/synapse/gestoria/invoicing`; deployment mounts `/var/lib/synapse` as `emptyDir` | P0: invoice OCR renders/PDF images are not durable across pod restart and do not reach Drive. | Add S3 backend support or code path using `skirmshop-drive`; prefix `skirmbooks/invoicing/`. |
| `skirmbooks-accounting` backend | Config has disabled retention S3 block for bucket `skirmshop-gestoria-archive` | P1: archive intent exists but is disabled and points at a separate bucket name. | Enable against shared endpoint/bucket; prefix `skirmbooks/accounting/archive/`. |
| `skirmbooks-fiscal-validator` backend | `corpus.path: /app/fiscal-corpus/built.txt` | Looks image-baked/read-only. Only dynamic corpus updates need object storage. | If mutable, publish corpus snapshots to `skirmbooks/fiscal-corpus/`. |
| `k8s-socialmedia-pocharlies` media | Dedicated `whatsapp-mcp-minio` on Longhorn, bucket `socialmedia-media` | P0/P1: WhatsApp and Telegram blobs already use object storage, but not the shared Drive-backed bucket. Code writes keys like `attachments/...` and `avatars/...`. | Add `MINIO_PREFIX` support, then point to shared endpoint/bucket with prefixes `socialmedia/attachments/` and `socialmedia/avatars/`. |
| `k8s-socialmedia-pocharlies` sessions/queues | WhatsApp session PVCs, NATS PVC, Postgres, Redis | Operational state; not user artifacts. | Keep out of S3. Back up with native DB/PVC strategy. |
| `k8s-video-mcp-pocharlies` | No local storage; proxy to dashboard `DASHBOARD_BASE_URL`; gallery comes from dashboard API | MCP is thin. The dashboard/Comfy side owns generated files and input image names. | Dashboard should upload outputs to `media/videos/`, `media/images/`, `media/audio/` and return S3 refs/presigned URLs. |
| `skirmshop-brain-k8s` | Qdrant/FalkorDB for RAG; audit reports under `/var/lib/brain-audit` on `nfs-warm` | Catalog/RAG data stores are already service-native. Audit reports are filesystem artifacts. | Keep vector/graph DBs native; export source docs/reports to `catalog/rag/source/` and `catalog/rag/reports/` when durability in Drive is required. |
| `k8s-shopify-chatbot-pocharlies` | SQLite file at `/app/prisma/data/chatbot.db` on `local-path` PVC | This is application DB state, not artifact storage; it is also pinned to Sauvage-local storage. | Migrate DB to Postgres/Synapse. Optional transcript exports go to `plugins/chatbot/` or `catalog/rag/source/`. |
| `k8s-shopify-sii-pocharlies` | Synapse/RabbitMQ env vars; no local artifact volume found in manifests | Already event-driven at manifest level. Generated AEAT/SII XML/PDF receipts should not stay only in app memory/logs. | Store fiscal artifacts under `invoices/sii/`. |
| `k8s-shopify-affiliate-pocharlies` | Postgres/Redis/Synapse; no local artifact volume found in manifests | No Drive/local blob usage found in k8s manifests. | Store future exports under `plugins/affiliate/`. |
| `k8s-shopify-picker-pocharlies` | CronJobs; no local artifact volume found in manifests | No durable local blob usage found in k8s manifests. | Store generated recommendations/price outputs under `price-lists/` or `plugins/picker/`. |
| `k8s-shopify-collections-tree-pocharlies` | Synapse/RabbitMQ; no local artifact volume found in manifests | Catalog tree events already go through Synapse at manifest level. | Store tree/catalog exports under `catalog/exports/`. |

## Migration order

1. Skirmbooks invoicing: replace `emptyDir` invoice artifacts with S3 writes.
2. Socialmedia media: add prefix support and move media blobs to shared S3.
3. Video dashboard/Comfy: publish gallery outputs and input references to S3.
4. Skirmbooks accounting retention: enable S3 archive on the shared bucket.
5. Brain/catalog/RAG exports: write source files and reports to S3.
6. Shopify plugins: use the prefix standard for price lists, catalog exports
   and plugin-generated artifacts.

## Code changes needed outside this repo

- Add a reusable S3 artifact client per runtime (Node/Python) that accepts the
  environment contract from `docs/s3-architecture.md`.
- Add optional `S3_PREFIX`/`MINIO_PREFIX` support where services currently write
  flat object keys.
- Keep database rows storing logical keys and `s3://` URIs, not presigned URLs.
- Generate presigned URLs only at API/read time.
