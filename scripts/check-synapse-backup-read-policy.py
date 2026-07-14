#!/usr/bin/env python3
"""Static least-privilege contract for the Synapse S3 backup identity."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "k8s" / "synapse-backup-read-policy.json"
BOOTSTRAP = ROOT / "k8s" / "synapse-backup-read-bootstrap.yaml"
EXTERNAL_SECRET = ROOT / "k8s" / "synapse-backup-read-externalsecret.yaml"


policy = json.loads(POLICY.read_text())
statements = policy["Statement"]
actions = {action for statement in statements for action in statement["Action"]}
resources = {resource for statement in statements for resource in statement["Resource"]}

assert actions == {
    "s3:GetBucketLocation",
    "s3:ListBucket",
    "s3:GetObject",
}, actions
assert resources == {
    "arn:aws:s3:::skirmshop-drive",
    "arn:aws:s3:::skirmshop-drive/*",
}, resources
assert all(statement["Effect"] == "Allow" for statement in statements)

bootstrap = BOOTSTRAP.read_text()
for required in (
    "automountServiceAccountToken: false",
    "target bucket list/get",
    "expect_denied put-object",
    "expect_denied delete-object",
    "expect_denied other-bucket-list",
    "expect_denied other-bucket-get",
    "skirmbooks-backup-s3-read-v2",
):
    assert required in bootstrap, required
assert "kubernetes.io/hostname: ubuntu" not in bootstrap

external_secret = EXTERNAL_SECRET.read_text()
assert "secret/skirmshop-drive/synapse-backup-read-v2" in external_secret
assert "kind: ExternalSecret" in external_secret
assert "AWS_ACCESS_KEY_ID:" not in external_secret
assert "AWS_SECRET_ACCESS_KEY:" not in external_secret

print("Synapse backup S3 read-only policy contract: PASS")
