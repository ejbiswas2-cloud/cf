#!/bin/bash
set -e

echo "======================================"
echo " 🚀 Synxiel Production Installer"
echo "======================================"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

### BASE PACKAGES
apt update -y
apt install -y curl git unzip ca-certificates gnupg \
  build-essential python3 python3-pip \
  apache2 docker.io docker-compose \
  postgresql postgresql-contrib

### NODE + PM2
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs
npm install -g pm2
pm2 startup systemd -u root --hp /root || true

### MONGODB
curl -fsSL https://pgp.mongodb.com/server-6.0.asc \
 | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg

echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
> /etc/apt/sources.list.d/mongodb.list

apt update -y
apt install -y mongodb-org
systemctl enable mongod
systemctl start mongod

### DIRECTORIES
mkdir -p /opt/{apps,backups,dashboard,data}
chmod -R 755 /opt

### AUTO BACKUP SCRIPT
cat > /usr/local/bin/homelab-backup.sh <<'EOF'
#!/bin/bash
BASE=/opt/backups
DATE=$(date +%F)
mkdir -p $BASE/{mongo,postgres,mysql}

mongodump --out $BASE/mongo/$DATE 2>/dev/null || true
sudo -u postgres pg_dumpall > $BASE/postgres/$DATE.sql 2>/dev/null || true
mysqldump --all-databases > $BASE/mysql/$DATE.sql 2>/dev/null || true

find $BASE -type d -mtime +7 -exec rm -rf {} \;
find $BASE -type f -mtime +7 -delete
EOF
chmod +x /usr/local/bin/homelab-backup.sh

### CRON (DAILY 2AM)
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/homelab-backup.sh") | crontab -

### DASHBOARD (WITH DEPLOY + BACKUP STATUS)
cat > /opt/dashboard/server.js <<'EOF'
const express = require("express");
const { execSync } = require("child_process");
const fs = require("fs");

const app = express();
app.use(express.urlencoded({ extended: true }));

const APPS = {
  frontend: "/opt/apps/frontend",
  backend: "/opt/apps/backend"
};

function run(cmd){
  try { return execSync(cmd,{encoding:"utf8"}); }
  catch(e){ return e.stdout || e.message; }
}

app.get("/",(_,res)=>{
res.send(`
<h2>🚀 Homelab Control Panel</h2>

<h3>🟢 Apps</h3>
<ul>
${Object.keys(APPS).map(a=>`
<li>${a}
 <a href="/deploy/${a}">Deploy</a>
 <a href="/restart/${a}">Restart</a>
</li>`).join("")}
</ul>

<h3>💾 Backup Status</h3>
<pre>${run("ls -lh /opt/backups")}</pre>

<h3>⚙ Services</h3>
<pre>${run("systemctl is-active apache2 mongod postgresql cloudflared")}</pre>

<h3>📊 PM2</h3>
<a href="/pm2">View PM2 Status</a>
`);
});

app.get("/deploy/:app",(req,res)=>{
const dir=APPS[req.params.app];
if(!dir) return res.send("Invalid app");
res.send(`<pre>${
 run(`cd ${dir} && git pull && npm install && pm2 restart ${req.params.app}`)
}</pre><a href="/">Back</a>`);
});

app.get("/restart/:app",(req,res)=>{
res.send(`<pre>${run(`pm2 restart ${req.params.app}`)}</pre><a href="/">Back</a>`);
});

app.get("/pm2",(_,res)=>res.send(`<pre>${run("pm2 status")}</pre>`));

app.listen(9001,()=>console.log("Dashboard running on :9001"));
EOF

pm2 start /opt/dashboard/server.js --name dashboard
pm2 save

### DONE
echo "======================================"
echo " ✅ INSTALL COMPLETE"
echo "======================================"
echo ""
echo "Dashboard: http://localhost:9001"
echo "Backups: /opt/backups (daily, keep 7)"
echo "Deploy: Git pull + npm install + PM2 restart"
echo ""
echo "Cloudflare Tunnel mapping:"
echo "  dash.domain.com → localhost:9001"
echo "  app.domain.com  → localhost:3000"
echo "  api.domain.com  → localhost:4000"
