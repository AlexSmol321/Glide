#!/bin/bash
# =====================================================================
# РУЧНАЯ УСТАНОВКА TIMEWEB PRO СЕРТИФИКАТА
# Версия: manual-1.0
# =====================================================================
set -euo pipefail

# ─── цветовая палитра ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
good(){ echo -e "${GREEN}[ OK ]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
fail(){ echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Запустите скрипт через sudo"

echo "🔧 РУЧНАЯ УСТАНОВКА TIMEWEB PRO СЕРТИФИКАТА"
echo "============================================="
echo ""

# ─── ввод параметров ─────────────────────────────────────────────────
read -p "Введите домен для сертификата: " DOMAIN
read -p "Путь к файлу сертификата (.crt): " CERT_FILE
read -p "Путь к файлу приватного ключа (.key): " KEY_FILE

# Проверка существования файлов
if [[ ! -f "$CERT_FILE" ]]; then
    fail "Файл сертификата не найден: $CERT_FILE"
fi

if [[ ! -f "$KEY_FILE" ]]; then
    fail "Файл приватного ключа не найден: $KEY_FILE"
fi

# Проверка формата файлов
if ! openssl x509 -in "$CERT_FILE" -text -noout >/dev/null 2>&1; then
    fail "Некорректный формат сертификата: $CERT_FILE"
fi

if ! openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
    fail "Некорректный формат приватного ключа: $KEY_FILE"
fi

# Проверка соответствия сертификата и ключа
cert_modulus=$(openssl x509 -in "$CERT_FILE" -noout -modulus | openssl md5)
key_modulus=$(openssl rsa -in "$KEY_FILE" -noout -modulus | openssl md5)

if [[ "$cert_modulus" != "$key_modulus" ]]; then
    fail "Сертификат и приватный ключ не соответствуют друг другу"
fi

# Проверка домена в сертификате
cert_domain=$(openssl x509 -in "$CERT_FILE" -noout -subject | grep -o "CN = [^,]*" | cut -d'=' -f2 | tr -d ' ')
if [[ "$cert_domain" != "$DOMAIN" ]]; then
    warn "Домен в сертификате ($cert_domain) не совпадает с указанным ($DOMAIN)"
    read -p "Продолжить? (y/n): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
        fail "Установка отменена"
    fi
fi

# Проверка срока действия
expiry_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d'=' -f2)
expiry_timestamp=$(date -d "$expiry_date" +%s)
current_timestamp=$(date +%s)
days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))

if [[ $days_until_expiry -lt 0 ]]; then
    fail "Сертификат истек: $expiry_date"
elif [[ $days_until_expiry -lt 30 ]]; then
    warn "Сертификат истекает через $days_until_expiry дней: $expiry_date"
    read -p "Продолжить? (y/n): " continue_expired
    if [[ ! "$continue_expired" =~ ^[Yy]$ ]]; then
        fail "Установка отменена"
    fi
else
    good "Сертификат действителен до: $expiry_date ($days_until_expiry дней)"
fi

# Создание директорий SSL
mkdir -p /etc/ssl/{certs,private}

# Копирование файлов
info "Копирование сертификата..."
cp "$CERT_FILE" "/etc/ssl/certs/$DOMAIN.pem"

info "Копирование приватного ключа..."
cp "$KEY_FILE" "/etc/ssl/private/$DOMAIN.key"

# Установка прав доступа
chmod 644 "/etc/ssl/certs/$DOMAIN.pem"
chmod 600 "/etc/ssl/private/$DOMAIN.key"

# Проверка установки
info "Проверка установки..."
if openssl x509 -in "/etc/ssl/certs/$DOMAIN.pem" -text -noout >/dev/null 2>&1; then
    good "Сертификат установлен корректно"
else
    fail "Ошибка установки сертификата"
fi

# Проверка Nginx (если установлен)
if command -v nginx >/dev/null 2>&1; then
    info "Проверка конфигурации Nginx..."
    if nginx -t >/dev/null 2>&1; then
        good "Конфигурация Nginx корректна"
        info "Перезагрузка Nginx..."
        systemctl reload nginx
        good "Nginx перезагружен"
    else
        warn "Проблемы с конфигурацией Nginx"
        echo "Проверьте конфигурацию вручную: nginx -t"
    fi
fi

# Создание скрипта для проверки срока действия
cat > "/usr/local/bin/check-cert-$DOMAIN.sh" <<EOF
#!/bin/bash
# Проверка срока действия сертификата для $DOMAIN
cert_file="/etc/ssl/certs/$DOMAIN.pem"
if [[ -f "\$cert_file" ]]; then
    expiry_date=\$(openssl x509 -in "\$cert_file" -noout -enddate | cut -d'=' -f2)
    expiry_timestamp=\$(date -d "\$expiry_date" +%s)
    current_timestamp=\$(date +%s)
    days_until_expiry=\$(( (expiry_timestamp - current_timestamp) / 86400 ))
    
    if [[ \$days_until_expiry -lt 0 ]]; then
        echo "❌ Сертификат $DOMAIN истек: \$expiry_date"
        exit 1
    elif [[ \$days_until_expiry -lt 30 ]]; then
        echo "⚠️  Сертификат $DOMAIN истекает через \$days_until_expiry дней: \$expiry_date"
        exit 1
    else
        echo "✅ Сертификат $DOMAIN действителен еще \$days_until_expiry дней"
    fi
else
    echo "❌ Файл сертификата не найден: \$cert_file"
    exit 1
fi
EOF

chmod +x "/usr/local/bin/check-cert-$DOMAIN.sh"

# Добавление в cron для автоматической проверки
echo "0 9 * * * root /usr/local/bin/check-cert-$DOMAIN.sh >> /var/log/cert-check.log 2>&1" > "/etc/cron.d/check-cert-$DOMAIN"

good "Установка завершена!"
echo ""
echo "📋 ИНФОРМАЦИЯ О СЕРТИФИКАТЕ:"
echo "   • Домен: $DOMAIN"
echo "   • Сертификат: /etc/ssl/certs/$DOMAIN.pem"
echo "   • Приватный ключ: /etc/ssl/private/$DOMAIN.key"
echo "   • Действителен до: $expiry_date"
echo "   • Дней до истечения: $days_until_expiry"
echo ""
echo "🔧 ПОЛЕЗНЫЕ КОМАНДЫ:"
echo "   • Проверка сертификата: /usr/local/bin/check-cert-$DOMAIN.sh"
echo "   • Просмотр деталей: openssl x509 -in /etc/ssl/certs/$DOMAIN.pem -text -noout"
echo "   • Проверка Nginx: nginx -t"
echo "   • Перезагрузка Nginx: systemctl reload nginx"
echo ""
echo "⚠️  ВАЖНО:"
echo "   • Регулярно проверяйте срок действия сертификата"
echo "   • Обновляйте сертификат до истечения срока"
echo "   • Храните приватный ключ в безопасном месте" 