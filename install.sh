#!/usr/bin/env bash
set -e

echo "==============================================="
echo " 🔥 DASHBOARDXE – FORCE SELF HEALING INSTALLER"
echo "==============================================="

PORT=9010
APP_NAME=DashboardXE
BASE_DIR=/opt/dashboardxe
APP_DIR=$BASE_DIR/app

# -----------------------------
# 1️⃣ FORCE KILL EVERYTHING
# -----------------------------
echo "[1/9] Stopping running processes..."
pm2 kill || true
systemctl stop apache2 || true

# -----------------------------
# 2️⃣ FORCE REMOVE NODE / NPM
# -----------------------------
echo "[2/9] Removing ALL Node/npm junk..."
apt-mark unhold nodejs npm || true
apt remove -y nodejs npm node-gyp node-cacache node-mkdirp node-nopt node-tar node-which || true
rm -rf /usr/lib/node_modules /usr/local/lib/node_modules ~/.npm ~/.pm2
apt autoremove -y
apt clean
rm -rf /var/lib/apt/lists/*

dpkg --configure -a || true
apt --fix-broken install -y || true
apt update

# -----------------------------
# 3️⃣ INSTALL NODE CLEAN
# -----------------------------
echo "[3/9] Installing Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
apt-mark hold npm

node -v
npm -v

# -----------------------------
# 4️⃣ INSTALL PM2 CLEAN
# -----------------------------
echo "[4/9] Installing PM2..."
npm install -g pm2
pm2 startup systemd -u root --hp /root || true

# -----------------------------
# 5️⃣ CREATE DIRECTORIES
# -----------------------------
echo "[5/9] Creating directories..."
rm -rf $BASE_DIR
mkdir -p $APP_DIR
mkdir -p $APP_DIR/{file-root,ssl_
