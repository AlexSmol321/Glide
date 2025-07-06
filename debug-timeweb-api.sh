#!/bin/bash

echo "🔍 ДИАГНОСТИКА API TIMEWEB"
echo "=========================="

# Проверка базового подключения
echo "1️⃣ Проверка базового подключения к API..."
if curl -sf --connect-timeout 10 "https://api.timeweb.cloud" >/dev/null 2>&1; then
    echo "✅ API Timeweb доступен"
else
    echo "❌ API Timeweb недоступен"
    echo "   Возможные причины:"
    echo "   • Проблемы с интернетом"
    echo "   • Блокировка на уровне провайдера"
    echo "   • Неправильный домен API"
fi

# Проверка различных endpoints
echo ""
echo "2️⃣ Проверка различных API endpoints..."

endpoints=(
    "https://api.timeweb.cloud/api/v1/ssl-certificates"
    "https://api.timeweb.cloud/api/v1/ssl"
    "https://api.timeweb.cloud/api/v2/ssl-certificates"
    "https://api.timeweb.cloud/ssl-certificates"
    "https://api.timeweb.cloud/api/v1/certificates"
    "https://api.timeweb.cloud/certificates"
    "https://api.timeweb.com/api/v1/ssl-certificates"
    "https://api.timeweb.com/ssl-certificates"
)

for endpoint in "${endpoints[@]}"; do
    echo "   Тестируем: $endpoint"
    response=$(curl -sf -w "%{http_code}" --connect-timeout 10 "$endpoint" 2>/dev/null || echo "000")
    http_code="${response: -3}"
    
    case $http_code in
        "200") echo "   ✅ 200 OK" ;;
        "401") echo "   🔒 401 Unauthorized (нужна авторизация)" ;;
        "403") echo "   🚫 403 Forbidden (доступ запрещен)" ;;
        "404") echo "   ❌ 404 Not Found (endpoint не существует)" ;;
        "000") echo "   🔌 Ошибка подключения" ;;
        *) echo "   ❓ HTTP $http_code" ;;
    esac
done

echo ""
echo "3️⃣ Проверка альтернативных доменов..."
alt_domains=(
    "https://api.timeweb.com"
    "https://api.timeweb.ru"
    "https://api.timeweb.org"
)

for domain in "${alt_domains[@]}"; do
    echo "   Тестируем: $domain"
    if curl -sf --connect-timeout 10 "$domain" >/dev/null 2>&1; then
        echo "   ✅ Доступен"
    else
        echo "   ❌ Недоступен"
    fi
done

echo ""
echo "4️⃣ Рекомендации:"
echo "   • Проверьте документацию Timeweb: https://timeweb.cloud/api/docs"
echo "   • Возможно, нужен другой тип токена (не JWT)"
echo "   • Попробуйте создать новый API токен в панели Timeweb"
echo "   • Обратитесь в поддержку Timeweb"
echo ""
echo "5️⃣ Альтернативы:"
echo "   • Используйте Let's Encrypt (бесплатно)"
echo "   • Скачайте сертификат вручную из панели"
echo "   • Используйте другой провайдер SSL-сертификатов" 