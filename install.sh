#!/bin/bash
set -e

LOG="/var/log/homelab-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Secure Homelab Installer ==="

# -------- Root check --------
if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo"
  exit 1
fi

# -------- Base packages --------
apt update -y
apt install -y curl wget python3-flask sqlite3 rclone mailutils

# -------- aaPanel --------
if [ ! -d /www/server/panel ]; then
  wget -O aapanel.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
  bash aapanel.sh
fi

# -------- Cloudflare Tunnel --------
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/install.sh | bash
  apt install cloudflared -y
fi

echo "➡ Browser will open for Cloudflare login"
cloudflared tunnel login

TUNNEL_NAME="homelab"
cloudflared tunnel create $TUNNEL_NAME || true
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
systemctl start cloudflared

# -------- Backups --------
mkdir -p /mnt/backup/local /mnt/backup/cloud

cat > /usr/local/bin/backup_all.sh <<'EOF'
#!/bin/bash
set -e
DATE=$(date +%Y-%m-%d)
LOCAL=/mnt/backup/local
CLOUD=/mnt/backup/cloud
TMP=/tmp/backup-$DATE

mkdir -p $TMP
tar -czf $TMP/files.tar.gz /www/wwwroot 2>/dev/null || true
mysqldump --all-databases | gzip > $TMP/mysql.sql.gz || true
sudo -u postgres pg_dumpall | gzip > $TMP/postgres.sql.gz || true
mongodump --archive=$TMP/mongo.gz --gzip || true

mkdir -p $LOCAL/backup-$DATE $CLOUD/backup-$DATE
cp -r $TMP/* $LOCAL/backup-$DATE/ || true
cp -r $TMP/* $CLOUD/backup-$DATE/ || true
rm -rf $TMP

cd $LOCAL
ls -1d backup-* | while read B; do
  D=${B#backup-}
  AGE=$(( ( $(date +%s) - $(date -d $D +%s) ) / 86400 ))
  DAY=$(date -d $D +%d)
  MONTHS=$(( ( $(date +%Y)*12+$(date +%m) ) - ( $(date -d $D +%Y)*12+$(date -d $D +%m) ) ))
  if [[ $AGE -le 3 ]]; then continue; fi
  if [[ ($DAY == "01" || $DAY == "15") && $MONTHS -le 3 ]]; then continue; fi
  rm -rf $LOCAL/$B $CLOUD/$B
done
EOF

chmod +x /usr/local/bin/backup_all.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup_all.sh") | crontab -

# -------- Health & Auto-restart --------
cat > /usr/local/bin/health_check.sh <<'EOF'
#!/bin/bash
SERVICES=(cloudflared nginx apache2 mysql postgresql mongod redis memcached)
for S in "${SERVICES[@]}"; do
  systemctl is-active --quiet "$S" || systemctl restart "$S"
done
EOF
chmod +x /usr/local/bin/health_check.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/health_check.sh") | crontab -

# -------- Access hint file --------
mkdir -p /etc/cloudflared
touch /etc/cloudflared/access-protected.txt

# -------- Dashboard GUI --------
cat > /opt/dashboard.py <<'EOF'
from flask import Flask, redirect
import os, re, subprocess

app = Flask(__name__)
VHOST="/www/server/panel/vhost"
ACCESS="/etc/cloudflared/access-protected.txt"

def port_open(p):
    return subprocess.call(f"ss -ltn | grep :{p}", shell=True) == 0

def detect(conf):
    if "wordpress" in conf.lower(): return "WordPress"
    if "proxy_pass" in conf: return "Node.js"
    return "PHP"

def domains():
    out=[]
    for r,_,fs in os.walk(VHOST):
        for f in fs:
            if f.endswith(".conf"):
                t=open(os.path.join(r,f)).read()
                names=re.findall(r"server_name\s+([^;]+);",t)
                p=80
                m=re.search(r"127.0.0.1:(\d+)",t)
                if m: p=int(m.group(1))
                for n in names:
                    for d in n.split():
                        out.append((d,detect(t),p))
    return out

@app.route("/")
def index():
    prot=set(l.strip() for l in open(ACCESS) if l.strip())
    html="<h2>Homelab Dashboard</h2>"
    html+='<form action="/test"><button>🧪 Test everything now</button></form>'
    html+="<table border=1 cellpadding=6>"
    html+="<tr><th>Domain</th><th>App</th><th>Port</th><th>Access</th><th>Status</th></tr>"
    for d,a,p in domains():
        html+=f"<tr><td>{d}</td><td>{a}</td><td>{p}</td><td>{'🟢 Protected' if d in prot else '🔴 Public'}</td><td>{'🟢 UP' if port_open(p) else '🔴 DOWN'}</td></tr>"
    return html+"</table>"

@app.route("/test")
def test():
    subprocess.call(["/usr/local/bin/health_check.sh"])
    return redirect("/")

app.run(host="127.0.0.1",port=9001)
EOF

cat > /etc/systemd/system/dashboard.service <<EOF
[Unit]
Description=Homelab Dashboard
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/dashboard.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable dashboard
systemctl start dashboard

echo "✅ INSTALL COMPLETE"
echo "Dashboard → http://localhost:9001"

