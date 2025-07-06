#!/bin/bash

echo "🧹 Очистка переменных окружения..."
unset CERT_MODE
unset TIMEWEB_TOKEN
unset TIMEWEB_CERT_ID

echo "📋 Текущие переменные окружения:"
echo "CERT_MODE: ${CERT_MODE:-не установлена}"
echo "TIMEWEB_TOKEN: ${TIMEWEB_TOKEN:-не установлен}"
echo "TIMEWEB_CERT_ID: ${TIMEWEB_CERT_ID:-не установлен}"

echo ""
echo "🔍 Тестирование curl..."
if command -v curl >/dev/null 2>&1; then
    echo "✅ curl установлен"
    echo "📡 Тестирование подключения к Timeweb API..."
    
    # Простой тест без токена
    if curl -sf --connect-timeout 5 --max-time 10 "https://api.timeweb.cloud" >/dev/null 2>&1; then
        echo "✅ API Timeweb доступен"
    else
        echo "❌ API Timeweb недоступен"
    fi
else
    echo "❌ curl не установлен"
fi

echo ""
echo "🚀 Готово! Теперь можно запускать основной скрипт." 