#!/usr/bin/env bash
set -e

echo "======================================"
echo "🟢 Phase 1 — Core Runtime Bootstrap"
echo "Target: Ubuntu 22.04 (minimal)"
echo "======================================"

########################################
# 0. ROOT CHECK
########################################
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (sudo)"
  exit 1
fi

########################################
# 1. HARD RESET APT STATE (SAFE)
########################################
echo "🧹 Resetting apt state (safe)..."

apt-mark unhold nodejs npm || true
apt remove -y nodejs npm || true
apt autoremove -y || true
apt clean
rm -rf /var/lib/apt/lists/*

apt update
apt --fix-broken install -y
dpkg --configure -a

########################################
# 2. INSTALL BASE DEPENDENCIES (MINIMAL SAFE SET)
########################################
echo "📦 Installing base system dependencies..."

apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common \
  build-essential \
  git \
  unzip \
  zip \
  nano \
  ufw \
  apache2

########################################
# 3. ENABLE & START APACHE
########################################
echo "🌐 Enabling Apache..."
systemctl enable apache2
systemctl start apache2

########################################
# 4. INSTALL NODE.JS 20 (NODESOURCE – OFFICIAL)
########################################
echo "🟢 Installing Node.js 20 (NodeSource)..."

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

########################################
# 5. VERIFY NODE & NPM
########################################
echo "🔍 Verifying Node.js & npm..."
node -v
npm -v

########################################
# 6. INSTALL PM2 (CORRECT METHOD)
########################################
echo "⚙️ Installing PM2 via npm (correct way)..."

npm install -g pm2

########################################
# 7. CONFIGURE PM2 STARTUP
########################################
echo "🔁 Configuring PM2 startup..."
pm2 startup systemd -u root --hp /root || true

########################################
# 8. FIREWALL BASELINE
########################################
echo "🔥 Configuring firewall..."
ufw allow OpenSSH
ufw allow 80
ufw --force enable

########################################
# 9. FINAL VERIFICATION
########################################
echo "======================================"
echo "✅ Phase 1 Completed Successfully"
echo "--------------------------------------"
echo "Apache : $(apache2 -v | head -n1)"
echo "Node   : $(node -v)"
echo "npm    : $(npm -v)"
echo "PM2    : $(pm2 -v)"
echo "UFW    : $(ufw status | head -n1)"
echo "======================================"
