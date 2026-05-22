#!/usr/bin/env bash
set -euo pipefail

# Resolve the directory where this script lives (for calling sibling scripts)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<USAGE
Usage:
  $0 --list-email
  $0 --domain <domain> --list-email
  $0 --create-email --email <address> [--size <quota>]
  $0 --send-test --email <address> --from <sender>
  $0 --delete-email --email <address>
  $0 --deactivate-email --email <address>
  $0 --deactivate-email --email <address> --reactivate
  $0 --set-quota --email <address> --size <quota>
  $0 --del-quota --email <address>

Quota sizes: use M for megabytes, G for gigabytes (e.g. 500M, 1G, 10G)
USAGE
  exit 1
}

# Default flags
DOMAIN=""
LIST_EMAIL=false
SEND_TEST=false
CREATE_EMAIL=false
DELETE_EMAIL=false
DEACTIVATE_EMAIL=false
REACTIVATE=false
SET_QUOTA=false
DEL_QUOTA=false
EMAIL_ARG=""
FROM_EMAIL=""  # dynamic – supply with --from
SIZE_ARG=""    # quota size – supply with --size

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      if [[ -n "${2-}" && ! "$2" =~ ^-- ]]; then
        DOMAIN="$2"
        shift 2
      else
        DOMAIN=""
        shift
      fi
      ;;
    --list-email)
      LIST_EMAIL=true
      shift
      ;;
    --send-test)
      SEND_TEST=true
      shift
      ;;
    --create-email)
      CREATE_EMAIL=true
      shift
      ;;
    --delete-email)
      DELETE_EMAIL=true
      shift
      ;;
    --deactivate-email)
      DEACTIVATE_EMAIL=true
      shift
      ;;
    --reactivate)
      REACTIVATE=true
      shift
      ;;
    --set-quota)
      SET_QUOTA=true
      shift
      ;;
    --del-quota)
      DEL_QUOTA=true
      shift
      ;;
    --email)
      EMAIL_ARG="$2"
      shift 2
      ;;
    --from)
      FROM_EMAIL="$2"
      shift 2
      ;;
    --size)
      SIZE_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

fetch_emails() {
  docker exec -i mailserver setup email list 2>/dev/null || {
    echo "Error: Could not retrieve email list. Is the mailserver container running?"
    exit 1
  }
}

# Show usage if no action was specified
if [[ "$LIST_EMAIL" == "false" && "$SEND_TEST" == "false" && "$CREATE_EMAIL" == "false" \
   && "$DELETE_EMAIL" == "false" && "$DEACTIVATE_EMAIL" == "false" \
   && "$SET_QUOTA" == "false" && "$DEL_QUOTA" == "false" && -z "$DOMAIN" ]]; then
  usage
fi

if $CREATE_EMAIL; then
  if [[ ! -f "$SCRIPT_DIR/create_email.sh" ]]; then
    echo "Error: create_email.sh not found in $SCRIPT_DIR"
    exit 1
  fi
  # Build arguments for create_email.sh
  create_args=()
  if [[ -n "$EMAIL_ARG" ]]; then
    create_args+=("$EMAIL_ARG")
    # Prompt for password
    read -s -p "Enter password for $EMAIL_ARG: " password
    echo ""
    create_args+=("$password")
    # Add quota if specified, default to 0 (unlimited)
    create_args+=("${SIZE_ARG:-0}")
  fi
  # Call create_email.sh (no args = interactive mode)
  exec "$SCRIPT_DIR/create_email.sh" "${create_args[@]+${create_args[@]}}"
fi

if $SEND_TEST; then
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required when using --send-test"
    exit 1
  fi
  echo "Sending test email to $EMAIL_ARG from $FROM_EMAIL..."
  docker exec -i mailserver bash -c "echo 'Test email from Docker‑Mailserver' | mail -s 'Test Email' -r \"$FROM_EMAIL\" $EMAIL_ARG"
  echo "Test email sent."
  exit 0
fi

if $DELETE_EMAIL; then
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required when using --delete-email"
    exit 1
  fi
  # Verify the account exists
  if ! fetch_emails | grep -qE "^${EMAIL_ARG} "; then
    echo "Error: Email account '$EMAIL_ARG' does not exist."
    exit 1
  fi
  # Confirm deletion
  printf "Are you sure you want to permanently delete '%s'? [y/N]: " "$EMAIL_ARG"
  read -r confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Deletion cancelled."
    exit 0
  fi
  echo "Deleting email account: $EMAIL_ARG ..."
  docker exec -i mailserver setup email del "$EMAIL_ARG" 2>/dev/null && \
    echo "Email account '$EMAIL_ARG' has been deleted." || {
    echo "Error: Failed to delete email account '$EMAIL_ARG'."
    exit 1
  }
  exit 0
fi

if $DEACTIVATE_EMAIL; then
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required when using --deactivate-email"
    exit 1
  fi
  # Verify the account exists
  if ! fetch_emails | grep -qE "^${EMAIL_ARG} "; then
    echo "Error: Email account '$EMAIL_ARG' does not exist."
    exit 1
  fi
  if $REACTIVATE; then
    echo "Reactivating email account: $EMAIL_ARG ..."
    docker exec -i mailserver setup email restrict del "$EMAIL_ARG" send 2>/dev/null
    docker exec -i mailserver setup email restrict del "$EMAIL_ARG" receive 2>/dev/null
    echo "Email account '$EMAIL_ARG' has been reactivated (send & receive restrictions removed)."
  else
    echo "Deactivating email account: $EMAIL_ARG ..."
    docker exec -i mailserver setup email restrict add "$EMAIL_ARG" send 2>/dev/null
    docker exec -i mailserver setup email restrict add "$EMAIL_ARG" receive 2>/dev/null
    echo "Email account '$EMAIL_ARG' has been deactivated (send & receive restricted)."
    echo "To reactivate, run: $0 --deactivate-email --email $EMAIL_ARG --reactivate"
  fi
  exit 0
fi

if $SET_QUOTA; then
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required when using --set-quota"
    exit 1
  fi
  if [[ -z "$SIZE_ARG" ]]; then
    echo "Error: --size is required when using --set-quota (e.g. 500M, 1G, 10G)"
    exit 1
  fi
  # Validate size format
  if [[ ! "$SIZE_ARG" =~ ^[0-9]+(M|G|T)$ ]]; then
    echo "Error: Invalid quota size '$SIZE_ARG'. Use format like 500M, 1G, or 10G."
    exit 1
  fi
  # Verify the account exists
  if ! fetch_emails | grep -qE "^${EMAIL_ARG} "; then
    echo "Error: Email account '$EMAIL_ARG' does not exist."
    exit 1
  fi
  echo "Setting quota for $EMAIL_ARG to $SIZE_ARG ..."
  docker exec -i mailserver setup quota set "$EMAIL_ARG" "$SIZE_ARG" 2>/dev/null && \
    echo "Quota for '$EMAIL_ARG' has been set to $SIZE_ARG." || {
    echo "Error: Failed to set quota. Make sure ENABLE_QUOTAS=1 is set in your .env-mailserver."
    exit 1
  }
  exit 0
fi

if $DEL_QUOTA; then
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required when using --del-quota"
    exit 1
  fi
  # Verify the account exists
  if ! fetch_emails | grep -qE "^${EMAIL_ARG} "; then
    echo "Error: Email account '$EMAIL_ARG' does not exist."
    exit 1
  fi
  echo "Removing quota for $EMAIL_ARG ..."
  docker exec -i mailserver setup quota del "$EMAIL_ARG" 2>/dev/null && \
    echo "Quota for '$EMAIL_ARG' has been removed (unlimited)." || {
    echo "Error: Failed to remove quota."
    exit 1
  }
  exit 0
fi

if $LIST_EMAIL; then
  if [[ -n "$DOMAIN" ]]; then
    echo "=== Email accounts for domain: $DOMAIN ==="
    fetch_emails | grep -E "@${DOMAIN}$" || {
      echo "No email accounts found for domain '$DOMAIN'."
      exit 0
    }
  else
    echo "=== All email accounts ==="
    fetch_emails
  fi
  exit 0
fi

