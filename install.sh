#!/bin/bash
set -e

##################################################
# NON-INTERACTIVE MODE (NO PROMPTS EVER)
##################################################
export DEBIAN_FRONTEND=noninteractive

##################################################
# LOGGING
##################################################
LOG="/var/log/homelab-install.log"
exec > >(tee -a "$LOG") 2>&1

##################################################
# ROOT CHECK
##################################################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

echo "=== Secure Homelab Installer (Ubuntu 22.04) ==="

##################################################
# FIX APT STATE (SAFE, ONE-TIME)
##################################################
echo "Fixing apt state if needed..."
pkill -9 apt || true
pkill -9 apt-get || true
pkill -9 dpkg || true

rm -f /var/lib/apt/lists/lock
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock*
rm -f /var/cache/apt/srcpkgcache.bin

dpkg --configure -a || true
apt clean

##################################################
# PRESEED POSTFIX (NO QUESTIONS)
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
  rclone mailutils \
  lsb-release gnupg

##################################################
# aaPanel INSTALL (BEST-EFFORT SILENT)
##################################################
if [ ! -d /www/server/panel ]; then
  echo "Installing aaPanel..."
  wget -O aapanel.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
  echo -e "y\n0" | bash aapanel.sh || true
else
  echo "aaPanel already installed"
fi

##################################################
# CLOUDFLARE TUNNEL (OFFICIAL .DEB – RELIABLE)
##################################################
if ! command -v cloudflared >/dev/null; then
  echo "Installing cloudflared..."
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
fi

##################################################
# CLOUDFLARE LOGIN (BROWSER)
##################################################
echo "➡ Browser will open for Cloudflare login"
cloudflared tunnel login

##################################################
# CREATE TUNNEL
##################################################
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

cloudflared service install
systemctl enable cloudflared
systemctl restart cloudflared

##################################################
# BACKUP SYSTEM (LOCAL, SAFE)
##################################################
mkdir -p /mnt/backup/local

cat > /usr/local/bin/backup_all.sh <<'EOF'
#!/bin/bash
set -e

DATE=$(date +%Y-%m-%d)
LOCAL=/mnt/backup/local
TMP=/tmp/backup-$DATE

mkdir -p "$TMP"

tar -czf "$TMP/www.tar.gz" /www/wwwroot 2>/dev/null || true
systemctl is-active --quiet mysql && mysqldump --all-databases | gzip > "$TMP/mysql.sql.gz" || true
systemctl is-active --quiet postgresql && sudo -u postgres pg_dumpall | gzip > "$TMP/postgres.sql.gz" || true

mkdir -p "$LOCAL/backup-$DATE"
cp -r "$TMP/"* "$LOCAL/backup-$DATE/"
rm -rf "$TMP"

# Keep last 7 backups
ls -1dt "$LOCAL"/backup-* | tail -n +8 | xargs rm -rf || true
EOF

chmod +x /usr/local/bin/backup_all.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup_all.sh") | crontab -

##################################################
# ACCESS HINTS (Protected / Public)
##################################################
mkdir -p /etc/cloudflared
touch /etc/cloudflared/access-protected.txt

##################################################
# LOCAL DASHBOARD (http://localhost:9001)
##################################################
mkdir -p /opt/homelab

cat > /opt/homelab/dashboard.py <<'EOF'
from flask import Flask
import os, re, subprocess

app = Flask(__name__)
VHOST="/www/server/panel/vhost/nginx"
ACCESS="/etc/cloudflared/access-protected.txt"

def port_open(p):
    return subprocess.call(f"ss -ltn | grep -q ':{p} '", shell=True) == 0

def domains():
    out=[]
    if not os.path.exists(VHOST):
        return out
    for r,_,fs in os.walk(VHOST):
        for f in fs:
            if f.endswith(".conf"):
                try:
                    t=open(os.path.join(r,f)).read()
                    names=re.findall(r"server_name\\s+([^;]+);", t)
                    port=80
                    m=re.search(r"127.0.0.1:(\\d+)", t)
                    if m: port=int(m.group(1))
                    for n in names:
                        for d in n.split():
                            out.append((d,port))
                except:
                    pass
    return out

@app.route("/")
def index():
    prot=set(l.strip() for l in open(ACCESS) if l.strip())
    html="<h2>Homelab Dashboard</h2><table border=1 cellpadding=6>"
    html+="<tr><th>Domain</th><th>Port</th><th>Access</th><th>Status</th></tr>"
    for d,p in domains():
        html+=f"<tr><td>{d}</td><td>{p}</td><td>{'🟢 Protected' if d in prot else '🔴 Public'}</td><td>{'🟢 UP' if port_open(p) else '🔴 DOWN'}</td></tr>"
    return html+"</table>"

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
echo "=== INSTALL COMPLETE ==="
echo "Dashboard: http://localhost:9001"
