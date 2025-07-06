#!/bin/bash
# =====================================================================
# UNIVERSAL REVERSE PROXY INSTALLER — Auto Fallback Edition
# Версия: auto-fallback-1.0 (Node.js 20 LTS | auto-fallback LE/Timeweb)
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
  local silent=${4:-0}
  
  # Если переменная уже установлена, используем её
  if [[ -n "${!var_name:-}" ]]; then
    return
  fi
  
  # Читаем значение от пользователя
  if (( silent )); then
    read -s -p "$prompt" value && echo
  else
    read -p "$prompt" value
  fi
  
  # Если значение пустое, используем дефолт
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  
  # Устанавливаем переменную
  eval "$var_name=\"$value\""
}

# ─── ввод параметров ─────────────────────────────────────────────────
echo "🚀 UNIVERSAL REVERSE PROXY INSTALLER"
echo "   Автоматический fallback на Let's Encrypt"
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

# ─── выбор режима сертификации ───────────────────────────────────────
echo ""
echo "🔐 ВЫБОР РЕЖИМА SSL-СЕРТИФИКАЦИИ"
echo "1) Let's Encrypt (бесплатно, автоматическое продление)"
echo "2) Timeweb PRO (коммерческий, с автоматическим fallback на LE)"
echo ""
read_var CERT_CHOICE "Введите номер (1 или 2): " ""

case $CERT_CHOICE in
  1)
    CERT_MODE=letsencrypt
    good "Выбран режим: Let's Encrypt"
    ;;
  2)
    CERT_MODE=timeweb
    good "Выбран режим: Timeweb PRO (с fallback на Let's Encrypt)"
    info "Для Timeweb PRO вам потребуется:"
    echo "  • API токен (создается в панели Timeweb)"
    echo "  • ID сертификата (указывается в заказе SSL)"
    echo ""
    echo "📋 ПОДРОБНАЯ ИНСТРУКЦИЯ ПО ПОЛУЧЕНИЮ ID СЕРТИФИКАТА:"
    echo ""
    echo "1️⃣ Создание API токена:"
    echo "   • Зайдите в панель Timeweb → Настройки → API"
    echo "   • Нажмите 'Создать токен'"
    echo "   • Выберите права: 'Чтение' для SSL-сертификатов"
    echo "   • Скопируйте токен (поддерживаются форматы):"
    echo "     - JWT токены (начинаются с 'eyJ')"
    echo "     - Стандартные токены (twc_, tw_, timeweb_)"
    echo "     - Любые другие форматы"
    echo ""
    echo "2️⃣ Получение ID сертификата:"
    echo "   • Зайдите в панель Timeweb → SSL-сертификаты"
    echo "   • Найдите ваш заказ в списке"
    echo "   • Нажмите на заказ для просмотра деталей"
    echo "   • ID сертификата - это число в URL или в деталях заказа"
    echo "   • Пример: если URL содержит 'ssl-certificates/12345', то ID = 12345"
    echo ""
    echo "💡 Если у вас еще нет сертификата:"
    echo "   • Закажите SSL-сертификат в Timeweb"
    echo "   • Дождитесь выдачи сертификата"
    echo "   • Затем получите его ID по инструкции выше"
    echo ""
    read_var TIMEWEB_TOKEN    "Timeweb API-token (скрытый ввод): " "" 1
    read_var TIMEWEB_CERT_ID  "ID заказа сертификата            : " ""
    
    # Проверка и валидация введенных данных
    if [[ -z "$TIMEWEB_TOKEN" || -z "$TIMEWEB_CERT_ID" ]]; then
      warn "Не указаны токен или ID сертификата"
      info "Переключаемся на Let's Encrypt..."
      CERT_MODE=letsencrypt
    else
      # Проверка формата токена
      if [[ "$TIMEWEB_TOKEN" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        good "Обнаружен JWT токен Timeweb"
        info "JWT токены поддерживаются"
      elif [[ "$TIMEWEB_TOKEN" =~ ^(twc_|tw_|timeweb_)[a-zA-Z0-9_-]+$ ]]; then
        good "Обнаружен стандартный API токен"
      else
        warn "Нестандартный формат токена"
        warn "Текущий токен: ${TIMEWEB_TOKEN:0:20}..."
        info "Продолжаем установку..."
      fi
      
      # Проверка формата ID
      if [[ ! "$TIMEWEB_CERT_ID" =~ ^[0-9]+$ ]]; then
        warn "ID сертификата должен быть числом"
        warn "Пример правильного ID: 12345"
        info "Переключаемся на Let's Encrypt..."
        CERT_MODE=letsencrypt
      fi
    fi
    ;;
  *)
    fail "Неверный выбор. Введите 1 для Let's Encrypt или 2 для Timeweb PRO"
    ;;
esac

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

console.log('Auto-fallback proxy (Node 20) →', TARGET);

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

# ─── получаем сертификат ────────────────────────────────────────────
if [[ $CERT_MODE == letsencrypt ]]; then
  info "Получаем сертификат Let's Encrypt…"
  if ! certbot certonly --webroot -w /var/www/html \
        -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
    fail "Ошибка получения сертификата Let's Encrypt"
  fi
  good "Сертификат Let's Encrypt получен"
else
  info "Пробуем скачать Timeweb PRO сертификат…"
  
  # Быстрая проверка API
  api_working=false
  if curl -sf --connect-timeout 5 --max-time 10 \
     -H "Authorization: Bearer $TIMEWEB_TOKEN" \
     "https://api.timeweb.cloud/api/v1/ssl-certificates" >/dev/null 2>&1; then
    api_working=true
  fi
  
  if [[ "$api_working" == true ]]; then
    # Пробуем скачать сертификат
    api="https://api.timeweb.cloud/api/v1"
    hdr=(-H "Authorization: Bearer $TIMEWEB_TOKEN" -H "Accept: application/zip")
    tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
    
    if curl -sf --connect-timeout 15 --max-time 60 "${hdr[@]}" \
       "$api/ssl-certificates/$TIMEWEB_CERT_ID/download" -o "$tmp/c.zip"; then
      
      if unzip -qo "$tmp/c.zip" -d "$tmp"; then
        # Проверяем наличие файлов
        if [[ -f "$tmp/certificate.crt" ]] && [[ -f "$tmp/private.key" ]]; then
          # Стандартная структура
          if [[ -f "$tmp/ca_bundle.crt" ]]; then
            cat "$tmp/certificate.crt" "$tmp/ca_bundle.crt" > /etc/ssl/certs/$PROXY_DOMAIN.pem
          else
            cat "$tmp/certificate.crt" > /etc/ssl/certs/$PROXY_DOMAIN.pem
          fi
          cp "$tmp/private.key" /etc/ssl/private/$PROXY_DOMAIN.key
          chmod 600 /etc/ssl/private/$PROXY_DOMAIN.key
          chmod 644 /etc/ssl/certs/$PROXY_DOMAIN.pem
          good "Сертификат Timeweb PRO установлен"
        else
          warn "Нестандартная структура архива Timeweb"
          info "Переключаемся на Let's Encrypt..."
          CERT_MODE=letsencrypt
          # Получаем Let's Encrypt сертификат
          if ! certbot certonly --webroot -w /var/www/html \
                -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
            fail "Ошибка получения сертификата Let's Encrypt"
          fi
          good "Сертификат Let's Encrypt получен (fallback)"
        fi
      else
        warn "Ошибка распаковки сертификата Timeweb"
        info "Переключаемся на Let's Encrypt..."
        CERT_MODE=letsencrypt
        # Получаем Let's Encrypt сертификат
        if ! certbot certonly --webroot -w /var/www/html \
              -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
          fail "Ошибка получения сертификата Let's Encrypt"
        fi
        good "Сертификат Let's Encrypt получен (fallback)"
      fi
    else
      warn "Не удалось скачать сертификат Timeweb"
      info "Переключаемся на Let's Encrypt..."
      CERT_MODE=letsencrypt
      # Получаем Let's Encrypt сертификат
      if ! certbot certonly --webroot -w /var/www/html \
            -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
        fail "Ошибка получения сертификата Let's Encrypt"
      fi
      good "Сертификат Let's Encrypt получен (fallback)"
    fi
  else
    warn "API Timeweb недоступен"
    info "Автоматически переключаемся на Let's Encrypt..."
    CERT_MODE=letsencrypt
    # Получаем Let's Encrypt сертификат
    if ! certbot certonly --webroot -w /var/www/html \
          -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
      fail "Ошибка получения сертификата Let's Encrypt"
    fi
    good "Сертификат Let's Encrypt получен (fallback)"
  fi
fi

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

# ─── скрипт продления Timeweb + cron (только если Timeweb работает) ──
if [[ $CERT_MODE == timeweb ]] && [[ "$api_working" == true ]]; then
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

api="https://api.timeweb.cloud/api/v1"
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
echo ""
echo "📋 ИТОГОВАЯ ИНФОРМАЦИЯ:"
echo "   • Режим сертификации: $CERT_MODE"
echo "   • Proxy домен: $PROXY_DOMAIN"
echo "   • Целевой домен: $TARGET_DOMAIN"
echo "   • Порт Node.js: $NODE_PORT"
echo "   • PM2 процесс: $PROJECT_NAME"
echo ""
echo "🔧 ПОЛЕЗНЫЕ КОМАНДЫ:"
echo "   • Статус: pm2 status"
echo "   • Логи: pm2 logs $PROJECT_NAME"
echo "   • Перезапуск: pm2 restart $PROJECT_NAME"
echo "   • Health check: curl https://$PROXY_DOMAIN/health" 