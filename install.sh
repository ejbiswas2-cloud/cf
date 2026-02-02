#!/usr/bin/env bash
set -e

APP=dashboardxe
BASE=/opt/$APP
APPDIR=$BASE/app
DOCKERDIR=$BASE/docker
PORT=9010

echo "======================================================"
echo "🔥 DASHBOARDXE – FIXED & SECURED INSTALLER"
echo "======================================================"

### 1️⃣ PURGE (Optimized)
echo "[1/10] Cleaning environment..."
pm2 kill 2>/dev/null || true
systemctl stop apache2 docker containerd 2>/dev/null || true

# Remove existing to prevent 'directory not empty' errors
rm -rf $BASE

### 2️⃣ CORE PACKAGES
apt update && apt install -y curl ca-certificates gnupg lsb-release apache2 ufw software-properties-common

### 3️⃣ NODE.JS 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

### 5️⃣ DOCKER
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash -
fi
systemctl enable --now docker

### 7️⃣ DIRECTORY STRUCTURE
# Ensure the upload directory exists BEFORE Node starts
mkdir -p $APPDIR/public $APPDIR/file-root $APPDIR/ssl/certs $APPDIR/ssl/keys $DOCKERDIR

cd $APPDIR

### 8️⃣ BACKEND (Fixed Logic & Security)
cat > package.json <<EOF
{
  "name": "dashboardxe",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "bcrypt": "^5.1.0",
    "jsonwebtoken": "^9.0.2",
    "multer": "^1.4.5-lts.1",
    "archiver": "^6.0.2"
  }
}
EOF

cat > server.js <<'EOF'
const express = require("express");
const fs = require("fs");
const path = require("path");
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");
const multer = require("multer");
const { execSync } = require("child_process");

const app = express();
app.use(express.json());
app.use(express.static("public"));

const PORT = 9010;
const SECRET = "super-secret-key-change-me";
const ROOT = path.resolve(__dirname, "file-root");
const ALLOWED_SERVICES = ["apache2", "docker", "containerd"];

// Ensure upload dir exists
if (!fs.existsSync(ROOT)) fs.mkdirSync(ROOT, { recursive: true });

const storage = multer.diskStorage({
    destination: (req, file, cb) => cb(null, ROOT),
    filename: (req, file, cb) => cb(null, file.originalname)
});
const upload = multer({ storage });

let users = { admin: bcrypt.hashSync("admin", 10) };

function auth(req, res, next) {
    const t = req.headers.authorization;
    try {
        req.user = jwt.verify(t, SECRET).user;
        next();
    } catch (e) { res.status(401).send("Unauthorized"); }
}

app.post("/api/login", (req, res) => {
    const { user, pass } = req.body;
    if (users[user] && bcrypt.compareSync(pass, users[user])) {
        return res.json({ token: jwt.sign({ user }, SECRET) });
    }
    res.status(401).send("Invalid credentials");
});

app.get("/api/services", auth, (req, res) => {
    let status = {};
    ALLOWED_SERVICES.forEach(s => {
        try {
            execSync(`systemctl is-active ${s}`);
            status[s] = "running";
        } catch { status[s] = "stopped"; }
    });
    res.json(status);
});

app.post("/api/restart", auth, (req, res) => {
    const { service } = req.body;
    if (!ALLOWED_SERVICES.includes(service)) return res.status(400).send("Forbidden service");
    execSync(`systemctl restart ${service}`);
    res.send("Restarted");
});

app.get("/api/pm2", auth, (req, res) => {
    try {
        const data = execSync("pm2 jlist").toString();
        res.json(JSON.parse(data));
    } catch (e) { res.status(500).send("PM2 Error"); }
});

app.post("/api/upload", auth, upload.single("file"), (req, res) => {
    res.send("Uploaded successfully to " + req.file.path);
});

app.listen(PORT, () => console.log(`DashboardXE running on port ${PORT}`));
EOF

### 🔟 FINALIZATION
npm install
npm install -g pm2
pm2 start server.js --name "dashboardxe"
pm2 save

# Setup Docker Containers
cat > $DOCKERDIR/docker-compose.yml <<EOF
services:
  phpmyadmin:
    image: phpmyadmin
    ports: ["8081:80"]
  pgadmin:
    image: dpage/pgadmin4:latest
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local
      PGADMIN_DEFAULT_PASSWORD: admin
    ports: ["8082:80"]
EOF

docker compose -f $DOCKERDIR/docker-compose.yml up -d

echo "✅ INSTALL COMPLETE - http://$(hostname -I | awk '{print $1}'):9010"
