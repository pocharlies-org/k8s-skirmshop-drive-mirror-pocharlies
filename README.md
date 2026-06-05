# Skirmshop Drive mirror

Mirrors Google Drive content from `info@skirmshop.es` into Kubernetes storage
backed by `sauvage`.

The stack uses:

- namespace `backup-hub`
- StorageClass `nfs-cold` (`sauvage:/srv/nfs/k8s-cold`)
- PVC `skirmshop-drive-mirror`
- `rclone/rclone` CronJob
- internal MinIO service `skirmshop-drive-s3`
- S3-to-Drive export CronJob `skirmshop-drive-s3-to-drive`
- existing Kubernetes Secret `backup-hub/gmail-backup-secrets`
- a tiny keeper Deployment so Velero filesystem backups always see the PVC

This intentionally avoids Longhorn/ks5 disks. `backup-hub` is already included
in the `daily-x86-critical` Velero schedule with
`defaultVolumesToFsBackup: true`.

## Deploy

```sh
kubectl apply -k /home/dibanez/k8s/k8s-skirmshop-drive-mirror-pocharlies/k8s
kubectl -n backup-hub get pvc,deploy,svc,job,cronjob -l app.kubernetes.io/name=skirmshop-drive-mirror
```

ArgoCD tracks this repo from `deploy/prod`:

- repo: `https://github.com/pocharlies-org/k8s-skirmshop-drive-mirror-pocharlies`
- app: `skirmshop-drive-mirror`
- path: `k8s`
- destination namespace: `backup-hub`

CI renders `k8s/` with Kustomize and validates the resulting manifests on every
push and pull request.

## First run

```sh
kubectl -n backup-hub create job --from=cronjob/skirmshop-drive-mirror skirmshop-drive-mirror-manual-$(date +%Y%m%d%H%M)
kubectl -n backup-hub logs -f job/<job-name>
```

## Source scope

By default the mirror reads the root of `My Drive` for the OAuth account, but
filters the copy to:

- `/Facturas/**`
- `/skirmshop/**`

That avoids copying unrelated root folders such as `Personal` or `Education`.
To mirror a different single subfolder, set either value in
`k8s/configmap.yaml` and adjust `RCLONE_FILTER_RULES`:

- `DRIVE_SOURCE`: path inside Drive, for example `Facturas`
- `DRIVE_ROOT_FOLDER_ID`: exact Drive folder ID, with `DRIVE_SOURCE` usually
  left empty

`RCLONE_MODE=sync` is used with `--backup-dir`, so local files removed or
overwritten by the Drive source are moved under `/mirror/archive/` instead of
being deleted outright.

## Internal S3

Cluster services can write to the LAN-only S3 endpoint:

- endpoint: `http://skirmshop-drive-s3.backup-hub.svc.cluster.local:9000`
- bucket: `skirmshop-drive`
- region: `us-east-1`
- addressing: path-style / MinIO-compatible
- Kubernetes Secret: `backup-hub/skirmshop-drive-s3-app`

The app Secret has also been copied to namespace `skirmshop` for store
workloads. Secrets are intentionally not stored in these manifests; recreate or
rotate them with `kubectl create secret generic ... --dry-run=client -o yaml |
kubectl apply -f -`.

After creating Secrets with `kubectl apply`, remove
`kubectl.kubernetes.io/last-applied-configuration` from those Secret objects so
the encoded payload is not retained in object annotations.

The MinIO data directory is stored on the same Sauvage-backed PVC under
`/mirror/s3-data`. The export job copies that bucket to Google Drive every 15
minutes:

- source: `s3://skirmshop-drive/`
- destination in Drive: `skirmshop/k8s-object-store`
- archive path in Drive for overwritten files: `skirmshop/k8s-object-store-archive`
- default mode: `copy`
- throttling: `S3_TO_DRIVE_BWLIMIT=8M`, `S3_TO_DRIVE_TRANSFERS=4`

Use this for documents, generated files, imports, exports and other artifacts
that should be durable in Drive. It is not intended for hot databases or
high-IO application state.
