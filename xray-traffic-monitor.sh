#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.4 - С поддержкой конфигурационного файла
# ============================================================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Пути
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${SCRIPT_DIR}/config.conf"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
BASEROW_CONFIG_FILE="/usr/local/etc/xray/baserow.conf"
SERVER_CONFIG_FILE="/usr/local/etc/xray/server.conf"
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"

# ============================================================================
# ЗАГРУЗКА КОНФИГУРАЦИИ
# ============================================================================

load_config() {
    if [[ -f "$CONFIG_PATH" ]]; then
        source "$CONFIG_PATH"
        echo -e "${GREEN}✓${NC} Конфигурация загружена из: ${CYAN}$CONFIG_PATH${NC}"
        
        # Проверка обязательных параметров
        if [[ -z "$BASEROW_TOKEN" ]] || [[ -z "$BASEROW_TABLE_ID" ]]; then
            echo -e "${RED}✗${NC} Ошибка: не указаны BASEROW_TOKEN или BASEROW_TABLE_ID в конфиге"
            exit 1
        fi
        
        # Устанавливаем значения по умолчанию если не указаны
        REFRESH_INTERVAL=${REFRESH_INTERVAL:-2}
        SYNC_INTERVAL=${SYNC_INTERVAL:-5}
        MIN_SYNC_MB=${MIN_SYNC_MB:-10}
        MIN_SYNC_BYTES=$((MIN_SYNC_MB * 1048576))
        
        echo -e "${CYAN}  → Baserow Table ID:${NC} $BASEROW_TABLE_ID"
        echo -e "${CYAN}  → Интервал обновления:${NC} ${REFRESH_INTERVAL}s"
        echo -e "${CYAN}  → Интервал синхронизации:${NC} ${SYNC_INTERVAL}m"
        echo -e "${CYAN}  → Минимум для синхр:${NC} ${MIN_SYNC_MB}MB"
        echo ""
        return 0
    else
        echo -e "${YELLOW}⚠${NC} Конфиг не найден: $CONFIG_PATH"
        echo -e "${YELLOW}Создаю конфиг по умолчанию...${NC}"
        create_default_config
        load_config
    fi
}

create_default_config() {
    cat > "$CONFIG_PATH" << 'EOF'
# ============================================================================
# Xray Traffic Monitor - Configuration File v3.4
# ============================================================================

# ===== BASEROW SETTINGS =====
BASEROW_TOKEN="zoJjilyrKAVe42EAV57kBOEQGc8izU1t"
BASEROW_TABLE_ID="742631"

# ===== MONITOR SETTINGS =====
REFRESH_INTERVAL=2          # Интервал обновления экрана (секунды)
SYNC_INTERVAL=5             # Интервал автосинхронизации (минуты)
MIN_SYNC_MB=10              # Минимальный трафик для синхронизации (MB)
EOF
    echo -e "${GREEN}✓${NC} Создан конфиг: $CONFIG_PATH"
}

# ============================================================================
# БАЗОВЫЕ ФУНКЦИИ
# ============================================================================

extract_username() {
    local full_name=$1
    if [[ "$full_name" == *"_"* ]]; then
        echo "${full_name%%_*}"
    else
        echo "$full_name"
    fi
}

load_baserow_from_config() {
    # Сохраняем данные из config.conf в baserow.conf для совместимости
    save_baserow_config "$BASEROW_TOKEN" "$BASEROW_TABLE_ID" "true"
}

save_baserow_config() {
    cat > "$BASEROW_CONFIG_FILE" << EOF
BASEROW_TOKEN="$1"
BASEROW_TABLE_ID="$2"
BASEROW_ENABLED="$3"
EOF
    chmod 600 "$BASEROW_CONFIG_FILE"
}

load_server_name() {
    if [[ -f "$SERVER_CONFIG_FILE" ]]; then
        source "$SERVER_CONFIG_FILE"
        return 0
    fi
    return 1
}

save_server_name() {
    cat > "$SERVER_CONFIG_FILE" << EOF
SERVER_NAME="$1"
EOF
    chmod 600 "$SERVER_CONFIG_FILE"
}

clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR v3.4                                ║${NC}"
    echo -e "${BLUE}║       (Multi-server + Автосинхронизация + Фильтр по подписке)            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

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

bytes_to_gb() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "0"
        return
    fi
    printf "%.6f" $(echo "scale=6; $bytes / 1073741824" | bc)
}

gb_to_bytes() {
    local gb=$1
    if [[ -z "$gb" || "$gb" == "0" ]]; then
        echo "0"
        return
    fi
    printf "%.0f" $(echo "$gb * 1073741824" | bc)
}

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
# BASEROW API
# ============================================================================

baserow_get_all_rows() {
    local response=$(curl -s -X GET \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
        -H "Authorization: Token ${BASEROW_TOKEN}" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        echo ""
        return 1
    fi
    echo "$response"
}

baserow_get_user_row() {
    local full_email=$1
    local server=$2
    local username=$(extract_username "$full_email")
    
    local all_rows=$(baserow_get_all_rows)
    if [[ -z "$all_rows" ]]; then
        echo ""
        return
    fi
    echo "$all_rows" | jq -r --arg user "$username" --arg srv "$server" \
        '.results[] | select(.user == $user and .server == $srv)' 2>/dev/null
}

baserow_get_user_gb() {
    local full_email=$1
    local server=$2
    local user_row=$(baserow_get_user_row "$full_email" "$server")
    if [[ -n "$user_row" ]]; then
        local gb=$(echo "$user_row" | jq -r '.GB // "0"' 2>/dev/null)
        gb=$(echo "$gb" | grep -oE '[0-9]+(\.[0-9]+)?')
        echo "${gb:-0}"
    else
        echo "0"
    fi
}

baserow_create_row() {
    local full_email=$1
    local server=$2
    local gb=$3
    local username=$(extract_username "$full_email")
    
    if [[ -z "$gb" ]] || ! [[ "$gb" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 0
    fi
    
    local gb_check=$(echo "$gb > 0" | bc -l 2>/dev/null)
    if [[ "$gb_check" != "1" ]]; then
        return 0
    fi
    
    local response=$(curl -s -X POST \
        "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
        -H "Authorization: Token ${BASEROW_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"user\": \"$username\", \"server\": \"$server\", \"GB\": $gb}" 2>/dev/null)
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

baserow_update_row() {
    local full_email=$1
    local server=$2
    local gb=$3
    local username=$(extract_username "$full_email")
    
    if [[ -z "$gb" ]] || ! [[ "$gb" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 0
    fi
    
    local user_row=$(baserow_get_user_row "$full_email" "$server")
    if [[ -n "$user_row" ]]; then
        local row_id=$(echo "$user_row" | jq -r '.id' 2>/dev/null)
        if [[ -n "$row_id" && "$row_id" != "null" ]]; then
            local response=$(curl -s -X PATCH \
                "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/?user_field_names=true" \
                -H "Authorization: Token ${BASEROW_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"GB\": $gb}" 2>/dev/null)
            
            if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
                return 0
            else
                return 1
            fi
        fi
    else
        baserow_create_row "$full_email" "$server" "$gb"
        return $?
    fi
}

baserow_sync_user() {
    local full_email=$1
    local server=$2
    local current_bytes=$3
    
    if (( current_bytes < MIN_SYNC_BYTES )); then
        local saved_gb=$(baserow_get_user_gb "$full_email" "$server")
        local saved_bytes=$(gb_to_bytes "$saved_gb")
        echo $((saved_bytes + current_bytes))
        return 0
    fi
    
    local saved_gb=$(baserow_get_user_gb "$full_email" "$server")
    local saved_bytes=$(gb_to_bytes "$saved_gb")
    local total_bytes=$((saved_bytes + current_bytes))
    local total_gb=$(bytes_to_gb "$total_bytes")
    
    if baserow_update_row "$full_email" "$server" "$total_gb"; then
        echo "$total_bytes"
        return 0
    else
        echo "$total_bytes"
        return 1
    fi
}

get_total_user_traffic() {
    local full_email=$1
    local server=$2
    local current_bytes=$3
    
    local saved_gb=$(baserow_get_user_gb "$full_email" "$server")
    local saved_bytes=$(gb_to_bytes "$saved_gb")
    echo $((saved_bytes + current_bytes))
}

baserow_delete_user() {
    local full_email=$1
    local server=$2
    local user_row=$(baserow_get_user_row "$full_email" "$server")
    
    if [[ -z "$user_row" ]]; then
        return 1
    fi
    
    local row_id=$(echo "$user_row" | jq -r '.id' 2>/dev/null)
    if [[ -n "$row_id" && "$row_id" != "null" ]]; then
        curl -s -X DELETE \
            "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/${row_id}/" \
            -H "Authorization: Token ${BASEROW_TOKEN}" > /dev/null 2>&1
        return $?
    fi
    return 1
}

# ============================================================================
# АВТОМАТИЧЕСКАЯ НАСТРОЙКА
# ============================================================================

auto_setup() {
    clear_screen
    
    # Проверка и настройка Stats API
    if ! check_stats_api; then
        echo -e "${YELLOW}⚙ Stats API не настроен. Выполняется автоматическая настройка...${NC}"
        echo ""
        
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        
        if ! jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1; then
            jq '. + {"stats": {}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        fi
        
        if ! jq -e '.api' "$XRAY_CONFIG" > /dev/null 2>&1; then
            jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        fi
        
        jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        
        api_exists=$(jq '.inbounds[] | select(.tag == "api")' "$XRAY_CONFIG")
        if [[ -z "$api_exists" ]]; then
            jq --argjson api_inbound '{
                "listen": "127.0.0.1",
                "port": '"$API_PORT"',
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
                "tag": "api"
            }' '.inbounds += [$api_inbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        fi
        
        api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$XRAY_CONFIG" 2>/dev/null)
        if [[ -z "$api_route_exists" ]]; then
            jq --argjson api_rule '{
                "type": "field",
                "inboundTag": ["api"],
                "outboundTag": "api"
            }' '.routing.rules += [$api_rule]' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        fi
        
        api_outbound_exists=$(jq '.outbounds[] | select(.tag == "api")' "$XRAY_CONFIG")
        if [[ -z "$api_outbound_exists" ]]; then
            jq --argjson api_outbound '{
                "protocol": "freedom",
                "tag": "api"
            }' '.outbounds += [$api_outbound]' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        fi
        
        systemctl restart xray
        sleep 3
        
        if systemctl is-active --quiet xray; then
            echo -e "${GREEN}✓${NC} Stats API настроен успешно"
        else
            echo -e "${RED}✗${NC} Ошибка настройки Stats API"
            return 1
        fi
    else
        echo -e "${GREEN}✓${NC} Stats API уже настроен"
    fi
    
    echo ""
    
    # Настройка Baserow из конфига
    echo -e "${YELLOW}⚙ Настройка Baserow из конфига...${NC}"
    load_baserow_from_config
    echo -e "${GREEN}✓${NC} Baserow настроен"
    
    echo ""
    
    # Запрос имени сервера
    if ! load_server_name || [[ -z "$SERVER_NAME" ]]; then
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              НАСТРОЙКА ИМЕНИ СЕРВЕРА                          ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Введите имя этого сервера (например: USA-1, EU-London, Asia-Tokyo):${NC}"
        read -p "> " server_input
        
        if [[ -z "$server_input" ]]; then
            server_input="Server-$(hostname)"
        fi
        
        save_server_name "$server_input"
        load_server_name
        echo -e "${GREEN}✓${NC} Имя сервера сохранено: ${CYAN}$SERVER_NAME${NC}"
    else
        echo -e "${GREEN}✓${NC} Имя сервера: ${CYAN}$SERVER_NAME${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Автоматическая настройка завершена!                  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    sleep 2
}

# ============================================================================
# ПРОВЕРКА ПОДПИСКИ
# ============================================================================

get_user_subscription() {
    local email=$1
    local subscription=$(jq -r --arg email "$email" \
        '.inbounds[0].settings.clients[] | select(.email == $email) | .metadata.subscription // "n/a"' \
        "$XRAY_CONFIG")
    echo "$subscription"
}

has_valid_subscription() {
    local email=$1
    local subscription=$(get_user_subscription "$email")
    if [[ "$subscription" == "n/a" || "$subscription" == "n" || -z "$subscription" ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# XRAY STATS API
# ============================================================================

check_stats_api() {
    if ! jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1; then
        return 1
    fi
    if ! jq -e '.api.services[] | select(. == "StatsService")' "$XRAY_CONFIG" > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

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

reset_user_stats() {
    local email=$1
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>uplink" -reset > /dev/null 2>&1
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>downlink" -reset > /dev/null 2>&1
}

reset_all_stats() {
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null))
    for email in "${emails[@]}"; do
        reset_user_stats "$email"
    done
}

# ============================================================================
# СИНХРОНИЗАЦИЯ ВСЕХ ПОЛЬЗОВАТЕЛЕЙ
# ============================================================================

sync_all_users() {
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null))
    local synced=0
    local skipped=0
    
    for email in "${emails[@]}"; do
        if ! has_valid_subscription "$email"; then
            continue
        fi
        
        local stats=$(get_user_stats "$email")
        local uplink=$(echo "$stats" | awk '{print $1}')
        local downlink=$(echo "$stats" | awk '{print $2}')
        local session_total=$((uplink + downlink))
        
        if (( session_total > 0 )); then
            if baserow_sync_user "$email" "$SERVER_NAME" "$session_total" > /dev/null 2>&1; then
                reset_user_stats "$email"
                synced=$((synced + 1))
            fi
        else
            skipped=$((skipped + 1))
        fi
    done
    
    echo -e "${GREEN}✓${NC} Синхронизировано: $synced | Пропущено: $skipped"
}

cleanup_and_sync() {
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║     Завершение работы - синхронизация данных с Baserow        ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    
    load_server_name
    sync_all_users
    
    echo ""
    echo -e "${GREEN}До свидания!${NC}"
}

trap cleanup_and_sync EXIT INT TERM

# ============================================================================
# МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ
# ============================================================================

realtime_monitor_auto() {
    if ! check_stats_api; then
        echo -e "${RED}✗ Stats API не настроен!${NC}"
        return 1
    fi
    
    load_server_name
    
    local interval=$REFRESH_INTERVAL
    local sync_interval_minutes=$SYNC_INTERVAL
    local sync_interval_seconds=$((sync_interval_minutes * 60))
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          АВТОМАТИЧЕСКИЙ РЕЖИМ МОНИТОРИНГА                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} Интервал обновления: ${interval}s"
    echo -e "${GREEN}✓${NC} Автосинхронизация: каждые ${sync_interval_minutes} минут"
    echo -e "${GREEN}✓${NC} Минимум для синхр: ${MIN_SYNC_MB} MB"
    echo -e "${GREEN}✓${NC} Сервер: ${CYAN}$SERVER_NAME${NC}"
    echo ""
    sleep 2
    
    declare -A prev_uplink
    declare -A prev_downlink
    
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null))
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        prev_uplink[$email]=$(echo "$stats" | awk '{print $1}')
        prev_downlink[$email]=$(echo "$stats" | awk '{print $2}')
    done
    
    local elapsed_seconds=0
    
    while true; do
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null))
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (Обновление: ${interval}s) | Сервер: ${SERVER_NAME}                    ║${NC}"
        local next_sync_in=$(( sync_interval_seconds - (elapsed_seconds % sync_interval_seconds) ))
        echo -e "${BLUE}║      ${GREEN}✓ Baserow активен${BLUE} | Автосинхронизация: каждые ${sync_interval_minutes}м | След. синхр. через: ${next_sync_in}с           ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Время:${NC} $(date '+%Y-%m-%d %H:%M:%S')    ${YELLOW}Всего:${NC} ${#current_emails[@]}    ${YELLOW}systemctl stop xray-monitor = остановка${NC}"
        echo ""
        
        printf "${CYAN}%-25s %10s %15s %15s %15s %15s %15s %15s${NC}\n" \
            "ПОЛЬЗОВАТЕЛЬ (→БД)" "ПОДПИСКА" "СЕССИЯ ↑" "СЕССИЯ ↓" "ВСЕГО (БД)" "СКОРОСТЬ ↑" "СКОРОСТЬ ↓" "ИТОГО"
        echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
        
        local total_session_up=0
        local total_session_down=0
        local total_speed_up=0
        local total_speed_down=0
        local total_all_traffic=0
        local active_count=0
        
        for email in "${current_emails[@]}"; do
            local stats=$(get_user_stats "$email")
            local uplink=$(echo "$stats" | awk '{print $1}')
            local downlink=$(echo "$stats" | awk '{print $2}')
            local subscription=$(get_user_subscription "$email")
            local db_name=$(extract_username "$email")
            
            local display_name="$email"
            if [[ "$email" == *"_"* ]]; then
                display_name="$email → $db_name"
            fi
            
            if [[ -z "${prev_uplink[$email]}" ]]; then
                prev_uplink[$email]=0
            fi
            if [[ -z "${prev_downlink[$email]}" ]]; then
                prev_downlink[$email]=0
            fi
            
            local speed_up=$((uplink - prev_uplink[$email]))
            local speed_down=$((downlink - prev_downlink[$email]))
            
            if (( speed_up < 0 )); then speed_up=0; fi
            if (( speed_down < 0 )); then speed_down=0; fi
            
            local session_total=$((uplink + downlink))
            local total_traffic=$(get_total_user_traffic "$email" "$SERVER_NAME" "$session_total")
            
            total_session_up=$((total_session_up + uplink))
            total_session_down=$((total_session_down + downlink))
            total_speed_up=$((total_speed_up + speed_up))
            total_speed_down=$((total_speed_down + speed_down))
            total_all_traffic=$((total_all_traffic + total_traffic))
            
            local color=$NC
            if (( speed_up > 0 || speed_down > 0 )); then
                color=$GREEN
                active_count=$((active_count + 1))
            fi
            
            printf "${color}%-25s %10s %15s %15s %15s %15s %15s %15s${NC}\n" \
                "$display_name" \
                "$subscription" \
                "$(bytes_to_human $uplink)" \
                "$(bytes_to_human $downlink)" \
                "$(bytes_to_human $total_traffic)" \
                "$(bytes_per_sec $speed_up $interval)" \
                "$(bytes_per_sec $speed_down $interval)" \
                "$(bytes_to_human $session_total)"
            
            prev_uplink[$email]=$uplink
            prev_downlink[$email]=$downlink
        done
        
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
        
        echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
        printf "${WHITE}%-25s %10s %15s %15s %15s %15s %15s %15s${NC}\n" \
            "ИТОГО:" \
            "" \
            "$(bytes_to_human $total_session_up)" \
            "$(bytes_to_human $total_session_down)" \
            "$(bytes_to_human $total_all_traffic)" \
            "$(bytes_per_sec $total_speed_up $interval)" \
            "$(bytes_per_sec $total_speed_down $interval)" \
            "$(bytes_to_human $((total_session_up + total_session_down)))"
        
        echo ""
        echo -e "${YELLOW}Легенда:${NC} ${GREEN}Зеленый${NC} = активен (${active_count}) | ${NC}Белый${NC} = неактивен ($((${#current_emails[@]} - active_count)))"
        echo -e "${CYAN}ℹ ВСЕГО (БД)${NC} = суммарный трафик | ${CYAN}→${NC} = имя в БД (всё до _) | ${RED}Подписка n/a = не синхронизируется${NC}"
        
        elapsed_seconds=$((elapsed_seconds + interval))
        
        if (( elapsed_seconds % sync_interval_seconds == 0 )); then
            echo ""
            echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${MAGENTA}║         АВТОМАТИЧЕСКАЯ СИНХРОНИЗАЦИЯ С BASEROW                ║${NC}"
            echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════╝${NC}"
            
            local synced=0
            local skipped=0
            local errors=0
            local no_subscription=0
            
            for email in "${current_emails[@]}"; do
                if ! has_valid_subscription "$email"; then
                    no_subscription=$((no_subscription + 1))
                    continue
                fi
                
                local stats=$(get_user_stats "$email")
                local uplink=$(echo "$stats" | awk '{print $1}')
                local downlink=$(echo "$stats" | awk '{print $2}')
                local session_total=$((uplink + downlink))
                local db_name=$(extract_username "$email")
                
                if (( session_total >= MIN_SYNC_BYTES )); then
                    echo -e "${YELLOW}  ⟳${NC} Синхронизация $email → ${CYAN}$db_name${NC} ($(bytes_to_human $session_total))..."
                    
                    if baserow_sync_user "$email" "$SERVER_NAME" "$session_total" > /dev/null 2>&1; then
                        reset_user_stats "$email"
                        synced=$((synced + 1))
                        echo -e "${GREEN}    ✓ Успешно${NC}"
                        
                        prev_uplink[$email]=0
                        prev_downlink[$email]=0
                    else
                        echo -e "${RED}    ✗ Ошибка${NC}"
                        errors=$((errors + 1))
                    fi
                else
                    skipped=$((skipped + 1))
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ Синхронизировано:${NC} $synced | ${CYAN}Пропущено (< ${MIN_SYNC_MB} MB):${NC} $skipped | ${RED}Без подписки:${NC} $no_subscription"
            if (( errors > 0 )); then
                echo -e "${RED}✗ Ошибок:${NC} $errors"
            fi
            sleep 3
        fi
        
        sleep $interval
    done
}

# ============================================================================
# ЗАПУСК
# ============================================================================

if [[ ! -f "$XRAY_CONFIG" ]]; then
    clear_screen
    echo -e "${RED}✗ Конфиг Xray не найден: $XRAY_CONFIG${NC}"
    exit 1
fi

# Загружаем конфигурацию
load_config

# Автоматическая настройка
auto_setup

# Запуск мониторинга
realtime_monitor_auto
