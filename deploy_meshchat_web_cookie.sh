set -e
ZIP=/root/MeshChat-Web-PWA-current.zip
WEB=/var/www/meshchat-web
BACKUP=/root/meshchat-web-backup-$(date +%Y%m%d-%H%M%S)
SECRET=$(openssl rand -hex 24)

mkdir -p /tmp/meshchat-web-new
rm -rf /tmp/meshchat-web-new/*
unzip -q -o "$ZIP" -d /tmp/meshchat-web-new

if [ -d "$WEB" ]; then
  cp -a "$WEB" "$BACKUP"
fi
mkdir -p "$WEB"
find "$WEB" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a /tmp/meshchat-web-new/. "$WEB"/
chown -R www-data:www-data "$WEB"
find "$WEB" -type d -exec chmod 755 {} \;
find "$WEB" -type f -exec chmod 644 {} \;

cp -a /etc/nginx/sites-available/meshchat-web /root/meshchat-web-nginx-backup-$(date +%Y%m%d-%H%M%S).conf
cat > /etc/nginx/sites-available/meshchat-web <<EOF
server {
    listen 80;
    server_name meshchat-losa.ru www.meshchat-losa.ru;
    return 301 https://meshchat-losa.ru\$request_uri;
}

server {
    listen 443 ssl;
    server_name meshchat-losa.ru www.meshchat-losa.ru;

    ssl_certificate /etc/letsencrypt/live/meshchat-losa.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meshchat-losa.ru/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/meshchat-web;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json application/octet-stream application/wasm font/ttf font/otf;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location = /unlock-$SECRET {
        add_header Set-Cookie "meshchat_access=$SECRET; Max-Age=31536000; Path=/; Secure; HttpOnly; SameSite=Lax" always;
        return 302 /;
    }

    location /ws {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600;
    }

    location = /meshpro {
        auth_basic off;
        return 308 /meshpro/;
    }

    location ^~ /meshpro/ {
        auth_basic off;
        proxy_pass http://127.0.0.1:8766;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 64k;
    }

    location ^~ /billing/manual/ {
        auth_basic off;
        access_log off;
        proxy_pass http://127.0.0.1:8766;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 64k;
    }

    location ^~ /billing/yookassa/ {
        auth_basic off;
        access_log off;
        proxy_pass http://127.0.0.1:8766;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 64k;
    }

    location = /billing/payment-complete {
        auth_basic off;
        proxy_pass http://127.0.0.1:8766;
        proxy_set_header Host \$host;
    }

    location / {
        if (\$cookie_meshchat_access != "$SECRET") {
            return 403;
        }
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

nginx -t
systemctl reload nginx

echo "UNLOCK_URL=https://meshchat-losa.ru/unlock-$SECRET"
echo "WEB_STATUS=$(curl -ks -o /dev/null -w '%{http_code}' https://meshchat-losa.ru/)"
echo "UNLOCK_STATUS=$(curl -ks -o /dev/null -w '%{http_code}' https://meshchat-losa.ru/unlock-$SECRET)"
echo "WS_STATIC_OK=$(test -f /var/www/meshchat-web/index.html && echo yes || echo no)"
