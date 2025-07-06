#!/bin/bash
# =====================================================================
# UNIVERSAL REVERSE PROXY INSTALLER — Minimal Stability Edition
# Версия: 1.6.8-unified  (Node.js 20 LTS | dual-cert LE/Timeweb | auto-renew)
# Автор  : Proxy Deployment System
#
# Версионная история:
# v1.6.8-unified (2024-12-19) - Расширенная диагностика и fallback на Let's Encrypt
#   • Добавлена подробная диагностика HTTP кодов ответа
#   • Расширен список API endpoints и базовых URL
#   • Добавлен fallback на Let's Encrypt при ошибках Timeweb API
#   • Улучшена обработка ошибок с альтернативными вариантами
# v1.6.7-unified (2024-12-19) - Поддержка JWT токенов Timeweb
#   • Добавлена поддержка JWT токенов (eyJ...)
#   • Расширен список API endpoints для тестирования
#   • Улучшена диагностика подключения к API
#   • Добавлены множественные endpoints для скачивания сертификатов
# v1.6.6-unified (2024-12-19) - Улучшенная поддержка Timeweb токенов
#   • Добавлена поддержка разных форматов API токенов (twc_, tw_, timeweb_)
#   • Улучшена диагностика скачивания сертификатов
#   • Добавлена проверка структуры архива сертификата
#   • Улучшена обработка ошибок API
# v1.6.5-unified (2024-12-19) - Исправление API endpoints Timeweb
#   • Исправлен API endpoint с /api/v2 на /api/v1
#   • Добавлена поддержка альтернативных API endpoints
#   • Улучшена диагностика проблем с API
#   • Добавлены предупреждения о возможных изменениях API
# v1.6.4-unified (2024-12-19) - Улучшенная поддержка Timeweb PRO
#   • Добавлена подробная пошаговая инструкция по получению ID сертификата
#   • Добавлена валидация формата API токена и ID сертификата
#   • Добавлена проверка подключения к Timeweb API
#   • Улучшены подсказки и сообщения об ошибках
# v1.6.3-unified (2024-12-19) - Улучшенный выбор режима сертификации
#   • Добавлен обязательный выбор режима SSL (Let's Encrypt / Timeweb PRO)
#   • Добавлена подробная инструкция по получению ID сертификата Timeweb
#   • Улучшен пользовательский интерфейс установки
#   • Добавлена валидация выбора режима
# v1.6.2-unified (2024-12-19) - Исправление установки зависимостей
#   • Исправлена проблема с установкой npm зависимостей
#   • Добавлена проверка установки критических модулей
#   • Улучшена диагностика PM2 запуска
#   • Добавлена автоматическая перезагрузка при сбоях
# v1.6.1-unified (2024-12-19) - Исправление функции read_var
#   • Исправлена ошибка в функции read_var, которая вызывала вылет скрипта
#   • Улучшена обработка ввода пользователя
#   • Добавлена дополнительная отладка
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
#   sudo bash installer-v1.6.8-unified.sh
#
#   # Коммерческий сертификат Timeweb PRO
#   export CERT_MODE=timeweb
#   export TIMEWEB_TOKEN="twc_xxx…"          # API read-only ключ
#   export TIMEWEB_CERT_ID=123456
#   sudo bash installer-v1.6.8-unified.sh
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

# ─── выбор режима сертификации ────────────────────────────────────────
info "Выберите режим SSL-сертификации:"
echo "1) Let's Encrypt (бесплатно, автоматическое продление)"
echo "2) Timeweb PRO (коммерческий, с автоматическим продлением)"
echo ""
read_var CERT_CHOICE "Введите номер (1 или 2): " ""

case $CERT_CHOICE in
  1)
    CERT_MODE=letsencrypt
    good "Выбран режим: Let's Encrypt"
    ;;
  2)
    CERT_MODE=timeweb
    good "Выбран режим: Timeweb PRO"
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
      fail "Необходимы TIMEWEB_TOKEN и TIMEWEB_CERT_ID для режима timeweb"
    fi
    
    # Проверка формата токена (поддержка разных форматов)
    if [[ "$TIMEWEB_TOKEN" =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
      good "Обнаружен JWT токен Timeweb"
      info "JWT токены поддерживаются"
    elif [[ "$TIMEWEB_TOKEN" =~ ^(twc_|tw_|timeweb_)[a-zA-Z0-9_-]+$ ]]; then
      good "Обнаружен стандартный API токен"
    else
      warn "Нестандартный формат токена"
      warn "Текущий токен: ${TIMEWEB_TOKEN:0:20}..."
      warn "Проверьте правильность токена в панели Timeweb"
      info "Продолжаем установку, но могут быть проблемы с API..."
    fi
    
    # Проверка формата ID
    if [[ ! "$TIMEWEB_CERT_ID" =~ ^[0-9]+$ ]]; then
      warn "ID сертификата должен быть числом"
      warn "Пример правильного ID: 12345"
    fi
    
    info "Проверка подключения к Timeweb API..."
    # Тестовая проверка API с подробной диагностикой
    api_endpoints=(
      "https://api.timeweb.cloud/api/v1/ssl-certificates"
      "https://api.timeweb.cloud/api/v1/ssl"
      "https://api.timeweb.cloud/api/v2/ssl-certificates"
      "https://api.timeweb.cloud/ssl-certificates"
      "https://api.timeweb.cloud/api/v1/certificates"
      "https://api.timeweb.cloud/certificates"
    )
    
    success=false
    for endpoint in "${api_endpoints[@]}"; do
      info "Тестируем endpoint: $endpoint"
      response=$(curl -sf -w "%{http_code}" -H "Authorization: Bearer $TIMEWEB_TOKEN" "$endpoint" 2>/dev/null)
      http_code="${response: -3}"
      
      if [[ "$http_code" == "200" ]]; then
        good "API токен работает с: $endpoint"
        success=true
        break
      elif [[ "$http_code" == "401" ]]; then
        warn "Ошибка авторизации (401) для: $endpoint"
      elif [[ "$http_code" == "403" ]]; then
        warn "Доступ запрещен (403) для: $endpoint"
      elif [[ "$http_code" == "404" ]]; then
        warn "Endpoint не найден (404) для: $endpoint"
      else
        warn "HTTP код $http_code для: $endpoint"
      fi
    done
    
    if [[ "$success" == false ]]; then
      warn "Не удалось подключиться к Timeweb API"
      warn "Проверьте правильность токена и подключение к интернету"
      warn "Возможно, API endpoint изменился. Проверьте документацию Timeweb."
      info "Продолжаем установку, попробуем скачать сертификат напрямую..."
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
  
  # Попробуем разные базовые URL для API
  api_urls=(
    "https://api.timeweb.cloud/api/v1"
    "https://api.timeweb.cloud/api/v2"
    "https://api.timeweb.cloud"
    "https://api.timeweb.com/api/v1"
    "https://api.timeweb.com"
  )
  
  api="https://api.timeweb.cloud/api/v1"  # По умолчанию
  hdr=(-H "Authorization: Bearer $TIMEWEB_TOKEN" -H "Accept: application/zip")
  tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
  
  info "Проверяем доступность сертификата ID: $TIMEWEB_CERT_ID"
  
  # Сначала проверим статус сертификата
  if ! curl -sf -H "Authorization: Bearer $TIMEWEB_TOKEN" "$api/ssl-certificates/$TIMEWEB_CERT_ID" >/dev/null 2>&1; then
    warn "Не удалось получить информацию о сертификате ID: $TIMEWEB_CERT_ID"
    warn "Проверьте правильность ID сертификата"
    warn "Попробуем скачать напрямую..."
  else
    good "Сертификат найден в API"
  fi
  
  # Пробуем скачать сертификат
  info "Скачиваем сертификат..."
  
  # Список возможных endpoints для попытки
  endpoints=(
    "$api/ssl-certificates/$TIMEWEB_CERT_ID/download"
    "$api/ssl/$TIMEWEB_CERT_ID/download"
    "https://api.timeweb.cloud/api/v2/ssl-certificates/$TIMEWEB_CERT_ID/download"
    "https://api.timeweb.cloud/ssl-certificates/$TIMEWEB_CERT_ID/download"
    "https://api.timeweb.cloud/api/v1/certificates/$TIMEWEB_CERT_ID/download"
    "https://api.timeweb.cloud/certificates/$TIMEWEB_CERT_ID/download"
    "https://api.timeweb.cloud/api/v1/ssl-certificates/$TIMEWEB_CERT_ID"
    "https://api.timeweb.cloud/api/v1/ssl/$TIMEWEB_CERT_ID"
  )
  
  success=false
  for endpoint in "${endpoints[@]}"; do
    info "Пробуем endpoint: $endpoint"
    if curl -sf "${hdr[@]}" "$endpoint" -o "$tmp/c.zip"; then
      good "Сертификат успешно скачан с: $endpoint"
      success=true
      break
    else
      warn "Не удалось скачать с: $endpoint"
    fi
  done
  
  if [[ "$success" == false ]]; then
    warn "Не удалось скачать сертификат через API"
    warn "Возможные причины:"
    warn "  • Неправильный API endpoint"
    warn "  • Недостаточно прав у токена"
    warn "  • Сертификат еще не выдан"
    warn "  • API Timeweb изменился"
    echo ""
    info "Альтернативные варианты:"
    echo "1. Скачайте сертификат вручную из панели Timeweb"
    echo "2. Используйте Let's Encrypt (бесплатно)"
    echo "3. Обратитесь в поддержку Timeweb"
    echo ""
    read -p "Хотите продолжить с Let's Encrypt? (y/n): " use_letsencrypt
    if [[ "$use_letsencrypt" =~ ^[Yy]$ ]]; then
      info "Переключаемся на Let's Encrypt..."
      CERT_MODE=letsencrypt
      # Повторяем установку Let's Encrypt
      info "Получаем сертификат Let's Encrypt…"
      if ! certbot certonly --webroot -w /var/www/html \
            -d "$PROXY_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive; then
        fail "Ошибка получения сертификата Let's Encrypt"
      fi
      cp /etc/letsencrypt/live/$PROXY_DOMAIN/fullchain.pem /etc/ssl/certs/$PROXY_DOMAIN.pem
      cp /etc/letsencrypt/live/$PROXY_DOMAIN/privkey.pem   /etc/ssl/private/$PROXY_DOMAIN.key
      chmod 600 /etc/ssl/private/$PROXY_DOMAIN.key
      chmod 644 /etc/ssl/certs/$PROXY_DOMAIN.pem
      good "Сертификат Let's Encrypt установлен"
    else
      fail "Установка прервана. Скачайте сертификат вручную и повторите установку."
    fi
  fi
  
  info "Распаковываем сертификат..."
  if ! unzip -qo "$tmp/c.zip" -d "$tmp"; then
    fail "Ошибка распаковки сертификата Timeweb"
  fi
  
  # Проверяем наличие файлов
  if [[ ! -f "$tmp/certificate.crt" ]] || [[ ! -f "$tmp/private.key" ]]; then
    warn "Нестандартная структура архива, проверяем содержимое..."
    ls -la "$tmp/"
    # Ищем файлы сертификата
    cert_file=$(find "$tmp" -name "*.crt" -o -name "*.pem" | head -1)
    key_file=$(find "$tmp" -name "*.key" -o -name "*private*" | head -1)
    
    if [[ -n "$cert_file" && -n "$key_file" ]]; then
      good "Найдены файлы сертификата: $cert_file, $key_file"
      cat "$cert_file" > /etc/ssl/certs/$PROXY_DOMAIN.pem
      cp "$key_file" /etc/ssl/private/$PROXY_DOMAIN.key
    else
      fail "Не найдены файлы сертификата в архиве"
    fi
  else
    # Стандартная структура
    if [[ -f "$tmp/ca_bundle.crt" ]]; then
      cat "$tmp/certificate.crt" "$tmp/ca_bundle.crt" > /etc/ssl/certs/$PROXY_DOMAIN.pem
    else
      cat "$tmp/certificate.crt" > /etc/ssl/certs/$PROXY_DOMAIN.pem
    fi
    cp "$tmp/private.key" /etc/ssl/private/$PROXY_DOMAIN.key
  fi
  
  chmod 600 /etc/ssl/private/$PROXY_DOMAIN.key
  good "Сертификат успешно установлен"
fi
chmod 644 /etc/ssl/certs/$PROXY_DOMAIN.pem

# ─── переключаемся на production-vhost ──────────────────────────────
rm -f /etc/nginx/sites-enabled/$PROJECT_NAME
ln -sf "$PROD_CONF" /etc/nginx/sites-enabled/$PROJECT_NAME
nginx -t && systemctl reload nginx
good "Nginx настроен"

# ─── npm install + PM2 ───────────────────────────────────────────────
cd "$PROJECT_DIR"
info "Установка Node.js зависимостей…"
# Удаляем node_modules если есть, чтобы избежать конфликтов
rm -rf node_modules package-lock.json 2>/dev/null || true
# Устанавливаем зависимости с подробным выводом
npm install --production
if [[ $? -ne 0 ]]; then
  warn "npm install не удался, пробуем альтернативный способ…"
  npm cache clean --force
  npm install --production
fi
good "Node.js зависимости установлены"

# Проверяем, что основные модули установились
if [[ ! -d "node_modules/dotenv" ]] || [[ ! -d "node_modules/express" ]] || [[ ! -d "node_modules/http-proxy-middleware" ]]; then
  fail "Критические модули не установились. Проверьте подключение к интернету и права доступа."
fi

info "Запуск приложения через PM2…"
pm2 start ecosystem.config.js --env production
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null
systemctl enable pm2-root

# Проверяем, что приложение запустилось
sleep 2
if ! pm2 list | grep -q "my-proxy.*online"; then
  warn "PM2 приложение не запустилось, пробуем перезапустить…"
  pm2 restart my-proxy
  sleep 2
  if ! pm2 list | grep -q "my-proxy.*online"; then
    fail "Не удалось запустить приложение через PM2. Проверьте логи: pm2 logs my-proxy"
  fi
fi
good "PM2 настроен и запущен"

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