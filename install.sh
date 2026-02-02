#!/bin/bash
set -e

APP_NAME="DashboardXE"
PORT=9010
BASE="/opt/dashboardxe"
APP_DIR="$BASE/app"
APP_USER="admin"
APP_PASS="admin"

echo "========================================"
echo " Installing $APP_NAME on port $PORT"
echo "========================================"

# -------------------------------
# FIX NODE / NPM CONFLICT (SAFE)
# -------------------------------
if dpkg -l | grep -q "^ii  npm "; then
  echo "⚠️ Removing Ubuntu npm (conflict)"
  apt remove -y npm || true
fi

if ! command -v node >/dev/null; then
  echo "🔧 Installing Node.js 20 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
fi

# -------------------------------
# BASE PACKAGES
# -------------------------------
apt install -y apache2 curl ufw

if ! command -v pm2 >/dev/null; then
  npm install -g pm2
fi

# -------------------------------
# FIREWALL
# -------------------------------
ufw allow ${PORT}/tcp || true

# -------------------------------
# DIRECTORIES
# -------------------------------
mkdir -p \
  $APP_DIR/public \
  $APP_DIR/file-root \
  $APP_DIR/ssl/certs \
  $APP_DIR/ssl/keys \
  $APP_DIR/backups/mysql \
  $APP_DIR/backups/postgres \
  $APP_DIR/backups/mongo

# -------------------------------
# ENV
# -------------------------------
cat > $APP_DIR/.env <<EOF
PORT=${PORT}
JWT_SECRET=$(openssl rand -hex 32)
EOF

# -------------------------------
# PACKAGE.JSON
# -------------------------------
cat > $APP_DIR/package.json <<'EOF'
{
  "name": "dashboardxe",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "bcrypt": "^5.1.0",
    "jsonwebtoken": "^9.0.2",
    "multer": "^2.0.0",
    "archiver": "^6.0.2",
    "dotenv": "^16.4.5"
  }
}
EOF

# -------------------------------
# SERVER.JS
# -------------------------------
cat > $APP_DIR/server.js <<'EOF'
require("dotenv").config();
const express = require("express");
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");
const { execSync } = require("child_process");

const app = express();
app.use(express.json());
app.use(express.static("public"));

const SERVICES = ["apache2","mariadb","postgresql","mongod","docker"];
const users = { admin: bcrypt.hashSync("admin",10) };

function auth(req,res,next){
  try{
    req.user = jwt.verify(req.headers.authorization, process.env.JWT_SECRET).user;
    next();
  }catch{ res.sendStatus(401); }
}

app.post("/api/login",(req,res)=>{
  if(!users[req.body.user]) return res.sendStatus(401);
  if(!bcrypt.compareSync(req.body.pass, users[req.body.user])) return res.sendStatus(401);
  res.json({ token: jwt.sign({user:req.body.user}, process.env.JWT_SECRET) });
});

app.get("/api/services",auth,(req,res)=>{
  const r = {};
  SERVICES.forEach(s=>{
    try{ execSync(`systemctl is-active ${s}`); r[s]="running"; }
    catch{ r[s]="stopped"; }
  });
  res.json(r);
});

app.listen(process.env.PORT,()=>{
  console.log("DashboardXE running on port", process.env.PORT);
});
EOF

# -------------------------------
# UI
# -------------------------------
cat > $APP_DIR/public/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<title>DashboardXE</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<h1>DashboardXE</h1>
<input id="u" placeholder="user">
<input id="p" placeholder="pass" type="password">
<button onclick="login()">Login</button>
<pre id="out"></pre>
<script src="app.js"></script>
</body>
</html>
EOF

cat > $APP_DIR/public/app.js <<'EOF'
function login(){
 fetch("/api/login",{
   method:"POST",
   headers:{"Content-Type":"application/json"},
   body:JSON.stringify({user:u.value,pass:p.value})
 }).then(r=>r.json()).then(d=>{
   out.textContent = d.token ? "Login OK" : "Login failed";
 });
}
EOF

cat > $APP_DIR/public/style.css <<'EOF'
body{background:#111;color:#eee;font-family:sans-serif;padding:20px}
input,button{margin:5px}
EOF

# -------------------------------
# PM2
# -------------------------------
cat > $APP_DIR/ecosystem.config.js <<EOF
module.exports = {
  apps: [{
    name: "DashboardXE",
    script: "server.js",
    cwd: "$APP_DIR",
    env: { NODE_ENV: "production" }
  }]
}
EOF

cd $APP_DIR
npm install

pm2 start ecosystem.config.js || pm2 restart DashboardXE
pm2 save

# -------------------------------
# SELF HEAL
# -------------------------------
cat > $BASE/self-heal.sh <<EOF
#!/bin/bash
if ! ss -tulpn | grep -q :$PORT; then
  pm2 restart DashboardXE || pm2 start $APP_DIR/ecosystem.config.js
fi
EOF

chmod +x $BASE/self-heal.sh
(crontab -l 2>/dev/null; echo "*/2 * * * * $BASE/self-heal.sh") | crontab -

echo "========================================"
echo " ✅ DashboardXE INSTALLED"
echo " 🌐 http://localhost:$PORT"
echo " 🔐 admin / admin"
echo "========================================"
