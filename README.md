# Secure Homelab with Cloudflare Tunnel (No IPv4 Required)

This project provides a **one-command installer** to securely publish
websites and apps from a local Ubuntu machine using **Cloudflare Tunnel**.

No public IP.  
No open ports.  
No coding knowledge required.

---

## ✨ Features

- aaPanel for WordPress / PHP / MySQL
- Cloudflare Tunnel (Zero Trust, outbound-only)
- Domain → App → Port dashboard
- Protected / Public visibility
- Local monitoring GUI
- Manual “Test everything now” button
- Automatic health checks
- Auto-restart failed services
- Backups:
  - Local + Google Drive
  - 6-backup retention (3 daily + 1st & 15th for 3 months)

---

## 🖥️ Requirements

- Ubuntu 22.04
- Internet access
- Domain already added to Cloudflare
- No IPv4 required

---

## 🚀 Installation (ONE COMMAND)

```bash
curl -fsSL https://raw.githubusercontent.com/ejbiswas2-cloud/cf/main/install.sh | sudo bash


## 🚀 Fix

sudo pkill -9 apt || true
sudo pkill -9 apt-get || true
sudo pkill -9 dpkg || true

sudo rm -f /var/lib/apt/lists/lock
sudo rm -f /var/cache/apt/archives/lock
sudo rm -f /var/lib/dpkg/lock*
sudo rm -f /var/cache/apt/srcpkgcache.bin

sudo dpkg --configure -a
sudo apt clean
sudo apt update

## 🚀 Fix 
sudo apt install curl -y


