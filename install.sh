#!/bin/bash
set -e

APP="DashboardXE"
PORT=9010
BASE="/opt/dashboardxe"
APPDIR="$BASE/app"
USER="admin"
PASS="admin"

echo "🚀 Installing $APP on port $PORT"

# ---------- SYSTEM ----------
apt update -y
apt install -y curl ufw apache2 nodejs npm

npm install -g pm2

ufw allow $PORT/tcp || true

mkdir -p $APPDIR/{public,file-root,ssl/certs,ssl/keys,backups/mysql,backups/postgres,backups/mongo}

# ---------- ENV ----------
cat > $APPDIR/.env <<EOF
PORT=$PORT
JWT_SECRET=$(openssl rand -hex 32)
EOF

# ---------- PACKAGE ----------
cat > $APPDIR/package.json <<EOF
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

# ---------- SERVER ----------
cat > $APPDIR/server.js <<'EOF'
require("dotenv").config();
const express=require("express");
const fs=require("fs");
const path=require("path");
const bcrypt=require("bcrypt");
const jwt=require("jsonwebtoken");
const {execSync}=require("child_process");

const app=express();
app.use(express.json());
app.use(express.static("public"));

const ROOT=path.resolve("file-root");
const SERVICES=["apache2","mariadb","postgresql","mongod","docker"];
const users={admin:bcrypt.hashSync("admin",10)};

function auth(req,res,next){
  try{
    req.user=jwt.verify(req.headers.authorization,process.env.JWT_SECRET).user;
    next();
  }catch{res.sendStatus(401);}
}

app.post("/api/login",(req,res)=>{
  if(!users[req.body.user]) return res.sendStatus(401);
  if(!bcrypt.compareSync(req.body.pass,users[req.body.user])) return res.sendStatus(401);
  res.json({token:jwt.sign({user:req.body.user},process.env.JWT_SECRET)});
});

app.get("/api/services",auth,(req,res)=>{
  const r={};
  SERVICES.forEach(s=>{
    try{execSync(`systemctl is-active ${s}`);r[s]="running";}
    catch{r[s]="stopped";}
  });
  res.json(r);
});

app.post("/api/restart",auth,(req,res)=>{
  execSync(`systemctl restart ${req.body.service}`);
  res.send("restarted");
});

app.get("/api/projects",auth,(req,res)=>{
  res.json(JSON.parse(execSync("pm2 jlist").toString()));
});

app.get("/api/logs",auth,(req,res)=>{
  res.send(execSync(`pm2 cat ${req.query.name} --lines 50`).toString());
});

app.listen(process.env.PORT,()=>console.log("DashboardXE running"));
EOF

# ---------- UI ----------
cat > $APPDIR/public/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>DashboardXE</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<h1>DashboardXE</h1>
<input id="u" placeholder="user"><input id="p" placeholder="pass" type="password">
<button onclick="login()">Login</button>
<pre id="out"></pre>
<script src="app.js"></script>
</body>
</html>
EOF

cat > $APPDIR/public/app.js <<EOF
let token="";
function login(){
 fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},
 body:JSON.stringify({user:u.value,pass:p.value})})
 .then(r=>r.json()).then(d=>{token=d.token;out.textContent="Logged in"});
}
EOF

cat > $APPDIR/public/style.css <<EOF
body{background:#111;color:#eee;font-family:sans-serif;padding:20px}
input,button{margin:5px}
EOF

# ---------- PM2 ----------
cat > $APPDIR/ecosystem.config.js <<EOF
module.exports={
 apps:[{
   name:"DashboardXE",
   script:"server.js",
   cwd:"$APPDIR",
   env:{NODE_ENV:"production"}
 }]
}
EOF

cd $APPDIR
npm install
pm2 start ecosystem.config.js
pm2 save

# ---------- SELF HEAL ----------
cat > $BASE/self-heal.sh <<EOF
#!/bin/bash
if ! ss -tulpn | grep -q :$PORT; then
 pm2 restart DashboardXE || pm2 start $APPDIR/ecosystem.config.js
fi
EOF

chmod +x $BASE/self-heal.sh
(crontab -l 2>/dev/null; echo "*/2 * * * * $BASE/self-heal.sh") | crontab -

echo "✅ DashboardXE installed"
echo "🌐 http://localhost:$PORT"
echo "🔐 admin / admin"
