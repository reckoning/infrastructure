#!/usr/bin/env bash

# The variables inside the ssh command strings and the heredoc are expanded on
# the client on purpose — they are local configuration, not remote shell state.
# shellcheck disable=SC2029,SC2087

set -euo pipefail

# Restore a Postgres dump into the Kamal `db` accessory of a destination.
#
# Usage:
#   ./scripts/import-db.sh <dump-file> [destination]
#
#   dump-file    A pg_dump custom-format (.dump) or plain SQL (.sql/.sql.gz) file.
#                This is the dump you already hold in your dev environment.
#   destination  Kamal destination — live (default) or stage.
#
# Requires:
#   - SSH access to the server hosting the db accessory (see `terraform output`)
#   - the destination's DB_HOST/DB_USER/DB_NAME exported, or the defaults below
#
# This DROPS and recreates the target database. It prompts before doing so.

DUMP_FILE="${1:-}"
DESTINATION="${2:-live}"

DB_NAME="${DB_NAME:-reckoning_production}"
DB_USER="${DB_USER:-reckoning}"
CONTAINER="${DB_CONTAINER:-reckoning-db}"

if [ -z "$DUMP_FILE" ]; then
  echo "Usage: $0 <dump-file> [live|stage]" >&2
  exit 1
fi

if [ ! -f "$DUMP_FILE" ]; then
  echo "Error: dump file '$DUMP_FILE' not found" >&2
  exit 1
fi

SSH_HOST="${SSH_HOST:-}"
if [ -z "$SSH_HOST" ]; then
  echo "Resolving host from terraform output (workspace: $DESTINATION)..."
  terraform workspace select "$DESTINATION" >/dev/null
  SSH_HOST=$(terraform output -raw web_server_ips | cut -d, -f1)
fi

SSH_TARGET="${SSH_USER:-kamal}@${SSH_HOST}"

echo "About to restore into destination '$DESTINATION'"
echo "  dump:      $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
echo "  host:      $SSH_TARGET"
echo "  container: $CONTAINER"
echo "  database:  $DB_NAME (WILL BE DROPPED AND RECREATED)"
echo
read -r -p "Type the destination name to confirm: " CONFIRM
if [ "$CONFIRM" != "$DESTINATION" ]; then
  echo "Aborted." >&2
  exit 1
fi

echo "==> Terminating existing connections and recreating $DB_NAME"
ssh "$SSH_TARGET" "docker exec -i $CONTAINER psql -U $DB_USER -d postgres" <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS $DB_NAME;
CREATE DATABASE $DB_NAME OWNER $DB_USER;
SQL

echo "==> Streaming dump into $CONTAINER"
case "$DUMP_FILE" in
  *.dump|*.pgdump|*.custom)
    ssh "$SSH_TARGET" \
      "docker exec -i $CONTAINER pg_restore -U $DB_USER -d $DB_NAME --no-owner --no-privileges --clean --if-exists" \
      < "$DUMP_FILE"
    ;;
  *.sql.gz|*.gz)
    gunzip -c "$DUMP_FILE" | ssh "$SSH_TARGET" \
      "docker exec -i $CONTAINER psql -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1"
    ;;
  *.sql)
    ssh "$SSH_TARGET" \
      "docker exec -i $CONTAINER psql -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1" \
      < "$DUMP_FILE"
    ;;
  *)
    echo "Error: unrecognised dump format for '$DUMP_FILE'" >&2
    exit 1
    ;;
esac

echo "==> Restore complete. Verifying"
ssh "$SSH_TARGET" "docker exec -i $CONTAINER psql -U $DB_USER -d $DB_NAME -c '\\dt'" | head -20

cat <<'NEXT'

Next steps (from the app repo):
  kamal app exec -d <destination> "bin/rails db:migrate"
  kamal app exec -d <destination> "bin/rails runner 'puts Invoice.count'"
NEXT
