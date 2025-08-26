#!/bin/bash

# Create Email Account Script for Docker Mailserver
# Usage: ./create_email.sh [email] [password]
# Example: ./create_email.sh user@domain.com mypassword123

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CONTAINER_NAME="mailserver"
DOMAIN="domain.com"

# Function to display usage
usage() {
    echo -e "${BLUE}Usage:${NC}"
    echo "  $0 [email] [password]"
    echo "  $0 [username] [password]  (will add @domain.com automatically)"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 john@domain.com mypassword123"
    echo "  $0 john mypassword123"
    echo "  $0  (interactive mode)"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  -h, --help     Show this help message"
    echo "  -l, --list     List existing email accounts"
    echo "  -d, --delete   Delete an email account"
    exit 1
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

# Function to create email account
create_email() {
    local email=$1
    local password=$2
    
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
    
    # Create the email account
    echo -e "${BLUE}Creating email account: $email${NC}"
    
    if docker exec -it $CONTAINER_NAME setup email add "$email" "$password"; then
        echo -e "${GREEN}✓ Email account created successfully!${NC}"
        echo -e "${BLUE}Account Details:${NC}"
        echo "  Email: $email"
        echo "  Password: $password"
        echo ""
        echo -e "${BLUE}IMAP/POP3 Settings:${NC}"
        echo "  Server: mail.domain.com (or your server IP)"
        echo "  IMAP Port: 143 (STARTTLS) or 993 (SSL)"
        echo "  POP3 Port: 110 (STARTTLS) or 995 (SSL)"
        echo ""
        echo -e "${BLUE}SMTP Settings:${NC}"
        echo "  Server: mail.domain.com (or your server IP)"
        echo "  Port: 587 (STARTTLS) or 465 (SSL)"
        echo ""
    else
        echo -e "${RED}✗ Failed to create email account!${NC}"
        exit 1
    fi
}

# Main script logic
main() {
    # Check if mailserver container is running
    check_container
    
    # Parse command line arguments
    case "$1" in
        -h|--help)
            usage
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
            
            if [ -z "$email" ] || [ -z "$password" ]; then
                echo -e "${RED}Email and password cannot be empty!${NC}"
                exit 1
            fi
            
            create_email "$email" "$password"
            ;;
        *)
            # Command line arguments provided
            if [ -z "$1" ] || [ -z "$2" ]; then
                echo -e "${RED}Error: Both email and password are required!${NC}"
                echo ""
                usage
            fi
            
            create_email "$1" "$2"
            ;;
    esac
}

# Run the main function
main "$@"
