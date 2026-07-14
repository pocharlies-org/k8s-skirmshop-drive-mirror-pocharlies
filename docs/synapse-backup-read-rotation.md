# Synapse S3 backup credential rotation (v2)

The existing Kubernetes Secret `synapse/skirmbooks-backup-s3-read` is named
read-only but its live MinIO user currently has the shared read/write policy.
This rotation introduces a separate identity whose policy contains exactly:

- `s3:GetBucketLocation` and `s3:ListBucket` on `skirmshop-drive`;
- `s3:GetObject` on `skirmshop-drive/*`.

The whole-bucket scope is intentional for this rotation: the existing backup
copies the whole bucket. Restricting it to `skirmbooks/*` is a separate change
that first requires a complete prefix, ownership and retention inventory.

## Fail-closed rollout order

1. Run `scripts/seed-synapse-backup-read-v2-vault.sh` from an approved operator
   workstation. It creates a new Vault generation with CAS=0 and never prints
   or commits either credential.
2. Merge and sync the provider PR from this repository. Wait for the
   `skirmbooks-backup-s3-read-v2` ExternalSecret to be Ready and for the
   PostSync bootstrap Job to pass all five authorization canaries: target
   list/get, denied put, denied delete and denied access to the other bucket.
   The bootstrap is constrained to the `ks5-nvme` node pool; it must not be
   scheduled on Ubuntu or Sauvage.
3. Keep the legacy Secret and user enabled. Merge the coordinated Synapse PR,
   which projects the same Vault generation into `synapse` and switches only
   the existing CronJob reference to the v2 Secret.
4. Launch one manual Job from the CronJob, then allow at least one normal
   scheduled cycle. Both must finish with `succeeded=1`, `failed=0`, and the
   expected non-destructive rclone completion. Argo applications must remain
   Synced/Healthy.
5. Disable (do not delete) the legacy MinIO user. Let one more scheduled cycle
   pass on v2. If it succeeds, remove the legacy MinIO user and delete the
   manually managed `synapse/skirmbooks-backup-s3-read` Secret. Do not remove
   the v2 Vault generation or either v2 ExternalSecret.

If any gate fails, re-enable the legacy MinIO user and point the CronJob back
to the legacy Secret. Never reuse or mutate the v2 Vault path in place; create
a v3 generation for a future rotation.

No step in this rotation connects to or modifies the Sauvage host, and no
credential is stored in Git.
