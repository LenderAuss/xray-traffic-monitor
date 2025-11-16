#!/bin/bash

# ============================================================================
# Xray Traffic Monitor - Мониторинг трафика пользователей через Stats API
# Установка: wget -O - https://raw.githubusercontent.com/YOUR_REPO/xray-traffic-monitor.sh | bash
# ============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Установка Xray Traffic Monitor v1.0                   ║${NC}"
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
if ! command -v bc &> /dev/null; then
    echo -e "${YELLOW}  Установка bc...${NC}"
    apt-get update > /dev/null 2>&1
    apt-get install -y bc > /dev/null 2>&1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}  Установка jq...${NC}"
    apt-get install -y jq > /dev/null 2>&1
fi

echo -e "${GREEN}✓ Зависимости установлены${NC}"

# Создание основного скрипта
echo -e "${YELLOW}⚙ Создание скрипта мониторинга...${NC}"

cat << 'EOF' > /usr/local/bin/xray-traffic-monitor
#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
API_PORT=10085
API_SERVER="127.0.0.1:${API_PORT}"

# Функция для конвертации байтов в читаемый формат
bytes_to_human() {
    local bytes=$1
    local gb mb kb
    
    if (( bytes >= 1073741824 )); then
        gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb} GB"
    elif (( bytes >= 1048576 )); then
        mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb} MB"
    elif (( bytes >= 1024 )); then
        kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb} KB"
    else
        echo "${bytes} B"
    fi
}

# Проверка установки Xray
if ! command -v xray &> /dev/null; then
    echo -e "${RED}✗ Xray не установлен!${NC}"
    exit 1
fi

# Проверка наличия конфига
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}✗ Конфиг Xray не найден: $CONFIG_FILE${NC}"
    exit 1
fi

# Функция проверки Stats API
check_stats_api() {
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        return 1
    fi
    
    if ! jq -e '.api.services[] | select(. == "StatsService")' "$CONFIG_FILE" > /dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# Функция установки Stats API
setup_stats_api() {
    echo -e "${YELLOW}⚙ Настройка Stats API...${NC}"
    
    # Создаем резервную копию
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓ Резервная копия создана${NC}"
    
    # Добавляем stats
    if ! jq -e '.stats' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"stats": {}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓ Добавлен блок stats${NC}"
    fi
    
    # Добавляем api
    if ! jq -e '.api' "$CONFIG_FILE" > /dev/null 2>&1; then
        jq '. + {"api": {"tag": "api", "services": ["StatsService"]}}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓ Добавлен API сервис${NC}"
    fi
    
    # Добавляем policy для статистики
    jq '.policy.levels."0" += {"statsUserUplink": true, "statsUserDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    jq '.policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true}' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
    echo -e "${GREEN}✓ Настроены политики статистики${NC}"
    
    # Проверяем наличие API inbound
    api_exists=$(jq '.inbounds[] | select(.tag == "api")' "$CONFIG_FILE")
    
    if [[ -z "$api_exists" ]]; then
        jq --argjson api_inbound '{
            "listen": "127.0.0.1",
            "port": '"$API_PORT"',
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"},
            "tag": "api"
        }' '.inbounds += [$api_inbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓ Добавлен API inbound${NC}"
    fi
    
    # Добавляем routing для API
    api_route_exists=$(jq '.routing.rules[] | select(.inboundTag[0] == "api")' "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$api_route_exists" ]]; then
        jq --argjson api_rule '{
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        }' '.routing.rules += [$api_rule]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓ Добавлен routing для API${NC}"
    fi
    
    # Добавляем API outbound если его нет
    api_outbound_exists=$(jq '.outbounds[] | select(.tag == "api")' "$CONFIG_FILE")
    
    if [[ -z "$api_outbound_exists" ]]; then
        jq --argjson api_outbound '{
            "protocol": "freedom",
            "tag": "api"
        }' '.outbounds += [$api_outbound]' "$CONFIG_FILE" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$CONFIG_FILE"
        echo -e "${GREEN}✓ Добавлен API outbound${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}⟳ Перезапуск Xray...${NC}"
    systemctl restart xray
    sleep 2
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Xray успешно перезапущен${NC}"
    else
        echo -e "${RED}✗ Ошибка перезапуска Xray!${NC}"
        echo -e "${YELLOW}Восстановление из резервной копии...${NC}"
        latest_backup=$(ls -t ${CONFIG_FILE}.backup.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" "$CONFIG_FILE"
            systemctl restart xray
        fi
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Stats API успешно установлен!                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
}

# Функция получения статистики пользователя
get_user_stats() {
    local email=$1
    local uplink downlink
    
    uplink=$(xray api statsquery --server="$API_SERVER" -pattern "user>>>$email>>>traffic>>>uplink" 2>/dev/null | \
             grep -oP '"value"\s*:\s*"\K\d+' || echo "0")
    
    downlink=$(xray api statsquery --server="$API_SERVER" -pattern "user>>>$email>>>traffic>>>downlink" 2>/dev/null | \
               grep -oP '"value"\s*:\s*"\K\d+' || echo "0")
    
    echo "$uplink $downlink"
}

# Функция сброса статистики пользователя
reset_user_stats() {
    local email=$1
    
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>uplink" -reset > /dev/null 2>&1
    xray api stats --server="$API_SERVER" -name "user>>>$email>>>traffic>>>downlink" -reset > /dev/null 2>&1
}

# Функция отображения статистики
show_stats() {
    local emails
    
    emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
    
    if [[ ${#emails[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Список пользователей пуст${NC}"
        exit 0
    fi
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║            СТАТИСТИКА ТРАФИКА ПОЛЬЗОВАТЕЛЕЙ XRAY                      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    printf "${CYAN}%-20s %15s %15s %15s${NC}\n" "ПОЛЬЗОВАТЕЛЬ" "ОТПРАВЛЕНО ↑" "ПОЛУЧЕНО ↓" "ВСЕГО"
    echo "────────────────────────────────────────────────────────────────────────────"
    
    local total_up=0
    local total_down=0
    
    for email in "${emails[@]}"; do
        local stats uplink downlink total
        
        stats=$(get_user_stats "$email")
        uplink=$(echo "$stats" | awk '{print $1}')
        downlink=$(echo "$stats" | awk '{print $2}')
        total=$((uplink + downlink))
        
        total_up=$((total_up + uplink))
        total_down=$((total_down + downlink))
        
        printf "%-20s %15s %15s %15s\n" \
            "$email" \
            "$(bytes_to_human $uplink)" \
            "$(bytes_to_human $downlink)" \
            "$(bytes_to_human $total)"
    done
    
    echo "────────────────────────────────────────────────────────────────────────────"
    printf "${GREEN}%-20s %15s %15s %15s${NC}\n" \
        "ИТОГО:" \
        "$(bytes_to_human $total_up)" \
        "$(bytes_to_human $total_down)" \
        "$(bytes_to_human $((total_up + total_down)))"
    echo ""
}

# Функция отображения детальной статистики пользователя
show_user_detail() {
    local email=$1
    local stats uplink downlink total
    
    if ! jq -e --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG_FILE" > /dev/null 2>&1; then
        echo -e "${RED}✗ Пользователь '$email' не найден${NC}"
        exit 1
    fi
    
    stats=$(get_user_stats "$email")
    uplink=$(echo "$stats" | awk '{print $1}')
    downlink=$(echo "$stats" | awk '{print $2}')
    total=$((uplink + downlink))
    
    local uuid subscription created_date
    uuid=$(jq -r --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' "$CONFIG_FILE")
    subscription=$(jq -r --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email) | .metadata.subscription // "n/a"' "$CONFIG_FILE")
    created_date=$(jq -r --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email) | .metadata.created_date // "n/a"' "$CONFIG_FILE")
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О ПОЛЬЗОВАТЕЛЕ              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Пользователь:${NC}    $email"
    echo -e "${CYAN}UUID:${NC}            $uuid"
    echo -e "${CYAN}Подписка:${NC}        $subscription"
    echo -e "${CYAN}Дата создания:${NC}   $created_date"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}Трафик:${NC}"
    echo -e "  ↑ Отправлено:     $(bytes_to_human $uplink) ${YELLOW}($uplink bytes)${NC}"
    echo -e "  ↓ Получено:       $(bytes_to_human $downlink) ${YELLOW}($downlink bytes)${NC}"
    echo -e "  ${CYAN}Σ Всего:${NC}          ${GREEN}$(bytes_to_human $total)${NC} ${YELLOW}($total bytes)${NC}"
    echo ""
}

# Функция сброса статистики
reset_stats() {
    local email=$1
    
    if [[ -n "$email" ]]; then
        if ! jq -e --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG_FILE" > /dev/null 2>&1; then
            echo -e "${RED}✗ Пользователь '$email' не найден${NC}"
            exit 1
        fi
        
        reset_user_stats "$email"
        echo -e "${GREEN}✓ Статистика пользователя '$email' сброшена${NC}"
    else
        local emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG_FILE" 2>/dev/null))
        
        for email in "${emails[@]}"; do
            reset_user_stats "$email"
        done
        
        echo -e "${GREEN}✓ Статистика всех пользователей сброшена${NC}"
    fi
}

# Функция проверки статуса Stats API
check_status() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  ПРОВЕРКА STATS API XRAY                      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if check_stats_api; then
        echo -e "${GREEN}✓ Stats API настроен в конфигурации${NC}"
    else
        echo -e "${RED}✗ Stats API не настроен в конфигурации${NC}"
        echo -e "${YELLOW}  Используйте: xray-traffic-monitor -i${NC}"
        return 1
    fi
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ Xray работает${NC}"
    else
        echo -e "${RED}✗ Xray не запущен${NC}"
        return 1
    fi
    
    if ss -tlnp 2>/dev/null | grep -q ":$API_PORT"; then
        echo -e "${GREEN}✓ API порт $API_PORT открыт${NC}"
    else
        echo -e "${RED}✗ API порт $API_PORT не открыт${NC}"
        return 1
    fi
    
    if xray api statsquery --server="$API_SERVER" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ API отвечает на запросы${NC}"
    else
        echo -e "${RED}✗ API не отвечает на запросы${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}Stats API полностью функционален!${NC}"
    echo ""
}

# Функция отображения помощи
show_help() {
    cat << 'HELP'

╔════════════════════════════════════════════════════════════════╗
║         XRAY TRAFFIC MONITOR - Мониторинг трафика Xray        ║
╚════════════════════════════════════════════════════════════════╝

Использование:
    xray-traffic-monitor [ОПЦИЯ] [АРГУМЕНТ]

Опции:
    -s, --show              Показать статистику всех пользователей
    -u, --user <email>      Показать детальную статистику пользователя
    -r, --reset [email]     Сбросить статистику (всех или конкретного)
    -i, --install           Установить/настроить Stats API
    -c, --check             Проверить статус Stats API
    -h, --help              Показать эту справку

Примеры:
    xray-traffic-monitor -s
        Показать статистику всех пользователей

    xray-traffic-monitor -u main
        Показать детальную статистику пользователя main

    xray-traffic-monitor -r
        Сбросить статистику всех пользователей

    xray-traffic-monitor -r john
        Сбросить статистику пользователя john

    xray-traffic-monitor -i
        Установить и настроить Stats API

    xray-traffic-monitor -c
        Проверить статус Stats API

Примечания:
    • Stats API должен быть настроен для работы мониторинга
    • Используйте -i для автоматической настройки
    • Статистика сбрасывается при перезапуске Xray
    • Все изменения конфига сохраняются в резервную копию

HELP
}

# Основная логика
case "${1}" in
    -s|--show)
        if ! check_stats_api; then
            echo -e "${RED}✗ Stats API не настроен!${NC}"
            echo -e "${YELLOW}Используйте: xray-traffic-monitor -i${NC}"
            exit 1
        fi
        show_stats
        ;;
    -u|--user)
        if [[ -z "$2" ]]; then
            echo -e "${RED}✗ Укажите имя пользователя${NC}"
            echo -e "Использование: xray-traffic-monitor -u <email>"
            exit 1
        fi
        if ! check_stats_api; then
            echo -e "${RED}✗ Stats API не настроен!${NC}"
            echo -e "${YELLOW}Используйте: xray-traffic-monitor -i${NC}"
            exit 1
        fi
        show_user_detail "$2"
        ;;
    -r|--reset)
        if ! check_stats_api; then
            echo -e "${RED}✗ Stats API не настроен!${NC}"
            echo -e "${YELLOW}Используйте: xray-traffic-monitor -i${NC}"
            exit 1
        fi
        reset_stats "$2"
        ;;
    -i|--install)
        setup_stats_api
        echo ""
        echo -e "${GREEN}Готово! Теперь используйте:${NC}"
        echo -e "  ${CYAN}xray-traffic-monitor -s${NC}      # показать статистику"
        echo -e "  ${CYAN}xray-traffic-monitor -u main${NC}  # детали пользователя"
        echo ""
        ;;
    -c|--check)
        check_status
        ;;
    -h|--help|*)
        show_help
        ;;
esac
EOF

chmod +x /usr/local/bin/xray-traffic-monitor

echo -e "${GREEN}✓ Скрипт установлен: /usr/local/bin/xray-traffic-monitor${NC}"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                   Установка завершена!                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Быстрый старт:${NC}"
echo -e "  ${CYAN}1.${NC} Настроить Stats API:"
echo -e "     ${GREEN}xray-traffic-monitor -i${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Показать статистику:"
echo -e "     ${GREEN}xray-traffic-monitor -s${NC}"
echo ""
echo -e "  ${CYAN}3.${NC} Детали пользователя:"
echo -e "     ${GREEN}xray-traffic-monitor -u main${NC}"
echo ""
echo -e "  ${CYAN}4.${NC} Полная справка:"
echo -e "     ${GREEN}xray-traffic-monitor -h${NC}"
echo ""
echo -e "${YELLOW}Примечание:${NC} Сначала выполните установку API командой ${GREEN}-i${NC}"
echo ""
