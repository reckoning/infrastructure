#!/usr/bin/env bash
set -euo pipefail

# Copy Active Storage blobs from the legacy DigitalOcean Spaces bucket into the
# Hetzner Object Storage bucket created by storage.tf.
#
# Usage:
#   ./scripts/migrate-storage.sh [destination] [--dry-run]
#
# Requires rclone and these env vars (source them from 1Password):
#   DO_SPACES_KEY / DO_SPACES_SECRET      DigitalOcean Spaces credentials
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   Hetzner Object Storage credentials
#
# rclone sync is incremental and restartable — run it once ahead of the cutover
# to move the bulk, then again during the maintenance window to catch the delta.

DESTINATION="${1:-live}"
DRY_RUN=""
[ "${2:-}" = "--dry-run" ] && DRY_RUN="--dry-run"

DO_BUCKET="${DO_BUCKET:-reckoning}"
DO_ENDPOINT="${DO_ENDPOINT:-fra1.digitaloceanspaces.com}"
HETZNER_ENDPOINT="${HETZNER_ENDPOINT:-fsn1.your-objectstorage.com}"

: "${DO_SPACES_KEY:?DO_SPACES_KEY must be set}"
: "${DO_SPACES_SECRET:?DO_SPACES_SECRET must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

if ! command -v rclone >/dev/null; then
  echo "Error: rclone is required (brew install rclone)" >&2
  exit 1
fi

TARGET_BUCKET="${TARGET_BUCKET:-}"
if [ -z "$TARGET_BUCKET" ]; then
  terraform workspace select "$DESTINATION" >/dev/null
  TARGET_BUCKET=$(terraform output -raw storage_bucket)
fi

echo "==> Syncing s3://$DO_BUCKET (DigitalOcean) -> s3://$TARGET_BUCKET (Hetzner) ${DRY_RUN:+[dry run]}"

export RCLONE_CONFIG_DOSPACES_TYPE=s3
export RCLONE_CONFIG_DOSPACES_PROVIDER=DigitalOcean
export RCLONE_CONFIG_DOSPACES_ACCESS_KEY_ID="$DO_SPACES_KEY"
export RCLONE_CONFIG_DOSPACES_SECRET_ACCESS_KEY="$DO_SPACES_SECRET"
export RCLONE_CONFIG_DOSPACES_ENDPOINT="$DO_ENDPOINT"

export RCLONE_CONFIG_HETZNER_TYPE=s3
export RCLONE_CONFIG_HETZNER_PROVIDER=Other
export RCLONE_CONFIG_HETZNER_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_HETZNER_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_HETZNER_ENDPOINT="$HETZNER_ENDPOINT"

rclone sync \
  "dospaces:$DO_BUCKET" \
  "hetzner:$TARGET_BUCKET" \
  --checksum \
  --transfers 16 \
  --checkers 32 \
  --progress \
  --stats 10s \
  $DRY_RUN

echo "==> Verifying object counts"
SRC_COUNT=$(rclone size "dospaces:$DO_BUCKET" --json | grep -o '"count":[0-9]*' | cut -d: -f2)
DST_COUNT=$(rclone size "hetzner:$TARGET_BUCKET" --json | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "  source: $SRC_COUNT objects"
echo "  target: $DST_COUNT objects"

if [ -z "$DRY_RUN" ] && [ "$SRC_COUNT" != "$DST_COUNT" ]; then
  echo "Warning: object counts differ — re-run to catch stragglers" >&2
  exit 1
fi
