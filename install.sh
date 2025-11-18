#!/bin/bash

# ============================================================================
# Установщик Xray Traffic Monitor v3.4
# ============================================================================

set -e

SCRIPT_URL="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main/xray-traffic-monitor.sh"
CONFIG_URL="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main/config.conf"
INSTALL_PATH="/root/xray-traffic-monitor.sh"
CONFIG_PATH="/root/config.conf"
SYMLINK_PATH="/usr/local/bin/xray-traffic-monitor"
SERVICE_FILE="/etc/systemd/system/xray-monitor.service"

echo "════════════════════════════════════════════════════════════"
echo "    Установка Xray Traffic Monitor v3.4"
echo "════════════════════════════════════════════════════════════"
echo ""

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен быть запущен с правами root (sudo)" 
   exit 1
fi

# Скачиваем скрипт
echo "📥 Скачивание скрипта..."
wget -q -O "$INSTALL_PATH" "$SCRIPT_URL"

if [[ $? -ne 0 ]]; then
    echo "❌ Ошибка скачивания скрипта!"
    exit 1
fi

# Скачиваем конфиг
echo "📥 Скачивание конфигурационного файла..."
wget -q -O "$CONFIG_PATH" "$CONFIG_URL"

if [[ $? -ne 0 ]]; then
    echo "❌ Ошибка скачивания конфига!"
    exit 1
fi

# Даем права на выполнение
echo "🔐 Установка прав доступа..."
chmod +x "$INSTALL_PATH"

# Создаем символическую ссылку
echo "🔗 Создание символической ссылки..."
ln -sf "$INSTALL_PATH" "$SYMLINK_PATH"

# Создаем systemd service
echo "⚙️  Создание systemd service..."
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Xray Traffic Monitor with Baserow Sync
After=network.target xray.service
Requires=xray.service
PartOf=xray.service

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/xray-traffic-monitor
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Корректное завершение с синхронизацией
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

# Перезагружаем systemd
echo "🔄 Перезагрузка systemd daemon..."
systemctl daemon-reload

# Включаем автозапуск
echo "✅ Включение автозапуска..."
systemctl enable xray-monitor.service

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Установка завершена!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "📝 Конфигурационный файл: ${CONFIG_PATH}"
echo "   Отредактируйте его для изменения настроек Baserow"
echo ""
echo "📋 Доступные команды:"
echo ""
echo "  systemctl start xray-monitor      # Запустить мониторинг"
echo "  systemctl stop xray-monitor       # Остановить мониторинг"
echo "  systemctl restart xray-monitor    # Перезапустить мониторинг"
echo "  systemctl status xray-monitor     # Статус мониторинга"
echo "  journalctl -u xray-monitor -f     # Просмотр логов в реальном времени"
echo ""
echo "  nano /root/config.conf             # Редактировать конфиг"
echo ""
echo "🚀 Запуск мониторинга..."
systemctl start xray-monitor

sleep 2

echo ""
echo "📊 Текущий статус:"
systemctl status xray-monitor --no-pager
echo ""
echo "💡 Для просмотра мониторинга: journalctl -u xray-monitor -f"
echo "💡 Для редактирования конфига: nano /root/config.conf"
echo ""
