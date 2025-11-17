#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v2.1 - Показывает только АКТИВНЫХ пользователей
# Обновление: исключает удалённых пользователей, синхронизация с config.json
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
echo -e "${BLUE}║         Установка Xray Traffic Monitor v2.1                   ║${NC}"
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
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"
REFRESH_INTERVAL=2

# Функция очистки экрана
clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  XRAY TRAFFIC MONITOR - Real-time v2.1                    ║${NC}"
    echo -e "${BLUE}║                    (Только активные пользователи)                         ║${NC}"
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

# Получение статистики пользователя
get_user_stats() {
    local email=$1
    local uplink downlink
    
    # Используем альтернативный способ получения статистики
    local stats_output=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)
    
    # Пытаемся получить uplink
    uplink=$(echo "$stats_output" | grep "user>>>$email>>>traffic>>>uplink" -A 3 | grep -oP '"value"\s*:\s*"\K\d+' | head -1)
    downlink=$(echo "$stats_output" | grep "user>>>$email>>>traffic>>>downlink" -A 3 | grep -oP '"value"\s*:\s*"\K\d+' | head -1)
    
    # Если не получили через grep, пробуем jq
    if [[ -z "$uplink" ]]; then
        uplink=$(echo "$stats_output" | jq -r '.stat[] | select(.name | contains("user>>>'"$email"'>>>traffic>>>uplink")) | .value // "0"' 2>/dev/null | head -1)
    fi
    
    if [[ -z "$downlink" ]]; then
        downlink=$(echo "$stats_output" | jq -r '.stat[] | select(.name | contains("user>>>'"$email"'>>>traffic>>>downlink")) | .value // "0"' 2>/dev/null | head -1)
    fi
    
    # Если все еще пусто, ставим 0
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

# Мониторинг в реальном времени (МОДЕРНИЗИРОВАННАЯ ВЕРСИЯ)
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
        # ВАЖНО: Обновляем список активных пользователей на каждой итерации
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                     МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (Обновление: ${interval}s)                           ║${NC}"
        echo -e "${BLUE}║                         (Показаны только активные пользователи)                                ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Время:${NC} $(date '+%Y-%m-%d %H:%M:%S')    ${YELLOW}Активных пользователей:${NC} ${#current_emails[@]}    ${YELLOW}Нажмите Ctrl+C для выхода${NC}"
        echo ""
        
        printf "${CYAN}%-20s %15s %15s %15s %15s %15s${NC}\n" \
            "ПОЛЬЗОВАТЕЛЬ" "ОТПРАВЛЕНО" "ПОЛУЧЕНО" "ВСЕГО" "СКОРОСТЬ ↑" "СКОРОСТЬ ↓"
        echo "────────────────────────────────────────────────────────────────────────────────────────────────────────"
        
        local total_up=0
        local total_down=0
        local total_speed_up=0
        local total_speed_down=0
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
            
            # Если скорость отрицательная (после сброса или удаления), обнуляем
            if (( speed_up < 0 )); then speed_up=0; fi
            if (( speed_down < 0 )); then speed_down=0; fi
            
            local total=$((uplink + downlink))
            
            total_up=$((total_up + uplink))
            total_down=$((total_down + downlink))
            total_speed_up=$((total_speed_up + speed_up))
            total_speed_down=$((total_speed_down + speed_down))
            
            # Цветовая индикация активности
            local color=$NC
            if (( speed_up > 0 || speed_down > 0 )); then
                color=$GREEN
                active_count=$((active_count + 1))
            fi
            
            printf "${color}%-20s %15s %15s %15s %15s %15s${NC}\n" \
                "$email" \
                "$(bytes_to_human $uplink)" \
                "$(bytes_to_human $downlink)" \
                "$(bytes_to_human $total)" \
                "$(bytes_per_sec $speed_up $interval)" \
                "$(bytes_per_sec $speed_down $interval)"
            
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
        
        echo "────────────────────────────────────────────────────────────────────────────────────────────────────────"
        printf "${WHITE}%-20s %15s %15s %15s %15s %15s${NC}\n" \
            "ИТОГО:" \
            "$(bytes_to_human $total_up)" \
            "$(bytes_to_human $total_down)" \
            "$(bytes_to_human $((total_up + total_down)))" \
            "$(bytes_per_sec $total_speed_up $interval)" \
            "$(bytes_per_sec $total_speed_down $interval)"
        
        echo ""
        echo -e "${YELLOW}Легенда:${NC} ${GREEN}Зеленый${NC} = активное соединение (${active_count}) | ${NC}Белый${NC} = неактивен ($((${#current_emails[@]} - active_count)))"
        echo -e "${CYAN}ℹ Показаны только пользователи из config.json | Статистика обнуляется при перезапуске Xray${NC}"
        
        sleep $interval
    done
}

# Просмотр общей статистики
view_stats() {
    if ! check_stats_api; then
        clear_screen
        echo -e "${RED}✗ Stats API не настроен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
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
    
    printf "${CYAN}%-20s %15s %15s %15s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "ОТПРАВЛЕНО ↑" "ПОЛУЧЕНО ↓" "ВСЕГО"
    echo "────────────────────────────────────────────────────────────────────"
    
    local total_up=0
    local total_down=0
    
    for email in "${emails[@]}"; do
        local stats=$(get_user_stats "$email")
        local uplink=$(echo "$stats" | awk '{print $1}')
        local downlink=$(echo "$stats" | awk '{print $2}')
        local total=$((uplink + downlink))
        
        total_up=$((total_up + uplink))
        total_down=$((total_down + downlink))
        
        printf "%-20s %15s %15s %15s\n" \
            "$email" \
            "$(bytes_to_human $uplink)" \
            "$(bytes_to_human $downlink)" \
            "$(bytes_to_human $total)"
    done
    
    echo "────────────────────────────────────────────────────────────────────"
    printf "${GREEN}%-20s %15s %15s %15s${NC}\n" \
        "ИТОГО:" \
        "$(bytes_to_human $total_up)" \
        "$(bytes_to_human $total_down)" \
        "$(bytes_to_human $((total_up + total_down)))"
    
    echo ""
    echo -e "${CYAN}ℹ Статистика обнуляется при перезапуске Xray${NC}"
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
    local total=$((uplink + downlink))
    
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
    echo -e "${CYAN}Трафик (с последнего перезапуска Xray):${NC}"
    echo -e "  ↑ Отправлено:     $(bytes_to_human $uplink)"
    echo -e "  ↓ Получено:       $(bytes_to_human $downlink)"
    echo -e "  ${CYAN}Σ Всего:${NC}          ${GREEN}$(bytes_to_human $total)${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Меню сброса статистики
reset_menu() {
    clear_screen
    echo -e "${CYAN}СБРОС СТАТИСТИКИ${NC}"
    echo ""
    echo "  1. Сбросить статистику всех пользователей"
    echo "  2. Сбросить статистику конкретного пользователя"
    echo "  0. Назад"
    echo ""
    read -p "Выберите опцию: " choice
    
    case $choice in
        1)
            read -p "Вы уверены? Это сбросит статистику ВСЕХ пользователей (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                reset_all_stats
                echo -e "${GREEN}✓ Статистика всех пользователей сброшена${NC}"
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
                echo -e "${GREEN}✓ Статистика пользователя '$selected_email' сброшена${NC}"
                sleep 2
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
    
    # Проверка наличия пользователей
    local user_count=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${CYAN}Активных пользователей:${NC} $user_count"
    
    # Версия Xray
    local xray_version=$(xray version 2>/dev/null | head -1)
    echo -e "${CYAN}Версия Xray:${NC} $xray_version"
    
    echo ""
    echo -e "${YELLOW}ℹ  Статистика хранится в оперативной памяти и обнуляется при перезапуске Xray${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Главное меню
main_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}ГЛАВНОЕ МЕНЮ${NC}"
        echo ""
        echo "  ${GREEN}1.${NC} Мониторинг в реальном времени"
        echo "  ${GREEN}2.${NC} Просмотр общей статистики"
        echo "  ${GREEN}3.${NC} Детали по пользователю"
        echo "  ${GREEN}4.${NC} Сброс статистики"
        echo "  ${GREEN}5.${NC} Настроить Stats API"
        echo "  ${GREEN}6.${NC} Проверка системы"
        echo "  ${GREEN}0.${NC} Выход"
        echo ""
        read -p "Выберите опцию: " choice
        
        case $choice in
            1) realtime_monitor ;;
            2) view_stats ;;
            3) view_user_detail ;;
            4) reset_menu ;;
            5) setup_stats_api ;;
            6) check_status ;;
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
echo -e "${YELLOW}Новое в v2.1:${NC}"
echo -e "  ✅ Показывает только АКТИВНЫХ пользователей из config.json"
echo -e "  ✅ Автоматически скрывает удалённых пользователей"
echo -e "  ✅ Динамическое обновление списка при добавлении/удалении"
echo -e "  ℹ️  Статистика обнуляется при перезапуске Xray (это нормально)"
echo ""
echo -e "${YELLOW}Первый запуск:${NC}"
echo -e "  1. Запустите скрипт"
echo -e "  2. Выберите опцию ${GREEN}5${NC} для настройки Stats API (если ещё не настроено)"
echo -e "  3. Используйте опцию ${GREEN}1${NC} для мониторинга в реальном времени"
echo ""
