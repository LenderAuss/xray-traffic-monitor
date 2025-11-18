#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.3 - АВТОМАТИЧЕСКИЙ РЕЖИМ
# С поддержкой multi-server и фильтрацией по подписке
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

CONFIG_FILE="/usr/local/etc/xray/config.json"
BASEROW_CONFIG="/usr/local/etc/xray/baserow.conf"
SERVER_CONFIG="/usr/local/etc/xray/server.conf"
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"
REFRESH_INTERVAL=2
MIN_SYNC_BYTES=10485760  # 10 MB минимум для синхронизации

# Встроенные настройки Baserow (можно изменить)
DEFAULT_BASEROW_TOKEN="zoJjilyrKAVe42EAV57kBOEQGc8izU1t"
DEFAULT_BASEROW_TABLE_ID="742631"

# ============================================================================
# БАЗОВЫЕ ФУНКЦИИ
# ============================================================================

# Функция извлечения имени пользователя (всё до первого _)
extract_username() {
    local full_name=$1
    if [[ "$full_name" == *"_"* ]]; then
        echo "${full_name%%_*}"
    else
        echo "$full_name"
    fi
}

load_baserow_config() {
    if [[ -f "$BASEROW_CONFIG" ]]; then
        source "$BASEROW_CONFIG"
        return 0
    fi
    return 1
}

save_baserow_config() {
    cat > "$BASEROW_CONFIG" << EOF
BASEROW_TOKEN="$1"
BASEROW_TABLE_ID="$2"
BASEROW_ENABLED="$3"
EOF
    chmod 600 "$BASEROW_CONFIG"
}

load_server_name() {
    if [[ -f "$SERVER_CONFIG" ]]; then
        source "$SERVER_CONFIG"
        return 0
    fi
    return 1
}

save_server_name() {
    cat > "$SERVER_CONFIG" << EOF
SERVER_NAME="$1"
EOF
    chmod 600 "$SERVER_CONFIG"
}

clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR - Real-time v3.3                    ║${NC}"
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
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
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
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
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
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
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
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        echo "$current_bytes"
        return 1
    fi
    
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
    
    if [[ "$BASEROW_ENABLED" == "true" ]]; then
        local saved_gb=$(baserow_get_user_gb "$full_email" "$server")
        local saved_bytes=$(gb_to_bytes "$saved_gb")
        echo $((saved_bytes + current_bytes))
    else
        echo "$current_bytes"
    fi
}

baserow_delete_user() {
    local full_email=$1
    local server=$2
    local user_row=$(baserow_get_user_row "$full_email" "$server")
    
    if [[ "$BASEROW_ENABLED" != "true" ]] || [[ -z "$user_row" ]]; then
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
        
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        
        if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
            jq '. + {"stats": {}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        fi
        
        if ! jq -e '.api' "$CONFIG_FILE" > /dev/null 2>&1; then
            jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        fi
        
        jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        
        api_exists=$(jq '.inbounds[] | select(.tag == "api")' "$CONFIG_FILE")
        if [[ -z "$api_exists" ]]; then
            jq --argjson api_inbound '{
                "listen": "127.0.0.1",
                "port": '"$API_PORT"',
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
                "tag": "api"
            }' '.inbounds += [$api_inbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        fi
        
        api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$CONFIG_FILE" 2>/dev/null)
        if [[ -z "$api_route_exists" ]]; then
            jq --argjson api_rule '{
                "type": "field",
                "inboundTag": ["api"],
                "outboundTag": "api"
            }' '.routing.rules += [$api_rule]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        fi
        
        api_outbound_exists=$(jq '.outbounds[] | select(.tag == "api")' "$CONFIG_FILE")
        if [[ -z "$api_outbound_exists" ]]; then
            jq --argjson api_outbound '{
                "protocol": "freedom",
                "tag": "api"
            }' '.outbounds += [$api_outbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
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
    
    # Настройка Baserow
    if ! load_baserow_config || [[ "$BASEROW_ENABLED" != "true" ]]; then
        echo -e "${YELLOW}⚙ Настройка Baserow...${NC}"
        save_baserow_config "$DEFAULT_BASEROW_TOKEN" "$DEFAULT_BASEROW_TABLE_ID" "true"
        load_baserow_config
        echo -e "${GREEN}✓${NC} Baserow настроен"
    else
        echo -e "${GREEN}✓${NC} Baserow уже настроен"
    fi
    
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
        "$CONFIG_FILE")
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
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        return 1
    fi
    if ! jq -e '.api.services[] | select(. == "StatsService")' "$CONFIG_FILE" > /dev/null 2>&1; then
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
        return 1
    fi
    
    load_baserow_config
    load_server_name
    
    clear_screen
    echo -e "${CYAN}Установите интервал обновления экрана (в секундах, по умолчанию 2):${NC}"
    read -p "> " interval
    interval=${interval:-2}
    
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        interval=2
    fi
    
    local auto_sync_enabled=false
    local sync_interval_minutes=0
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
                echo -e "${YELLOW}ℹ Пользователи без подписки (n/a) не синхронизируются${NC}"
                echo -e "${CYAN}ℹ Формат имени: 123456_uk → записывается как '123456'${NC}"
                sleep 3
            else
                echo -e "${YELLOW}⚠ Некорректный интервал, автосинхронизация отключена${NC}"
                sleep 2
            fi
        fi
    fi
    
    declare -A prev_uplink
    declare -A prev_downlink
    
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        prev_uplink[$email]=$(echo "$stats" | awk '{print $1}')
        prev_downlink[$email]=$(echo "$stats" | awk '{print $2}')
    done
    
    local elapsed_seconds=0
    
    while true; do
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (Обновление: ${interval}s) | Сервер: ${SERVER_NAME}                    ║${NC}"
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
        echo -e "${YELLOW}Время:${NC} $(date '+%Y-%m-%d %H:%M:%S')    ${YELLOW}Всего:${NC} ${#current_emails[@]}    ${YELLOW}Ctrl+C = выход${NC}"
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
            
            # Форматируем отображение: "full_email → db_name" если есть _, иначе просто email
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
        
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${CYAN}ℹ ВСЕГО (БД)${NC} = суммарный трафик | ${CYAN}→${NC} = имя в БД (всё до _) | ${RED}Подписка n/a = не синхронизируется${NC}"
        else
            echo -e "${YELLOW}⚠ Baserow выключен - статистика обнулится при перезапуске Xray${NC}"
        fi
        
        if [[ "$auto_sync_enabled" == true ]]; then
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
                echo -e "${GREEN}✓ Синхронизировано:${NC} $synced | ${CYAN}Пропущено (< 10 MB):${NC} $skipped | ${RED}Без подписки:${NC} $no_subscription"
                if (( errors > 0 )); then
                    echo -e "${RED}✗ Ошибок:${NC} $errors"
                fi
                sleep 3
            fi
        fi
        
        sleep $interval
    done
}

# ============================================================================
# ЗАПУСК
# ============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    clear_screen
    echo -e "${RED}✗ Конфиг Xray не найден: $CONFIG_FILE${NC}"
    exit 1
fi

# Автоматическая настройка при первом запуске
auto_setup

# Автоматический запуск мониторинга
realtime_monitor
