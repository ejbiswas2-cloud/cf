#!/usr/bin/env bash
set -e

LOG="/opt/devops-panel/install.log"
mkdir -p /opt/devops-panel
exec > >(tee -a "$LOG") 2>&1

echo "=================================================="
echo " 🚀 DEVOPS CONTROL PANEL INSTALLER"
echo "=================================================="

### 0. SYSTEM SAFETY
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || true
apt --fix-broken install -y || true

### 1. BASE PACKAGES
apt update
apt install -y \
  ca-certificates curl gnupg lsb-release \
  software-properties-common jq unzip git

### 2. APACHE + PHP 8.3
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y \
  apache2 \
  php8.3 php8.3-cli php8.3-curl php8.3-mbstring \
  php8.3-mysql php8.3-pgsql php8.3-xml php8.3-zip

systemctl enable --now apache2

### 3. NODE.JS LTS (20.x ONLY)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

### 4. PM2 (GLOBAL, ROOT)
npm install -g pm2
pm2 startup systemd -u root --hp /root || true

### 5. DATABASES
apt install -y mariadb-server postgresql postgresql-contrib

# MongoDB
if [ ! -f /etc/apt/sources.list.d/mongodb-org.list ]; then
  curl -fsSL https://pgp.mongodb.com/server-6.0.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg
  echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org.list
fi

apt update
apt install -y mongodb-org
systemctl enable --now mongod mariadb postgresql

### 6. DOCKER
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | bash
fi
systemctl enable --now docker

### 7. DOCKER GUIs
mkdir -p /opt/devops-panel/docker
cat >/opt/devops-panel/docker/docker-compose.yml <<EOF
version: "3.8"
services:
  phpmyadmin:
    image: phpmyadmin
    ports: ["8081:80"]
    environment:
      PMA_HOST: mariadb
  pgadmin:
    image: dpage/pgadmin4
    ports: ["8082:80"]
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local.dev
      PGADMIN_DEFAULT_PASSWORD: admin123
  mongo-express:
    image: mongo-express
    ports: ["8083:8081"]
    environment:
      ME_CONFIG_BASICAUTH_USERNAME: admin
      ME_CONFIG_BASICAUTH_PASSWORD: admin
EOF

docker compose -f /opt/devops-panel/docker/docker-compose.yml up -d

### 8. DASHBOARD APP
mkdir -p /opt/devops-panel/dashboard
cd /opt/devops-panel/dashboard

cat >package.json <<EOF
{
  "name": "devops-dashboard",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.0"
  }
}
EOF

npm install

cat >server.js <<'EOF'
const express = require("express");
const app = express();
const PORT = process.env.PORT || 9001;

app.get("/", (req, res) => {
  res.send("<h1>DevOps Control Panel</h1><p>Status: RUNNING</p>");
});

app.listen(PORT, () => {
  console.log("Dashboard running on http://localhost:" + PORT);
});
EOF

pm2 start server.js --name devops-dashboard
pm2 save

### 9. FINISH
echo "=================================================="
echo " ✅ INSTALL COMPLETE"
echo "=================================================="
echo "Dashboard: http://localhost:9001"
echo "phpMyAdmin: http://localhost:8081"
echo "pgAdmin: http://localhost:8082"
echo "Mongo Express: http://localhost:8083"
