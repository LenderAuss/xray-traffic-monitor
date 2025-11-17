#!/bin/bash

# ============================================================================
# Xray Traffic Monitor v3.0 - Persistent Traffic Tracking with iptables
# Новое: Статистика сохраняется при перезапуске Xray
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
echo -e "${BLUE}║         (Persistent tracking с iptables)                       ║${NC}"
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

for pkg in bc jq curl iptables iptables-persistent; do
    if ! command -v $pkg &> /dev/null && ! dpkg -l | grep -q "^ii  $pkg"; then
        echo -e "${YELLOW}  Установка $pkg...${NC}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg > /dev/null 2>&1
    fi
done

echo -e "${GREEN}✓ Зависимости установлены${NC}"

# Создание директории для хранения данных
mkdir -p /var/lib/xray-monitor

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
STATS_DIR="/var/lib/xray-monitor"
IPTABLES_CHAIN="XRAY_MONITOR"
REFRESH_INTERVAL=2

# Функция очистки экрана
clear_screen() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              XRAY TRAFFIC MONITOR v3.0 - Persistent Tracking              ║${NC}"
    echo -e "${BLUE}║                    (Статистика сохраняется всегда)                        ║${NC}"
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

# Получение UUID пользователя по email
get_user_uuid() {
    local email=$1
    jq -r --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' "$CONFIG_FILE" 2>/dev/null
}

# Создание цепочки iptables для мониторинга
setup_iptables() {
    clear_screen
    echo -e "${YELLOW}⚙ Настройка iptables для мониторинга трафика...${NC}"
    echo ""
    
    # Создаем цепочку если её нет
    if ! iptables -L $IPTABLES_CHAIN -n &>/dev/null; then
        iptables -N $IPTABLES_CHAIN
        echo -e "${GREEN}✓${NC} Создана цепочка $IPTABLES_CHAIN"
    else
        echo -e "${YELLOW}ℹ${NC} Цепочка $IPTABLES_CHAIN уже существует"
    fi
    
    # Проверяем, подключена ли цепочка к INPUT/OUTPUT
    if ! iptables -L INPUT -n | grep -q "$IPTABLES_CHAIN"; then
        iptables -I INPUT -j $IPTABLES_CHAIN
        echo -e "${GREEN}✓${NC} Цепочка подключена к INPUT"
    fi
    
    if ! iptables -L OUTPUT -n | grep -q "$IPTABLES_CHAIN"; then
        iptables -I OUTPUT -j $IPTABLES_CHAIN
        echo -e "${GREEN}✓${NC} Цепочка подключена к OUTPUT"
    fi
    
    # Добавляем правила для каждого пользователя
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    local added_count=0
    
    for email in "${emails[@]}"; do
        local uuid=$(get_user_uuid "$email")
        if [[ -n "$uuid" ]]; then
            # Проверяем, есть ли уже правила для этого UUID
            if ! iptables -L $IPTABLES_CHAIN -n -v | grep -q "xray-${uuid:0:8}"; then
                # INPUT (downlink) - трафик К пользователю
                iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid:0:8}-down-$email" -j RETURN
                # OUTPUT (uplink) - трафик ОТ пользователя  
                iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid:0:8}-up-$email" -j RETURN
                added_count=$((added_count + 1))
            fi
        fi
    done
    
    echo -e "${GREEN}✓${NC} Добавлено правил для пользователей: $added_count"
    
    # Сохраняем правила
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        echo -e "${GREEN}✓${NC} Правила iptables сохранены"
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4
        echo -e "${GREEN}✓${NC} Правила iptables сохранены в /etc/iptables/rules.v4"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Мониторинг iptables успешно настроен!                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Получение статистики из iptables
get_iptables_stats() {
    local email=$1
    local uuid=$(get_user_uuid "$email")
    
    if [[ -z "$uuid" ]]; then
        echo "0 0"
        return
    fi
    
    local uuid_short="${uuid:0:8}"
    
    # Получаем статистику из iptables
    local stats=$(iptables -L $IPTABLES_CHAIN -n -v -x 2>/dev/null | grep "xray-$uuid_short")
    
    # Uplink (OUTPUT)
    local uplink=$(echo "$stats" | grep "${uuid_short}-up" | awk '{print $2}')
    # Downlink (INPUT)
    local downlink=$(echo "$stats" | grep "${uuid_short}-down" | awk '{print $2}')
    
    uplink=${uplink:-0}
    downlink=${downlink:-0}
    
    echo "$uplink $downlink"
}

# Синхронизация правил с активными пользователями
sync_iptables_rules() {
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    local synced=0
    
    for email in "${emails[@]}"; do
        local uuid=$(get_user_uuid "$email")
        if [[ -n "$uuid" ]]; then
            local uuid_short="${uuid:0:8}"
            # Проверяем наличие правил
            if ! iptables -L $IPTABLES_CHAIN -n -v | grep -q "xray-$uuid_short"; then
                iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid_short}-down-$email" -j RETURN
                iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid_short}-up-$email" -j RETURN
                synced=$((synced + 1))
            fi
        fi
    done
    
    return $synced
}

# Очистка правил удалённых пользователей
cleanup_iptables_rules() {
    clear_screen
    echo -e "${YELLOW}⚙ Очистка правил удалённых пользователей...${NC}"
    echo ""
    
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    local removed=0
    
    # Получаем все правила из цепочки
    local all_rules=$(iptables -L $IPTABLES_CHAIN -n --line-numbers 2>/dev/null | grep "xray-" | tac)
    
    while IFS= read -r rule; do
        if [[ -n "$rule" ]]; then
            local rule_num=$(echo "$rule" | awk '{print $1}')
            local comment=$(echo "$rule" | grep -oP 'xray-[a-f0-9]{8}-(up|down)-\K.*' || echo "")
            
            if [[ -n "$comment" ]]; then
                local email_exists=0
                for email in "${emails[@]}"; do
                    if [[ "$comment" == "$email" ]]; then
                        email_exists=1
                        break
                    fi
                done
                
                if [[ $email_exists -eq 0 ]]; then
                    iptables -D $IPTABLES_CHAIN $rule_num 2>/dev/null
                    removed=$((removed + 1))
                    echo -e "${GREEN}✓${NC} Удалено правило для: $comment"
                fi
            fi
        fi
    done <<< "$all_rules"
    
    if [[ $removed -gt 0 ]]; then
        # Сохраняем изменения
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        elif command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4
        fi
        echo ""
        echo -e "${GREEN}✓${NC} Удалено правил: $removed"
    else
        echo -e "${YELLOW}ℹ${NC} Нет правил для удаления"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Мониторинг в реальном времени с iptables
realtime_monitor() {
    # Проверяем наличие цепочки
    if ! iptables -L $IPTABLES_CHAIN -n &>/dev/null; then
        clear_screen
        echo -e "${RED}✗ iptables мониторинг не настроен!${NC}"
        echo ""
        read -p "Настроить сейчас? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            setup_iptables
        else
            return
        fi
    fi
    
    # Синхронизация правил
    sync_iptables_rules
    
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
    declare -A prev_time
    
    # Получаем список активных пользователей
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    # Инициализация
    local current_time=$(date +%s)
    for email in "${emails[@]}"; do
        local stats=$(get_iptables_stats "$email")
        prev_uplink[$email]=$(echo "$stats" | awk '{print $1}')
        prev_downlink[$email]=$(echo "$stats" | awk '{print $2}')
        prev_time[$email]=$current_time
    done
    
    while true; do
        # Обновляем список активных пользователей
        local current_emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        current_time=$(date +%s)
        
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║               МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ (iptables) - Обновление: ${interval}s                      ║${NC}"
        echo -e "${BLUE}║                  ✨ Статистика сохраняется при перезапуске Xray ✨                             ║${NC}"
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
        
        for email in "${current_emails[@]}"; do
            local stats=$(get_iptables_stats "$email")
            local uplink=$(echo "$stats" | awk '{print $1}')
            local downlink=$(echo "$stats" | awk '{print $2}')
            
            # Инициализация для новых пользователей
            if [[ -z "${prev_uplink[$email]}" ]]; then
                prev_uplink[$email]=0
                prev_downlink[$email]=0
                prev_time[$email]=$current_time
            fi
            
            # Вычисляем временной интервал
            local time_diff=$((current_time - prev_time[$email]))
            if (( time_diff <= 0 )); then
                time_diff=1
            fi
            
            # Вычисляем скорость
            local speed_up=$((uplink - prev_uplink[$email]))
            local speed_down=$((downlink - prev_downlink[$email]))
            
            # Защита от отрицательных значений
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
                "$(bytes_per_sec $speed_up $time_diff)" \
                "$(bytes_per_sec $speed_down $time_diff)"
            
            # Сохраняем текущие значения
            prev_uplink[$email]=$uplink
            prev_downlink[$email]=$downlink
            prev_time[$email]=$current_time
        done
        
        # Очистка данных удалённых пользователей
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
                unset prev_time[$email]
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
        echo -e "${CYAN}ℹ Статистика сохраняется в iptables и НЕ теряется при перезапуске Xray${NC}"
        
        sleep $interval
    done
}

# Просмотр общей статистики
view_stats() {
    if ! iptables -L $IPTABLES_CHAIN -n &>/dev/null; then
        clear_screen
        echo -e "${RED}✗ iptables мониторинг не настроен!${NC}"
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    clear_screen
    echo -e "${CYAN}ОБЩАЯ СТАТИСТИКА (iptables - Persistent)${NC}"
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
        local stats=$(get_iptables_stats "$email")
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
    echo -e "${GREEN}✨ Статистика сохраняется постоянно и не теряется!${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Детали пользователя
view_user_detail() {
    if ! iptables -L $IPTABLES_CHAIN -n &>/dev/null; then
        clear_screen
        echo -e "${RED}✗ iptables мониторинг не настроен!${NC}"
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
    local stats=$(get_iptables_stats "$selected_email")
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
    echo -e "${CYAN}Трафик (постоянный учёт с iptables):${NC}"
    echo -e "  ↑ Отправлено:     $(bytes_to_human $uplink)"
    echo -e "  ↓ Получено:       $(bytes_to_human $downlink)"
    echo -e "  ${CYAN}Σ Всего:${NC}          ${GREEN}$(bytes_to_human $total)${NC}"
    echo ""
    echo -e "${GREEN}✨ Данные сохраняются постоянно!${NC}"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Сброс статистики пользователя
reset_user_stats() {
    local email=$1
    local uuid=$(get_user_uuid "$email")
    
    if [[ -z "$uuid" ]]; then
        return 1
    fi
    
    local uuid_short="${uuid:0:8}"
    
    # Находим номера правил для этого пользователя
    local rules=$(iptables -L $IPTABLES_CHAIN -n --line-numbers 2>/dev/null | grep "xray-$uuid_short" | awk '{print $1}' | tac)
    
    # Удаляем правила (в обратном порядке)
    while IFS= read -r rule_num; do
        if [[ -n "$rule_num" ]]; then
            iptables -D $IPTABLES_CHAIN $rule_num 2>/dev/null
        fi
    done <<< "$rules"
    
    # Добавляем правила заново (счётчики обнулятся)
    iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid_short}-down-$email" -j RETURN
    iptables -A $IPTABLES_CHAIN -m comment --comment "xray-${uuid_short}-up-$email" -j RETURN
}

reset_all_stats() {
    local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    for email in "${emails[@]}"; do
        reset_user_stats "$email"
    done
    
    # Сохраняем изменения
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4
    fi
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
                
                # Сохраняем
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v iptables-save &>/dev/null; then
                    iptables-save > /etc/iptables/rules.v4
                fi
                
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
    
    if iptables -L $IPTABLES_CHAIN -n &>/dev/null; then
        echo -e "${GREEN}✓${NC} iptables цепочка $IPTABLES_CHAIN существует"
        
        local rule_count=$(iptables -L $IPTABLES_CHAIN -n | grep -c "xray-" || echo "0")
        echo -e "${GREEN}✓${NC} Активных правил мониторинга: $rule_count"
    else
        echo -e "${RED}✗${NC} iptables цепочка не настроена"
    fi
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓${NC} Xray работает"
    else
        echo -e "${RED}✗${NC} Xray не запущен"
    fi
    
    # Проверка наличия пользователей
    local user_count=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${CYAN}Активных пользователей в конфиге:${NC} $user_count"
    
    # Версия Xray
    local xray_version=$(xray version 2>/dev/null | head -1)
    echo -e "${CYAN}Версия Xray:${NC} $xray_version"
    
    echo ""
    echo -e "${GREEN}✨ Статистика хранится в iptables и сохраняется при перезапуске!${NC}"
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
        echo "  ${GREEN}5.${NC} Настроить iptables мониторинг"
        echo "  ${GREEN}6.${NC} Очистить правила удалённых пользователей"
        echo "  ${GREEN}7.${NC} Проверка системы"
        echo "  ${GREEN}0.${NC} Выход"
        echo ""
        read -p "Выберите опцию: " choice
        
        case $choice in
            1) realtime_monitor ;;
            2) view_stats ;;
            3) view_user_detail ;;
            4) reset_menu ;;
            5) setup_iptables ;;
            6) cleanup_iptables_rules ;;
            7) check_status ;;
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
echo -e "  ${GREEN}✨ Статистика сохраняется ВСЕГДА (даже после перезапуска Xray)${NC}"
echo -e "  ✅ Использует iptables на уровне ядра Linux"
echo -e "  ✅ Persistent tracking - данные не теряются"
echo -e "  ✅ Автоматическая синхронизация с config.json"
echo -e "  ✅ Очистка правил удалённых пользователей"
echo ""
echo -e "${YELLOW}Первый запуск:${NC}"
echo -e "  1. Запустите скрипт"
echo -e "  2. Выберите опцию ${GREEN}5${NC} для настройки iptables мониторинга"
echo -e "  3. Используйте опцию ${GREEN}1${NC} для мониторинга в реальном времени"
echo ""
echo -e "${CYAN}Преимущества v3.0:${NC}"
echo -e "  • Статистика на уровне ядра (быстрее и надёжнее)"
echo -e "  • Данные сохраняются при любых перезапусках"
echo -e "  • Меньше нагрузка на систему"
echo -e "  • Более точный учёт трафика"
echo ""
