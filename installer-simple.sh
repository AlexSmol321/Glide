#!/bin/bash
# =====================================================================
# УПРОЩЕННЫЙ REVERSE PROXY INSTALLER
# Версия: simple-1.0 (Node.js 20 LTS | Let's Encrypt только)
# Автор  : Proxy Deployment System
# =====================================================================
set -euo pipefail

# ─── цветовая палитра ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
good(){ echo -e "${GREEN}[ OK ]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
fail(){ echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Запустите скрипт через sudo"

# ─── функция валидации домена ────────────────────────────────────────
validate_domain() {
  local domain=$1
  if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    fail "Некорректный домен: $domain"
  fi
}

# ─── функция чтения переменной с дефолтом ────────────────────────────
read_var() {
  local var_name=$1
  local prompt=$2
  local default=$3
  
  # Если переменная уже установлена, используем её
  if [[ -n "${!var_name:-}" ]]; then
    return
  fi
  
  # Читаем значение от пользователя
  read -p "$prompt" value
  
  # Если значение пустое, используем дефолт
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  
  # Устанавливаем переменную
  eval "$var_name=\"$value\""
}

# ─── ввод параметров ─────────────────────────────────────────────────
echo "🚀 УПРОЩЕННЫЙ УСТАНОВЩИК REVERSE PROXY"
echo "   Использует только Let's Encrypt (бесплатно)"
echo ""

read_var PROXY_DOMAIN   "Proxy-домен                : " ""
read_var TARGET_DOMAIN  "Целевой домен (Glide)      : " ""
read_var SSL_EMAIL      "Email для Let's Encrypt    : " ""
read_var PROJECT_NAME   "Имя проекта     [my-proxy] : " "my-proxy"
read_var NODE_PORT      "Порт Node.js    [3000]     : " "3000"
read_var MAX_MEMORY     "PM2 max memory  [512M]     : " "512M"

# Валидация доменов
validate_domain "$PROXY_DOMAIN"
validate_domain "$TARGET_DOMAIN"

PROJECT_DIR=/opt/$PROJECT_NAME
mkdir -p "$PROJECT_DIR"/{src,config,logs,scripts}

# ─── пакеты системы ─────────────────────────────────────────────────
info "Установка базовых пакетов (Node 20, Nginx, PM2)…"
apt-get update -qq
apt-get install -y curl wget gnupg2 software-properties-common nginx ufw jq unzip > /dev/null
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
apt-get install -y nodejs >/dev/null
npm install -g pm2 >/dev/null
apt-get install -y certbot python3-certbot-nginx >/dev/null
good "Установлено"

# ─── .env ────────────────────────────────────────────────────────────
cat > "$PROJECT_DIR/.env" <<EOF
NODE_ENV=production
PORT=$NODE_PORT
PROXY_DOMAIN=$PROXY_DOMAIN
TARGET_DOMAIN=$TARGET_DOMAIN
TARGET_PROTOCOL=https
CERT_MODE=letsencrypt
EOF
chmod 600 "$PROJECT_DIR/.env"

# ─── package.json ───────────────────────────────────────────────────
cat > "$PROJECT_DIR/package.json" <<EOF
{
  "name": "$PROJECT_NAME",
  "version": "1.0.0",
  "main": "src/app.js",
  "dependencies": {
    "dotenv": "^16.3.1",
    "express": "^4.18.2",
    "http-proxy-middleware": "^2.0.6"
  }
}
EOF

# ─── src/app.js ─────────────────────────────────────────────────────
cat > "$PROJECT_DIR/src/app.js" <<'JS'
require('dotenv').config();
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app   = express();
const PORT  = process.env.PORT || 3000;
const TARGET= `${process.env.TARGET_PROTOCOL || 'https'}://${process.env.TARGET_DOMAIN}`;

console.log('Simple proxy (Node 20) →', TARGET);

app.get('/health',          (_req,res)=>res.json({status:'ok'}));
app.get('/health/detailed', (_req,res)=>res.json({
  status:'ok', target:TARGET, uptime:process.uptime()
}));

app.use('/', createProxyMiddleware({
  target: TARGET,
  changeOrigin: true,
  secure: true,
  onProxyRes(proxyRes) {
    delete proxyRes.headers['content-security-policy'];
    proxyRes.headers['x-frame-options']                  = 'DENY';
    proxyRes.headers['access-control-allow-origin']      = '*';
    proxyRes.headers['access-control-allow-methods']     = 'GET, POST, PUT, DELETE, OPTIONS, PATCH';
    proxyRes.headers['access-control-allow-headers']     = 'Content-Type, Authorization, X-Requested-With, Accept';
    proxyRes.headers['access-control-allow-credentials'] = 'true';
    proxyRes.headers['content-security-policy'] =
      "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:;";
  },
  onError(err, _req, res) {
    console.error('Proxy error:', err.message);
    if (!res.headersSent) res.status(502).send('Bad Gateway');
  }
}));

app.listen(PORT, ()=>console.log('Listening on', PORT));
['SIGINT','SIGTERM'].forEach(sig=>process.on(sig,()=>process.exit(0)));
JS

# ─── ecosystem.config.js ────────────────────────────────────────────
cat > "$PROJECT_DIR/ecosystem.config.js" <<EOF
module.exports = { apps:[{
  name:'$PROJECT_NAME',
  script:'src/app.js',
  instances:1,
  exec_mode:'fork',
  max_memory_restart:'$MAX_MEMORY',
  env_production:{ NODE_ENV:'production', PORT:$NODE_PORT },
  cron_restart:'0 3 * * *'
}]};
EOF

# ─── nginx конфиги ──────────────────────────────────────────────────
ACME_CONF="$PROJECT_DIR/config/nginx-acme.conf"
PROD_CONF="$PROJECT_DIR/config/nginx-proxy.conf"

# HTTP-vhost только для ACME
cat > "$ACME_CONF" <<EOF
server {
    listen 80;
    server_name $PROXY_DOMAIN;
    root /var/www/html;
    location / { return 200 "ACME host"; }
    location /.well-known/acme-challenge/ { root /var/www/html; }
}
EOF

# Production vhost (80 redirect → 443)
cat > "$PROD_CONF" <<EOF
upstream ${PROJECT_NAME}_up { server 127.0.0.1:$NODE_PORT; keepalive 16; }

server { 
  listen 80; 
  server_name $PROXY_DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/html; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name $PROXY_DOMAIN;

  ssl_certificate     /etc/letsencrypt/live/$PROXY_DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$PROXY_DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;

  add_header X-Frame-Options DENY always;
  add_header Content-Security-Policy "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:;" always;

  location / {
    proxy_pass http://${PROJECT_NAME}_up;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

# ─── включаем ACME-vhost, nginx стартует без SSL ────────────────────
ln -sf "$ACME_CONF" /etc/nginx/sites-enabled/$PROJECT_NAME
nginx -t && systemctl reload nginx

mkdir -p /var/www/html

# ─── получаем сертификат Let's Encrypt ──────────────────────────────
info "Получаем сертификат Let's Encrypt…"
if ! certbot certonly --webroot -w /var/www/html \
      -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
  fail "Ошибка получения сертификата Let's Encrypt"
fi
good "Сертификат получен"

# ─── переключаемся на production-vhost ──────────────────────────────
rm -f /etc/nginx/sites-enabled/$PROJECT_NAME
ln -sf "$PROD_CONF" /etc/nginx/sites-enabled/$PROJECT_NAME
nginx -t && systemctl reload nginx
good "Nginx настроен"

# ─── npm install + PM2 ───────────────────────────────────────────────
cd "$PROJECT_DIR"
npm ci --production -s
pm2 start ecosystem.config.js --env production
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null
systemctl enable pm2-root
good "PM2 настроен и запущен"

# ─── UFW ────────────────────────────────────────────────────────────
ufw --force enable
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp

good "Установка завершена → https://$PROXY_DOMAIN/" 