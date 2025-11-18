#!/bin/bash

# ============================================================================
# Установщик Xray Traffic Monitor
# ============================================================================

SCRIPT_URL="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main/xray-traffic-monitor.sh"
INSTALL_PATH="/root/xray-traffic-monitor.sh"
SYMLINK_PATH="/usr/local/bin/xray-traffic-monitor"

echo "════════════════════════════════════════════════════════════"
echo "    Установка Xray Traffic Monitor v3.3"
echo "════════════════════════════════════════════════════════════"
echo ""

# Скачиваем скрипт
echo "📥 Скачивание скрипта..."
wget -q -O "$INSTALL_PATH" "$SCRIPT_URL"

if [[ $? -ne 0 ]]; then
    echo "❌ Ошибка скачивания!"
    exit 1
fi

# Даем права на выполнение
echo "🔐 Установка прав доступа..."
chmod +x "$INSTALL_PATH"

# Создаем символическую ссылку
echo "🔗 Создание символической ссылки..."
ln -sf "$INSTALL_PATH" "$SYMLINK_PATH"

echo ""
echo "✅ Установка завершена!"
echo ""
echo "Запуск: xray-traffic-monitor"
echo ""
