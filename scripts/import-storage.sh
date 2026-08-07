#!/usr/bin/env bash
set -euo pipefail

# Upload Active Storage blobs from a local archive into the Hetzner Object
# Storage bucket. The DigitalOcean Spaces bucket no longer exists, so this
# archive is the only copy — it is the source of truth for every attachment.
#
# Usage:
#   ./scripts/import-storage.sh <archive.zip|directory> [destination] [--dry-run]
#
# Requires rclone and Hetzner Object Storage credentials:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#
# Active Storage looks blobs up by their exact key, with no prefix. If the
# archive wraps the blobs in a directory, uploading it verbatim would put every
# object one level too deep and silently break every attachment. This script
# detects the wrapper and strips it, and prints a sample of the resulting keys
# so you can eyeball them before anything is written.

SOURCE="${1:-}"
DESTINATION="${2:-live}"
DRY_RUN=""
[ "${3:-}" = "--dry-run" ] && DRY_RUN="--dry-run"

HETZNER_ENDPOINT="${HETZNER_ENDPOINT:-fsn1.your-objectstorage.com}"

if [ -z "$SOURCE" ]; then
  echo "Usage: $0 <archive.zip|directory> [live|stage] [--dry-run]" >&2
  exit 1
fi

if [ ! -e "$SOURCE" ]; then
  echo "Error: '$SOURCE' not found" >&2
  exit 1
fi

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

for cmd in rclone unzip; do
  if ! command -v "$cmd" >/dev/null; then
    echo "Error: $cmd is required (brew install $cmd)" >&2
    exit 1
  fi
done

WORKDIR=""
cleanup() {
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ -d "$SOURCE" ]; then
  BLOB_ROOT="$SOURCE"
  echo "==> Using directory $SOURCE"
else
  WORKDIR=$(mktemp -d)
  echo "==> Extracting $SOURCE ($(du -h "$SOURCE" | cut -f1))"
  unzip -q "$SOURCE" -d "$WORKDIR"
  BLOB_ROOT="$WORKDIR"
fi

# Descend through single-child wrapper directories (__MACOSX and dotfiles from
# the download are ignored) until we reach the level holding the blobs.
while true; do
  ENTRIES=$(find "$BLOB_ROOT" -mindepth 1 -maxdepth 1 \
    ! -name '__MACOSX' ! -name '.*' -exec basename {} \;)
  ENTRY_COUNT=$(printf '%s\n' "$ENTRIES" | grep -c . || true)
  if [ "$ENTRY_COUNT" -eq 1 ] && [ -d "$BLOB_ROOT/$ENTRIES" ]; then
    echo "    stripping wrapper directory: $ENTRIES/"
    BLOB_ROOT="$BLOB_ROOT/$ENTRIES"
  else
    break
  fi
done

FILE_COUNT=$(find "$BLOB_ROOT" -type f ! -path '*/__MACOSX/*' ! -name '.DS_Store' | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "Error: no files found under $BLOB_ROOT" >&2
  exit 1
fi

TARGET_BUCKET="${TARGET_BUCKET:-}"
if [ -z "$TARGET_BUCKET" ]; then
  terraform workspace select "$DESTINATION" >/dev/null
  TARGET_BUCKET=$(terraform output -raw storage_bucket)
fi

echo
echo "==> $FILE_COUNT blobs -> s3://$TARGET_BUCKET ${DRY_RUN:+[dry run]}"
echo "    Keys will be uploaded as (sample):"
find "$BLOB_ROOT" -type f ! -path '*/__MACOSX/*' ! -name '.DS_Store' \
  | head -5 | sed "s|^$BLOB_ROOT/|      |"
echo
echo "    These must match Active Storage blob keys exactly. Cross-check against:"
echo "      bin/rails runner 'puts ActiveStorage::Blob.limit(5).pluck(:key)'"
echo

if [ -z "$DRY_RUN" ]; then
  read -r -p "Proceed? [y/N] " CONFIRM
  case "$CONFIRM" in
    [yY]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

export RCLONE_CONFIG_HETZNER_TYPE=s3
export RCLONE_CONFIG_HETZNER_PROVIDER=Other
export RCLONE_CONFIG_HETZNER_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_HETZNER_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_HETZNER_ENDPOINT="$HETZNER_ENDPOINT"

# copy, not sync — sync would delete anything already in the bucket that the
# archive doesn't contain.
rclone copy \
  "$BLOB_ROOT" \
  "hetzner:$TARGET_BUCKET" \
  --exclude '__MACOSX/**' \
  --exclude '.DS_Store' \
  --checksum \
  --transfers 16 \
  --checkers 32 \
  --progress \
  --stats 10s \
  $DRY_RUN

if [ -n "$DRY_RUN" ]; then
  exit 0
fi

echo "==> Verifying"
UPLOADED=$(rclone size "hetzner:$TARGET_BUCKET" --json | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "    archive: $FILE_COUNT files"
echo "    bucket:  $UPLOADED objects"

if [ "$UPLOADED" -lt "$FILE_COUNT" ]; then
  echo "Warning: bucket holds fewer objects than the archive — re-run to catch stragglers" >&2
  exit 1
fi

cat <<'NEXT'

Confirm attachments resolve before decommissioning anything (from the app repo):

  kamal app exec -d live "bin/rails runner '
    b = ActiveStorage::Blob.order(created_at: :desc).first
    puts %{#{b.key} present=#{b.service.exist?(b.key)}}
  '"

Any missing blob means the archive is incomplete — there is no longer a
DigitalOcean bucket to re-pull from, so resolve it before going live.
NEXT
