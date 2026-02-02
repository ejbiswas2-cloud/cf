#!/usr/bin/env bash
set -e

APP=dashboardxe
BASE=/opt/$APP
APPDIR=$BASE/app
DOCKERDIR=$BASE/docker
PORT=9010

echo "======================================================"
echo "🔥 DASHBOARDXE – ULTIMATE FORCE SELF-HEAL INSTALLER"
echo "======================================================"

### ===============================
### 1️⃣ TOTAL PURGE (KNOWN ERRORS)
### ===============================
echo "[1/10] Force removing Node / npm / PM2 / Docker / containerd"

pm2 kill 2>/dev/null || true
systemctl stop apache2 docker containerd 2>/dev/null || true

apt-mark unhold nodejs npm containerd containerd.io docker docker.io || true

apt remove -y \
  nodejs npm pm2 \
  docker docker.io docker-compose docker-compose-plugin \
  containerd containerd.io || true

apt purge -y containerd || true

rm -rf \
  /usr/lib/node_modules \
  /usr/local/lib/node_modules \
  /var/lib/docker \
  /var/lib/containerd \
  ~/.npm ~/.pm2 \
  $BASE

apt autoremove -y
apt clean
rm -rf /var/lib/apt/lists/*
apt update

dpkg --configure -a || true
apt --fix-broken install -y || true

### ===============================
### 2️⃣ CORE PACKAGES
### ===============================
echo "[2/10] Installing core system packages"

apt install -y \
  curl ca-certificates gnupg lsb-release \
  apache2 ufw software-properties-common

### ===============================
### 3️⃣ NODE.JS (SAFE METHOD)
### ===============================
echo "[3/10] Installing Node.js 20 LTS"

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
apt-mark hold npm

node -v
npm -v

### ===============================
### 4️⃣ PM2
### ===============================
echo "[4/10] Installing PM2"

npm install -g pm2
pm2 startup systemd -u root --hp /root || true

### ===============================
### 5️⃣ DOCKER (OFFICIAL ONLY)
### ===============================
echo "[5/10] Installing Docker (official)"

curl -fsSL https://get.docker.com | bash -
systemctl enable docker
systemctl start docker

apt-mark hold docker-ce docker-ce-cli containerd.io

docker --version
containerd --version

### ===============================
### 6️⃣ FIREWALL
### ===============================
echo "[6/10] Configuring firewall"

ufw allow 80
ufw allow 443
ufw allow 9010
ufw allow 8081
ufw allow 8082
ufw allow 8083
ufw --force enable || true

### ===============================
### 7️⃣ DIRECTORY STRUCTURE
### ===============================
echo "[7/10] Creating directory structure"

mkdir -p \
  $APPDIR/public \
  $APPDIR/file-root \
  $APPDIR/ssl/certs \
  $APPDIR/ssl/keys \
  $APPDIR/backups \
  $DOCKERDIR

cd $APPDIR

### ===============================
### 8️⃣ DASHBOARD BACKEND
### ===============================
echo "[8/10] Writing backend code"

cat > package.json <<EOF
{
  "name": "dashboardxe",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "bcrypt": "^5.1.0",
    "jsonwebtoken": "^9.0.2",
    "multer": "^2.0.0",
    "archiver": "^6.0.2"
  }
}
EOF

cat > ecosystem.config.js <<EOF
module.exports = {
  apps: [{
    name: "DashboardXE",
    script: "server.js",
    env: { PORT: 9010 }
  }]
}
EOF

cat > server.js <<'EOF'
const express=require("express");
const fs=require("fs");
const path=require("path");
const bcrypt=require("bcrypt");
const jwt=require("jsonwebtoken");
const multer=require("multer");
const archiver=require("archiver");
const {execSync}=require("child_process");

const app=express();
app.use(express.json());
app.use(express.static("public"));

const PORT=process.env.PORT||9010;
const SECRET="dashboardxe-secret";
const ROOT=path.resolve("file-root");
const SERVICES=["apache2","docker"];

let users={admin:bcrypt.hashSync("admin",10)};

function auth(req,res,next){
 const t=req.headers.authorization;
 if(!t)return res.sendStatus(401);
 try{req.user=jwt.verify(t,SECRET).user;next();}
 catch{res.sendStatus(403);}
}

app.post("/api/login",(r,s)=>{
 if(!users[r.body.user])return s.sendStatus(401);
 if(!bcrypt.compareSync(r.body.pass,users[r.body.user]))return s.sendStatus(401);
 s.json({token:jwt.sign({user:r.body.user},SECRET)});
});

app.get("/api/services",auth,(r,s)=>{
 let o={};
 SERVICES.forEach(x=>{
  try{execSync(`systemctl is-active ${x}`);o[x]="running";}
  catch{o[x]="stopped";}
 });
 s.json(o);
});

app.post("/api/restart",auth,(r,s)=>{
 execSync(`systemctl restart ${r.body.service}`);
 s.send("Restarted");
});

app.get("/api/pm2",auth,(r,s)=>{
 s.json(JSON.parse(execSync("pm2 jlist")));
});

app.get("/api/logs",auth,(r,s)=>{
 s.send(execSync(`pm2 logs ${r.query.name} --lines 50 --nostream`).toString());
});

function safe(p=""){
 const r=path.resolve(ROOT,p);
 if(!r.startsWith(ROOT))throw "";
 return r;
}

app.get("/api/files",auth,(r,s)=>{
 s.json(fs.readdirSync(safe(r.query.path||"")));
});

const upload=multer({dest:ROOT});
app.post("/api/upload",auth,upload.single("file"),(r,s)=>{
 fs.renameSync(r.file.path,safe(r.file.originalname));
 s.send("Uploaded");
});

app.post("/api/ssl",auth,(r,s)=>{
 fs.writeFileSync(`ssl/certs/${r.body.domain}.crt`,r.body.cert);
 fs.writeFileSync(`ssl/keys/${r.body.domain}.key`,r.body.key);
 const conf=`
<VirtualHost *:80>
 ServerName ${r.body.domain}
 ProxyPass / http://127.0.0.1:${PORT}/
 ProxyPassReverse / http://127.0.0.1:${PORT}/
</VirtualHost>`;
 fs.writeFileSync(`/etc/apache2/sites-available/${r.body.domain}.conf`,conf);
 execSync("a2enmod proxy proxy_http");
 execSync(`a2ensite ${r.body.domain}.conf`);
 execSync("systemctl reload apache2");
 s.send("SSL attached");
});

app.listen(PORT,()=>console.log("DashboardXE on "+PORT));
EOF

### ===============================
### 9️⃣ FRONTEND
### ===============================
echo "[9/10] Writing frontend UI"

cat > public/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>DashboardXE</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<h1>DashboardXE</h1>
<div id="login">
<input id="u" value="admin">
<input id="p" value="admin" type="password">
<button onclick="login()">Login</button>
</div>
<pre id="out"></pre>
<script src="app.js"></script>
</body>
</html>
EOF

cat > public/app.js <<EOF
let token="";
function login(){
 fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},
 body:JSON.stringify({user:u.value,pass:p.value})})
 .then(r=>r.json()).then(j=>{token=j.token;load();});
}
function load(){
 fetch("/api/services",{headers:{Authorization:token}})
 .then(r=>r.json()).then(d=>out.textContent=JSON.stringify(d,null,2));
}
EOF

cat > public/style.css <<EOF
body{background:#111;color:#0f0;font-family:monospace;padding:20px}
input,button{margin:5px}
EOF

### ===============================
### 🔟 INSTALL, RUN, DOCKER GUIs
### ===============================
echo "[10/10] Installing dependencies & starting services"

npm install
pm2 start ecosystem.config.js
pm2 save

cat > $DOCKERDIR/docker-compose.yml <<EOF
version: "3"
services:
 phpmyadmin:
  image: phpmyadmin
  ports: ["8081:80"]
  environment:
   PMA_HOST: host.docker.internal
 pgadmin:
  image: dpage/pgadmin4
  ports: ["8082:80"]
  environment:
   PGADMIN_DEFAULT_EMAIL: admin@local
   PGADMIN_DEFAULT_PASSWORD: admin
 mongo-express:
  image: mongo-express
  ports: ["8083:8081"]
  environment:
   ME_CONFIG_BASICAUTH_USERNAME: admin
   ME_CONFIG_BASICAUTH_PASSWORD: admin
EOF

docker compose -f $DOCKERDIR/docker-compose.yml up -d

echo "======================================================"
echo "✅ DASHBOARDXE INSTALL COMPLETE"
echo "🌐 Dashboard: http://localhost:9010"
echo "👤 Login: admin / admin"
echo "======================================================"
