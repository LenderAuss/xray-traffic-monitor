#!/bin/bash

# ============================================================================
# Установщик Xray Traffic Monitor Python v4.0
# Высокопроизводительная версия на Python с gRPC
# ============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# URLs
SCRIPT_URL="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main/xray_monitor.py"
CONFIG_URL="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main/monitor_config.conf"

# Пути установки
INSTALL_DIR="/opt/xray-monitor"
SCRIPT_PATH="${INSTALL_DIR}/xray_monitor.py"
CONFIG_PATH="${INSTALL_DIR}/monitor_config.conf"
SYMLINK_PATH="/usr/local/bin/xray-monitor"
SERVICE_FILE="/etc/systemd/system/xray-monitor.service"
VENV_PATH="${INSTALL_DIR}/venv"

# ============================================================================
# ФУНКЦИИ
# ============================================================================

print_header() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    Установка Xray Traffic Monitor Python v4.0${NC}"
    echo -e "${BLUE}    High-Performance Edition with gRPC${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Этот скрипт должен быть запущен с правами root (sudo)${NC}"
        exit 1
    fi
}

check_python() {
    echo -e "${CYAN}🔍 Проверка Python...${NC}"
    
    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 --version | awk '{print $2}')
        PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
        PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
        
        if [[ $PYTHON_MAJOR -ge 3 ]] && [[ $PYTHON_MINOR -ge 8 ]]; then
            echo -e "${GREEN}✓ Python $PYTHON_VERSION найден${NC}"
            return 0
        else
            echo -e "${RED}✗ Требуется Python 3.8+, найден $PYTHON_VERSION${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Python 3 не найден${NC}"
        return 1
    fi
}

install_python() {
    echo -e "${YELLOW}📦 Установка Python 3.10+...${NC}"
    
    if [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y python3 python3-pip python3-venv
    elif [[ -f /etc/redhat-release ]]; then
        # CentOS/RHEL
        yum install -y python3 python3-pip
    else
        echo -e "${RED}✗ Неизвестная ОС. Установите Python 3.10+ вручную${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Python установлен${NC}"
}

create_directory() {
    echo -e "${CYAN}📁 Создание директории...${NC}"
    mkdir -p "$INSTALL_DIR"
    echo -e "${GREEN}✓ Директория создана: $INSTALL_DIR${NC}"
}

download_files() {
    echo -e "${CYAN}📥 Скачивание файлов...${NC}"
    
    # Скачиваем основной скрипт
    echo -e "  → Скачивание xray_monitor.py..."
    if wget -q -O "$SCRIPT_PATH" "$SCRIPT_URL" 2>/dev/null; then
        echo -e "${GREEN}  ✓ xray_monitor.py загружен${NC}"
    else
        echo -e "${RED}  ✗ Ошибка загрузки скрипта${NC}"
        exit 1
    fi
    
    # Скачиваем конфиг
    echo -e "  → Скачивание конфигурации..."
    if wget -q -O "$CONFIG_PATH" "$CONFIG_URL" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Конфиг загружен${NC}"
    else
        echo -e "${YELLOW}  ⚠ Конфиг не найден, создаем локально${NC}"
        create_default_config
    fi
    
    chmod +x "$SCRIPT_PATH"
}

create_default_config() {
    cat > "$CONFIG_PATH" << 'EOF'
# ============================================================================
# Xray Traffic Monitor Python - Configuration File v4.0
# ============================================================================

# ===== XRAY API SETTINGS =====
XRAY_API_SERVER=127.0.0.1:10085
XRAY_CONFIG_PATH=/usr/local/etc/xray/config.json

# ===== BASEROW SETTINGS =====
BASEROW_TOKEN=zoJjilyrKAVe42EAV57kBOEQGc8izU1t
BASEROW_TABLE_ID=742631
BASEROW_ENABLED=true

# ===== SERVER SETTINGS =====
SERVER_NAME=ES

# ===== MONITOR SETTINGS =====
REFRESH_INTERVAL=2
SYNC_INTERVAL=5
MIN_SYNC_MB=10

# ===== DISPLAY SETTINGS =====
CONSOLE_MODE=true
SHOW_INACTIVE_USERS=true
COLOR_OUTPUT=true

# ===== PROMETHEUS SETTINGS =====
PROMETHEUS_ENABLED=false
PROMETHEUS_PORT=9090

# ===== ADVANCED SETTINGS =====
MAX_RECONNECT_ATTEMPTS=5
RECONNECT_DELAY=3
LOG_LEVEL=INFO
EOF
    chmod 600 "$CONFIG_PATH"
}

setup_venv() {
    echo -e "${CYAN}🐍 Настройка виртуального окружения Python...${NC}"
    
    # Создаем venv
    python3 -m venv "$VENV_PATH"
    
    # Активируем и устанавливаем зависимости
    source "${VENV_PATH}/bin/activate"
    
    echo -e "  → Установка grpcio..."
    pip3 install --upgrade pip > /dev/null 2>&1
    pip3 install grpcio > /dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Зависимости установлены${NC}"
    else
        echo -e "${RED}✗ Ошибка установки зависимостей${NC}"
        exit 1
    fi
    
    deactivate
}

create_symlink() {
    echo -e "${CYAN}🔗 Создание символической ссылки...${NC}"
    
    # Создаем wrapper script
    cat > "$SYMLINK_PATH" << EOF
#!/bin/bash
source ${VENV_PATH}/bin/activate
exec python3 ${SCRIPT_PATH} "\$@"
EOF
    
    chmod +x "$SYMLINK_PATH"
    echo -e "${GREEN}✓ Команда 'xray-monitor' создана${NC}"
}

create_systemd_service() {
    echo -e "${CYAN}⚙️  Создание systemd service...${NC}"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Traffic Monitor Python (High-Performance Edition)
After=network.target xray.service
Requires=xray.service
PartOf=xray.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${VENV_PATH}/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${VENV_PATH}/bin/python3 ${SCRIPT_PATH} --mode console --interval 2
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Корректное завершение
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
    
    # Перезагружаем systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ Systemd service создан${NC}"
}

configure_xray_api() {
    echo -e "${CYAN}🔧 Проверка Xray Stats API...${NC}"
    
    XRAY_CONFIG="/usr/local/etc/xray/config.json"
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${YELLOW}⚠ Xray конфиг не найден: $XRAY_CONFIG${NC}"
        return 1
    fi
    
    # Проверяем наличие Stats API
    if jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1 && \
       jq -e '.api.services[] | select(. == "StatsService")' "$XRAY_CONFIG" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Stats API уже настроен${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⚠ Stats API не настроен${NC}"
    echo -e "${CYAN}Хотите настроить автоматически? (y/n)${NC}"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        setup_xray_stats_api
    else
        echo -e "${YELLOW}ℹ Пропуск настройки Stats API${NC}"
        echo -e "${YELLOW}  Настройте вручную для работы мониторинга${NC}"
    fi
}

setup_xray_stats_api() {
    echo -e "${CYAN}⚙️  Настройка Xray Stats API...${NC}"
    
    XRAY_CONFIG="/usr/local/etc/xray/config.json"
    API_PORT=10085
    
    # Backup
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Добавляем stats
    if ! jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1; then
        jq '. + {"stats": {}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp
        mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    fi
    
    # Добавляем api
    if ! jq -e '.api' "$XRAY_CONFIG" > /dev/null 2>&1; then
        jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp
        mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    fi
    
    # Настраиваем policy
    jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp
    mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp
    mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # Добавляем API inbound
    api_exists=$(jq '.inbounds[] | select(.tag == "api")' "$XRAY_CONFIG")
    if [[ -z "$api_exists" ]]; then
        jq --argjson api_inbound '{
            "listen": "127.0.0.1",
            "port": '"$API_PORT"',
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"},
            "tag": "api"
        }' '.inbounds += [$api_inbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp
        mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    fi
    
    # Добавляем routing для API
    api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$XRAY_CONFIG" 2>/dev/null)
    if [[ -z "$api_route_exists" ]]; then
        jq --argjson api_rule '{
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        }' '.routing.rules += [$api_rule]' "$XRAY_CONFIG" > /tmp/xray_config.tmp
        mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    fi
    
    # Добавляем API outbound
    api_outbound_exists=$(jq '.outbounds[] | select(.tag == "api")' "$XRAY_CONFIG")
    if [[ -z "$api_outbound_exists" ]]; then
        jq --argjson api_outbound '{
            "protocol": "freedom",
            "tag": "api"
        }' '.outbounds += [$api_outbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp
        mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    fi
    
    # Перезапускаем Xray
    echo -e "${CYAN}  → Перезапуск Xray...${NC}"
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Stats API настроен и активен${NC}"
    else
        echo -e "${RED}✗ Ошибка настройки Stats API${NC}"
        return 1
    fi
}

print_usage() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Установка завершена успешно!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📁 Файлы установлены:${NC}"
    echo -e "   • Скрипт:  ${YELLOW}${SCRIPT_PATH}${NC}"
    echo -e "   • Конфиг:  ${YELLOW}${CONFIG_PATH}${NC}"
    echo -e "   • Venv:    ${YELLOW}${VENV_PATH}${NC}"
    echo -e "   • Service: ${YELLOW}${SERVICE_FILE}${NC}"
    echo ""
    echo -e "${CYAN}📋 Доступные команды:${NC}"
    echo ""
    echo -e "${YELLOW}  Управление сервисом:${NC}"
    echo -e "    systemctl start xray-monitor      # Запустить мониторинг"
    echo -e "    systemctl stop xray-monitor       # Остановить мониторинг"
    echo -e "    systemctl restart xray-monitor    # Перезапустить мониторинг"
    echo -e "    systemctl status xray-monitor     # Статус мониторинга"
    echo -e "    systemctl enable xray-monitor     # Автозапуск при загрузке"
    echo ""
    echo -e "${YELLOW}  Просмотр логов:${NC}"
    echo -e "    journalctl -u xray-monitor -f     # Просмотр в реальном времени"
    echo -e "    journalctl -u xray-monitor -n 100 # Последние 100 строк"
    echo ""
    echo -e "${YELLOW}  Ручной запуск:${NC}"
    echo -e "    xray-monitor --mode console --interval 2"
    echo -e "    xray-monitor --mode prometheus --port 9090"
    echo -e "    xray-monitor --mode both --interval 5 --port 9090"
    echo ""
    echo -e "${YELLOW}  Конфигурация:${NC}"
    echo -e "    nano ${CONFIG_PATH}    # Редактировать конфиг"
    echo -e "    После изменений: systemctl restart xray-monitor"
    echo ""
    echo -e "${CYAN}🔧 Настройка конфига:${NC}"
    echo -e "   1. Откройте: ${YELLOW}nano ${CONFIG_PATH}${NC}"
    echo -e "   2. Измените необходимые параметры:"
    echo -e "      • SERVER_NAME        - имя вашего сервера"
    echo -e "      • BASEROW_TOKEN      - токен Baserow API"
    echo -e "      • BASEROW_TABLE_ID   - ID таблицы Baserow"
    echo -e "      • REFRESH_INTERVAL   - интервал обновления"
    echo -e "   3. Сохраните (Ctrl+O, Enter, Ctrl+X)"
    echo -e "   4. Перезапустите: ${YELLOW}systemctl restart xray-monitor${NC}"
    echo ""
}

# ============================================================================
# ОСНОВНОЙ ПРОЦЕСС УСТАНОВКИ
# ============================================================================

main() {
    print_header
    
    # Проверка root
    check_root
    
    # Проверка Python
    if ! check_python; then
        install_python
    fi
    
    # Создание директории
    create_directory
    
    # Скачивание файлов
    download_files
    
    # Настройка venv
    setup_venv
    
    # Создание символической ссылки
    create_symlink
    
    # Создание systemd service
    create_systemd_service
    
    # Настройка Xray API
    configure_xray_api
    
    # Включаем автозапуск
    echo -e "${CYAN}✅ Включение автозапуска...${NC}"
    systemctl enable xray-monitor.service
    
    # Вывод инструкций
    print_usage
    
    # Предложение запустить
    echo -e "${CYAN}🚀 Запустить мониторинг сейчас? (y/n)${NC}"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Запуск...${NC}"
        systemctl start xray-monitor
        sleep 2
        echo ""
        systemctl status xray-monitor --no-pager
        echo ""
        echo -e "${GREEN}✓ Мониторинг запущен!${NC}"
        echo -e "${CYAN}💡 Просмотр в реальном времени: ${YELLOW}journalctl -u xray-monitor -f${NC}"
    fi
    
    echo ""
}

# Запуск
main
