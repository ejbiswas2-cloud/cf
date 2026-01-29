#!/bin/bash
set -e

############################################
# NON-INTERACTIVE CONFIGURATION
############################################
export DEBIAN_FRONTEND=noninteractive

############################################
# LOGGING & ROOT CHECK
############################################
LOG="/var/log/homelab-install.log"
exec > >(tee -a "$LOG") 2>&1

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

echo "=== Secure Homelab Installer (Ubuntu 22.04) ==="

############################################
# PRESEED POSTFIX (NO PROMPTS)
############################################
echo "postfix postfix/mailname string localhost" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections

############################################
# BASE PACKAGES
############################################
apt update -y
apt install -y \
  curl wget \
  python3-flask python3-pip sqlite3 \
  rclone mailutils lsb-release gnupg

############################################
# aaPanel INSTALL (BEST-EFFORT SILENT)
############################################
if [ ! -d /www/server/panel ]; then
  echo "Installing aaPanel..."
  wget -O aapanel.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
  echo -e "y\n0" | bash aapanel.sh || true
else
  echo "aaPanel already installed"
fi

############################################
# CLOUDFLARE TUNNEL (BROWSER LOGIN)
############################################
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/install.sh | bash
  apt install -y cloudflared
fi

echo "➡ Browser will open for Cloudflare login"
cloudflared tunnel login

TUNNEL_NAME="homelab"
cloudflared tunnel create "$TUNNEL_NAME" || true
TUNNEL_ID=$(cloudflared tunnel list | awk '/homelab/ {print $1}')

mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: homelab
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - service: http_status:404
EOF

cloudfla
