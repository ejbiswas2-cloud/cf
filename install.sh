#!/bin/bash
set -e

##################################################
# NON-INTERACTIVE + LOGGING
##################################################
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/homelab-install.log"
exec > >(tee -a "$LOG") 2>&1

##################################################
# ROOT CHECK
##################################################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

echo "=== Homelab Installer (Ubuntu 22.04) ==="

##################################################
# FIX APT / DPKG SAFELY (NO FORCE DAMAGE)
##################################################
echo "Cleaning apt state..."
pkill -9 apt || true
pkill -9 apt-get || true
pkill -9 dpkg || true

rm -f /var/lib/apt/lists/lock
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock*

dpkg --configure -a || true
apt clean

##################################################
# PRESEED POSTFIX (NO PROMPTS EVER)
##################################################
echo "postfix postfix/mailname string localhost" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections

##################################################
# BASE PACKAGES
##################################################
apt update -y
apt install -y \
  curl wget \
  python3 python3-flask sqlite3 \
  mailutils rclone \
  lsb-release ca-certificates gnupg

##################################################
# aaPanel (BEST-EFFORT SILENT)
##################################################
if [ ! -d /www/server/panel ]; then
  echo "Installing aaPanel..."
  wget -O aapanel.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
  echo -e "y\n0" | bash aapanel.sh || true
else
  echo "aaPanel already installed"
fi

##################################################
# CLEAN CLOUDFLARED (REMOVE BROKEN STATES)
##################################################
systemctl stop cloudflared 2>/dev/null || true
systemctl disable cloudflared 2>/dev/null || true

rm -f /usr/bin/cloudflared
rm -f /usr/local/bin/cloudflared
rm -rf /etc/cloudflared
rm -rf /root/.cloudflared

##################################################
# INSTALL CLOUDFLARED (OFFICIAL .DEB ONLY)
##################################################
echo "Installing cloudflared..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb
rm -f /tmp/cloudflared.deb

##################################################
# VERIFY CLOUDFLARED
##################################################
if ! command -v cloudflared >/dev/null; then
  echo "ERROR: cloudflared install failed"
  exit 1
fi

cloudflared --version

##################################################
# CLOUDFLARE LOGIN (BROWSER – REQUIRED ONCE)
##################################################
echo
echo "➡ Cloudflare browser login required"
echo "➡ If browser does not open, COPY the URL and open it manually"
echo

cloudflared tunnel login

##################################################
# CREATE TUNNEL (IDEMPOTENT)
##################################################
TUNNEL_NAME="homelab"

cloudflared tunnel create "$TUNNEL_NAME" || true

TUNNEL_ID=$(cloudflared tunnel list | awk '/homelab/ {print $1}')

if [ -z "$TUNNEL_ID" ]; then
  echo "ERROR: Tunnel ID not found"
  exit 1
fi

##################################################
# CONFIGURE TUNNEL
##################################################
mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - service: http_status:404
EOF

##################################################
# INSTALL AS SYSTEM SERVICE
##################################################
cloudflared service install
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

##################################################
# LOCAL DASHBOARD (READ-ONLY)
##################################################
mkdir -p /opt/homelab /etc/cloudflared
touch /etc/cloudflared/access-protected.txt

cat > /opt/homelab/dashboard.py <<'EOF'
from flask import Flask
import os, re, subprocess

app = Flask(__name__)
VHOST="/www/server/panel/vhost/nginx"
ACCESS="/etc/cloudflared/access-protected.txt"

def up(port):
    return subprocess.call(f"ss -ltn | grep -q ':{port} '", shell=True) == 0

@app.route("/")
def index():
    rows=[]
    if os.path.exists(VHOST):
        for r,_,fs in os.walk(VHOST):
            for f in fs:
                if f.endswith(".conf"):
                    try:
                        t=open(os.path.join(r,f)).read()
                        names=re.findall(r"server_name\s+([^;]+);", t)
                        port=80
                        m=re.search(r"127.0.0.1:(\d+)", t)
                        if m: port=int(m.group(1))
                        for n in names:
                            for d in n.split():
                                rows.append((d,port))
                    except:
                        pass

    prot=set(open(ACCESS).read().split())
    h="<h2>Homelab Dashboard</h2><table border=1 cellpadding=6>"
    h+="<tr><th>Domain</th><th>Port</th><th>Access</th><th>Status</th></tr>"
    for d,p in rows:
        h+=f"<tr><td>{d}</td><td>{p}</td><td>{'Protected' if d in prot else 'Public'}</td><td>{'UP' if up(p) else 'DOWN'}</td></tr>"
    return h+"</table>"

app.run(host="127.0.0.1", port=9001)
EOF

cat > /etc/systemd/system/dashboard.service <<EOF
[Unit]
Description=Homelab Dashboard
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/homelab/dashboard.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dashboard
systemctl start dashboard

##################################################
# DONE
##################################################
echo
echo "=== INSTALL COMPLETE ==="
echo "Cloudflare Tunnel: RUNNING"
echo "Dashboard: http://localhost:9001"
