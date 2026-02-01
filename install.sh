#!/bin/bash
set -e

# ==========================================
# ⚙️  CONFIGURATION (CHANGE THESE!)
# ==========================================
DB_ROOT_PASS="rootpassword123"
PG_EMAIL="admin@localhost.com"
PG_PASS="adminpassword123"
MONGO_USER="admin"
MONGO_PASS="mongopassword123"
DASHBOARD_PORT=9001  # <--- CHANGED TO 9001
# ==========================================

echo "=================================================="
echo " 🚀 SYNXIEL DEVOPS STACK INSTALLER"
echo "=================================================="

if [ "$EUID" -ne 0 ]; then
  echo "❌ Run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- 1. PRE-FLIGHT & REPOS ---
echo "📦 Updating Repositories..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common git unzip

# Node.js LTS
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -

# PHP 8.3 (Ondrej PPA)
add-apt-repository -y ppa:ondrej/php

# MongoDB 7.0
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
   gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor --yes
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" \
| tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# Docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y

# --- 2. INSTALL CORE SERVICES ---
echo "🛠️  Installing Core Services (Apache, PHP, MySQL, Postgres, Mongo, Docker)..."

# Set MySQL Pass selections to avoid prompt
echo "mysql-server mysql-server/root_password password $DB_ROOT_PASS" | debconf-set-selections
echo "mysql-server mysql-server/root_password_again password $DB_ROOT_PASS" | debconf-set-selections

apt-get install -y \
  apache2 \
  php8.3 php8.3-cli php8.3-mysql php8.3-pgsql php8.3-curl php8.3-mbstring php8.3-xml \
  nodejs \
  mysql-server \
  postgresql postgresql-contrib \
  mongodb-org \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable Services
systemctl enable --now apache2 mysql postgresql mongod docker

# --- 3. PM2 SETUP ---
echo "📈 Installing PM2..."
npm install -g pm2
pm2 startup systemd -u root --hp /root || true

# --- 4. CONFIGURE DATABASES ---
echo "🗄️  Configuring Databases..."

# MySQL: Allow remote root (for Docker GUI access)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_ROOT_PASS';" || true
mysql -e "CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_ROOT_PASS';" || true
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;" || true
mysql -e "FLUSH PRIVILEGES;"
sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

# PostgreSQL: Set password and allow listen
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_PASS';"
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
echo "host    all             all             0.0.0.0/0            scram-sha-256" >> /etc/postgresql/*/main/pg_hba.conf
systemctl restart postgresql

# MongoDB: Create Admin
sleep 5 # Wait for Mongo to wake up
mongosh admin --eval "db.createUser({user: '$MONGO_USER', pwd: '$MONGO_PASS', roles: [{ role: 'userAdminAnyDatabase', db: 'admin' }, 'readWriteAnyDatabase']})" || true
sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
systemctl restart mongod

# --- 5. INSTALL DB GUIS (DOCKER) ---
echo "🐳 Deploying DB GUIs (phpMyAdmin, pgAdmin, Mongo Express)..."
mkdir -p /opt/devops-dashboard
cat > /opt/devops-dashboard/docker-compose.yml <<EOF
version: '3.8'
services:
  phpmyadmin:
    image: phpmyadmin/phpmyadmin
    ports:
      - "8081:80"
    environment:
      PMA_HOST: host.docker.internal
      MYSQL_ROOT_PASSWORD: $DB_ROOT_PASS
    extra_hosts:
      - "host.docker.internal:host-gateway"

  pgadmin:
    image: dpage/pgadmin4
    ports:
      - "8082:80"
    environment:
      PGADMIN_DEFAULT_EMAIL: $PG_EMAIL
      PGADMIN_DEFAULT_PASSWORD: $PG_PASS
    extra_hosts:
      - "host.docker.internal:host-gateway"

  mongo-express:
    image: mongo-express
    ports:
      - "8083:8081"
    environment:
      ME_CONFIG_MONGODB_ADMINUSERNAME: $MONGO_USER
      ME_CONFIG_MONGODB_ADMINPASSWORD: $MONGO_PASS
      ME_CONFIG_MONGODB_SERVER: host.docker.internal
      ME_CONFIG_BASICAUTH_USERNAME: $MONGO_USER
      ME_CONFIG_BASICAUTH_PASSWORD: $MONGO_PASS
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

cd /opt/devops-dashboard
docker compose up -d

# --- 6. CREATE CENTRAL DASHBOARD ---
echo "🖥️  Generating Central Dashboard..."

# Initialize Node Project
npm init -y >/dev/null
npm install express systeminformation axios --save

# Create Server Script
cat > server.js <<EOF
const express = require('express');
const si = require('systeminformation');
const { exec } = require('child_process');
const app = express();
const PORT = $DASHBOARD_PORT;

app.use(express.static('public'));

// API: System Stats
app.get('/api/stats', async (req, res) => {
    const mem = await si.mem();
    const cpu = await si.currentLoad();
    const disk = await si.fsSize();
    
    // Check Services via Systemctl
    exec('systemctl is-active apache2 mysql postgresql mongod docker', (err, stdout) => {
        const services = stdout.split('\n').filter(Boolean);
        res.json({
            cpu: Math.round(cpu.currentLoad),
            mem: Math.round((mem.active / mem.total) * 100),
            disk: disk[0] ? Math.round(disk[0].use) : 0,
            services: {
                apache: services[0] === 'active',
                mysql: services[1] === 'active',
                postgres: services[2] === 'active',
                mongo: services[3] === 'active',
                docker: services[4] === 'active'
            }
        });
    });
});

// API: PM2 Processes
app.get('/api/pm2', (req, res) => {
    exec('pm2 jlist', (err, stdout) => {
        if(err) return res.json([]);
        res.json(JSON.parse(stdout).map(p => ({
            name: p.name,
            status: p.pm2_env.status,
            memory: Math.round(p.monit.memory / 1024 / 1024),
            cpu: p.monit.cpu,
            uptime: p.pm2_env.pm_uptime
        })));
    });
});

// API: Restart PM2 App
app.post('/api/restart/:name', (req, res) => {
    exec(\`pm2 restart \${req.params.name}\`, (err) => {
        res.json({ success: !err });
    });
});

app.listen(PORT, () => console.log(\`Dashboard running on port \${PORT}\`));
EOF

# Create Frontend
mkdir -p public
cat > public/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>DevOps Control Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
</head>
<body class="bg-gray-900 text-gray-100 font-sans p-6">
    <div id="app" class="max-w-6xl mx-auto">
        <header class="mb-8 flex justify-between items-center border-b border-gray-700 pb-4">
            <h1 class="text-3xl font-bold text-blue-400"><i class="fas fa-terminal mr-2"></i> DevOps Control Panel</h1>
            <div class="text-sm text-gray-400">Host: $(hostname) | IP: $(hostname -I | awk '{print $1}')</div>
        </header>

        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
            <div class="bg-gray-800 p-4 rounded-lg shadow border-l-4 border-blue-500">
                <h3 class="text-gray-400 text-sm">CPU Load</h3>
                <p class="text-2xl font-bold">{{ stats.cpu }}%</p>
            </div>
            <div class="bg-gray-800 p-4 rounded-lg shadow border-l-4 border-green-500">
                <h3 class="text-gray-400 text-sm">RAM Usage</h3>
                <p class="text-2xl font-bold">{{ stats.mem }}%</p>
            </div>
            <div class="bg-gray-800 p-4 rounded-lg shadow border-l-4 border-yellow-500">
                <h3 class="text-gray-400 text-sm">Disk Usage</h3>
                <p class="text-2xl font-bold">{{ stats.disk }}%</p>
            </div>
            <div class="bg-gray-800 p-4 rounded-lg shadow border-l-4 border-purple-500">
                <h3 class="text-gray-400 text-sm">Services Active</h3>
                <div class="flex gap-2 mt-1">
                    <span v-for="(active, name) in stats.services" :key="name" 
                        class="w-3 h-3 rounded-full" 
                        :class="active ? 'bg-green-500' : 'bg-red-500'" 
                        :title="name"></span>
                </div>
            </div>
        </div>

        <h2 class="text-xl font-bold mb-4 text-gray-300">🗄️ Database Tools</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
            <a href="http://$(hostname -I | awk '{print $1}'):8081" target="_blank" class="bg-gray-800 hover:bg-gray-700 p-6 rounded-lg transition group">
                <div class="flex items-center justify-between mb-2">
                    <span class="text-xl font-bold text-orange-400">phpMyAdmin</span>
                    <i class="fas fa-external-link-alt text-gray-500 group-hover:text-white"></i>
                </div>
                <p class="text-sm text-gray-500">MySQL / MariaDB Management</p>
            </a>
            <a href="http://$(hostname -I | awk '{print $1}'):8082" target="_blank" class="bg-gray-800 hover:bg-gray-700 p-6 rounded-lg transition group">
                <div class="flex items-center justify-between mb-2">
                    <span class="text-xl font-bold text-blue-400">pgAdmin</span>
                    <i class="fas fa-external-link-alt text-gray-500 group-hover:text-white"></i>
                </div>
                <p class="text-sm text-gray-500">PostgreSQL Management</p>
            </a>
            <a href="http://$(hostname -I | awk '{print $1}'):8083" target="_blank" class="bg-gray-800 hover:bg-gray-700 p-6 rounded-lg transition group">
                <div class="flex items-center justify-between mb-2">
                    <span class="text-xl font-bold text-green-400">Mongo Express</span>
                    <i class="fas fa-external-link-alt text-gray-500 group-hover:text-white"></i>
                </div>
                <p class="text-sm text-gray-500">MongoDB GUI</p>
            </a>
        </div>

        <h2 class="text-xl font-bold mb-4 text-gray-300">⚙️ Process Manager (PM2)</h2>
        <div class="bg-gray-800 rounded-lg overflow-hidden">
            <table class="w-full text-left">
                <thead class="bg-gray-700 text-gray-400">
                    <tr>
                        <th class="p-4">Name</th>
                        <th class="p-4">Status</th>
                        <th class="p-4">Memory</th>
                        <th class="p-4">CPU</th>
                        <th class="p-4 text-right">Action</th>
                    </tr>
                </thead>
                <tbody>
                    <tr v-for="proc in processes" :key="proc.name" class="border-t border-gray-700">
                        <td class="p-4 font-bold">{{ proc.name }}</td>
                        <td class="p-4">
                            <span :class="proc.status === 'online' ? 'text-green-400' : 'text-red-400'">
                                {{ proc.status }}
                            </span>
                        </td>
                        <td class="p-4">{{ proc.memory }} MB</td>
                        <td class="p-4">{{ proc.cpu }}%</td>
                        <td class="p-4 text-right">
                            <button @click="restart(proc.name)" class="bg-blue-600 hover:bg-blue-500 px-3 py-1 rounded text-xs text-white">
                                <i class="fas fa-sync"></i> Restart
                            </button>
                        </td>
                    </tr>
                    <tr v-if="processes.length === 0">
                        <td colspan="5" class="p-4 text-center text-gray-500">No processes running via PM2</td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>

    <script>
        const { createApp } = Vue;
        createApp({
            data() {
                return {
                    stats: { cpu: 0, mem: 0, disk: 0, services: {} },
                    processes: []
                }
            },
            methods: {
                async fetchStats() {
                    const res = await fetch('/api/stats');
                    this.stats = await res.json();
                },
                async fetchPM2() {
                    const res = await fetch('/api/pm2');
                    this.processes = await res.json();
                },
                async restart(name) {
                    await fetch('/api/restart/' + name, { method: 'POST' });
                    this.fetchPM2();
                }
            },
            mounted() {
                this.fetchStats();
                this.fetchPM2();
                setInterval(() => {
                    this.fetchStats();
                    this.fetchPM2();
                }, 5000);
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF

# Start Dashboard via PM2
pm2 delete devops-dashboard 2>/dev/null || true
pm2 start server.js --name devops-dashboard
pm2 save

echo ""
echo "=================================================="
echo " ✅ INSTALLATION COMPLETE!"
echo "=================================================="
echo ""
echo "🖥️  Control Panel:  http://$(hostname -I | awk '{print $1}'):$DASHBOARD_PORT"
echo "🐘 pgAdmin:        http://$(hostname -I | awk '{print $1}'):8082 ($PG_EMAIL / $PG_PASS)"
echo "🐬 phpMyAdmin:     http://$(hostname -I | awk '{print $1}'):8081 (root / $DB_ROOT_PASS)"
echo "🍃 Mongo Express:  http://$(hostname -I | awk '{print $1}'):8083 ($MONGO_USER / $MONGO_PASS)"
echo ""
echo "⚠️  SECURITY NOTICE: Default passwords are set in the script."
echo "    Please change them before exposing this server to the internet!"
echo "=================================================="
