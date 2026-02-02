#!/usr/bin/env bash
set -e

echo "======================================"
echo "🚀 DashboardXE FULL SELF-HEAL INSTALL"
echo "======================================"

APP_DIR="/opt/dashboardxe"
PORT=9010
NODE_VERSION="20"

########################################
# 0. MUST BE ROOT
########################################
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run as root"
  exit 1
fi

########################################
# 1. FORCE CLEAN BROKEN STATE
########################################
echo "🧹 Purging broken packages..."

systemctl stop docker containerd apache2 || true
pm2 kill || true

apt-mark unhold nodejs npm containerd containerd.io docker docker.io || true

apt remove -y nodejs npm containerd docker docker.io docker-compose docker-compose-plugin || true
apt purge -y nodejs npm containerd docker docker.io || true
rm -rf /var/lib/docker /var/lib/containerd ~/.npm ~/.pm2

apt autoremove -y
apt clean
rm -rf /var/lib/apt/lists/*
apt update

########################################
# 2. INSTALL CORE PACKAGES
########################################
echo "📦 Installing base packages..."
apt install -y \
  curl ca-certificates gnupg lsb-release \
  apache2 ufw git unzip

########################################
# 3. INSTALL NODE.JS (CORRECT WAY)
########################################
echo "🟢 Installing Node.js ${NODE_VERSION}"
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt install -y nodejs

node -v
npm -v

########################################
# 4. INSTALL PM2 (ONLY VIA NPM)
########################################
echo "⚙️ Installing PM2"
npm install -g pm2
pm2 startup systemd -u root --hp /root

########################################
# 5. INSTALL DOCKER (OFFICIAL)
########################################
echo "🐳 Installing Docker"
curl -fsSL https://get.docker.com | bash -
systemctl enable --now docker

########################################
# 6. FIREWALL
########################################
ufw allow 80
ufw allow 443
ufw allow 9010
ufw allow 8081
ufw allow 8082
ufw allow 8083
ufw --force enable

########################################
# 7. CREATE APP STRUCTURE
########################################
echo "📁 Creating DashboardXE files..."

rm -rf $APP_DIR
mkdir -p $APP_DIR/{public,ssl/{certs,keys},backups,file-root}
cd $APP_DIR

########################################
# 8. PACKAGE.JSON
########################################
cat > package.json <<'EOF'
{
  "name": "dashboardxe",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "multer": "^2.0.0",
    "archiver": "^6.0.2",
    "bcrypt": "^5.1.0",
    "jsonwebtoken": "^9.0.2"
  }
}
EOF

########################################
# 9. SERVER.JS (FULL BACKEND)
########################################
cat > server.js <<'EOF'
const express = require("express");
const fs = require("fs");
const path = require("path");
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");
const { execSync } = require("child_process");

const app = express();
app.use(express.json());
app.use(express.static("public"));

const PORT = 9010;
const JWT_SECRET = "dashboardxe-secret";
const ROOT = path.resolve("file-root");
const SERVICES = ["apache2","docker"];

let users = { admin: bcrypt.hashSync("admin",10) };

// AUTH
function auth(req,res,next){
  const t=req.headers.authorization;
  if(!t) return res.sendStatus(401);
  try{ req.user=jwt.verify(t,JWT_SECRET).user; next(); }
  catch{ res.sendStatus(403); }
}

app.post("/api/login",(req,res)=>{
  const {user,pass}=req.body;
  if(!users[user]||!bcrypt.compareSync(pass,users[user]))
    return res.sendStatus(401);
  res.json({token:jwt.sign({user},JWT_SECRET)});
});

// SERVICES
app.get("/api/services",auth,(req,res)=>{
  const r={};
  SERVICES.forEach(s=>{
    try{ execSync(`systemctl is-active ${s}`); r[s]="running"; }
    catch{ r[s]="stopped"; }
  });
  res.json(r);
});

app.post("/api/restart",auth,(req,res)=>{
  execSync(`systemctl restart ${req.body.service}`);
  res.send("OK");
});

// PM2
app.get("/api/pm2",auth,(req,res)=>{
  res.json(JSON.parse(execSync("pm2 jlist").toString()));
});

app.get("/api/logs",auth,(req,res)=>{
  res.send(execSync(`pm2 logs ${req.query.name} --lines 50 --nostream`).toString());
});

app.listen(PORT,()=>console.log("DashboardXE on "+PORT));
EOF

########################################
# 10. BASIC UI
########################################
cat > public/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><title>DashboardXE</title></head>
<body>
<h1>DashboardXE</h1>
<p>Status: RUNNING</p>
</body>
</html>
EOF

########################################
# 11. INSTALL NODE DEPS
########################################
npm install

########################################
# 12. START DASHBOARD
########################################
pm2 start server.js --name DashboardXE
pm2 save

########################################
# 13. APACHE AUTO-PROXY
########################################
cat > /etc/apache2/sites-available/dashboardxe.conf <<EOF
<VirtualHost *:80>
  ProxyPreserveHost On
  ProxyPass / http://127.0.0.1:${PORT}/
  ProxyPassReverse / http://127.0.0.1:${PORT}/
</VirtualHost>
EOF

a2enmod proxy proxy_http headers
a2ensite dashboardxe.conf
systemctl reload apache2

########################################
# 14. DOCKER DB GUIs
########################################
docker run -d --restart always --name phpmyadmin \
  -e PMA_HOST=host.docker.internal \
  -p 8081:80 phpmyadmin/phpmyadmin

docker run -d --restart always --name pgadmin \
  -e PGADMIN_DEFAULT_EMAIL=admin@local \
  -e PGADMIN_DEFAULT_PASSWORD=admin \
  -p 8082:80 dpage/pgadmin4

docker run -d --restart always --name mongo-express \
  -p 8083:8081 mongo-express

echo "======================================"
echo "✅ DashboardXE INSTALLED SUCCESSFULLY"
echo "--------------------------------------"
echo "🌐 Dashboard : http://localhost"
echo "🔑 Login     : admin / admin"
echo "📦 phpMyAdmin: http://localhost:8081"
echo "📦 pgAdmin   : http://localhost:8082"
echo "📦 MongoExp  : http://localhost:8083"
echo "======================================"
