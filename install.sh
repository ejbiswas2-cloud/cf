#!/usr/bin/env bash
set -e

LOG_FILE="/opt/devops-panel/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 DevOps Control Panel Installer"

### -------------------------
### Globals
### -------------------------
DASHBOARD_DIR="/opt/devops-panel"
DASHBOARD_PORT=3000
MYSQL_ROOT_PASSWORD="root"
PG_ADMIN_EMAIL="admin@local.dev"
PG_ADMIN_PASSWORD="admin"
MONGO_EXPRESS_USER="admin"
MONGO_EXPRESS_PASS="admin"

### -------------------------
### Helpers
### -------------------------
function installed() {
  command -v "$1" >/dev/null 2>&1
}

function apt_install() {
  apt-get install -y "$@"
}

### -------------------------
### Base System
### -------------------------
echo "📦 Updating system..."
apt-get update -y

apt_install \
  curl wget gnupg lsb-release ca-certificates \
  software-properties-common unzip git \
  apt-transport-https jq

### -------------------------
### Apache + PHP 8.3
### -------------------------
if ! installed php8.3; then
  echo "🌐 Installing Apache + PHP 8.3..."
  add-apt-repository ppa:ondrej/php -y
  apt-get update -y
  apt_install apache2 php8.3 php8.3-cli php8.3-mysql php8.3-pgsql php8.3-mongodb \
              php8.3-curl php8.3-xml php8.3-mbstring php8.3-zip
fi

systemctl enable apache2
systemctl restart apache2

### -------------------------
### Node.js LTS + PM2
### -------------------------
if ! installed node; then
  echo "🟢 Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt_install nodejs
fi

if ! installed pm2; then
  echo "⚙️ Installing PM2..."
  npm install -g pm2
fi

pm2 startup systemd -u root --hp /root || true

### -------------------------
### Databases
### -------------------------
echo "🗄 Installing databases..."

DEBIAN_FRONTEND=noninteractive apt_install \
  mariadb-server \
  postgresql postgresql-contrib \
  mongodb

systemctl enable mariadb postgresql mongodb
systemctl restart mariadb postgresql mongodb

### -------------------------
### Docker + Compose
### -------------------------
if ! installed docker; then
  echo "🐳 Installing Docker..."
  curl -fsSL https://get.docker.com | bash
fi

if ! installed docker-compose; then
  echo "🐳 Installing Docker Compose..."
  curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

### -------------------------
### Dashboard Setup
### -------------------------
echo "🧠 Setting up DevOps Dashboard..."

mkdir -p "$DASHBOARD_DIR"/{dashboard,data/{backups/{mysql,postgres,mongo},ssl},logs,docker}

### -------------------------
### Docker DB GUIs
### -------------------------
cat > "$DASHBOARD_DIR/docker/docker-compose.yml" <<EOF
version: "3"
services:
  phpmyadmin:
    image: phpmyadmin
    ports:
      - "8081:80"
    environment:
      PMA_HOST: host.docker.internal

  pgadmin:
    image: dpage/pgadmin4
    ports:
      - "8082:80"
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PG_ADMIN_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PG_ADMIN_PASSWORD}

  mongo-express:
    image: mongo-express
    ports:
      - "8083:8081"
    environment:
      ME_CONFIG_BASICAUTH_USERNAME: ${MONGO_EXPRESS_USER}
      ME_CONFIG_BASICAUTH_PASSWORD: ${MONGO_EXPRESS_PASS}
      ME_CONFIG_MONGODB_SERVER: host.docker.internal
EOF

docker-compose -f "$DASHBOARD_DIR/docker/docker-compose.yml" up -d

### -------------------------
### Dashboard App
### -------------------------
cat > "$DASHBOARD_DIR/dashboard/package.json" <<EOF
{
  "name": "devops-panel",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.0",
    "child_process": "^1.0.2"
  }
}
EOF

cat > "$DASHBOARD_DIR/dashboard/server.js" <<'EOF'
const express = require("express");
const { exec } = require("child_process");
const app = express();

app.use(express.json());
app.use(express.static("public"));

function cmd(command, res) {
  exec(command, (err, stdout) => {
    if (err) return res.json({ error: err.message });
    res.json({ output: stdout });
  });
}

app.get("/api/services", (req, res) => {
  cmd("systemctl list-units --type=service --state=running", res);
});

app.get("/api/pm2", (req, res) => {
  cmd("pm2 jlist", res);
});

app.post("/api/restart/:service", (req, res) => {
  cmd(`systemctl restart ${req.params.service}`, res);
});

app.listen(3000, () =>
  console.log("DevOps Panel running on http://localhost:3000")
);
EOF

cat > "$DASHBOARD_DIR/dashboard/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: "devops-dashboard",
    script: "server.js"
  }]
}
EOF

cat > "$DASHBOARD_DIR/dashboard/public/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>DevOps Control Panel</title>
  <style>
    body { font-family: sans-serif; background:#111; color:#0f0 }
    button { margin:5px }
  </style>
</head>
<body>
<h1>🧠 DevOps Control Panel</h1>
<button onclick="load()">Refresh Status</button>
<pre id="out"></pre>

<script>
async function load(){
  const res = await fetch('/api/services');
  document.getElementById('out').innerText = JSON.stringify(await res.json(),null,2);
}
</script>
</body>
</html>
EOF

cd "$DASHBOARD_DIR/dashboard"
npm install

pm2 start ecosystem.config.js
pm2 save

### -------------------------
### Final Output
### -------------------------
echo ""
echo "✅ INSTALL COMPLETE"
echo "--------------------------------"
echo "🧠 Dashboard:      http://localhost:${DASHBOARD_PORT}"
echo "🛢 phpMyAdmin:     http://localhost:8081"
echo "🐘 pgAdmin:        http://localhost:8082"
echo "🍃 Mongo Express:  http://localhost:8083"
echo ""
echo "🔑 Credentials:"
echo "MySQL root: root / root"
echo "pgAdmin: ${PG_ADMIN_EMAIL} / ${PG_ADMIN_PASSWORD}"
echo "Mongo Express: ${MONGO_EXPRESS_USER} / ${MONGO_EXPRESS_PASS}"
echo ""
echo "📜 Log file: ${LOG_FILE}"
