
#!/bin/bash
set -e

DOMAIN="synxiel.com"
WEBROOT="/www/wwwroot/$DOMAIN"
NGINX_CONF="/etc/nginx/conf.d/$DOMAIN.conf"

echo "======================================="
echo " 🔧 Fixing website for $DOMAIN"
echo "======================================="

# 1. Ensure nginx exists
if ! command -v nginx >/dev/null; then
  echo "❌ Nginx not installed. Install it first via aaPanel."
  exit 1
fi

# 2. Create web root
echo "📁 Ensuring web root exists..."
mkdir -p "$WEBROOT"

# 3. Create index.html
echo "📝 Creating index.html..."
cat > "$WEBROOT/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>$DOMAIN</title>
</head>
<body>
  <h1>✅ $DOMAIN is LIVE</h1>
  <p>Cloudflare Tunnel + Nginx working correctly</p>
</body>
</html>
EOF

# 4. Fix permissions
echo "🔐 Fixing permissions..."
chown -R www:www "$WEBROOT"
chmod -R 755 "$WEBROOT"

# 5. Create nginx vhost if missing
if [ ! -f "$NGINX_CONF" ]; then
  echo "🌐 Creating nginx vhost..."
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root $WEBROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.well-known {
        allow all;
    }
}
EOF
else
  echo "ℹ️ Nginx vhost already exists"
fi

# 6. Test nginx config
echo "🧪 Testing nginx configuration..."
nginx -t

# 7. Reload nginx
echo "🔄 Reloading nginx..."
systemctl reload nginx

# 8. Local test
echo "🧪 Testing locally..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1)

if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ Local nginx test OK (HTTP 200)"
else
  echo "❌ Local nginx test failed (HTTP $HTTP_CODE)"
  exit 1
fi

# 9. Final message
echo "======================================="
echo " 🎉 DONE!"
echo " 🌍 Open: https://$DOMAIN"
echo "======================================="
