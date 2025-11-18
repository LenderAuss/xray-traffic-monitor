#!/bin/bash

# ============================================================================
# Установщик Xray Traffic Monitor Python v4.0
# Автономный установщик - скачивает файлы при запуске
# ============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути установки
INSTALL_DIR="/opt/xray-monitor"
SCRIPT_PATH="${INSTALL_DIR}/xray_monitor.py"
CONFIG_PATH="${INSTALL_DIR}/monitor_config.conf"
REQUIREMENTS_PATH="${INSTALL_DIR}/requirements.txt"
SYMLINK_PATH="/usr/local/bin/xray-monitor"
SERVICE_FILE="/etc/systemd/system/xray-monitor.service"
VENV_PATH="${INSTALL_DIR}/venv"

# Xray конфиг
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_API_PORT=10085

# ============================================================================
# ФУНКЦИИ
# ============================================================================

print_header() {
    clear
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    Установка Xray Traffic Monitor Python v4.0${NC}"
    echo -e "${BLUE}    High-Performance Edition with gRPC${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Запустите с правами root: sudo $0${NC}"
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
            echo -e "${GREEN}✓ Python $PYTHON_VERSION${NC}"
            return 0
        else
            install_python
        fi
    else
        install_python
    fi
}

install_python() {
    echo -e "${CYAN}📦 Установка Python...${NC}"
    
    if [[ -f /etc/debian_version ]]; then
        apt-get update -qq
        apt-get install -y python3 python3-pip python3-venv python3-dev build-essential wget curl
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y python3 python3-pip python3-devel gcc wget curl
    fi
    
    echo -e "${GREEN}✓ Python установлен${NC}"
}

create_directory() {
    echo -e "${CYAN}📁 Создание директории...${NC}"
    
    # Backup существующего конфига
    if [[ -f "$CONFIG_PATH" ]]; then
        cp "$CONFIG_PATH" "${CONFIG_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}⚠ Создан backup конфига${NC}"
    fi
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    echo -e "${GREEN}✓ Директория: $INSTALL_DIR${NC}"
}

download_files() {
    echo -e "${CYAN}📥 Скачивание файлов с GitHub...${NC}"
    
    # Определяем GitHub repo из того, откуда скачали установщик
    # Или используем стандартный
    GITHUB_REPO="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main"
    
    # xray_monitor.py
    echo -ne "  → xray_monitor.py ... "
    if wget -q --timeout=30 -O "$SCRIPT_PATH" "${GITHUB_REPO}/xray_monitor.py" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo -e "${RED}Ошибка: не удалось скачать xray_monitor.py${NC}"
        echo -e "${YELLOW}Проверьте: ${GITHUB_REPO}/xray_monitor.py${NC}"
        exit 1
    fi
    
    # monitor_config.conf
    echo -ne "  → monitor_config.conf ... "
    if [[ -f "$CONFIG_PATH.backup."* ]]; then
        echo -e "${YELLOW}пропущен (используется backup)${NC}"
    else
        if wget -q --timeout=30 -O "$CONFIG_PATH" "${GITHUB_REPO}/monitor_config.conf" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}⚠ (создан локально)${NC}"
            create_default_config
        fi
    fi
    
    # requirements.txt
    echo -ne "  → requirements.txt ... "
    if wget -q --timeout=30 -O "$REQUIREMENTS_PATH" "${GITHUB_REPO}/requirements.txt" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}⚠ (создан локально)${NC}"
        echo "grpcio>=1.50.0,<2.0.0" > "$REQUIREMENTS_PATH"
        echo "protobuf>=3.20.0,<5.0.0" >> "$REQUIREMENTS_PATH"
    fi
    
    chmod +x "$SCRIPT_PATH"
    chmod 600 "$CONFIG_PATH"
}

create_default_config() {
    cat > "$CONFIG_PATH" << 'EOF'
# Xray Traffic Monitor Python - Configuration File v4.0
XRAY_API_SERVER=127.0.0.1:10085
XRAY_CONFIG_PATH=/usr/local/etc/xray/config.json
BASEROW_TOKEN=zoJjilyrKAVe42EAV57kBOEQGc8izU1t
BASEROW_TABLE_ID=742631
BASEROW_ENABLED=true
SERVER_NAME=ES
REFRESH_INTERVAL=2
SYNC_INTERVAL=5
MIN_SYNC_MB=10
CONSOLE_MODE=true
SHOW_INACTIVE_USERS=true
COLOR_OUTPUT=true
PROMETHEUS_ENABLED=false
PROMETHEUS_PORT=9090
MAX_RECONNECT_ATTEMPTS=5
RECONNECT_DELAY=3
LOG_LEVEL=INFO
EOF
    chmod 600 "$CONFIG_PATH"
}

setup_venv() {
    echo -e "${CYAN}🐍 Настройка виртуального окружения...${NC}"
    
    [[ -d "$VENV_PATH" ]] && rm -rf "$VENV_PATH"
    
    python3 -m venv "$VENV_PATH"
    source "${VENV_PATH}/bin/activate"
    
    pip3 install --upgrade pip > /dev/null 2>&1
    pip3 install -r "$REQUIREMENTS_PATH" > /dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Зависимости установлены${NC}"
    else
        echo -e "${RED}✗ Ошибка установки зависимостей${NC}"
        deactivate
        exit 1
    fi
    
    deactivate
}

create_symlink() {
    echo -e "${CYAN}🔗 Создание команды xray-monitor...${NC}"
    
    cat > "$SYMLINK_PATH" << EOF
#!/bin/bash
source ${VENV_PATH}/bin/activate
exec python3 ${SCRIPT_PATH} "\$@"
EOF
    
    chmod +x "$SYMLINK_PATH"
    echo -e "${GREEN}✓ Команда доступна: xray-monitor${NC}"
}

load_config() {
    if [[ -f "$CONFIG_PATH" ]]; then
        source "$CONFIG_PATH"
    fi
}

create_systemd_service() {
    echo -e "${CYAN}⚙️  Создание systemd service...${NC}"
    
    # Загружаем параметры из конфига
    load_config
    
    local mode="console"
    local interval="${REFRESH_INTERVAL:-2}"
    local prometheus_args=""
    
    if [[ "${PROMETHEUS_ENABLED}" == "true" ]]; then
        mode="both"
        prometheus_args="--port ${PROMETHEUS_PORT:-9090}"
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Traffic Monitor Python (HPC Edition)
After=network.target xray.service
Requires=xray.service
PartOf=xray.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${VENV_PATH}/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${VENV_PATH}/bin/python3 ${SCRIPT_PATH} --mode ${mode} --interval ${interval} ${prometheus_args}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "${GREEN}✓ Systemd service создан${NC}"
}

configure_xray_api() {
    echo -e "${CYAN}🔧 Проверка Xray Stats API...${NC}"
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${YELLOW}⚠ Xray конфиг не найден${NC}"
        return 1
    fi
    
    if jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1 && \
       jq -e '.api.services[] | select(. == "StatsService")' "$XRAY_CONFIG" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Stats API настроен${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⚠ Stats API не настроен${NC}"
    echo -ne "${CYAN}Настроить автоматически? (y/n): ${NC}"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        setup_xray_stats_api
    else
        echo -e "${YELLOW}⚠ Мониторинг не будет работать без Stats API${NC}"
    fi
}

setup_xray_stats_api() {
    echo -e "${CYAN}⚙️  Настройка Xray Stats API...${NC}"
    
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Добавляем stats
    jq '. + {"stats": {}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # Добавляем api
    jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # Policy
    jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # API inbound
    jq --argjson api_inbound '{
        "listen": "127.0.0.1",
        "port": '"$XRAY_API_PORT"',
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"},
        "tag": "api"
    }' '.inbounds += [$api_inbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # API routing
    jq --argjson api_rule '{
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
    }' '.routing.rules += [$api_rule]' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    # API outbound
    jq --argjson api_outbound '{
        "protocol": "freedom",
        "tag": "api"
    }' '.outbounds += [$api_outbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp 2>/dev/null && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
    
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Stats API активен${NC}"
    else
        echo -e "${RED}✗ Ошибка перезапуска Xray${NC}"
        return 1
    fi
}

start_monitor() {
    echo -e "${CYAN}🚀 Запуск мониторинга...${NC}"
    
    systemctl enable xray-monitor > /dev/null 2>&1
    systemctl start xray-monitor
    
    sleep 2
    
    if systemctl is-active --quiet xray-monitor; then
        echo -e "${GREEN}✓ Мониторинг запущен${NC}"
        return 0
    else
        echo -e "${RED}✗ Ошибка запуска${NC}"
        return 1
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Установка завершена!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📊 Статус:${NC}"
    systemctl status xray-monitor --no-pager -l | head -10
    echo ""
    echo -e "${CYAN}📋 Команды:${NC}"
    echo -e "  ${WHITE}systemctl stop xray-monitor${NC}       # Остановить"
    echo -e "  ${WHITE}systemctl restart xray-monitor${NC}    # Перезапустить"
    echo -e "  ${WHITE}journalctl -u xray-monitor -f${NC}     # Логи"
    echo -e "  ${WHITE}nano $CONFIG_PATH${NC}  # Редактировать конфиг"
    echo ""
    echo -e "${CYAN}📺 Просмотр мониторинга:${NC}"
    echo -e "  ${WHITE}journalctl -u xray-monitor -f${NC}"
    echo ""
}

# ============================================================================
# ОСНОВНОЙ ПРОЦЕСС
# ============================================================================

main() {
    print_header
    check_root
    check_python
    create_directory
    download_files
    setup_venv
    create_symlink
    create_systemd_service
    configure_xray_api
    start_monitor
    print_summary
}

main
