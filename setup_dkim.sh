#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
DKIM_SIGNING_CONF="$CONFIG_DIR/rspamd/override.d/dkim_signing.conf"
CONTAINER_NAME="${CONTAINER_NAME:-mailserver}"
SELECTOR="${DKIM_SELECTOR:-mail}"

usage() {
  cat <<USAGE
Usage:
  $0 persist-live <domain> [domain...]
  $0 generate <domain> [domain...]
  $0 show-dns [domain...]

Commands:
  persist-live  Copy an existing manual OpenDKIM key from the running container
                into ./config and configure Rspamd to use it. Keeps current DNS.
  generate      Generate a new persistent DKIM key with Docker Mailserver setup.
                DNS TXT record must be updated after this.
  show-dns      Print DKIM DNS TXT record files from ./config.

Environment:
  CONTAINER_NAME=mailserver
  DKIM_SELECTOR=mail
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

validate_domain() {
  local domain=$1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Invalid domain '$domain'"
}

detect_compose_file() {
  local file
  for file in "$SCRIPT_DIR/compose.yaml" "$SCRIPT_DIR/compose.yml" "$SCRIPT_DIR/compose.yaml_example"; do
    [[ -f "$file" ]] && {
      echo "$file"
      return 0
    }
  done
  return 1
}

detect_dms_image() {
  local compose_file image
  compose_file=$(detect_compose_file) || {
    echo "ghcr.io/docker-mailserver/docker-mailserver:15.1.0"
    return 0
  }

  image=$(awk '/image:[[:space:]]*.*docker-mailserver/ {print $2; exit}' "$compose_file")
  if [[ -n "$image" ]]; then
    echo "$image"
  else
    echo "ghcr.io/docker-mailserver/docker-mailserver:15.1.0"
  fi
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR/opendkim/keys" "$CONFIG_DIR/rspamd/override.d"
}

copy_live_opendkim_key() {
  local domain=$1
  local dest="$CONFIG_DIR/opendkim/keys/$domain"

  validate_domain "$domain"
  ensure_dirs
  mkdir -p "$dest"

  docker cp "$CONTAINER_NAME:/etc/opendkim/keys/$domain/$SELECTOR.private" "$dest/$SELECTOR.private" \
    || die "Could not copy /etc/opendkim/keys/$domain/$SELECTOR.private from container '$CONTAINER_NAME'"

  if docker cp "$CONTAINER_NAME:/etc/opendkim/keys/$domain/$SELECTOR.txt" "$dest/$SELECTOR.txt" 2>/dev/null; then
    :
  else
    echo "Warning: public DNS TXT file not found in container for $domain; private key was copied."
  fi

  chmod 600 "$dest/$SELECTOR.private"
  echo "Persisted DKIM private key: $dest/$SELECTOR.private"
}

write_rspamd_dkim_signing_conf() {
  local domain

  ensure_dirs
  {
    cat <<EOF
# Managed by setup_dkim.sh. Rspamd signs outbound mail with persisted DKIM keys.
enabled = true;

sign_authenticated = true;
sign_local = true;

use_domain = "header";
use_redis = false;
use_esld = true;
check_pubkey = true;

selector = "$SELECTOR";

domain {
EOF

    for domain in "$@"; do
      validate_domain "$domain"
      cat <<EOF
  $domain {
    path = "/tmp/docker-mailserver/opendkim/keys/$domain/$SELECTOR.private";
    selector = "$SELECTOR";
  }
EOF
    done

    cat <<EOF
}
EOF
  } > "$DKIM_SIGNING_CONF"

  echo "Wrote Rspamd DKIM signing config: $DKIM_SIGNING_CONF"
}

generate_dkim_key() {
  local domain=$1
  local image env_args=()

  validate_domain "$domain"
  ensure_dirs
  image=$(detect_dms_image)

  if [[ -f "$SCRIPT_DIR/.env-mailserver" ]]; then
    env_args+=(--env-file "$SCRIPT_DIR/.env-mailserver")
  elif [[ -f "$SCRIPT_DIR/.env-mailserver.example" ]]; then
    env_args+=(--env-file "$SCRIPT_DIR/.env-mailserver.example")
  fi

  docker run --rm \
    "${env_args[@]}" \
    -v "$CONFIG_DIR:/tmp/docker-mailserver" \
    --entrypoint /bin/bash \
    "$image" \
    -c 'exec setup config dkim domain "$1"' \
    _ "$domain"
}

show_dns_records() {
  local domain=${1:-}
  local found=false
  local file

  while IFS= read -r file; do
    if [[ -n "$domain" && "$file" != *"$domain"* ]]; then
      continue
    fi
    found=true
    echo ""
    echo "DNS TXT from: $file"
    sed -n '1,120p' "$file"
  done < <(
    find "$CONFIG_DIR" -type f \( -name "*.txt" -o -name "*.dns.txt" \) 2>/dev/null | sort
  )

  if [[ "$found" == "false" ]]; then
    if [[ -n "$domain" ]]; then
      echo "No DKIM DNS TXT files found for $domain under $CONFIG_DIR"
    else
      echo "No DKIM DNS TXT files found under $CONFIG_DIR"
    fi
  fi
}

command=${1:-}
shift || true

case "$command" in
  persist-live)
    [[ $# -gt 0 ]] || die "Provide at least one domain"
    for domain in "$@"; do
      copy_live_opendkim_key "$domain"
    done
    write_rspamd_dkim_signing_conf "$@"
    for domain in "$@"; do
      show_dns_records "$domain"
    done
    echo ""
    echo "Restart mailserver after verifying .env has ENABLE_RSPAMD=1 and ENABLE_OPENDKIM=0:"
    echo "  docker compose restart mailserver"
    ;;
  generate)
    [[ $# -gt 0 ]] || die "Provide at least one domain"
    for domain in "$@"; do
      generate_dkim_key "$domain"
      show_dns_records "$domain"
    done
    echo ""
    echo "Update DNS TXT records above, then restart mailserver:"
    echo "  docker compose restart mailserver"
    ;;
  show-dns)
    if [[ $# -gt 0 ]]; then
      for domain in "$@"; do
        show_dns_records "$domain"
      done
    else
      show_dns_records
    fi
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage
    die "Unknown command '$command'"
    ;;
esac
