#!/usr/bin/env bash
set -e

APP=dashboardxe
BASE=/opt/$APP
APPDIR=$BASE/app
PORT=9010

echo "================================================="
echo "🔥 DASHBOARDXE – FULL FORCE SELF HEALING INSTALL"
echo "================================================="

### 1. HARD RESET
pm2 kill || true
systemctl stop apache2 || true
docker stop $(docker ps -aq) 2>/dev/null || true

apt-mark unhold nodejs npm || true
apt remove -y nodejs npm pm2 || true
rm -rf /usr/lib/node_modules /usr/local/lib/node_modules ~/.npm ~/.pm2
apt autoremove -y
apt clean
rm -rf /var/lib/apt/lists/*
dpkg --configure -a || true
apt --fix-broken install -y || true
apt update

### 2. INSTALL CORE
apt install -y curl ca-certificates gnupg apache2 ufw docker.io docker-compose

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
apt-mark hold npm

npm install -g pm2

systemctl enable apache2 docker
systemctl start apache2 docker

ufw allow 80
ufw allow 443
ufw allow 8081
ufw allow 8082
ufw allow 8083
ufw allow $PORT

### 3. CREATE STRUCTURE
rm -rf $BASE
mkdir -p $APPDIR/{public,file-root,ssl/certs,ssl/keys,backups}
mkdir -p $BASE/docker
cd $APPDIR

### 4. DASHBOARD BACKEND
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
    env: { PORT: $PORT }
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

app.post("/api/deploy",auth,(r,s)=>{
 const p=r.body.path;
 if(!fs.existsSync(p))return s.send("Not found");
 if(fs.existsSync(p+"/package.json")){
  execSync("npm install",{cwd:p});
  execSync(`pm2 start ${p} --name ${path.basename(p)}`);
  pm2save();
  return s.send("Node deployed");
 }
 s.send("Unknown project");
});

function pm2save(){try{execSync("pm2 save");}catch{}}

function safe(p=""){const r=path.resolve(ROOT,p);if(!r.startsWith(ROOT))throw"";return r;}

app.get("/api/files",auth,(r,s)=>{
 s.json(fs.readdirSync(safe(r.query.path||"")));
});

const up=multer({dest:ROOT});
app.post("/api/upload",auth,up.single("f"),(r,s)=>{
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

### 5. FRONTEND
cat > public/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><title>DashboardXE</title><link rel="stylesheet" href="style.css"></head>
<body>
<h1>DashboardXE</h1>
<div id="login">
<input id="u" value="admin"><input id="p" value="admin">
<button onclick="login()">Login</button>
</div>
<pre id="out"></pre>
<script src="app.js"></script>
</body>
</html>
EOF

cat > public/app.js <<'EOF'
let t="";
function login(){
 fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},
 body:JSON.stringify({user:u.value,pass:p.value})})
 .then(r=>r.json()).then(j=>{t=j.token;load();});
}
function load(){
 fetch("/api/services",{headers:{Authorization:t}})
 .then(r=>r.json()).then(o=>out.textContent=JSON.stringify(o,null,2));
}
EOF

cat > public/style.css <<EOF
body{background:#111;color:#0f0;font-family:monospace;padding:20px}
input,button{margin:5px}
EOF

### 6. INSTALL & RUN
npm install
pm2 start ecosystem.config.js
pm2 save

### 7. DOCKER DB GUIS
cat > $BASE/docker/docker-compose.yml <<EOF
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

docker-compose -f $BASE/docker/docker-compose.yml up -d

echo "================================================="
echo "✅ DashboardXE READY"
echo "🌐 http://localhost:$PORT"
echo "👤 admin / admin"
echo "================================================="
