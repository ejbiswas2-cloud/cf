#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/opt/devops-panel"
LOG_FILE="$LOG_DIR/install.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo " 🚀 DEVOPS CONTROL PANEL INSTALLER (FIXED)"
echo "=================================================="

### ----------------------------------
### Recover if apt was interrupted
### ----------------------------------
echo "🩹 Checking dpkg state..."
dpkg --configure -a || true
apt --fix-broken install -y || true

### ----------------------------------
### Base packages
### ----------------------------------
apt update -y
apt install -y \
  curl wget gnupg lsb-release ca-certificates \
  software-properties-common apt-transport-https \
  unzip git jq

### ----------------------------------
### Apache + PHP 8.3
### ----------------------------------
add-apt-repository ppa:ondrej/php -y
apt update -y

apt install -y \
  apache2 \
  php8.3 php8.3-cli php8.3-mysql php8.3-pgsql php8.3-mongodb \
  php8.3-curl php8.3-mbstring php8.3-xml php8.3-zip

systemctl enable --now apache2

### ----------------------------------
### Node.js 20 LTS (NOT 24)
### ----------------------------------
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

npm install -g pm2
pm2 startup systemd -u root --hp /root || true

### ----------------------------------
### MongoDB (Correct Way)
### ----------------------------------
curl -fsSL https://pgp.mongodb.com/server-6.0.asc | \
gpg --dearmor | tee /usr/share/keyrings/mongodb.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | \
tee /etc/apt/sources.list.d/mongodb-org.list

apt update -y
apt install -y mongodb-org

systemctl enable --now mongod

### ----------------------------------
### PostgreSQL + MariaDB
### ----------------------------------
apt install -y mariadb-server postgresql postgresql-contrib
systemctl enable --now mariadb postgresql

### ----------------------------------
### Docker + Compose
### ----------------------------------
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | bash
fi

if ! command -v docker-compose >/dev/null; then
  curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

echo ""
echo "======================================"
echo " ✅ INSTALLATION COMPLETE"
echo "======================================"
echo "Apache:        http://localhost"
echo "MongoDB:       running"
echo "PostgreSQL:    running"
echo "MariaDB:       running"
echo "PM2:           installed"
echo "Log file:      $LOG_FILE"
