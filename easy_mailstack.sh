#!/usr/bin/env bash
set -euo pipefail

# Resolve the directory where the real script lives (follows symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
  local exit_code=${1:-1}
  cat <<USAGE
Usage:
  $0 --list-email
  $0 --domain <domain> --list-email
  $0 --create-email --email <address> [--size <quota>] [--limit <emails-per-day>]
  $0 --send-test --email <address> --from <sender>
  $0 --delete-email --email <address>
  $0 --deactivate-email --email <address>
  $0 --deactivate-email --email <address> --reactivate
  $0 --set-quota --email <address> --size <quota>
  $0 --del-quota --email <address>
  $0 --set-rate-limit [--limit <emails-per-day>]
  $0 --show-rate-limit
  $0 --del-rate-limit
  $0 --persist-live-dkim --domain <domain> [--domain <domain> ...]
  $0 --setup-dkim --domain <domain> [--domain <domain> ...]
  $0 --show-dkim-dns [--domain <domain> ...]
  $0 --import-email --email <address> --source-host <host> [--source-user <user>] [--source-port <port>] [--source-ssl] [--dry-run]

Quota sizes: use M for megabytes, G for gigabytes (e.g. 500M, 1G, 10G)
Rate limit: authenticated SMTP users, emails/day, recipient-counted. Default: 1000
USAGE
  exit "$exit_code"
}

RSPAMD_RATE_LIMIT_FILE="$SCRIPT_DIR/config/rspamd/override.d/ratelimit.conf"
ENV_FILE="$SCRIPT_DIR/.env-mailserver"
ENV_EXAMPLE_FILE="$SCRIPT_DIR/.env-mailserver.example"

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
SET_RATE_LIMIT=false
SHOW_RATE_LIMIT=false
DEL_RATE_LIMIT=false
PERSIST_LIVE_DKIM=false
SETUP_DKIM=false
SHOW_DKIM_DNS=false
IMPORT_EMAIL=false
DRY_RUN=false
EMAIL_ARG=""
FROM_EMAIL=""      # dynamic – supply with --from
SIZE_ARG=""        # quota size – supply with --size
LIMIT_ARG=""       # emails/day – supply with --limit
DKIM_DOMAINS=()
SOURCE_HOST=""     # source IMAP host for migration
SOURCE_USER=""     # source IMAP user (defaults to --email)
SOURCE_PORT=""     # source IMAP port
SOURCE_SSL=false   # use SSL for source connection

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      if [[ -n "${2-}" && ! "$2" =~ ^-- ]]; then
        DOMAIN="$2"
        DKIM_DOMAINS+=("$2")
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
    --set-rate-limit)
      SET_RATE_LIMIT=true
      shift
      ;;
    --show-rate-limit)
      SHOW_RATE_LIMIT=true
      shift
      ;;
    --del-rate-limit)
      DEL_RATE_LIMIT=true
      shift
      ;;
    --persist-live-dkim)
      PERSIST_LIVE_DKIM=true
      shift
      ;;
    --setup-dkim)
      SETUP_DKIM=true
      shift
      ;;
    --show-dkim-dns)
      SHOW_DKIM_DNS=true
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
    --limit)
      LIMIT_ARG="$2"
      shift 2
      ;;
    --import-email)
      IMPORT_EMAIL=true
      shift
      ;;
    --source-host)
      SOURCE_HOST="$2"
      shift 2
      ;;
    --source-user)
      SOURCE_USER="$2"
      shift 2
      ;;
    --source-port)
      SOURCE_PORT="$2"
      shift 2
      ;;
    --source-ssl)
      SOURCE_SSL=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage 0
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

get_env_value() {
  local key=$1
  local file value

  for file in "$ENV_FILE" "$ENV_EXAMPLE_FILE"; do
    [[ -f "$file" ]] || continue
    value=$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
  done

  return 1
}

default_rate_limit() {
  get_env_value MAIL_RATE_LIMIT_PER_DAY || echo "1000"
}

validate_rate_limit() {
  local limit=$1
  [[ "$limit" =~ ^[1-9][0-9]*$ ]]
}

write_rspamd_rate_limit_config() {
  local limit=$1

  if ! validate_rate_limit "$limit"; then
    echo "Error: Invalid rate limit '$limit'. Use a positive integer, e.g. 1000."
    exit 1
  fi

  mkdir -p "$(dirname "$RSPAMD_RATE_LIMIT_FILE")"
  cat > "$RSPAMD_RATE_LIMIT_FILE" <<EOF
# Managed by easy-mailstack. Edit with: easy-mailstack --set-rate-limit --limit <N>
# Rspamd ratelimit module: daily outbound limit per authenticated SMTP user.
# Recipient-counted: one message to 10 recipients consumes 10 from the bucket.
rates {
  authenticated_user_daily = {
    selector = "user.lower";
    bucket = {
      burst = ${limit};
      rate = "${limit} / 1d";
      skip_recipients = false;
      message = "Daily outbound email limit reached";
    }
  }
}
EOF
}

current_rate_limit() {
  local limit
  [[ -f "$RSPAMD_RATE_LIMIT_FILE" ]] || return 1
  limit=$(sed -nE 's/.*rate = "([0-9]+) \/ 1d";.*/\1/p' "$RSPAMD_RATE_LIMIT_FILE" | head -n 1)
  [[ -n "$limit" ]] || return 1
  echo "$limit"
}

print_rate_limit_apply_hint() {
  echo "Restart mailserver to apply:"
  echo "  docker compose restart mailserver"
  echo "Verify rendered Rspamd config after restart:"
  echo "  docker exec -it mailserver rspamadm configdump ratelimit"
}

# Show usage if no action was specified
if [[ "$LIST_EMAIL" == "false" && "$SEND_TEST" == "false" && "$CREATE_EMAIL" == "false" \
   && "$DELETE_EMAIL" == "false" && "$DEACTIVATE_EMAIL" == "false" \
   && "$SET_QUOTA" == "false" && "$DEL_QUOTA" == "false" \
   && "$SET_RATE_LIMIT" == "false" && "$SHOW_RATE_LIMIT" == "false" && "$DEL_RATE_LIMIT" == "false" \
   && "$PERSIST_LIVE_DKIM" == "false" && "$SETUP_DKIM" == "false" && "$SHOW_DKIM_DNS" == "false" \
   && "$IMPORT_EMAIL" == "false" && -z "$DOMAIN" ]]; then
  usage
fi

if $PERSIST_LIVE_DKIM || $SETUP_DKIM || $SHOW_DKIM_DNS; then
  if [[ ! -f "$SCRIPT_DIR/setup_dkim.sh" ]]; then
    echo "Error: setup_dkim.sh not found in $SCRIPT_DIR"
    exit 1
  fi

  if [[ ${#DKIM_DOMAINS[@]} -eq 0 && "$SHOW_DKIM_DNS" == "false" ]]; then
    echo "Error: --domain is required for DKIM setup"
    exit 1
  fi

  if $PERSIST_LIVE_DKIM; then
    exec "$SCRIPT_DIR/setup_dkim.sh" persist-live "${DKIM_DOMAINS[@]}"
  elif $SETUP_DKIM; then
    exec "$SCRIPT_DIR/setup_dkim.sh" generate "${DKIM_DOMAINS[@]}"
  else
    if [[ ${#DKIM_DOMAINS[@]} -gt 0 ]]; then
      exec "$SCRIPT_DIR/setup_dkim.sh" show-dns "${DKIM_DOMAINS[@]}"
    else
      exec "$SCRIPT_DIR/setup_dkim.sh" show-dns
    fi
  fi
fi

if $SET_RATE_LIMIT; then
  limit="${LIMIT_ARG:-$(default_rate_limit)}"
  write_rspamd_rate_limit_config "$limit"
  echo "Rspamd rate limit set to $limit emails/day per authenticated SMTP user."
  echo "Config: $RSPAMD_RATE_LIMIT_FILE"
  print_rate_limit_apply_hint
  exit 0
fi

if $SHOW_RATE_LIMIT; then
  if limit=$(current_rate_limit); then
    echo "Rspamd rate limit: $limit emails/day per authenticated SMTP user"
    echo "Config: $RSPAMD_RATE_LIMIT_FILE"
  else
    echo "Rspamd rate limit config not found."
    echo "Create one with: $0 --set-rate-limit --limit $(default_rate_limit)"
  fi
  exit 0
fi

if $DEL_RATE_LIMIT; then
  if [[ -f "$RSPAMD_RATE_LIMIT_FILE" ]]; then
    rm -f "$RSPAMD_RATE_LIMIT_FILE"
    echo "Rspamd rate limit config removed."
    print_rate_limit_apply_hint
  else
    echo "Rspamd rate limit config not found."
  fi
  exit 0
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
    if [[ -n "$LIMIT_ARG" ]]; then
      create_args+=("$LIMIT_ARG")
    fi
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

if $IMPORT_EMAIL; then
  # Check if imapsync is installed
  if ! command -v imapsync &>/dev/null; then
    echo "imapsync is not installed."
    printf "Install it now? [Y/n]: "
    read -r install_confirm
    if [[ "$install_confirm" =~ ^[Nn]$ ]]; then
      echo "Aborted. Install imapsync manually: apt install imapsync"
      exit 1
    fi
    echo "Installing imapsync ..."
    apt-get update -qq && apt-get install -y -qq imapsync || {
      echo "Error: Failed to install imapsync."
      exit 1
    }
    echo "imapsync installed successfully."
  fi

  # Validate required arguments
  if [[ -z "$EMAIL_ARG" ]]; then
    echo "Error: --email is required (the destination email on your server)"
    exit 1
  fi
  if [[ -z "$SOURCE_HOST" ]]; then
    echo "Error: --source-host is required (e.g. imap.hostinger.com)"
    exit 1
  fi

  # Default source user to the same email address
  [[ -z "$SOURCE_USER" ]] && SOURCE_USER="$EMAIL_ARG"

  # Detect destination IMAP host from the mailserver container
  DEST_HOST=$(docker exec -i mailserver hostname 2>/dev/null || echo "localhost")

  # Prompt for passwords
  echo "=== Email Migration ==="
  echo "  Source: $SOURCE_USER @ $SOURCE_HOST"
  echo "  Dest:   $EMAIL_ARG @ $DEST_HOST"
  echo ""
  read -s -p "Enter password for SOURCE ($SOURCE_USER on $SOURCE_HOST): " source_pass
  echo ""
  read -s -p "Enter password for DESTINATION ($EMAIL_ARG on your server): " dest_pass
  echo ""
  echo ""

  # Build imapsync command
  imapsync_cmd=(
    imapsync
    --host1 "$SOURCE_HOST"
    --user1 "$SOURCE_USER"
    --password1 "$source_pass"
    --host2 "$DEST_HOST"
    --user2 "$EMAIL_ARG"
    --password2 "$dest_pass"
    --automap
    --addheader
  )

  # Source port
  if [[ -n "$SOURCE_PORT" ]]; then
    imapsync_cmd+=(--port1 "$SOURCE_PORT")
  fi

  # Source SSL
  if $SOURCE_SSL; then
    imapsync_cmd+=(--ssl1)
    # Default port for SSL if not specified
    if [[ -z "$SOURCE_PORT" ]]; then
      imapsync_cmd+=(--port1 993)
    fi
  fi

  # Destination is local, use port 143 without SSL
  imapsync_cmd+=(--port2 143)

  # Dry run mode
  if $DRY_RUN; then
    imapsync_cmd+=(--dry)
    echo "[DRY RUN] No emails will actually be transferred."
    echo ""
  fi

  echo "Starting migration..."
  echo "Command: imapsync --host1 $SOURCE_HOST --user1 $SOURCE_USER --host2 $DEST_HOST --user2 $EMAIL_ARG [passwords hidden]"
  echo "---"

  "${imapsync_cmd[@]}" && {
    echo ""
    echo "=== Migration complete ==="
    echo "Emails from '$SOURCE_USER' on '$SOURCE_HOST' have been imported to '$EMAIL_ARG'."
    if ! $DRY_RUN; then
      echo ""
      echo "Tip: After updating MX records, run this command again to catch"
      echo "     any emails that arrived during DNS propagation."
    fi
  } || {
    echo ""
    echo "Error: Migration failed. Check the output above for details."
    echo "Common issues:"
    echo "  - Wrong password"
    echo "  - Wrong source host (try: imap.provider.com or mail.provider.com)"
    echo "  - Source requires SSL (add --source-ssl)"
    echo "  - Firewall blocking IMAP ports"
    exit 1
  }
  exit 0
fi
