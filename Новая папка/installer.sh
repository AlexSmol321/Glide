#!/bin/bash
# =====================================================================
# UNIVERSAL REVERSE PROXY INSTALLER — Minimal Stability Edition
# Версия: 1.6-unified  (Node.js 20 LTS | dual-cert LE/Timeweb | auto-renew)
# Автор  : Proxy Deployment System
#
# Версионная история:
# v1.6-unified (2024-12-19) - Исправления безопасности и стабильности
#   • Добавлена проверка валидности доменов
#   • Исправлена проблема с экранированием в nginx конфигах
#   • Улучшена обработка ошибок при получении сертификатов
#   • Добавлена проверка существования директорий SSL
#   • Исправлена проблема с правами доступа к файлам
#   • Добавлена проверка доступности целевого домена
# v1.5-unified (2024-12-18) - Базовая версия
#   • Node 20 LTS + PM2  ▪ Nginx SSL-termination
#   • X-Frame-Options: DENY        ▪ Разрешающий CSP для Glide
#   • CERT_MODE  = letsencrypt | timeweb
#   • Для Timeweb PRO ➜ автоматическая пролонгация через cron
#
# ▸ Что умеет
#   ▪ Node 20 LTS + PM2  ▪ Nginx SSL-termination
#   ▪ X-Frame-Options: DENY        ▪ Разрешающий CSP для Glide
#   ▪ CERT_MODE  = letsencrypt | timeweb
#   ▪ Для Timeweb PRO ➜ автоматическая пролонгация через cron
#
# ▸ Примеры запуска
#   # Бесплатный Let's Encrypt
#   sudo bash installer-v1.6-unified.sh
#
#   # Коммерческий сертификат Timeweb PRO
#   export CERT_MODE=timeweb
#   export TIMEWEB_TOKEN="twc_xxx…"          # API read-only ключ
#   export TIMEWEB_CERT_ID=123456
#   sudo bash installer-v1.6-unified.sh
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

# ─── функция проверки доступности домена ─────────────────────────────
check_domain_availability() {
  local domain=$1
  if ! nslookup "$domain" >/dev/null 2>&1; then
    warn "Домен $domain недоступен в DNS. Убедитесь, что A-запись настроена."
  fi
}

# ─── функция чтения переменной с дефолтом ────────────────────────────
read_var(){ local v=$1 prompt=$2 def=$3 silent=${4:-0}
  [[ -n "${!v:-}" ]] && return
  if (( silent )); then
      read -s -p "$prompt" $v && echo
  else
      read -p "$prompt" $v
  fi
  [[ -z "${!v}" ]] && eval "$v=$def"
}

# ─── ввод параметров ─────────────────────────────────────────────────
read_var PROXY_DOMAIN   "Proxy-домен                : " ""
read_var TARGET_DOMAIN  "Целевой домен (Glide)      : " ""
read_var SSL_EMAIL      "Email для Let's Encrypt    : " ""
read_var PROJECT_NAME   "Имя проекта     [my-proxy] : " "my-proxy"
read_var NODE_PORT      "Порт Node.js    [3000]     : " "3000"
read_var MAX_MEMORY     "PM2 max memory  [512M]     : " "512M"

# Валидация доменов
validate_domain "$PROXY_DOMAIN"
validate_domain "$TARGET_DOMAIN"
check_domain_availability "$PROXY_DOMAIN"

CERT_MODE=${CERT_MODE:-letsencrypt}
if [[ $CERT_MODE == "timeweb" ]]; then
  read_var TIMEWEB_TOKEN    "Timeweb API-token (скрытый ввод): " "" 1
  read_var TIMEWEB_CERT_ID  "ID заказа сертификата            : " ""
  [[ -z "$TIMEWEB_TOKEN" || -z "$TIMEWEB_CERT_ID" ]] && fail "Необходимы TIMEWEB_TOKEN и TIMEWEB_CERT_ID для режима timeweb"
fi

PROJECT_DIR=/opt/$PROJECT_NAME
mkdir -p "$PROJECT_DIR"/{src,config,logs,scripts}

# ─── пакеты системы ─────────────────────────────────────────────────
info "Установка базовых пакетов (Node 20, Nginx, PM2)…"
apt-get update -qq
apt-get install -y curl wget gnupg2 software-properties-common nginx ufw jq unzip > /dev/null
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
apt-get install -y nodejs >/dev/null
npm install -g pm2 >/dev/null
if [[ $CERT_MODE == letsencrypt ]]; then
  apt-get install -y certbot python3-certbot-nginx >/dev/null
fi
good "Установлено"

# ─── .env ────────────────────────────────────────────────────────────
cat > "$PROJECT_DIR/.env" <<EOF
NODE_ENV=production
PORT=$NODE_PORT
PROXY_DOMAIN=$PROXY_DOMAIN
TARGET_DOMAIN=$TARGET_DOMAIN
TARGET_PROTOCOL=https

CERT_MODE=$CERT_MODE
TIMEWEB_TOKEN=${TIMEWEB_TOKEN:-}
TIMEWEB_CERT_ID=${TIMEWEB_CERT_ID:-}
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

console.log('Minimal proxy (Node 20) →', TARGET);

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

  ssl_certificate     /etc/ssl/certs/$PROXY_DOMAIN.pem;
  ssl_certificate_key /etc/ssl/private/$PROXY_DOMAIN.key;
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

# ─── создаем SSL директории если не существуют ──────────────────────
mkdir -p /etc/ssl/{certs,private}

# ─── получаем сертификат ────────────────────────────────────────────
if [[ $CERT_MODE == letsencrypt ]]; then
  info "Получаем сертификат Let's Encrypt…"
  if ! certbot certonly --webroot -w /var/www/html \
        -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
    fail "Ошибка получения сертификата Let's Encrypt"
  fi
  cp /etc/letsencrypt/live/$PROXY_DOMAIN/fullchain.pem /etc/ssl/certs/$PROXY_DOMAIN.pem
  cp /etc/letsencrypt/live/$PROXY_DOMAIN/privkey.pem   /etc/ssl/private/$PROXY_DOMAIN.key
else
  info "Скачиваем Timeweb PRO сертификат…"
  api="https://api.timeweb.cloud/api/v2"
  hdr=(-H "Authorization: Bearer $TIMEWEB_TOKEN" -H "Accept: application/zip")
  tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
  if ! curl -sf "${hdr[@]}" "$api/ssl-certificates/$TIMEWEB_CERT_ID/download" -o "$tmp/c.zip"; then
    fail "Ошибка скачивания сертификата Timeweb"
  fi
  if ! unzip -qo "$tmp/c.zip" -d "$tmp"; then
    fail "Ошибка распаковки сертификата Timeweb"
  fi
  cat "$tmp/certificate.crt" "$tmp/ca_bundle.crt" > /etc/ssl/certs/$PROXY_DOMAIN.pem
  mv  "$tmp/private.key" /etc/ssl/private/$PROXY_DOMAIN.key
  chmod 600 /etc/ssl/private/$PROXY_DOMAIN.key
fi
chmod 644 /etc/ssl/certs/$PROXY_DOMAIN.pem

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

# ─── UFW ────────────────────────────────────────────────────────────
ufw --force enable
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp

# ─── скрипт продления Timeweb + cron ────────────────────────────────
if [[ $CERT_MODE == timeweb ]]; then
  info "Создаём auto-renew скрипт для Timeweb…"
  cat > "$PROJECT_DIR/scripts/renew-timeweb.sh" <<'RENEW'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../.env"
[[ $CERT_MODE != timeweb ]] && exit 0
threshold=25
domain=$PROXY_DOMAIN
remain=$(( ( $(date -d "$(openssl x509 -noout -enddate -in /etc/ssl/certs/$domain.pem | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
(( remain > threshold )) && exit 0

api="https://api.timeweb.cloud/api/v2"
auth=(-H "Authorization: Bearer $TIMEWEB_TOKEN")

curl -sf "${auth[@]}" -H "Content-Type: application/json" -X POST \
     "$api/ssl-certificates/$TIMEWEB_CERT_ID/renew" -d '{}' >/dev/null

for i in {1..12}; do
  status=$(curl -sf "${auth[@]}" "$api/ssl-certificates/$TIMEWEB_CERT_ID" | jq -r .status)
  [[ $status == issued ]] && break
  sleep 60
done

tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
curl -sf "${auth[@]}" -H "Accept: application/zip" \
     "$api/ssl-certificates/$TIMEWEB_CERT_ID/download" -o "$tmp/c.zip"
unzip -qo "$tmp/c.zip" -d "$tmp"

cat "$tmp"/certificate.crt "$tmp"/ca_bundle.crt > /etc/ssl/certs/$domain.pem
cp  "$tmp"/private.key /etc/ssl/private/$domain.key
chmod 600 /etc/ssl/private/$domain.key
systemctl reload nginx
echo "$(date) — Timeweb ssl renewed"
RENEW

  chmod 700 "$PROJECT_DIR/scripts/renew-timeweb.sh"
  echo "0 4 4 * * root $PROJECT_DIR/scripts/renew-timeweb.sh >> /var/log/timeweb-renew.log 2>&1" \
      > /etc/cron.d/timeweb-renew
  good "Cron-renew для Timeweb настроен"
fi

good "Установка завершена → https://$PROXY_DOMAIN/"
