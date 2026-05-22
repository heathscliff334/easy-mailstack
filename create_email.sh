#!/bin/bash

# Create Email Account Script for Docker Mailserver
# Usage: ./create_email.sh [email] [password] [quota] [daily_limit]
# Example: ./create_email.sh user@domain.com mypassword123 1G 1000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CONTAINER_NAME="mailserver"
DOMAIN="domain.com"
RSPAMD_RATE_LIMIT_FILE="$SCRIPT_DIR/config/rspamd/override.d/ratelimit.conf"
ENV_FILE="$SCRIPT_DIR/.env-mailserver"
ENV_EXAMPLE_FILE="$SCRIPT_DIR/.env-mailserver.example"

# Function to display usage
usage() {
    local exit_code=${1:-1}
    echo -e "${BLUE}Usage:${NC}"
    echo "  $0 [email] [password] [quota] [daily_limit]"
    echo "  $0 [username] [password] [quota] [daily_limit]  (will add @domain.com automatically)"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 john@domain.com mypassword123 1G 1000"
    echo "  $0 john mypassword123 500M 250"
    echo "  $0 john mypassword123 0      (unlimited quota)"
    echo "  $0  (interactive mode)"
    echo ""
    echo -e "${BLUE}Quota sizes:${NC} use M for MB, G for GB, T for TB, or 0 for unlimited"
    echo -e "${BLUE}Daily limit:${NC} authenticated SMTP users, emails/day, recipient-counted; omit to keep current"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  -h, --help     Show this help message"
    echo "  -l, --list     List existing email accounts"
    echo "  -d, --delete   Delete an email account"
    exit "$exit_code"
}

# Function to check if mailserver container is running
check_container() {
    if ! docker ps --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}Error: Mailserver container '${CONTAINER_NAME}' is not running!${NC}"
        echo "Please start your mailserver first with: docker compose up -d"
        exit 1
    fi
}

# Function to validate email format
validate_email() {
    local email=$1
    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate password strength
validate_password() {
    local password=$1
    if [ ${#password} -lt 8 ]; then
        echo -e "${YELLOW}Warning: Password is less than 8 characters. Consider using a stronger password.${NC}"
    fi
}

# Function to list existing email accounts
list_emails() {
    echo -e "${BLUE}Listing existing email accounts:${NC}"
    docker exec -it $CONTAINER_NAME setup email list
}

# Function to delete email account
delete_email() {
    local email=$1
    if [ -z "$email" ]; then
        read -p "Enter email address to delete: " email
    fi
    
    if validate_email "$email"; then
        echo -e "${YELLOW}Are you sure you want to delete $email? (y/N)${NC}"
        read -r confirmation
        if [[ $confirmation =~ ^[Yy]$ ]]; then
            docker exec -it $CONTAINER_NAME setup email del "$email"
            echo -e "${GREEN}Email account $email deleted successfully!${NC}"
        else
            echo "Deletion cancelled."
        fi
    else
        echo -e "${RED}Invalid email format: $email${NC}"
        exit 1
    fi
}

# Function to detect mailserver configuration from the running container
detect_mail_config() {
    # Read environment variables from the running container
    local env_output
    env_output=$(docker exec -it $CONTAINER_NAME env 2>/dev/null) || return 1

    SSL_TYPE_VAL=$(echo "$env_output" | grep -oP '^SSL_TYPE=\K.*' | tr -d '\r' || true)
    ENABLE_POP3_VAL=$(echo "$env_output" | grep -oP '^ENABLE_POP3=\K.*' | tr -d '\r' || true)
    ENABLE_IMAP_VAL=$(echo "$env_output" | grep -oP '^ENABLE_IMAP=\K.*' | tr -d '\r' || true)
    HOSTNAME_VAL=$(echo "$env_output" | grep -oP '^OVERRIDE_HOSTNAME=\K.*' | tr -d '\r' || true)

    # Defaults
    [[ -z "$ENABLE_IMAP_VAL" ]] && ENABLE_IMAP_VAL="1"
    [[ -z "$ENABLE_POP3_VAL" ]] && ENABLE_POP3_VAL="0"
    [[ -z "$HOSTNAME_VAL" ]]    && HOSTNAME_VAL="mail.domain.com"
}

# Function to print connection info based on detected config
print_connection_info() {
    detect_mail_config

    local has_ssl=false
    if [[ -n "$SSL_TYPE_VAL" && "$SSL_TYPE_VAL" != "false" && "$SSL_TYPE_VAL" != "0" ]]; then
        has_ssl=true
    fi

    # --- IMAP ---
    if [[ "$ENABLE_IMAP_VAL" == "1" ]]; then
        echo -e "${BLUE}IMAP Settings:${NC}"
        echo "  Server: $HOSTNAME_VAL"
        if $has_ssl; then
            echo "  Port: 993 (SSL/TLS)  or  143 (STARTTLS)"
        else
            echo "  Port: 143 (no encryption)"
        fi
        echo ""
    fi

    # --- POP3 ---
    if [[ "$ENABLE_POP3_VAL" == "1" ]]; then
        echo -e "${BLUE}POP3 Settings:${NC}"
        echo "  Server: $HOSTNAME_VAL"
        if $has_ssl; then
            echo "  Port: 995 (SSL/TLS)  or  110 (STARTTLS)"
        else
            echo "  Port: 110 (no encryption)"
        fi
        echo ""
    fi

    # --- SMTP ---
    echo -e "${BLUE}SMTP Settings:${NC}"
    echo "  Server: $HOSTNAME_VAL"
    if $has_ssl; then
        echo "  Port: 465 (SSL/TLS)  or  587 (STARTTLS)"
    else
        echo "  Port: 587 (no encryption)"
    fi
    echo ""

    if ! $has_ssl; then
        echo -e "${YELLOW}⚠  SSL is not configured. Connections are unencrypted.${NC}"
        echo -e "${YELLOW}   Consider setting SSL_TYPE in your .env-mailserver for production use.${NC}"
        echo ""
    fi
}

# Function to validate quota format
validate_quota() {
    local quota=$1
    if [[ "$quota" == "0" || "$quota" =~ ^[0-9]+(M|G|T)$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to read default values from .env-mailserver, falling back to example values
get_env_value() {
    local key=$1
    local file value

    for file in "$ENV_FILE" "$ENV_EXAMPLE_FILE"; do
        [ -f "$file" ] || continue
        value=$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    done

    return 1
}

# Function to detect current Rspamd daily send limit
current_rate_limit() {
    local limit
    [ -f "$RSPAMD_RATE_LIMIT_FILE" ] || return 1
    limit=$(sed -nE 's/.*rate = "([0-9]+) \/ 1d";.*/\1/p' "$RSPAMD_RATE_LIMIT_FILE" | head -n 1)
    [ -n "$limit" ] || return 1
    echo "$limit"
}

# Function to get default daily send limit
default_rate_limit() {
    current_rate_limit || get_env_value MAIL_RATE_LIMIT_PER_DAY || echo "1000"
}

# Function to validate daily send limit
validate_rate_limit() {
    local limit=$1
    [[ "$limit" =~ ^[1-9][0-9]*$ ]]
}

# Function to write Rspamd ratelimit configuration
write_rspamd_rate_limit_config() {
    local limit=$1

    if ! validate_rate_limit "$limit"; then
        echo -e "${RED}Invalid daily send limit: $limit${NC}"
        echo "Use a positive integer, e.g. 1000"
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

# Function to print Rspamd apply hint
print_rate_limit_apply_hint() {
    echo -e "${YELLOW}Restart mailserver to apply the Rspamd rate limit:${NC}"
    echo "  docker compose restart mailserver"
    echo "Verify after restart:"
    echo "  docker exec -it mailserver rspamadm configdump ratelimit"
}

# Function to create email account
create_email() {
    local email=$1
    local password=$2
    local quota=${3:-0}
    local daily_limit=${4:-}
    
    # If email doesn't contain @, add the default domain
    if [[ ! $email == *"@"* ]]; then
        email="${email}@${DOMAIN}"
        echo -e "${BLUE}Using full email address: $email${NC}"
    fi
    
    # Validate email format
    if ! validate_email "$email"; then
        echo -e "${RED}Invalid email format: $email${NC}"
        exit 1
    fi
    
    # Validate password
    validate_password "$password"

    # Validate quota format
    if ! validate_quota "$quota"; then
        echo -e "${RED}Invalid quota format: $quota${NC}"
        echo "Use M for MB, G for GB, T for TB, or 0 for unlimited (e.g. 500M, 1G, 0)"
        exit 1
    fi

    # Validate daily send limit before creating the account
    if [ -n "$daily_limit" ] && ! validate_rate_limit "$daily_limit"; then
        echo -e "${RED}Invalid daily send limit: $daily_limit${NC}"
        echo "Use a positive integer, e.g. 1000"
        exit 1
    fi
    
    # Create the email account
    echo -e "${BLUE}Creating email account: $email${NC}"
    
    if docker exec -it $CONTAINER_NAME setup email add "$email" "$password"; then
        echo -e "${GREEN}✓ Email account created successfully!${NC}"

        # Set quota
        if [[ "$quota" != "0" ]]; then
            echo -e "${BLUE}Setting quota to $quota ...${NC}"
            if docker exec -it $CONTAINER_NAME setup quota set "$email" "$quota" 2>/dev/null; then
                echo -e "${GREEN}✓ Quota set to $quota${NC}"
            else
                echo -e "${YELLOW}⚠  Failed to set quota. Make sure ENABLE_QUOTAS=1 in .env-mailserver${NC}"
            fi
        else
            echo -e "${BLUE}Quota: unlimited${NC}"
        fi

        if [ -n "$daily_limit" ]; then
            write_rspamd_rate_limit_config "$daily_limit"
            echo -e "${GREEN}✓ Daily send limit set to $daily_limit emails/day per authenticated SMTP user${NC}"
            print_rate_limit_apply_hint
        fi

        echo ""
        echo -e "${BLUE}Account Details:${NC}"
        echo "  Email: $email"
        echo "  Password: $password"
        echo "  Quota: $([ "$quota" = "0" ] && echo "unlimited" || echo "$quota")"
        if [ -n "$daily_limit" ]; then
            echo "  Daily send limit: $daily_limit emails/day (global authenticated-user limit)"
        fi
        echo ""
        print_connection_info
    else
        echo -e "${RED}✗ Failed to create email account!${NC}"
        exit 1
    fi
}

# Main script logic
main() {
    case "${1:-}" in
        -h|--help)
            usage 0
            ;;
    esac

    # Check if mailserver container is running
    check_container
    
    # Parse command line arguments
    case "$1" in
        -h|--help)
            usage 0
            ;;
        -l|--list)
            list_emails
            exit 0
            ;;
        -d|--delete)
            delete_email "$2"
            exit 0
            ;;
        "")
            # Interactive mode
            echo -e "${BLUE}=== Interactive Email Account Creation ===${NC}"
            read -p "Enter email address (or just username for @domain.com): " email
            read -s -p "Enter password: " password
            echo ""
            read -p "Enter quota (e.g. 500M, 1G, or 0 for unlimited) [0]: " quota
            quota=${quota:-0}
            default_daily_limit=$(default_rate_limit)
            read -p "Enter daily SMTP send limit (emails/day, blank to keep current [$default_daily_limit]): " daily_limit
            
            if [ -z "$email" ] || [ -z "$password" ]; then
                echo -e "${RED}Email and password cannot be empty!${NC}"
                exit 1
            fi
            
            create_email "$email" "$password" "$quota" "$daily_limit"
            ;;
        *)
            # Command line arguments provided
            if [ -z "$1" ] || [ -z "$2" ]; then
                echo -e "${RED}Error: Both email and password are required!${NC}"
                echo ""
                usage
            fi
            
            create_email "$1" "$2" "${3:-0}" "${4:-}"
            ;;
    esac
}

# Run the main function
main "$@"
