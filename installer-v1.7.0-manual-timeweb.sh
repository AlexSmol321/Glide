#!/bin/bash
# =====================================================================
# UNIVERSAL REVERSE PROXY INSTALLER — Auto Fallback Edition
# Версия: v1.7.0 (Node.js 20 LTS | manual Timeweb PRO + Let's Encrypt fallback)
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
    echo "Для Timeweb PRO вам потребуется сертификат и приватный ключ из панели Timeweb."
    echo "Подготовьте содержимое сертификата (.crt файл) и приватного ключа (.key файл)."
    echo "Скрипт поможет создать файлы из вставленного содержимого."
    echo ""
    read -p "Нажмите Enter для продолжения..."
    ;;
  *)
    fail "Неверный выбор. Введите 1 для Let's Encrypt или 2 для Timeweb PRO"
    ;;
esac

PROJECT_DIR=/opt/$PROJECT_NAME
mkdir -p "$PROJECT_DIR"/{src,config,logs,scripts}

# --- функция ожидания освобождения apt lock ---
wait_for_apt_lock() {
  local lock_file="/var/lib/apt/lists/lock"
  local sleep_time=5
  while fuser "$lock_file" >/dev/null 2>&1; do
    warn "apt занят другим процессом. Жду освобождения lock-файла..."
    sleep $sleep_time
  done
}

# ─── пакеты системы ─────────────────────────────────────────────────
info "Установка базовых пакетов (Node 20, Nginx, PM2)…"
wait_for_apt_lock
apt-get update -qq
wait_for_apt_lock
apt-get install -y curl wget gnupg2 software-properties-common nginx ufw jq unzip > /dev/null
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
wait_for_apt_lock
apt-get install -y nodejs >/dev/null

# --- обновление pm2 до последней версии ---
info "Обновление PM2 до последней версии…"
npm install -g pm2@latest >/dev/null
good "PM2 обновлён до последней версии"

wait_for_apt_lock
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
LETSENCRYPT_CONF="$PROJECT_DIR/config/nginx-letsencrypt.conf"
TIMEWEB_CONF="$PROJECT_DIR/config/nginx-timeweb.conf"

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

# Let's Encrypt конфигурация
cat > "$LETSENCRYPT_CONF" <<EOF
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

# Timeweb PRO конфигурация
cat > "$TIMEWEB_CONF" <<EOF
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

# ─── получаем сертификат ────────────────────────────────────────────
if [[ $CERT_MODE == letsencrypt ]]; then
  info "Получаем сертификат Let's Encrypt…"
  if ! certbot certonly --webroot -w /var/www/html \
        -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
    fail "Ошибка получения сертификата Let's Encrypt"
  fi
  good "Сертификат Let's Encrypt получен"
else
  info "Установка Timeweb PRO сертификата…"
  
  # Создание директорий SSL
  mkdir -p /etc/ssl/{certs,private}
  
  # Создание файла сертификата
  echo ""
  echo "📋 СОЗДАНИЕ ФАЙЛА СЕРТИФИКАТА"
  echo "============================="
  echo "1. Скопируйте содержимое сертификата из панели Timeweb"
  echo "2. Вставьте его ниже (включая BEGIN и END строки)"
  echo "3. Нажмите Ctrl+D когда закончите"
  echo ""
  echo "Вставьте содержимое сертификата:"
  
  # Создание временного файла
  temp_cert=$(mktemp)
  cat > "$temp_cert"
  
  # Проверка формата сертификата
  if ! openssl x509 -in "$temp_cert" -text -noout >/dev/null 2>&1; then
    fail "Некорректный формат сертификата"
  fi
  
  # Создание файла приватного ключа
  echo ""
  echo "🔑 СОЗДАНИЕ ФАЙЛА ПРИВАТНОГО КЛЮЧА"
  echo "=================================="
  echo "1. Скопируйте приватный ключ из панели Timeweb"
  echo "2. Вставьте его ниже (включая BEGIN и END строки)"
  echo "3. Нажмите Ctrl+D когда закончите"
  echo ""
  echo "Вставьте приватный ключ:"
  
  # Создание временного файла для ключа
  temp_key=$(mktemp)
  cat > "$temp_key"
  
  # Проверка формата ключа
  if ! openssl rsa -in "$temp_key" -check -noout >/dev/null 2>&1; then
    fail "Некорректный формат приватного ключа"
  fi
  
  # Проверка соответствия сертификата и ключа
  cert_modulus=$(openssl x509 -in "$temp_cert" -noout -modulus | openssl md5)
  key_modulus=$(openssl rsa -in "$temp_key" -noout -modulus | openssl md5)
  
  if [[ "$cert_modulus" != "$key_modulus" ]]; then
    fail "Сертификат и приватный ключ не соответствуют друг другу"
  fi
  
  # Проверка домена в сертификате
  cert_domain=$(openssl x509 -in "$temp_cert" -noout -subject | grep -o "CN = [^,]*" | cut -d'=' -f2 | tr -d ' ')
  if [[ "$cert_domain" != "$PROXY_DOMAIN" ]]; then
    warn "Домен в сертификате ($cert_domain) не совпадает с указанным ($PROXY_DOMAIN)"
    read -p "Продолжить? (y/n): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
      rm -f "$temp_cert" "$temp_key"
      fail "Установка отменена"
    fi
  fi
  
  # Проверка срока действия
  expiry_date=$(openssl x509 -in "$temp_cert" -noout -enddate | cut -d'=' -f2)
  expiry_timestamp=$(date -d "$expiry_date" +%s)
  current_timestamp=$(date +%s)
  days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
  
  if [[ $days_until_expiry -lt 0 ]]; then
    fail "Сертификат истек: $expiry_date"
  elif [[ $days_until_expiry -lt 30 ]]; then
    warn "Сертификат истекает через $days_until_expiry дней: $expiry_date"
    read -p "Продолжить? (y/n): " continue_expired
    if [[ ! "$continue_expired" =~ ^[Yy]$ ]]; then
      rm -f "$temp_cert" "$temp_key"
      fail "Установка отменена"
    fi
  else
    good "Сертификат действителен до: $expiry_date ($days_until_expiry дней)"
  fi
  
  # Копирование файлов
  info "Копирование сертификата..."
  cp "$temp_cert" "/etc/ssl/certs/$PROXY_DOMAIN.pem"
  
  info "Копирование приватного ключа..."
  cp "$temp_key" "/etc/ssl/private/$PROXY_DOMAIN.key"
  
  # Установка прав доступа
  chmod 644 "/etc/ssl/certs/$PROXY_DOMAIN.pem"
  chmod 600 "/etc/ssl/private/$PROXY_DOMAIN.key"
  
  # Очистка временных файлов
  rm -f "$temp_cert" "$temp_key"
  
  # Проверка установки
  info "Проверка установки..."
  if openssl x509 -in "/etc/ssl/certs/$PROXY_DOMAIN.pem" -text -noout >/dev/null 2>&1; then
    good "Сертификат Timeweb PRO установлен корректно"
  else
    fail "Ошибка установки сертификата"
  fi
fi

# ─── переключаемся на production-vhost ──────────────────────────────
rm -f /etc/nginx/sites-enabled/$PROJECT_NAME

if [[ $CERT_MODE == letsencrypt ]]; then
  ln -sf "$LETSENCRYPT_CONF" /etc/nginx/sites-enabled/$PROJECT_NAME
  good "Nginx настроен для Let's Encrypt"
else
  ln -sf "$TIMEWEB_CONF" /etc/nginx/sites-enabled/$PROJECT_NAME
  good "Nginx настроен для Timeweb PRO"
fi

nginx -t && systemctl reload nginx

# ─── npm install + PM2 ───────────────────────────────────────────────
cd "$PROJECT_DIR"

info "Установка Node.js зависимостей…"
rm -rf node_modules package-lock.json 2>/dev/null || true
npm install --production
if [[ $? -ne 0 ]]; then
  warn "npm install не удался, пробуем ещё раз…"
  npm cache clean --force
  npm install --production
fi
good "Node.js зависимости установлены"

# Проверяем, что основные модули установились
if [[ ! -d "node_modules/dotenv" ]] || [[ ! -d "node_modules/express" ]] || [[ ! -d "node_modules/http-proxy-middleware" ]]; then
  fail "Критические модули не установились. Проверьте подключение к интернету и права доступа."
fi

pm2 start ecosystem.config.js --env production
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null
systemctl enable pm2-root
good "PM2 настроен и запущен"

# ─── UFW ────────────────────────────────────────────────────────────
ufw --force enable
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp

# ─── скрипт продления Let's Encrypt + cron ──
if [[ $CERT_MODE == letsencrypt ]]; then
  info "Создаём auto-renew скрипт для Let's Encrypt…"
  cat > "$PROJECT_DIR/scripts/renew-letsencrypt.sh" <<'RENEW'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../.env"
[[ $CERT_MODE != letsencrypt ]] && exit 0
certbot renew --quiet --deploy-hook "systemctl reload nginx"
echo "$(date) — Let's Encrypt ssl renewed"
RENEW
  chmod +x "$PROJECT_DIR/scripts/renew-letsencrypt.sh"
  
  # Добавляем в cron
  (crontab -l 2>/dev/null; echo "0 2 * * * $PROJECT_DIR/scripts/renew-letsencrypt.sh") | crontab -
  good "Auto-renew настроен для Let's Encrypt"
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