#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./easy_mailstack.sh --list-email
  ./easy_mailstack.sh --domain <domain> --list-email
  ./easy_mailstack.sh --send-test --email <address> --from <sender>
USAGE
  exit 1
}

# Default flags
DOMAIN=""
LIST_EMAIL=false
SEND_TEST=false
EMAIL_ARG=""
FROM_EMAIL=""  # dynamic – supply with --from

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
    --email)
      EMAIL_ARG="$2"
      shift 2
      ;;
    --from)
      FROM_EMAIL="$2"
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

if [[ -z "$DOMAIN" && ! $LIST_EMAIL && ! $SEND_TEST ]]; then
  usage
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

