#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.3 - ИСПРАВЛЕННАЯ ВЕРСИЯ
# С улучшенной автосинхронизацией и обработкой ошибок
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
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"
REFRESH_INTERVAL=2
MIN_SYNC_BYTES=10485760  # 10 MB минимум для синхронизации

# ============================================================================
# БАЗОВЫЕ ФУНКЦИИ
# ============================================================================

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

clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR - Real-time v3.2                    ║${NC}"
    echo -e "${BLUE}║         (Автосинхронизация + персистентное хранение в Baserow)            ║${NC}"
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
    # Увеличена точность до 6 знаков для предотвращения потери данных
    printf "%.6f" $(echo "scale=6; $bytes / 1073741824" | bc)
}

gb_to_bytes() {
    local gb=$1
    if [[ -z "$gb" || "$gb" == "0" ]]; then
        echo "0"
        return
    fi
    # Используем целочисленное деление для точности
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
    local username=$1
    local all_rows=$(baserow_get_all_rows)
    if [[ -z "$all_rows" ]]; then
        echo ""
        return
    fi
    echo "$all_rows" | jq -r --arg user "$username" '.results[] | select(.user == $user)' 2>/dev/null
}

baserow_get_user_gb() {
    local username=$1
    local user_row=$(baserow_get_user_row "$username")
    if [[ -n "$user_row" ]]; then
        local gb=$(echo "$user_row" | jq -r '.GB // "0"' 2>/dev/null)
        # Очистка от возможных нечисловых значений
        gb=$(echo "$gb" | grep -oE '[0-9]+(\.[0-9]+)?')
        echo "${gb:-0}"
    else
        echo "0"
    fi
}

baserow_create_row() {
    local username=$1
    local gb=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    # Проверка валидности GB
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
        -d "{\"user\": \"$username\", \"GB\": $gb}" 2>/dev/null)
    
    # Проверка успешности создания
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

baserow_update_row() {
    local username=$1
    local gb=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        return 1
    fi
    
    # Проверка валидности GB
    if [[ -z "$gb" ]] || ! [[ "$gb" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 0
    fi
    
    local user_row=$(baserow_get_user_row "$username")
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
        baserow_create_row "$username" "$gb"
        return $?
    fi
}

baserow_sync_user() {
    local username=$1
    local current_bytes=$2
    
    if [[ "$BASEROW_ENABLED" != "true" ]]; then
        echo "$current_bytes"
        return 1
    fi
    
    # Проверка минимального порога
    if (( current_bytes < MIN_SYNC_BYTES )); then
        local saved_gb=$(baserow_get_user_gb "$username")
        local saved_bytes=$(gb_to_bytes "$saved_gb")
        echo $((saved_bytes + current_bytes))
        return 0
    fi
    
    local saved_gb=$(baserow_get_user_gb "$username")
    local saved_bytes=$(gb_to_bytes "$saved_gb")
    local total_bytes=$((saved_bytes + current_bytes))
    local total_gb=$(bytes_to_gb "$total_bytes")
    
    if baserow_update_row "$username" "$total_gb"; then
        echo "$total_bytes"
        return 0
    else
        # В случае ошибки возвращаем текущую сумму без обновления
        echo "$total_bytes"
        return 1
    fi
}

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
        return $?
    fi
    return 1
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
    
    local test_response=$(curl -s -X GET \
        "https://api.baserow.io/api/database/rows/table/${table_id}/?user_field_names=true" \
        -H "Authorization: Token ${token}" 2>/dev/null)
    
    if echo "$test_response" | jq -e '.results' > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Подключение успешно!"
        save_baserow_config "$token" "$table_id" "true"
        load_baserow_config
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              Baserow успешно настроен!                        ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}✗${NC} Ошибка подключения к Baserow!"
        echo -e "${YELLOW}Проверьте токен и ID таблицы${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

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

enable_baserow() {
    if [[ -f "$BASEROW_CONFIG" ]]; then
        load_baserow_config
        save_baserow_config "$BASEROW_TOKEN" "$BASEROW_TABLE_ID" "true"
        load_baserow_config
        echo -e "${GREEN}✓${NC} Baserow включен"
        sleep 1
    else
        echo -e "${YELLOW}⚠${NC} Сначала настройте Baserow (опция 6)"
        sleep 2
    fi
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

setup_stats_api() {
    clear_screen
    echo -e "${YELLOW}⚙ Настройка Stats API...${NC}"
    echo ""
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓${NC} Резервная копия создана"
    
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"stats": {}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен блок stats"
    fi
    
    if ! jq -e '.api' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен API сервис"
    fi
    
    jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Настроены политики статистики"
    
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
    
    api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$api_route_exists" ]]; then
        jq --argjson api_rule '{
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        }' '.routing.rules += [$api_rule]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Добавлен routing для API"
    fi
    
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
        
        for email in "${current_emails[@]}"; do
            local stats=$(get_user_stats "$email")
            local uplink=$(echo "$stats" | awk '{print $1}')
            local downlink=$(echo "$stats" | awk '{print $2}')
            
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
            local total_traffic=$(get_total_user_traffic "$email" "$session_total")
            
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
            
            printf "${color}%-20s %15s %15s %15s %15s %15s %15s${NC}\n" \
                "$email" \
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
                
                for email in "${current_emails[@]}"; do
                    local stats=$(get_user_stats "$email")
                    local uplink=$(echo "$stats" | awk '{print $1}')
                    local downlink=$(echo "$stats" | awk '{print $2}')
                    local session_total=$((uplink + downlink))
                    
                    if (( session_total >= MIN_SYNC_BYTES )); then
                        echo -e "${YELLOW}  ⟳${NC} Синхронизация $email ($(bytes_to_human $session_total))..."
                        
                        if baserow_sync_user "$email" "$session_total" > /dev/null 2>&1; then
                            # Успешная синхронизация - сбрасываем счетчики Xray
                            reset_user_stats "$email"
                            synced=$((synced + 1))
                            echo -e "${GREEN}    ✓ Успешно${NC}"
                            
                            # ВАЖНО: Обнуляем предыдущие значения для корректного расчета скорости
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
                echo -e "${GREEN}✓ Синхронизировано:${NC} $synced | ${CYAN}Пропущено (< 10 MB):${NC} $skipped"
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
    echo -e "${CYAN}ОБЩАЯ СТАТИСТИКА${NC}"
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
    
    echo -e "${CYAN}ВЫБЕРИТЕ ПОЛЬЗОВАТЕЛЯ:${NC}"
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
    local skipped_count=0
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        local uplink=$(echo "$stats" | awk '{print $1}')
        local downlink=$(echo "$stats" | awk '{print $2}')
        local session_total=$((uplink + downlink))
        
        if (( session_total >= MIN_SYNC_BYTES )); then
            echo -e "${YELLOW}⟳${NC} Синхронизация $email..."
            
            if baserow_sync_user "$email" "$session_total" > /dev/null 2>&1; then
                echo -e "${GREEN}  ✓${NC} Успешно ($(bytes_to_human $session_total))"
                synced_count=$((synced_count + 1))
                reset_user_stats "$email"
            else
                echo -e "${RED}  ✗${NC} Ошибка синхронизации"
                error_count=$((error_count + 1))
            fi
        else
            echo -e "${CYAN}⊘${NC} Пропуск $email (< 10 MB)"
            skipped_count=$((skipped_count + 1))
        fi
    done
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Синхронизация завершена!                         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Синхронизировано:${NC} $synced_count пользователей"
    echo -e "${CYAN}Пропущено:${NC} $skipped_count пользователей"
    if (( error_count > 0 )); then
        echo -e "${RED}Ошибок:${NC} $error_count"
    fi
    echo ""
    echo -e "${YELLOW}ℹ Статистика Xray сброшена для синхронизированных пользователей${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

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
    
    if [[ -z "$response" ]] || ! echo "$response" | jq -e '.results' > /dev/null 2>&1; then
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

reset_menu() {
    clear_screen
    echo -e "${CYAN}СБРОС СТАТИСТИКИ${NC}"
    echo ""
    echo "  1. Сбросить статистику всех пользователей (только Xray)"
    echo "  2. Сбросить статистику конкретного пользователя (только Xray)"
    echo "  3. Удалить данные пользователя из Baserow"
    echo "  0. Назад"
    echo ""
    read -p "Выберите опцию: " choice
    
    case $choice in
        1)
            read -p "Сбросить статистику ВСЕХ пользователей в Xray? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                reset_all_stats
                echo -e "${GREEN}✓ Статистика Xray сброшена${NC}"
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
                        echo -e "${GREEN}✓ Данные удалены из Baserow${NC}"
                    else
                        echo -e "${RED}✗ Ошибка удаления${NC}"
                    fi
                    sleep 2
                fi
            fi
            ;;
        0)
            return
            ;;
    esac
}

check_status() {
    clear_screen
    echo -e "${CYAN}ПРОВЕРКА СИСТЕМЫ${NC}"
    echo ""
    
    if check_stats_api; then
        echo -e "${GREEN}✓${NC} Stats API настроен"
    else
        echo -e "${RED}✗${NC} Stats API не настроен"
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
        echo -e "${RED}✗${NC} API не отвечает"
    fi
    
    echo ""
    
    if load_baserow_config; then
        if [[ "$BASEROW_ENABLED" == "true" ]]; then
            echo -e "${GREEN}✓${NC} Baserow настроен и включен"
            
            local test_response=$(curl -s -X GET \
                "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true&size=1" \
                -H "Authorization: Token ${BASEROW_TOKEN}" 2>/dev/null)
            
            if echo "$test_response" | jq -e '.results' > /dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} Подключение к Baserow работает"
                local row_count=$(curl -s -X GET \
                    "https://api.baserow.io/api/database/rows/table/${BASEROW_TABLE_ID}/?user_field_names=true" \
                    -H "Authorization: Token ${BASEROW_TOKEN}" 2>/dev/null | jq '.count')
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
    local user_count=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${CYAN}Пользователей в config.json:${NC} $user_count"
    
    local xray_version=$(xray version 2>/dev/null | head -1)
    echo -e "${CYAN}Версия Xray:${NC} $xray_version"
    
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# ============================================================================
# ГЛАВНОЕ МЕНЮ
# ============================================================================

main_menu() {
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

# ============================================================================
# ЗАПУСК
# ============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    clear_screen
    echo -e "${RED}✗ Конфиг Xray не найден: $CONFIG_FILE${NC}"
    exit 1
fi

main_menu
