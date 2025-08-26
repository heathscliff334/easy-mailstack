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

---

## 📂 Project Structure

```
.
├── certs/                  # SSL certificates
├── compose.yaml            # Your main docker-compose file (ignored in Git)
├── compose.yaml_example    # Example compose file
├── config/                 # Custom mail server configs
├── config.inc.php          # Roundcube config (ignored in Git)
├── config.inc.php_example  # Example Roundcube config
├── create_email.sh         # Script to create email accounts
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

## 👤 Creating Email Accounts

Use the included script:
```bash
./create_email.sh user@example.com password
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

**Create new email:**
```bash
./create_email.sh newuser@example.com strongpassword
```

---

## 🧾 License
This project is licensed under the MIT License.

---

## 🌟 Contribute
Feel free to open issues or submit pull requests to improve this project.
