#!/bin/bash
# =====================================================================
# СОЗДАНИЕ ФАЙЛОВ СЕРТИФИКАТА ИЗ СКОПИРОВАННОГО СОДЕРЖИМОГО
# Версия: create-1.0
# =====================================================================
set -euo pipefail

# ─── цветовая палитра ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
good(){ echo -e "${GREEN}[ OK ]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
fail(){ echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Запустите скрипт через sudo"

echo "🔧 СОЗДАНИЕ ФАЙЛОВ СЕРТИФИКАТА TIMEWEB"
echo "======================================="
echo ""

# ─── ввод параметров ─────────────────────────────────────────────────
read -p "Введите домен для сертификата: " DOMAIN

# Создание директорий
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
if [[ "$cert_domain" != "$DOMAIN" ]]; then
    warn "Домен в сертификате ($cert_domain) не совпадает с указанным ($DOMAIN)"
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
cp "$temp_cert" "/etc/ssl/certs/$DOMAIN.pem"

info "Копирование приватного ключа..."
cp "$temp_key" "/etc/ssl/private/$DOMAIN.key"

# Установка прав доступа
chmod 644 "/etc/ssl/certs/$DOMAIN.pem"
chmod 600 "/etc/ssl/private/$DOMAIN.key"

# Очистка временных файлов
rm -f "$temp_cert" "$temp_key"

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
echo "   • Просмотр деталей: openssl x509 -in /etc/ssl/certs/$DOMAIN.pem -text -noout"
echo "   • Проверка Nginx: nginx -t"
echo "   • Перезагрузка Nginx: systemctl reload nginx" 