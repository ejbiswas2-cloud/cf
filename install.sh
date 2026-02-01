#!/bin/bash
set -e

echo "======================================"
echo " 🧹 Synxiel Homelab Uninstall Script"
echo "======================================"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root (sudo)"
  exit 1
fi

echo "[1/10] Stopping PM2 apps..."
pm2 delete all >/dev/null 2>&1 || true
pm2 kill >/dev/null 2>&1 || true
npm uninstall -g pm2 >/dev/null 2>&1 || true

echo "[2/10] Removing dashboard..."
rm -rf /opt/dashboard

echo "[3/10] Removing auto-backup cron & script..."
crontab -l 2>/dev/null | grep -v homelab-backup.sh | crontab - || true
rm -f /usr/local/bin/homelab-backup.sh
rm -rf /opt/backups

echo "[4/10] Stopping & removing Docker containers..."
docker rm -f phpmyadmin pgadmin >/dev/null 2>&1 || true
systemctl stop docker >/dev/null 2>&1 || true
apt purge -y docker.io docker-compose >/dev/null 2>&1 || true
rm -rf /var/lib/docker

echo "[5/10] Removing Apache..."
systemctl stop apache2 >/dev/null 2>&1 || true
apt purge -y apache2 apache2-utils apache2-bin >/dev/null 2>&1 || true
rm -rf /etc/apache2 /var/www/html

echo "[6/10] Removing MongoDB..."
systemctl stop mongod >/dev/null 2>&1 || true
apt purge -y mongodb-org* >/dev/null 2>&1 || true
rm -rf /var/lib/mongodb /var/log/mongodb

echo "[7/10] Removing PostgreSQL..."
systemctl stop postgresql >/dev/null 2>&1 || true
apt purge -y postgresql* >/dev/null 2>&1 || true
rm -rf /var/lib/postgresql /etc/postgresql

echo "[8/10] Removing Node.js..."
apt purge -y nodejs >/dev/null 2>&1 || true
rm -rf /usr/lib/node_modules /root/.npm

echo "[9/10] Cleaning leftover packages..."
apt autoremove -y
apt autoclean -y

echo "[10/10] Cleanup done"

echo "======================================"
echo " ✅ UNINSTALL COMPLETE"
echo "======================================"
echo ""
echo "Cloudflare Tunnel NOT removed."
echo "System is clean and stable."
