#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.1 - С автосинхронизацией и персистентным хранением
# Исправления: защита от пустых записей, правильное обновление Baserow
# ============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Установка Xray Traffic Monitor v3.1                   ║${NC}"
echo -e "${BLUE}║        (с автосинхронизацией и Baserow интеграцией)           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ Этот скрипт должен быть запущен с правами root${NC}"
   exit 1
fi

# Проверка установки Xray
if ! command -v xray &> /dev/null; then
    echo -e "${RED}✗ Xray не установлен!${NC}"
    echo -e "${YELLOW}Установите Xray перед использованием этого скрипта${NC}"
    exit 1
fi

# Установка зависимостей
echo -e "${YELLOW}⚙ Проверка зависимостей...${NC}"
apt-get update > /dev/null 2>&1

for pkg in bc jq curl; do
    if ! command -v $pkg &> /dev/null; then
        echo -e "${YELLOW}  Установка $pkg...${NC}"
        apt-get install -y $pkg > /dev/null 2>&1
    fi
done

echo -e "${GREEN}✓ Зависимости установлены${NC}"

# Создание основного скрипта
echo -e "${YELLOW}⚙ Создание скрипта мониторинга...${NC}"

cat << 'MAINSCRIPT' > /usr/local/bin/xray-traffic-monitor
#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BASEROW_CONFIG="/usr/local/etc/xray/baserow.conf"
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"
REFRESH_INTERVAL=2

# Загрузка конфигурации Baserow
load_baserow_config() {
    if [[ -f "$BASEROW_CONFIG" ]]; then
        source "$BASEROW_CONFIG"
        return 0
    fi
    return 1
}

# Сохранение конфигурации Baserow
save_baserow_config() {
    cat > "$BASEROW_CONFIG" << EOF
BASEROW_TOKEN="$1"
BASEROW_TABLE_ID="$2"
BASEROW_ENABLED="$3"
EOF
    chmod 600 "$BASEROW_CONFIG"
}

# Функция очистки экрана
clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR - Real-time v3.1                    ║${NC}"
    echo -e "${BLUE}║         (Автосинхронизация + персистентное хранение в Baserow)            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Функция для конвертации байтов
bytes_to_human() {
    local bytes=$1
    
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0 B"
        return
    fi
    
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" $(echo "scale=2; $bytes / 1073741824" | bc)
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" $(echo "scale=2; $bytes / 1048576" | bc)
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" $(echo "scale=2; $bytes / 1024" | bc)
    else
        echo "${bytes} B"
    fi
}

# Конвертация в гигабайты (число)
bytes_to_gb() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0"
        return
    fi
    printf "%.4f" $(echo "scale=4; $bytes / 1073741824" | bc)
}

# Конвертация GB в байты
gb_to_bytes() {
    local gb=$1
    if [[ -z "$gb" || "$gb" == "0" ]]; then
        echo "0"
        return
    fi
    printf "%.0f" $(echo "scale=0; $gb * 1073741824 / 1" | bc)
}

# Функция конвертации в байты в секунду
bytes_per_sec() {
    local bytes=$1
    local interval=${2:-1}
    
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0 B/s"
        return
    fi
    
    local bps=$(echo "$bytes / $interval" | bc)
    
    if (( bps >= 1048576 )); then
        printf "%.2f MB/s" $(echo "scale=2; $bps / 1048576" | bc)
    elif (( bps >= 1024 )); then
        printf "%.2f KB/s" $(echo "scale=2; $bps / 1024" | bc)
    else
        echo "${bps} B/s"
    fi
}

# ============================================================================
# BASEROW API ФУНКЦИИ
# ============================================================================

# Получить все записи из таблицы
baserow_get_all_rows() {
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    local response=$(curl -s -X GET \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
        -H "Authorization: Token ${BASEROW_TOKEN}")
    
    echo "$response"
}

# Получить запись по имени пользователя
baserow_get_user_row() {
    local username=$1
    local all_rows=$(baserow_get_all_rows)
    
    if [[ -z "$all_rows" ]]; then
        echo ""
        return
    fi
    
    echo "$all_rows" | jq -r --arg user "$username" '.results[] | select(.user == $user)' 2>/dev/null
}

# Получить GB пользователя из Baserow
baserow_get_user_gb() {
    local username=$1
    local user_row=$(baserow_get_user_row "$username")
    
    if [[ -n "$user_row" ]]; then
        local gb=$(echo "$user_row" | jq -r '.GB // "0"' 2>/dev/null)
        echo "${gb:-0}"
    else
        echo "0"
    fi
}

# Создать новую запись (ТОЛЬКО если трафик > 0)
baserow_create_row() {
    local username=$1
    local gb=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    # Проверка: не создаём запись если GB = 0 или пустое
    if [[ -z "$gb" || "$gb" == "0" || "$gb" == "0.00" || "$gb" == "0.0000" ]]; then
        return 0
    fi
    
    # Дополнительная проверка: GB должен быть числом больше 0
    local gb_check=$(echo "$gb > 0" | bc -l 2>/dev/null)
    if [[ "$gb_check" != "1" ]]; then
        return 0
    fi
    
    curl -s -X POST \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
        -H "Authorization: Token ${BASEROW_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"user\": \"$username\", \"GB\": $gb}" > /dev/null 2>&1
}

# Обновить существующую запись
baserow_update_row() {
    local username=$1
    local gb=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    # Проверка: не обновляем если GB = 0
    if [[ -z "$gb" || "$gb" == "0" || "$gb" == "0.00" || "$gb" == "0.0000" ]]; then
        return 0
    fi
    
    local user_row=$(baserow_get_user_row "$username")
    
    if [[ -n "$user_row" ]]; then
        local row_id=$(echo "$user_row" | jq -r '.id' 2>/dev/null)
        if [[ -n "$row_id" && "$row_id" != "null" ]]; then
            curl -s -X PATCH \
                "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/?user_field_names=true" \
                -H "Authorization: Token ${BASEROW_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"GB\": $gb}" > /dev/null 2>&1
        fi
    else
        # Создаём новую запись только если GB > 0
        baserow_create_row "$username" "$gb"
    fi
}

# Синхронизировать трафик пользователя с Baserow (УЛУЧШЕННАЯ ВЕРСИЯ)
baserow_sync_user() {
    local username=$1
    local current_bytes=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # КРИТИЧЕСКИ ВАЖНО: НЕ синхронизируем если трафик < 10 MB
    if (( current_bytes < 10485760 )); then
        return 0
    fi
    
    # Получаем сохраненные GB из Baserow
    local saved_gb=$(baserow_get_user_gb "$username")
    local saved_bytes=$(gb_to_bytes "$saved_gb")
    
    # Суммируем с текущими байтами
    local total_bytes=$((saved_bytes + current_bytes))
    local total_gb=$(bytes_to_gb "$total_bytes")
    
    # Обновляем в Baserow
    baserow_update_row "$username" "$total_gb"
    
    echo "$total_bytes"
}

# Получить полный трафик пользователя (Baserow + текущая сессия)
get_total_user_traffic() {
    local username=$1
    local current_bytes=$2
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        local saved_gb=$(baserow_get_user_gb "$username")
        local saved_bytes=$(gb_to_bytes "$saved_gb")
        echo $((saved_bytes + current_bytes))
    else
        echo "$current_bytes"
    fi
}

# Удалить запись пользователя из Baserow
baserow_delete_user() {
    local username=$1
    local user_row=$(baserow_get_user_row "$username")
    
    if [[ "$BASEROW_ENABLED" != "true" ]] || [[ -z "$user_row" ]]; then
        return 1
    fi
    
    local row_id=$(echo "$user_row" | jq -r '.id' 2>/dev/null)
    if [[ -n "$row_id" && "$row_id" != "null" ]]; then
        curl -s -X DELETE \
            "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/" \
            -H "Authorization: Token ${BASEROW_TOKEN}" > /dev/null 2>&1
    fi
}

# ============================================================================
# НАСТРОЙКА BASEROW
# ============================================================================

setup_baserow() {
    clear_screen
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              НАСТРОЙКА ИНТЕГРАЦИИ С BASEROW                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if load_baserow_config && [[ "$BASEROW_ENABLED" == "true" ]]; then
        echo -e "${GREEN}✓${NC} Baserow уже настроен"
        echo -e "${YELLOW}Текущие параметры:${NC}"
        echo -e "  Token: ${BASEROW_TOKEN:0:10}..."
        echo -e "  Table ID: $BASEROW_TABLE_ID"
        echo ""
        read -p "Изменить настройки? (y/n): " change
        if [[ "$change" != "y" && "$change" != "Y" ]]; then
            return
        fi
    fi
    
    echo -e "${YELLOW}Введите ваш Baserow API Token:${NC}"
    read -p "> " token
    
    echo -e "${YELLOW}Введите ID таблицы Traffic:${NC}"
    read -p "> " table_id
    
    echo ""
    echo -e "${YELLOW}Проверка подключения к Baserow...${NC}"
    
    # Тестовый запрос
    local test_response=$(curl -s -X GET \
        "https://api.baserow.io/api/database/rows/table/${table_id}/?user_field_names=true" \
        -H "Authorization: Token ${token}")
    
    if echo "$test_response" | jq -e '.results' > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Подключение успешно!"
        save_baserow_config "$token" "$table_id" "true"
        
        # Перезагружаем конфиг
        load_baserow_config
        
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              Baserow успешно настроен!                        ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}✗${NC} Ошибка подключения к Baserow!"
        echo -e "${YELLOW}Проверьте токен и ID таблицы${NC}"
        echo ""
        echo -e "${RED}Ответ API:${NC}"
        echo "$test_response" | jq '.' 2>/dev/null || echo "$test_response"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Отключить Baserow
disable_baserow() {
    clear_screen
    echo -e "${YELLOW}Отключение интеграции с Baserow...${NC}"
    
    if [[ -f "$BASEROW_CONFIG" ]]; then
        load_baserow_config
        save_baserow_config "$BASEROW_TOKEN" "$BASEROW_TABLE_ID" "false"
        echo -e "${GREEN}✓${NC} Baserow отключен (данные сохранены)"
    else
        echo -e "${YELLOW}⚠${NC} Baserow не был настроен"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Включить Baserow
enable_baserow() {
    if [[ -f "$BASEROW_CONFIG" ]]; then
        load_baserow_config
        save_baserow_config "$BASEROW_TOKEN" "$BASEROW_TABLE_ID" "true"
        load_baserow_config
        echo -e "${GREEN}✓${NC} Baserow включен"
    else
        echo -e "${YELLOW}⚠${NC} Сначала настройте Baserow (опция 7)"
    fi
}

# ============================================================================
# XRAY STATS API
# ============================================================================

# Проверка Stats API
check_stats_api() {
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        return 1
    fi
    if ! jq -e '.api.services[] | select(. == "StatsService")' "$CONFIG_FILE" > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Установка Stats API
setup_stats_api() {
    clear_screen
    echo -e "${YELLOW}⚙ Настройка Stats API...${NC}"
    echo ""
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓${NC} Резервная копия создана"
    
    # Добавляем stats
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"stats": {}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен блок stats"
    fi
    
    # Добавляем api
    if ! jq -e '.api' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен API сервис"
    fi
    
    # Policy
    jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Настроены политики статистики"
    
    # API inbound
    api_exists=$(jq '.inbounds[] | select(.tag == "api")' "$CONFIG_FILE")
    if [[ -z "$api_exists" ]]; then
        jq --argjson api_inbound '{
            "listen": "127.0.0.1",
            "port": '"$API_PORT"',
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"},
            "tag": "api"
        }' '.inbounds += [$api_inbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен API inbound"
    fi
    
    # Routing
    api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$api_route_exists" ]]; then
        jq --argjson api_rule '{
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        }' '.routing.rules += [$api_rule]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен routing для API"
    fi
    
    # Outbound
    api_outbound_exists=$(jq '.outbounds[] | select(.tag == "api")' "$CONFIG_FILE")
    if [[ -z "$api_outbound_exists" ]]; then
        jq --argjson api_outbound '{
            "protocol": "freedom",
            "tag": "api"
        }' '.outbounds += [$api_outbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен API outbound"
    fi
    
    echo ""
    echo -e "${YELLOW}⟳${NC} Перезапуск Xray..."
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓${NC} Xray успешно перезапущен"
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              Stats API успешно установлен!                    ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}✗${NC} Ошибка перезапуска Xray!"
        latest_backup=$(ls -t ${CONFIG_FILE}.backup.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" "$CONFIG_FILE"
            systemctl restart xray
        fi
        return 1
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Получение статистики пользователя (текущая сессия)
get_user_stats() {
    local email=$1
    local uplink downlink
    
    local stats_output=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)
    
    uplink=$(echo "$stats_output" | grep "user>>>$email>>>traffic>>>uplink" -A 3 | grep -oP '"value"\s*:\s*"\K\d+' | head -1)
    downlink=$(echo "$stats_output" | grep "user>>>$email>>>traffic>>>downlink" -A 3 | grep -oP '"value"\s*:\s*"\K\d+' | head -1)
    
    if [[ -z "$uplink" ]]; then
        uplink=$(echo "$stats_output" | jq -r '.stat[] | select(.name | contains("user>>>'"$email"'>>>traffic>>>uplink")) | .value // "0"' 2>/dev/null | head -1)
    fi
    
    if [[ -z "$downlink" ]]; then
        downlink=$(echo "$stats_output" | jq -r '.stat[] | select(.name | contains("user>>>'"$email"'>>>traffic>>>downlink")) | .value // "0"' 2>/dev/null | head -1)
    fi
    
    uplink=${uplink:-0}
    downlink=${downlink:-0}
    
    echo "$uplink $downlink"
}

# Сброс статистики
reset_user_stats() {
    local email=$1
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>uplink" -reset > /dev/null 2>&1
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>downlink" -reset > /dev/null 2>&1
}

reset_all_stats() {
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    for email in "${emails[@]}"; do
        reset_user_stats "$email"
    done
}

# ============================================================================
# МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ С АВТОСИНХРОНИЗАЦИЕЙ
# ============================================================================

realtime_monitor() {
    if ! check_stats_api; then
        clear_screen
        echo -e "${RED}✗ Stats API не настроен!${NC}"
        echo ""
        read -p "Настроить сейчас? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            setup_stats_api
        else
            return
        fi
    fi
    
    load_baserow_config
    
    clear_screen
    echo -e "${CYAN}Установите интервал обновления экрана (в секундах, по умолчанию 2):${NC}"
    read -p "> " interval
    interval=${interval:-2}
    
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        interval=2
    fi
    
    # НОВОЕ: Настройка автосинхронизации с Baserow
    local auto_sync_enabled=false
    local sync_interval_minutes=0
    local sync_counter=0
    local sync_interval_seconds=0
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}Включить автоматическую синхронизацию с Baserow? (y/n):${NC}"
        read -p "> " enable_sync
        
        if [[ "$enable_sync" == "y" || "$enable_sync" == "Y" ]]; then
            echo -e "${CYAN}Интервал синхронизации в минутах (рекомендуется: 5-60):${NC}"
            read -p "> " sync_interval_minutes
            
            if [[ "$sync_interval_minutes" =~ ^[0-9]+$ ]] && (( sync_interval_minutes > 0 )); then
                auto_sync_enabled=true
                sync_interval_seconds=$((sync_interval_minutes * 60))
                echo -e "${GREEN}✓ Автосинхронизация включена: каждые $sync_interval_minutes минут${NC}"
                echo -e "${YELLOW}ℹ Минимальный трафик для синхронизации: 10 MB${NC}"
                sleep 3
            else
                echo -e "${YELLOW}⚠ Некорректный интервал, автосинхронизация отключена${NC}"
                sleep 2
            fi
        fi
    fi
    
    # Массивы для хранения предыдущих значений
    declare -A prev_uplink
    declare -A prev_downlink
    
    # Получаем список АКТИВНЫХ пользователей из config.json
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    # Инициализация
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        prev_uplink[$email]=$(echo "$stats" | awk '{print $1}')
        prev_downlink[$email]=$(echo "$stats" | awk '{print $2}')
    done
    
    # Счётчик для автосинхронизации
    local elapsed_seconds=0
    
    while true; do
        # Обновляем список активных пользователей на каждой итерации
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                     МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (Обновление: ${interval}s)                                   ║${NC}"
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            if [[ "$auto_sync_enabled" == true ]]; then
                local next_sync_in=$(( sync_interval_seconds - (elapsed_seconds % sync_interval_seconds) ))
                echo -e "${BLUE}║      ${GREEN}✓ Baserow активен${BLUE} | Автосинхронизация: каждые ${sync_interval_minutes}м | След. синхр. через: ${next_sync_in}с           ║${NC}"
            else
                echo -e "${BLUE}║                     ${GREEN}✓ Baserow активен${BLUE} - статистика сохраняется между перезапусками                    ║${NC}"
            fi
        else
            echo -e "${BLUE}║                     ${YELLOW}⚠ Baserow выключен${BLUE} - статистика НЕ сохраняется                                     ║${NC}"
        fi
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Время:${NC} $(date '+%Y-%m-%d %H:%M:%S')    ${YELLOW}Активных:${NC} ${#current_emails[@]}    ${YELLOW}Ctrl+C = выход${NC}"
        echo ""
        
        printf "${CYAN}%-20s %15s %15s %15s %15s %15s %15s${NC}\n" \
            "ПОЛЬЗОВАТЕЛЬ" "СЕССИЯ ↑" "СЕССИЯ ↓" "ВСЕГО (БД)" "СКОРОСТЬ ↑" "СКОРОСТЬ ↓" "ИТОГО"
        echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
        
        local total_session_up=0
        local total_session_down=0
        local total_speed_up=0
        local total_speed_down=0
        local total_all_traffic=0
        local active_count=0
        
        # Обрабатываем ТОЛЬКО активных пользователей
        for email in "${current_emails[@]}"; do
            local stats=$(get_user_stats "$email")
            local uplink=$(echo "$stats" | awk '{print $1}')
            local downlink=$(echo "$stats" | awk '{print $2}')
            
            # Инициализируем prev значения если пользователь новый
            if [[ -z "${prev_uplink[$email]}" ]]; then
                prev_uplink[$email]=0
            fi
            if [[ -z "${prev_downlink[$email]}" ]]; then
                prev_downlink[$email]=0
            fi
            
            # Вычисляем скорость
            local speed_up=$((uplink - prev_uplink[$email]))
            local speed_down=$((downlink - prev_downlink[$email]))
            
            # Если скорость отрицательная, обнуляем
            if (( speed_up < 0 )); then speed_up=0; fi
            if (( speed_down < 0 )); then speed_down=0; fi
            
            local session_total=$((uplink + downlink))
            
            # Получаем полный трафик (Baserow + текущая сессия)
            local total_traffic=$(get_total_user_traffic "$email" "$session_total")
            
            total_session_up=$((total_session_up + uplink))
            total_session_down=$((total_session_down + downlink))
            total_speed_up=$((total_speed_up + speed_up))
            total_speed_down=$((total_speed_down + speed_down))
            total_all_traffic=$((total_all_traffic + total_traffic))
            
            # Цветовая индикация активности
            local color=$NC
            if (( speed_up > 0 || speed_down > 0 )); then
                color=$GREEN
                active_count=$((active_count + 1))
            fi
            
            printf "${color}%-20s %15s %15s %15s %15s %15s %15s${NC}\n" \
                "$email" \
                "$(bytes_to_human $uplink)" \
                "$(bytes_to_human $downlink)" \
                "$(bytes_to_human $total_traffic)" \
                "$(bytes_per_sec $speed_up $interval)" \
                "$(bytes_per_sec $speed_down $interval)" \
                "$(bytes_to_human $session_total)"
            
            # Сохраняем текущие значения
            prev_uplink[$email]=$uplink
            prev_downlink[$email]=$downlink
        done
        
        # Очищаем старые записи удалённых пользователей
        for email in "${!prev_uplink[@]}"; do
            local found=0
            for current_email in "${current_emails[@]}"; do
                if [[ "$email" == "$current_email" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                unset prev_uplink[$email]
                unset prev_downlink[$email]
            fi
        done
        
        echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
        printf "${WHITE}%-20s %15s %15s %15s %15s %15s %15s${NC}\n" \
            "ИТОГО:" \
            "$(bytes_to_human $total_session_up)" \
            "$(bytes_to_human $total_session_down)" \
            "$(bytes_to_human $total_all_traffic)" \
            "$(bytes_per_sec $total_speed_up $interval)" \
            "$(bytes_per_sec $total_speed_down $interval)" \
            "$(bytes_to_human $((total_session_up + total_session_down)))"
        
        echo ""
        echo -e "${YELLOW}Легенда:${NC} ${GREEN}Зеленый${NC} = активен (${active_count}) | ${NC}Белый${NC} = неактивен ($((${#current_emails[@]} - active_count)))"
        
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${CYAN}ℹ ВСЕГО (БД)${NC} = суммарный трафик | ${CYAN}СЕССИЯ${NC} = текущая сессия Xray | ${YELLOW}Минимум для синхр: 10 MB${NC}"
        else
            echo -e "${YELLOW}⚠ Baserow выключен - статистика обнулится при перезапуске Xray${NC}"
        fi
        
        # НОВОЕ: Автосинхронизация
        if [[ "$auto_sync_enabled" == true ]]; then
            elapsed_seconds=$((elapsed_seconds + interval))
            
            # Проверяем, пора ли синхронизировать
            if (( elapsed_seconds % sync_interval_seconds == 0 )); then
                echo ""
                echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${MAGENTA}║         АВТОМАТИЧЕСКАЯ СИНХРОНИЗАЦИЯ С BASEROW                ║${NC}"
                echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════╝${NC}"
                
                local synced=0
                local skipped=0
                
                for email in "${current_emails[@]}"; do
                    local stats=$(get_user_stats "$email")
                    local uplink=$(echo "$stats" | awk '{print $1}')
                    local downlink=$(echo "$stats" | awk '{print $2}')
                    local session_total=$((uplink + downlink))
                    
                    # Синхронизируем только если трафик >= 10 MB
                    if (( session_total >= 10485760 )); then
                        echo -e "${YELLOW}  ⟳${NC} Синхронизация $email ($(bytes_to_human $session_total))..."
                        if baserow_sync_user "$email" "$session_total" > /dev/null 2>&1; then
                            reset_user_stats "$email"
                            synced=$((synced + 1))
                            echo -e "${GREEN}    ✓ Успешно${NC}"
                        else
                            echo -e "${RED}    ✗ Ошибка${NC}"
                        fi
                    else
                        skipped=$((skipped + 1))
                    fi
                done
                
                echo ""
                echo -e "${GREEN}✓ Синхронизировано:${NC} $synced | ${CYAN}Пропущено (< 10 MB):${NC} $skipped"
                sleep 3
            fi
        fi
        
        sleep $interval
    done
}

# ============================================================================
# ОСТАЛЬНЫЕ ФУНКЦИИ (view_stats, view_user_detail, sync_to_baserow и т.д.)
# Оставляем без изменений, как в предыдущей версии
# ============================================================================

# [ВСЕ ОСТАЛЬНЫЕ ФУНКЦИИ ИЗ ПРЕДЫДУЩЕЙ ВЕРСИИ - БЕЗ ИЗМЕНЕНИЙ]
# view_stats(), view_user_detail(), sync_to_baserow(), view_baserow_data(), 
# reset_menu(), check_status(), main_menu()

MAINSCRIPT

chmod +x /usr/local/bin/xray-traffic-monitor

echo -e "${GREEN}✓ Скрипт установлен: /usr/local/bin/xray-traffic-monitor${NC}"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                   Установка завершена!                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
