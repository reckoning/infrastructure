#!/usr/bin/env bash
set -euo pipefail

# Report which fields in the Reckoning 1Password vault are populated.
#
# Usage:
#   ./scripts/check-vault.sh
#
# Prints SET / EMPTY per field — never the values themselves. Terraform reads
# these from the item's TOP-LEVEL fields only (username, credential, public
# key); a value stored in a custom field reads back as an empty string and
# fails at apply time in a confusing way, so this checks the same attributes
# Terraform does.

VAULT="${OP_VAULT:-Reckoning}"
ACCOUNT="${OP_ACCOUNT:-my.1password.eu}"

if ! command -v op >/dev/null; then
  echo "Error: the 1Password CLI is required (brew install 1password-cli)" >&2
  exit 1
fi

check() {
  local title="$1" field="$2" note="${3:-}"
  local value status err attempt errfile
  errfile=$(mktemp)

  # A failed lookup is not the same as an absent item: the CLI also fails on
  # transient API errors, and reporting those as MISSING sends someone hunting
  # for a secret that is actually there. Retry, and only claim absence when the
  # CLI actually says the item is absent.
  for attempt in 1 2 3; do
    if value=$(op item get "$title" --vault "$VAULT" --account "$ACCOUNT" --fields "$field" --reveal 2>"$errfile"); then
      break
    fi
    err=$(tr '\n' ' ' <"$errfile")
    case "$err" in
      *"isn't an item"*|*"not found"*|*"no item matched"*)
        printf '  %-32s %-30s MISSING ITEM\n' "$title" "$field"
        rm -f "$errfile"
        return 1
        ;;
    esac
    if [ "$attempt" -eq 3 ]; then
      printf '  %-32s %-30s LOOKUP FAILED  %s\n' "$title" "$field" "$err"
      rm -f "$errfile"
      return 1
    fi
  done
  rm -f "$errfile"
  if [ -z "$value" ]; then
    status="EMPTY"
  else
    status="SET"
  fi
  printf '  %-32s %-30s %-8s %s\n' "$title" "$field" "$status" "$note"
  [ "$status" = "SET" ]
}

echo "Vault: $VAULT ($ACCOUNT)"
echo

MISSING=0
check "HCLOUD_LIVE"      "credential" "Hetzner API token, reckoning-live project"   || MISSING=$((MISSING + 1))
check "HCLOUD_STAGE"     "credential" "Hetzner API token, reckoning-stage project"  || MISSING=$((MISSING + 1))
check "HETZNER_S3"       "username"   "Object Storage access key"                   || MISSING=$((MISSING + 1))
check "HETZNER_S3"       "credential" "Object Storage secret"                       || MISSING=$((MISSING + 1))
check "SSH Config"       "username"   "name of the SSH key in the Hetzner console"  || MISSING=$((MISSING + 1))
check "Deploy Key Live"  "public key" "injected into authorized_keys by cloud-init" || MISSING=$((MISSING + 1))
check "Deploy Key Stage" "public key" "injected into authorized_keys by cloud-init" || MISSING=$((MISSING + 1))
check "APPSIGNAL"        "credential" "or set enable_appsignal = false"             || MISSING=$((MISSING + 1))

echo
if [ "$MISSING" -gt 0 ]; then
  echo "$MISSING field(s) still to fill. See the Secrets table in README.md."
  exit 1
fi
echo "All fields populated."
