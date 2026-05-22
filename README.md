# Easy Mailstack

Easily set up a **Mail Server** with **Roundcube Webmail** using Docker — without any hassle.

## 📌 Overview
**Easy Mailstack** is a simple Docker-based solution to deploy a fully functional mail server along with the Roundcube webmail interface in just a few steps. Perfect for developers, small businesses, or anyone who needs an email solution without complex configurations.

---

## ✅ Features
- Mail server powered by **Postfix/Dovecot**.
- **Roundcube** webmail pre-configured for easy access.
- Support for **custom SSL certificates**.
- Persistent storage for mail data, logs, and PostgreSQL database.
- Simple script to **create email accounts**.
- **Management CLI** (`easy_mailstack.sh`) for listing, deleting, deactivating accounts, and managing quotas.
- **Rspamd daily send rate limiting** for authenticated SMTP users (`1000 emails/day` by default, configurable to `N emails/day`).

---

## 📂 Project Structure

```
.
├── certs/                  # SSL certificates
├── compose.yaml            # Your main docker-compose file (ignored in Git)
├── compose.yaml_example    # Example compose file
├── config/                 # Custom mail server configs
│   └── rspamd/override.d/  # Rspamd override configs, including daily send rate limit
├── config.inc.php          # Roundcube config (ignored in Git)
├── config.inc.php_example  # Example Roundcube config
├── create_email.sh         # Script to create email accounts
├── easy_mailstack.sh       # Management CLI for email accounts
├── mail-data/              # Mail data storage (ignored in Git)
├── mail-logs/              # Log files (ignored in Git)
├── mail-state/             # Mail state data (ignored in Git)
└── postgresql/             # Database data (ignored in Git)
```

---

## ⚙️ Requirements
- **Docker** and **Docker Compose**
- A domain name (e.g., `mail.example.com`)
- Open ports: `25`, `143`, `587`, `993`, `80`, `443`

---

## 🚀 Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/easy-mailstack.git
   cd easy-mailstack
   ```

2. **Copy example configuration files**
   ```bash
   cp .env-mailserver.example .env-mailserver
   cp compose.yaml_example compose.yaml
   cp config.inc.php_example config.inc.php
   ```

3. **Edit the `.env-mailserver` file**
   - Set your domain name
   - Configure mail settings (hostname, users, etc.)

4. **Start the containers**
   ```bash
   docker compose up -d
   ```

5. **Access Roundcube**
   - Open `https://mail.yourdomain.com`
   - Login with your email credentials

---

## 🔧 Install as System-Wide Command

By default you need to `cd` into the project directory to run `./easy_mailstack.sh`. To make it available as a command from **anywhere** on your system, follow these steps:

### Option 1: Symlink (Recommended)

Create a symbolic link in `/usr/local/bin`:

```bash
# Make sure the script is executable
chmod +x /path/to/easy-mailstack/easy_mailstack.sh

# Create a symlink with a shorter name
sudo ln -sf /path/to/easy-mailstack/easy_mailstack.sh /usr/local/bin/easy-mailstack
```

Now you can run it from anywhere:
```bash
easy-mailstack --list-email
easy-mailstack --set-quota --email user@example.com --size 1G
```

### Option 2: Add to PATH

Add the project directory to your shell's `PATH`:

```bash
# For bash (~/.bashrc)
echo 'export PATH="/path/to/easy-mailstack:$PATH"' >> ~/.bashrc
source ~/.bashrc

# For zsh (~/.zshrc)
echo 'export PATH="/path/to/easy-mailstack:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Option 3: Shell Alias

Add an alias to your shell config:

```bash
# For bash (~/.bashrc) or zsh (~/.zshrc)
echo "alias easy-mailstack='/path/to/easy-mailstack/easy_mailstack.sh'" >> ~/.bashrc
source ~/.bashrc
```

> **Note:** Replace `/path/to/easy-mailstack` with your actual project path (e.g. `/root/docker_app/easy-mailstack`).

---

## 👤 Creating Email Accounts

Use the included script:
```bash
# With a 1G quota and 1000 emails/day SMTP send limit
./create_email.sh user@example.com password 1G 1000

# With a 1G quota and no rate-limit change
./create_email.sh user@example.com password 1G

# With unlimited quota (default)
./create_email.sh user@example.com password 0
./create_email.sh user@example.com password        # 0 is the default

# Interactive mode (prompts for email, password, quota, and optional daily send limit)
./create_email.sh
```

Quota sizes: use `M` for MB, `G` for GB, `T` for TB, or `0` for unlimited.
Daily send limits are global per authenticated SMTP user. Passing the fourth argument updates the Rspamd limit for all authenticated users.

---

## 📧 Email Management CLI (`easy_mailstack.sh`)

### List all email accounts
```bash
easy-mailstack --list-email
```

### List email accounts for a specific domain
```bash
easy-mailstack --domain example.com --list-email
```

### Send a test email
```bash
easy-mailstack --send-test --email recipient@example.com --from sender@example.com
```

### Delete an email account
Permanently removes the account (with confirmation prompt):
```bash
easy-mailstack --delete-email --email user@example.com
```

### Deactivate an email account
Disables sending and receiving without deleting the account or its data:
```bash
easy-mailstack --deactivate-email --email user@example.com
```

### Reactivate a deactivated account
```bash
easy-mailstack --deactivate-email --email user@example.com --reactivate
```

### Set a quota on an email account
Set a storage limit (use `M` for MB, `G` for GB, `T` for TB):
```bash
easy-mailstack --set-quota --email user@example.com --size 1G
easy-mailstack --set-quota --email user@example.com --size 500M
```

### Remove a quota (set to unlimited)
```bash
easy-mailstack --del-quota --email user@example.com
```

### Set daily SMTP send rate limit
Sets the Rspamd authenticated-user daily send limit. The default is `1000` emails/day; use any positive integer for `N` emails/day:
```bash
easy-mailstack --set-rate-limit --limit 1000
easy-mailstack --set-rate-limit --limit 250
```

Check or remove the generated Rspamd override:
```bash
easy-mailstack --show-rate-limit
easy-mailstack --del-rate-limit
```

After changing the rate limit, restart the mailserver:
```bash
docker compose restart mailserver
```

Verify Rspamd sees the config:
```bash
docker exec -it mailserver rspamadm configdump ratelimit
```

---

## 📊 Enabling Quotas

To use quota management, you must enable quotas in your mailserver configuration:

1. **Add to your `.env-mailserver` file:**
   ```env
   ENABLE_QUOTAS=1
   ```

2. **Restart the mailserver:**
   ```bash
   docker compose down && docker compose up -d
   ```

3. **Verify quotas are working:**
   ```bash
   easy-mailstack --list-email
   ```
   You should see quota usage like `( 881K / 1G ) [8%]` instead of `( 881K / ~ ) [0%]`.

---

## 🚦 Rspamd Daily Send Rate Limiting

Rate limiting is enabled through Docker Mailserver's built-in Rspamd support. The repository includes:

```text
config/rspamd/override.d/ratelimit.conf
```

Default behavior:
- `1000 emails/day` per authenticated SMTP user.
- Recipient-counted: one message to 10 recipients consumes 10 from the bucket.
- Uses Rspamd token-bucket behavior, so the limit refills continuously over one day.
- Applies to authenticated outbound SMTP users through `selector = "user.lower"`.

Recommended `.env-mailserver` settings:
```env
ENABLE_RSPAMD=1
ENABLE_RSPAMD_REDIS=1
RSPAMD_CHECK_AUTHENTICATED=1
RSPAMD_GREYLISTING=0
ENABLE_OPENDKIM=0
ENABLE_OPENDMARC=0
ENABLE_POLICYD_SPF=0
ENABLE_AMAVIS=0
MAIL_RATE_LIMIT_PER_DAY=1000
```

`MAIL_RATE_LIMIT_PER_DAY` is used by the helper scripts as the default value; Rspamd uses `config/rspamd/override.d/ratelimit.conf`.

Change the limit to any `N` emails/day:
```bash
easy-mailstack --set-rate-limit --limit N
docker compose restart mailserver
```

Example:
```bash
easy-mailstack --set-rate-limit --limit 500
docker compose restart mailserver
```

---

## 🔐 SSL Certificates
- Place your SSL certificates in the `certs/` directory.
- Update the `compose.yaml` file to map them correctly.

---

## 📜 Environment Variables

Edit `.env-mailserver`:
```env
DOMAIN=example.com
HOSTNAME=mail.example.com
POSTMASTER_ADDRESS=postmaster@example.com
ENABLE_QUOTAS=1
ENABLE_RSPAMD=1
ENABLE_RSPAMD_REDIS=1
RSPAMD_CHECK_AUTHENTICATED=1
MAIL_RATE_LIMIT_PER_DAY=1000
# Add more as needed
```

---

## 🛠️ Usage Examples

**Start the stack:**
```bash
docker compose up -d
```

**Stop the stack:**
```bash
docker compose down
```

**Check logs:**
```bash
docker compose logs -f
```

**Create new email with 1G quota:**
```bash
./create_email.sh newuser@example.com strongpassword 1G
```

**Create new email and set daily send limit to 1000 emails/day:**
```bash
./create_email.sh newuser@example.com strongpassword 1G 1000
```

**Create new email with unlimited quota:**
```bash
./create_email.sh newuser@example.com strongpassword 0
```

---

## 🧾 License
This project is licensed under the MIT License.

---

## 🌟 Contribute
Feel free to open issues or submit pull requests to improve this project.
