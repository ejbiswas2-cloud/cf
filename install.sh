#!/bin/bash
set -e

############################################
# NON-INTERACTIVE CONFIGURATION
############################################
export DEBIAN_FRONTEND=noninteractive
# REPLACE THIS WITH YOUR ACTUAL CLOUDFLARE TUNNEL TOKEN
TUNNEL_TOKEN="your_token_here" 

############################################
# LOGGING & ROOT CHECK
############################################
LOG="/var/log/homelab-install.log"
exec > >(tee -a "$LOG") 2>&1

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo"
  exit 1
fi

echo "=== Secure Homelab Installer for Ubuntu 22.04 ==="

############################################
# PRESEED & REPOS
############################################
echo "postfix postfix/mailname string localhost" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections

apt update -y
apt install -y curl wget python3-flask python3-pip sqlite3 rclone mailutils ls-release gnupg

############################################
# aaPanel INSTALL (FORCE SILENT)
############################################
if [ ! -d /www/server/panel ]; then
  echo "Installing aaPanel..."
  wget -O aapanel.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
  # Echo 'y' and '0' to bypass the "Do you want to install to /www" and "Enable SSL" prompts
  echo -e "y\n0" | bash aapanel.sh
else
  echo "aaPanel already installed"
fi

############################################
# CLOUDFLARE TUNNEL (TOKEN-BASED)
############################################
if ! command -v cloudflared >/dev/null; then
  curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared.deb
  rm cloudflared.deb
fi

if [ "$TUNNEL_TOKEN" != "your_token_here" ]; then
    cloudflared service install "$TUNNEL_TOKEN" || echo "Cloudflared service already exists"
    systemctl start cloudflared
else
    echo "WARNING: No Tunnel Token provided. Cloudflare will not start."
fi

############################################
# ROBUST BACKUP SCRIPT
############################################
cat > /usr/local/bin/backup_all.sh <<'EOF'
#!/bin/bash
DATE=$(date +%Y-%m-%d)
LOCAL=/mnt/backup/local
TMP=/tmp/backup-$DATE
mkdir -p $TMP $LOCAL

# Backup Files
tar -czf $TMP/www.tar.gz /www/wwwroot 2>/dev/null || true

# Backup Databases (Check if service is running before dumping)
pg_isready -q && sudo -u postgres pg_dumpall | gzip > $TMP/postgres.sql.gz || true
systemctl is-active --quiet mysql && mysqldump --all-databases | gzip > $TMP/mysql.sql.gz || true

cp -r $TMP $LOCAL/
rm -rf $TMP

# Retention: Remove local backups older than 7 days
find $LOCAL -type d -name "backup-*" -mtime +7 -exec rm -rf {} +
EOF
chmod +x /usr/local/bin/backup_all.sh

############################################
# PYTHON DASHBOARD (UBUNTU 22.04 COMPATIBLE)
############################################
mkdir -p /opt/homelab
cat > /opt/homelab/dashboard.py <<'EOF'
from flask import Flask, redirect
import os, re, subprocess

app = Flask(__name__)
# Updated paths for aaPanel Nginx layout
VHOST="/www/server/panel/vhost/nginx"
ACCESS="/etc/cloudflared/access-protected.txt"

def port_open(p):
    if p == 80: return True # Default
    return subprocess.call(f"ss -ltn | grep -q ':{p} '", shell=True) == 0

def domains():
    out=[]
    if not os.path.exists(VHOST): return out
    for r,_,fs in os.walk(VHOST):
        for f in fs:
            if f.endswith(".conf"):
                try:
                    with open(os.path.join(r,f)) as tf:
                        t = tf.read()
                        names = re.findall(r"server_name\s+([^;]+);", t)
                        p = 80
                        m = re.search(r"proxy_pass http://127.0.0.1:(\d+)", t)
                        if m: p = int(m.group(1))
                        for n in names:
                            for d in n.split():
                                out.append((d, p))
                except: continue
    return out

@app.route("/")
def index():
    if not os.path.exists(ACCESS): open(ACCESS, 'a').close()
    prot=set(l.strip() for l in open(ACCESS) if l.strip())
    html="<h2>Homelab Dashboard</h2><table border=1 cellpadding=6>"
    html+="<tr><th>Domain</th><th>Port</th><th>Access</th><th>Status</th></tr>"
    for d,p in domains():
        status = "🟢 UP" if port_open(p) else "🔴 DOWN"
        acc = "🟢 Protected" if d in prot else "🔴 Public"
        html+=f"<tr><td>{d}</td><td>{p}</td><td>{acc}</td><td>{status}</td></tr>"
    return html+"</table>"

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=9001)
EOF

############################################
# SYSTEMD SERVICE FOR DASHBOARD
############################################
cat > /etc/systemd/system/dashboard.service <<EOF
[Unit]
Description=Homelab Dashboard
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/homelab/dashboard.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dashboard
systemctl start dashboard

echo "=== INSTALL COMPLETE ==="
echo "Access Dashboard locally: http://localhost:9001"
