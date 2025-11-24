#!/bin/bash

# ============================================================================
# Установщик Xray Traffic Monitor Python v4.0
# Автономный установщик - скачивает файлы при запуске
# Все настройки берутся из monitor_config.conf
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

# Xray конфиг (будет перезаписан из monitor_config.conf)
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_API_PORT=10085

# GitHub repository
GITHUB_REPO="https://raw.githubusercontent.com/LenderAuss/xray-traffic-monitor/main"

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
            # Надежная проверка через создание тестового venv
            if ! python3 -m venv /tmp/test_venv_$$ &> /dev/null; then
                echo -e "${YELLOW}⚠ python3-venv не установлен${NC}"
                install_python_venv
            else
                rm -rf /tmp/test_venv_$$
            fi
            return 0
        else
            install_python
        fi
    else
        install_python
    fi
}

install_python_venv() {
    echo -e "${CYAN}📦 Установка python3-venv...${NC}"
    
    if [[ -f /etc/debian_version ]]; then
        apt-get update -qq
        apt-get install -y python3-venv python3-dev build-essential jq
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y python3-virtualenv python3-devel gcc jq
    fi
    
    echo -e "${GREEN}✓ python3-venv установлен${NC}"
}

install_python() {
    echo -e "${CYAN}📦 Установка Python...${NC}"
    
    if [[ -f /etc/debian_version ]]; then
        apt-get update -qq
        apt-get install -y python3 python3-pip python3-venv python3-dev build-essential wget curl jq
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y python3 python3-pip python3-devel gcc wget curl jq
    fi
    
    echo -e "${GREEN}✓ Python установлен${NC}"
}

create_directory() {
    echo -e "${CYAN}📁 Создание директории...${NC}"
    
    # Backup существующего конфига
    if [[ -f "$CONFIG_PATH" ]]; then
        BACKUP_PATH="${CONFIG_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_PATH" "$BACKUP_PATH"
        echo -e "${YELLOW}⚠ Создан backup конфига: $BACKUP_PATH${NC}"
    fi
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    echo -e "${GREEN}✓ Директория: $INSTALL_DIR${NC}"
}

download_files() {
    echo -e "${CYAN}📥 Скачивание файлов с GitHub...${NC}"
    
    # xray_monitor.py
    echo -ne "  → xray_monitor.py ... "
    if wget -q --timeout=30 -O "$SCRIPT_PATH" "${GITHUB_REPO}/xray_monitor.py" 2>/dev/null; then
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo -e "${RED}Ошибка: не удалось скачать xray_monitor.py${NC}"
        echo -e "${YELLOW}Проверьте: ${GITHUB_REPO}/xray_monitor.py${NC}"
        exit 1
    fi
    
    # monitor_config.conf (только если нет backup)
    echo -ne "  → monitor_config.conf ... "
    if [[ -f "${CONFIG_PATH}.backup."* ]] && ls "${CONFIG_PATH}.backup."* 1> /dev/null 2>&1; then
        # Восстанавливаем из последнего backup
        LATEST_BACKUP=$(ls -t "${CONFIG_PATH}.backup."* | head -1)
        cp "$LATEST_BACKUP" "$CONFIG_PATH"
        echo -e "${YELLOW}восстановлен из backup${NC}"
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
        create_default_requirements
    fi
    
    chmod 600 "$CONFIG_PATH"
}

create_default_config() {
    cat > "$CONFIG_PATH" << 'EOF'
# ============================================================================
# Xray Traffic Monitor Python - Configuration File v4.0
# ============================================================================

# ===== XRAY API SETTINGS =====
XRAY_API_SERVER=127.0.0.1:10085    # Адрес Xray Stats API
XRAY_CONFIG_PATH=/usr/local/etc/xray/config.json

# ===== BASEROW SETTINGS =====
BASEROW_TOKEN=****
BASEROW_TABLE_ID=*****
BASEROW_ENABLED=true                # true/false - включить/выключить синхронизацию

# ===== SERVER SETTINGS =====
SERVER_NAME=ES                      # Имя сервера (UK, USA-1, EU-London, Asia-Tokyo и т.д.)

# ===== MONITOR SETTINGS =====
REFRESH_INTERVAL=2                  # Интервал обновления экрана (секунды)
SYNC_INTERVAL=5                     # Интервал автосинхронизации (минуты)
MIN_SYNC_MB=10                      # Минимальный трафик для синхронизации (MB)

# ===== DISPLAY SETTINGS =====
CONSOLE_MODE=true                   # Показывать таблицу в консоли
SHOW_INACTIVE_USERS=true            # Показывать неактивных пользователей
COLOR_OUTPUT=true                   # Цветной вывод

# ===== PROMETHEUS SETTINGS =====
PROMETHEUS_ENABLED=false            # Включить Prometheus exporter
PROMETHEUS_PORT=9090                # Порт для метрик

# ===== ADVANCED SETTINGS =====
MAX_RECONNECT_ATTEMPTS=5            # Максимум попыток переподключения
RECONNECT_DELAY=3                   # Задержка между попытками (секунды)
LOG_LEVEL=INFO                      # DEBUG, INFO, WARNING, ERROR
EOF
    chmod 600 "$CONFIG_PATH"
}

create_default_requirements() {
    cat > "$REQUIREMENTS_PATH" << 'EOF'
grpcio>=1.50.0,<2.0.0
protobuf>=3.20.0,<5.0.0
requests>=2.28.0
EOF
}

setup_venv() {
    echo -e "${CYAN}🐍 Настройка виртуального окружения...${NC}"
    
    [[ -d "$VENV_PATH" ]] && rm -rf "$VENV_PATH"
    
    python3 -m venv "$VENV_PATH"
    source "${VENV_PATH}/bin/activate"
    
    echo -ne "  → Обновление pip ... "
    pip3 install --upgrade pip > /dev/null 2>&1 && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}⚠${NC}"
    
    echo -ne "  → Установка зависимостей ... "
    pip3 install -r "$REQUIREMENTS_PATH" > /dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo -e "${RED}Ошибка установки зависимостей${NC}"
        deactivate
        exit 1
    fi
    
    deactivate
    echo -e "${GREEN}✓ Виртуальное окружение готово${NC}"
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
        # Загружаем переменные из конфига
        source "$CONFIG_PATH"
        
        # Переопределяем XRAY_CONFIG если указан в конфиге
        if [[ -n "$XRAY_CONFIG_PATH" ]]; then
            XRAY_CONFIG="$XRAY_CONFIG_PATH"
        fi
        
        # Извлекаем порт из XRAY_API_SERVER (127.0.0.1:10085 -> 10085)
        if [[ -n "$XRAY_API_SERVER" ]]; then
            XRAY_API_PORT=$(echo "$XRAY_API_SERVER" | cut -d: -f2)
        fi
    fi
}

create_systemd_service() {
    echo -e "${CYAN}⚙️  Создание systemd service...${NC}"
    
    # Загружаем параметры из конфига
    load_config
    
    # Определяем режим работы
    local mode="console"
    local interval="${REFRESH_INTERVAL:-2}"
    local prometheus_args=""
    local server_arg=""
    
    # Проверяем Prometheus
    if [[ "${PROMETHEUS_ENABLED}" == "true" ]]; then
        mode="both"
        prometheus_args="--port ${PROMETHEUS_PORT:-9090}"
    fi
    
    # Проверяем XRAY_API_SERVER
    if [[ -n "$XRAY_API_SERVER" ]]; then
        server_arg="--server ${XRAY_API_SERVER}"
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
Environment="PYTHONUNBUFFERED=1"
ExecStart=${VENV_PATH}/bin/python3 ${SCRIPT_PATH} --mode ${mode} --interval ${interval} ${server_arg} ${prometheus_args}
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
    echo -e "${CYAN}  Режим: ${mode}, Интервал: ${interval}s${NC}"
    if [[ -n "$prometheus_args" ]]; then
        echo -e "${CYAN}  Prometheus: :${PROMETHEUS_PORT:-9090}/metrics${NC}"
    fi
}

configure_xray_api() {
    echo -e "${CYAN}🔧 Проверка Xray Stats API...${NC}"
    
    # Загружаем конфиг для получения пути к Xray config
    load_config
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${YELLOW}⚠ Xray конфиг не найден: $XRAY_CONFIG${NC}"
        echo -e "${YELLOW}⚠ Мониторинг не будет работать без настроенного Xray${NC}"
        return 1
    fi
    
    # Проверяем наличие jq
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}⚠ jq не установлен, автонастройка невозможна${NC}"
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
        echo -e "${YELLOW}⚠ Настройте вручную или перезапустите установщик${NC}"
    fi
}

setup_xray_stats_api() {
    echo -e "${CYAN}⚙️  Настройка Xray Stats API...${NC}"
    
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓ Создан backup: ${XRAY_CONFIG}.backup.*${NC}"
    
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
    
    echo -e "${CYAN}🔄 Перезапуск Xray...${NC}"
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Xray перезапущен, Stats API активен${NC}"
    else
        echo -e "${RED}✗ Ошибка перезапуска Xray${NC}"
        echo -e "${YELLOW}Проверьте логи: journalctl -u xray -n 50${NC}"
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
        echo -e "${YELLOW}Проверьте логи: journalctl -u xray-monitor -n 50${NC}"
        return 1
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Установка завершена!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📊 Статус сервиса:${NC}"
    systemctl status xray-monitor --no-pager -l | head -10
    echo ""
    echo -e "${CYAN}📋 Управление:${NC}"
    echo -e "  ${WHITE}systemctl stop xray-monitor${NC}       # Остановить"
    echo -e "  ${WHITE}systemctl restart xray-monitor${NC}    # Перезапустить"
    echo -e "  ${WHITE}systemctl status xray-monitor${NC}     # Проверить статус"
    echo ""
    echo -e "${CYAN}📺 Просмотр логов:${NC}"
    echo -e "  ${WHITE}journalctl -u xray-monitor -f${NC}     # Следить за логами"
    echo -e "  ${WHITE}journalctl -u xray-monitor -n 100${NC}  # Последние 100 строк"
    echo ""
    echo -e "${CYAN}⚙️  Настройки:${NC}"
    echo -e "  ${WHITE}nano $CONFIG_PATH${NC}"
    echo -e "  После изменения конфига: ${WHITE}systemctl restart xray-monitor${NC}"
    echo ""
    
    # Показываем текущие настройки
    load_config
    echo -e "${CYAN}📌 Текущая конфигурация:${NC}"
    echo -e "  Сервер: ${WHITE}${SERVER_NAME:-Unknown}${NC}"
    echo -e "  Xray API: ${WHITE}${XRAY_API_SERVER:-127.0.0.1:10085}${NC}"
    echo -e "  Интервал: ${WHITE}${REFRESH_INTERVAL:-2}s${NC}"
    if [[ "${PROMETHEUS_ENABLED}" == "true" ]]; then
        echo -e "  Prometheus: ${WHITE}http://$(hostname -I | awk '{print $1}'):${PROMETHEUS_PORT:-9090}/metrics${NC}"
    fi
    if [[ "${BASEROW_ENABLED}" == "true" ]]; then
        echo -e "  Baserow: ${WHITE}Включен (синхронизация каждые ${SYNC_INTERVAL:-5} мин)${NC}"
    fi
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
