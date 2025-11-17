#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.0 - С персистентным хранением в Baserow
# Новое: статистика сохраняется между перезапусками Xray
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
echo -e "${BLUE}║         Установка Xray Traffic Monitor v3.0                   ║${NC}"
echo -e "${BLUE}║           (с поддержкой Baserow для статистики)               ║${NC}"
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
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR - Real-time v3.0                    ║${NC}"
    echo -e "${BLUE}║              (Персистентное хранение статистики в Baserow)                ║${NC}"
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
    echo "scale=2; $bytes / 1073741824" | bc
}

# Конвертация GB в байты
gb_to_bytes() {
    local gb=$1
    echo "scale=0; $gb * 1073741824 / 1" | bc
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
    
    echo "$all_rows" | jq -r --arg user "$username" '.results[] | select(.user == $user)'
}

# Получить GB пользователя из Baserow
baserow_get_user_gb() {
    local username=$1
    local user_row=$(baserow_get_user_row "$username")
    
    if [[ -n "$user_row" ]]; then
        echo "$user_row" | jq -r '.GB // "0"'
    else
        echo "0"
    fi
}

# Создать новую запись
baserow_create_row() {
    local username=$1
    local gb=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    curl -s -X POST \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
        -H "Authorization: Token ${BASEROW_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"user\": \"$username\", \"GB\": $gb}" > /dev/null
}

# Обновить существующую запись
baserow_update_row() {
    local username=$1
    local gb=$2
    local user_row=$(baserow_get_user_row "$username")
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    if [[ -n "$user_row" ]]; then
        local row_id=$(echo "$user_row" | jq -r '.id')
        curl -s -X PATCH \
            "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/?user_field_names=true" \
            -H "Authorization: Token ${BASEROW_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"GB\": $gb}" > /dev/null
    else
        baserow_create_row "$username" "$gb"
    fi
}

# Синхронизировать трафик пользователя с Baserow
baserow_sync_user() {
    local username=$1
    local current_bytes=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
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
    
    local row_id=$(echo "$user_row" | jq -r '.id')
    curl -s -X DELETE \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/" \
        -H "Authorization: Token ${BASEROW_TOKEN}" > /dev/null
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
        echo "$test_response" | jq '.'
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
# МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ
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
    echo -e "${CYAN}Установите интервал обновления (в секундах, по умолчанию 2):${NC}"
    read -p "> " interval
    interval=${interval:-2}
    
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        interval=2
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
    
    while true; do
        # Обновляем список активных пользователей на каждой итерации
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                     МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (Обновление: ${interval}s)                                   ║${NC}"
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${BLUE}║                     ${GREEN}✓ Baserow активен${BLUE} - статистика сохраняется между перезапусками                    ║${NC}"
        else
            echo -e "${BLUE}║                     ${YELLOW}⚠ Baserow выключен${BLUE} - статистика НЕ сохраняется                                     ║${NC}"
        fi
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Время:${NC} $(date '+%Y-%m-%d %H:%M:%S')    ${YELLOW}Активных пользователей:${NC} ${#current_emails[@]}    ${YELLOW}Нажмите Ctrl+C для выхода${NC}"
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
        echo -e "${YELLOW}Легенда:${NC} ${GREEN}Зеленый${NC} = активное соединение (${active_count}) | ${NC}Белый${NC} = неактивен ($((${#current_emails[@]} - active_count)))"
        
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${CYAN}ℹ ВСЕГО (БД)${NC} = суммарный трафик (включая предыдущие сессии) | ${CYAN}СЕССИЯ${NC} = текущая сессия Xray"
        else
            echo -e "${YELLOW}⚠ Baserow выключен - статистика обнулится при перезапуске Xray${NC}"
        fi
        
        sleep $interval
    done
}

# ============================================================================
# ПРОСМОТР СТАТИСТИКИ
# ============================================================================

view_stats() {
    if ! check_stats_api; then
        clear_screen
        echo -e "${RED}✗ Stats API не настроен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    load_baserow_config
    
    clear_screen
    echo -e "${CYAN}ОБЩАЯ СТАТИСТИКА (Только активные пользователи)${NC}"
    echo ""
    
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    if [[ ${#emails[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Список пользователей пуст${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        printf "${CYAN}%-20s %15s %15s %15s %20s %15s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "СЕССИЯ ↑" "СЕССИЯ ↓" "СЕССИЯ ВСЕГО" "ВСЕГО (с БД)" "СОХРАНЕНО В БД"
    else
        printf "${CYAN}%-20s %15s %15s %15s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "ОТПРАВЛЕНО ↑" "ПОЛУЧЕНО ↓" "ВСЕГО"
    fi
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    local total_session_up=0
    local total_session_down=0
    local total_all=0
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        local uplink=$(echo "$stats" | awk '{print $1}')
        local downlink=$(echo "$stats" | awk '{print $2}')
        local session_total=$((uplink + downlink))
        
        total_session_up=$((total_session_up + uplink))
        total_session_down=$((total_session_down + downlink))
        
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            local total_traffic=$(get_total_user_traffic "$email" "$session_total")
            local saved_gb=$(baserow_get_user_gb "$email")
            total_all=$((total_all + total_traffic))
            
            printf "%-20s %15s %15s %15s %20s %15s GB\n" \
                "$email" \
                "$(bytes_to_human $uplink)" \
                "$(bytes_to_human $downlink)" \
                "$(bytes_to_human $session_total)" \
                "$(bytes_to_human $total_traffic)" \
                "$saved_gb"
        else
            total_all=$((total_all + session_total))
            printf "%-20s %15s %15s %15s\n" \
                "$email" \
                "$(bytes_to_human $uplink)" \
                "$(bytes_to_human $downlink)" \
                "$(bytes_to_human $session_total)"
        fi
    done
    
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        printf "${GREEN}%-20s %15s %15s %15s %20s${NC}\n" \
            "ИТОГО:" \
            "$(bytes_to_human $total_session_up)" \
            "$(bytes_to_human $total_session_down)" \
            "$(bytes_to_human $((total_session_up + total_session_down)))" \
            "$(bytes_to_human $total_all)"
    else
        printf "${GREEN}%-20s %15s %15s %15s${NC}\n" \
            "ИТОГО:" \
            "$(bytes_to_human $total_session_up)" \
            "$(bytes_to_human $total_session_down)" \
            "$(bytes_to_human $total_all)"
    fi
    
    echo ""
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        echo -e "${CYAN}ℹ Статистика текущей сессии + сохраненная в Baserow${NC}"
    else
        echo -e "${YELLOW}⚠ Baserow выключен - статистика обнулится при перезапуске Xray${NC}"
    fi
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Детали пользователя
view_user_detail() {
    if ! check_stats_api; then
        clear_screen
        echo -e "${RED}✗ Stats API не настроен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    load_baserow_config
    
    clear_screen
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    if [[ ${#emails[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Список пользователей пуст${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    echo -e "${CYAN}ВЫБЕРИТЕ ПОЛЬЗОВАТЕЛЯ (Только активные):${NC}"
    echo ""
    for i in "${!emails[@]}"; do
        echo "  $((i+1)). ${emails[$i]}"
    done
    echo ""
    read -p "Введите номер (или 0 для отмены): " choice
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
        echo -e "${RED}✗ Неверный выбор${NC}"
        sleep 2
        return
    fi
    
    local selected_email="${emails[$((choice - 1))]}"
    local stats=$(get_user_stats "$selected_email")
    local uplink=$(echo "$stats" | awk '{print $1}')
    local downlink=$(echo "$stats" | awk '{print $2}')
    local session_total=$((uplink + downlink))
    
    local uuid=$(jq -r --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' "$CONFIG_FILE")
    local subscription=$(jq -r --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email) | .metadata.subscription // "n/a"' "$CONFIG_FILE")
    local created_date=$(jq -r --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email) | .metadata.created_date // "n/a"' "$CONFIG_FILE")
    
    clear_screen
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О ПОЛЬЗОВАТЕЛЕ              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Пользователь:${NC}    $selected_email"
    echo -e "${CYAN}UUID:${NC}            $uuid"
    echo -e "${CYAN}Подписка:${NC}        $subscription"
    echo -e "${CYAN}Дата создания:${NC}   $created_date"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}Трафик текущей сессии Xray:${NC}"
    echo -e "  ↑ Отправлено:     $(bytes_to_human $uplink)"
    echo -e "  ↓ Получено:       $(bytes_to_human $downlink)"
    echo -e "  ${CYAN}Σ Всего:${NC}          ${GREEN}$(bytes_to_human $session_total)${NC}"
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        echo ""
        local saved_gb=$(baserow_get_user_gb "$selected_email")
        local saved_bytes=$(gb_to_bytes "$saved_gb")
        local total_traffic=$((saved_bytes + session_total))
        
        echo -e "${CYAN}Данные из Baserow:${NC}"
        echo -e "  Сохранено:        ${saved_gb} GB ($(bytes_to_human $saved_bytes))"
        echo ""
        echo -e "${MAGENTA}ИТОГО за всё время:${NC}"
        echo -e "  ${MAGENTA}Σ Общий трафик:${NC}   ${GREEN}$(bytes_to_human $total_traffic)${NC} ($(bytes_to_gb $total_traffic) GB)"
    else
        echo ""
        echo -e "${YELLOW}⚠ Baserow выключен - показана только текущая сессия${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# ============================================================================
# СИНХРОНИЗАЦИЯ С BASEROW
# ============================================================================

sync_to_baserow() {
    if ! load_baserow_config || [[ "$BASEROW_ENABLED" != "true" ]]; then
        clear_screen
        echo -e "${RED}✗ Baserow не настроен или выключен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    clear_screen
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           СИНХРОНИЗАЦИЯ ТРАФИКА С BASEROW                     ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    if [[ ${#emails[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Список пользователей пуст${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    echo -e "${CYAN}Синхронизация данных трафика с Baserow...${NC}"
    echo ""
    
    local synced_count=0
    local error_count=0
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        local uplink=$(echo "$stats" | awk '{print $1}')
        local downlink=$(echo "$stats" | awk '{print $2}')
        local session_total=$((uplink + downlink))
        
        if (( session_total > 0 )); then
            echo -e "${YELLOW}⟳${NC} Синхронизация $email..."
            
            if baserow_sync_user "$email" "$session_total" > /dev/null; then
                echo -e "${GREEN}  ✓${NC} Успешно ($(bytes_to_human $session_total))"
                synced_count=$((synced_count + 1))
                
                # Сбрасываем статистику после успешной синхронизации
                reset_user_stats "$email"
            else
                echo -e "${RED}  ✗${NC} Ошибка синхронизации"
                error_count=$((error_count + 1))
            fi
        else
            echo -e "${CYAN}⊘${NC} Пропуск $email (нет трафика)"
        fi
    done
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Синхронизация завершена!                         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Синхронизировано:${NC} $synced_count пользователей"
    if (( error_count > 0 )); then
        echo -e "${RED}Ошибок:${NC} $error_count"
    fi
    echo ""
    echo -e "${YELLOW}ℹ Статистика Xray сброшена для синхронизированных пользователей${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Просмотр данных Baserow
view_baserow_data() {
    if ! load_baserow_config || [[ "$BASEROW_ENABLED" != "true" ]]; then
        clear_screen
        echo -e "${RED}✗ Baserow не настроен или выключен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    clear_screen
    echo -e "${CYAN}ДАННЫЕ BASEROW (Traffic Table)${NC}"
    echo ""
    
    local response=$(baserow_get_all_rows)
    
    if ! echo "$response" | jq -e '.results' > /dev/null 2>&1; then
        echo -e "${RED}✗ Ошибка получения данных из Baserow${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    printf "${CYAN}%-25s %15s %20s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "GB" "БАЙТЫ"
    echo "──────────────────────────────────────────────────────────────────"
    
    local total_gb=0
    
    while IFS= read -r row; do
        local user=$(echo "$row" | jq -r '.user')
        local gb=$(echo "$row" | jq -r '.GB // "0"')
        local bytes=$(gb_to_bytes "$gb")
        
        total_gb=$(echo "$total_gb + $gb" | bc)
        
        printf "%-25s %15s %20s\n" \
            "$user" \
            "$gb GB" \
            "$(bytes_to_human $bytes)"
    done < <(echo "$response" | jq -c '.results[]')
    
    echo "──────────────────────────────────────────────────────────────────"
    printf "${GREEN}%-25s %15s${NC}\n" "ИТОГО:" "${total_gb} GB"
    
    echo ""
    echo -e "${CYAN}ℹ Данные напрямую из Baserow${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Меню сброса статистики
reset_menu() {
    clear_screen
    echo -e "${CYAN}СБРОС СТАТИСТИКИ${NC}"
    echo ""
    echo "  1. Сбросить статистику всех пользователей (только Xray)"
    echo "  2. Сбросить статистику конкретного пользователя (только Xray)"
    echo "  3. Удалить данные пользователя из Baserow"
    echo "  4. Очистить всю таблицу Baserow"
    echo "  0. Назад"
    echo ""
    read -p "Выберите опцию: " choice
    
    case $choice in
        1)
            read -p "Вы уверены? Это сбросит статистику ВСЕХ пользователей в Xray (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                reset_all_stats
                echo -e "${GREEN}✓ Статистика Xray всех пользователей сброшена${NC}"
                sleep 2
            fi
            ;;
        2)
            local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
            clear_screen
            echo -e "${CYAN}ВЫБЕРИТЕ ПОЛЬЗОВАТЕЛЯ:${NC}"
            echo ""
            for i in "${!emails[@]}"; do
                echo "  $((i+1)). ${emails[$i]}"
            done
            echo ""
            read -p "Введите номер (или 0 для отмены): " user_choice
            
            if [[ "$user_choice" != "0" ]] && [[ "$user_choice" =~ ^[0-9]+$ ]] && (( user_choice >= 1 && user_choice <= ${#emails[@]} )); then
                local selected_email="${emails[$((user_choice - 1))]}"
                reset_user_stats "$selected_email"
                echo -e "${GREEN}✓ Статистика Xray пользователя '$selected_email' сброшена${NC}"
                sleep 2
            fi
            ;;
        3)
            if ! load_baserow_config || [[ "$BASEROW_ENABLED" != "true" ]]; then
                echo -e "${RED}✗ Baserow не настроен!${NC}"
                sleep 2
                return
            fi
            
            local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
            clear_screen
            echo -e "${CYAN}ВЫБЕРИТЕ ПОЛЬЗОВАТЕЛЯ ДЛЯ УДАЛЕНИЯ ИЗ BASEROW:${NC}"
            echo ""
            for i in "${!emails[@]}"; do
                echo "  $((i+1)). ${emails[$i]}"
            done
            echo ""
            read -p "Введите номер (или 0 для отмены): " user_choice
            
            if [[ "$user_choice" != "0" ]] && [[ "$user_choice" =~ ^[0-9]+$ ]] && (( user_choice >= 1 && user_choice <= ${#emails[@]} )); then
                local selected_email="${emails[$((user_choice - 1))]}"
                read -p "Удалить данные '$selected_email' из Baserow? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    if baserow_delete_user "$selected_email"; then
                        echo -e "${GREEN}✓ Данные пользователя '$selected_email' удалены из Baserow${NC}"
                    else
                        echo -e "${RED}✗ Ошибка удаления или пользователь не найден в Baserow${NC}"
                    fi
                    sleep 2
                fi
            fi
            ;;
        4)
            if ! load_baserow_config || [[ "$BASEROW_ENABLED" != "true" ]]; then
                echo -e "${RED}✗ Baserow не настроен!${NC}"
                sleep 2
                return
            fi
            
            read -p "ВНИМАНИЕ! Это удалит ВСЕ данные из таблицы Baserow! Продолжить? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                read -p "Последнее предупреждение! Вы уверены? (yes/no): " final_confirm
                if [[ "$final_confirm" == "yes" ]]; then
                    local response=$(baserow_get_all_rows)
                    local deleted_count=0
                    
                    while IFS= read -r row; do
                        local row_id=$(echo "$row" | jq -r '.id')
                        curl -s -X DELETE \
                            "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/" \
                            -H "Authorization: Token ${BASEROW_TOKEN}" > /dev/null
                        deleted_count=$((deleted_count + 1))
                    done < <(echo "$response" | jq -c '.results[]')
                    
                    echo -e "${GREEN}✓ Удалено $deleted_count записей из Baserow${NC}"
                    sleep 3
                fi
            fi
            ;;
        0)
            return
            ;;
    esac
}

# Проверка статуса
check_status() {
    clear_screen
    echo -e "${CYAN}ПРОВЕРКА СИСТЕМЫ${NC}"
    echo ""
    
    # Xray Stats API
    if check_stats_api; then
        echo -e "${GREEN}✓${NC} Stats API настроен в конфигурации"
    else
        echo -e "${RED}✗${NC} Stats API не настроен в конфигурации"
    fi
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓${NC} Xray работает"
    else
        echo -e "${RED}✗${NC} Xray не запущен"
    fi
    
    if ss -tlnp 2>/dev/null | grep -q ":$API_PORT"; then
        echo -e "${GREEN}✓${NC} API порт $API_PORT открыт"
    else
        echo -e "${RED}✗${NC} API порт $API_PORT не открыт"
    fi
    
    if xray api statsquery --server="$API_SERVER" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} API отвечает на запросы"
    else
        echo -e "${RED}✗${NC} API не отвечает на запросы"
    fi
    
    echo ""
    
    # Baserow
    if load_baserow_config; then
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${GREEN}✓${NC} Baserow настроен и включен"
            
            # Проверяем подключение
            local test_response=$(curl -s -X GET \
                "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true&size=1" \
                -H "Authorization: Token ${BASEROW_TOKEN}")
            
            if echo "$test_response" | jq -e '.results' > /dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} Подключение к Baserow работает"
                local row_count=$(curl -s -X GET \
                    "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
                    -H "Authorization: Token ${BASEROW_TOKEN}" | jq '.count')
                echo -e "${CYAN}  Записей в Baserow:${NC} $row_count"
            else
                echo -e "${RED}✗${NC} Ошибка подключения к Baserow"
            fi
        else
            echo -e "${YELLOW}⚠${NC} Baserow настроен, но выключен"
        fi
    else
        echo -e "${RED}✗${NC} Baserow не настроен"
    fi
    
    echo ""
    
    # Пользователи
    local user_count=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${CYAN}Активных пользователей в config.json:${NC} $user_count"
    
    # Версия Xray
    local xray_version=$(xray version 2>/dev/null | head -1)
    echo -e "${CYAN}Версия Xray:${NC} $xray_version"
    
    echo ""
    echo -e "${YELLOW}ℹ  Статистика Xray хранится в RAM и обнуляется при перезапуске${NC}"
    if load_baserow_config && [[ "$BASEROW_ENABLED" == "true" ]]; then
        echo -e "${GREEN}✓  Baserow сохраняет историю трафика между перезапусками${NC}"
    fi
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Главное меню
main_menu() {
    # Загружаем конфиг при старте
    load_baserow_config
    
    while true; do
        clear_screen
        
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${GREEN}● Baserow активен${NC}"
        else
            echo -e "${YELLOW}○ Baserow выключен${NC}"
        fi
        echo ""
        echo -e "${CYAN}ГЛАВНОЕ МЕНЮ${NC}"
        echo ""
        echo -e "${BLUE}═══ Мониторинг ═══${NC}"
        echo "  ${GREEN}1.${NC} Мониторинг в реальном времени"
        echo "  ${GREEN}2.${NC} Просмотр общей статистики"
        echo "  ${GREEN}3.${NC} Детали по пользователю"
        echo ""
        echo -e "${BLUE}═══ Baserow ═══${NC}"
        echo "  ${GREEN}4.${NC} Синхронизировать трафик с Baserow"
        echo "  ${GREEN}5.${NC} Просмотр данных Baserow"
        echo "  ${GREEN}6.${NC} Настроить Baserow"
        
        if load_baserow_config && [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo "  ${YELLOW}7.${NC} Отключить Baserow"
        else
            echo "  ${GREEN}7.${NC} Включить Baserow"
        fi
        
        echo ""
        echo -e "${BLUE}═══ Настройки ═══${NC}"
        echo "  ${GREEN}8.${NC} Сброс/удаление статистики"
        echo "  ${GREEN}9.${NC} Настроить Stats API"
        echo "  ${GREEN}10.${NC} Проверка системы"
        echo ""
        echo "  ${GREEN}0.${NC} Выход"
        echo ""
        read -p "Выберите опцию: " choice
        
        case $choice in
            1) realtime_monitor ;;
            2) view_stats ;;
            3) view_user_detail ;;
            4) sync_to_baserow ;;
            5) view_baserow_data ;;
            6) setup_baserow ;;
            7) 
                if load_baserow_config && [[ "$BASEROW_ENABLED" == "true" ]]; then
                    disable_baserow
                else
                    enable_baserow
                fi
                ;;
            8) reset_menu ;;
            9) setup_stats_api ;;
            10) check_status ;;
            0) 
                clear
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}✗ Неверный выбор${NC}"
                sleep 1
                ;;
        esac
    done
}

# Запуск
if [[ ! -f "$CONFIG_FILE" ]]; then
    clear_screen
    echo -e "${RED}✗ Конфиг Xray не найден: $CONFIG_FILE${NC}"
    exit 1
fi

main_menu
MAINSCRIPT

chmod +x /usr/local/bin/xray-traffic-monitor

echo -e "${GREEN}✓ Скрипт установлен: /usr/local/bin/xray-traffic-monitor${NC}"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                   Установка завершена!                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Запуск:${NC}"
echo -e "  ${GREEN}xray-traffic-monitor${NC}"
echo ""
echo -e "${YELLOW}Новое в v3.0:${NC}"
echo -e "  ${GREEN}✅ Интеграция с Baserow${NC} - статистика сохраняется между перезапусками"
echo -e "  ${GREEN}✅ Автоматическая синхронизация${NC} трафика с базой данных"
echo -e "  ${GREEN}✅ Отображение суммарного трафика${NC} (текущая сессия + история)"
echo -e "  ${GREEN}✅ Управление данными${NC} в Baserow через меню"
echo -e "  ℹ️  Статистика Xray обнуляется при restart, но сохраняется в Baserow"
echo ""
echo -e "${YELLOW}Первый запуск:${NC}"
echo -e "  1. Запустите скрипт"
echo -e "  2. Выберите опцию ${GREEN}9${NC} для настройки Stats API (если ещё не настроено)"
echo -e "  3. Выберите опцию ${GREEN}6${NC} для настройки Baserow"
echo -e "  4. Используйте опцию ${GREEN}1${NC} для мониторинга в реальном времени"
echo -e "  5. Используйте опцию ${GREEN}4${NC} для синхронизации данных с Baserow"
echo ""
