#!/bin/bash
# ==============================================
# UI FUNCTIONS
# Обработка вывода, цветов и Telegram
# ==============================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Глобальные переменные для отслеживания параллельных задач
declare -A TASK_PIDS
declare -A TASK_DESCRIPTIONS

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')][INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')][WARN]${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')][ERROR]${NC} $1" >&2
}

start_task() {
    local func_name="$1"
    local description="$2"

    # Запускаем функцию в отдельном подоболочке, чтобы не блокировать
    (
        # Используем лог для обозначения начала работы
        echo -e "${CYAN}[START]${NC} Начало задачи: ${description}..."
        "$func_name"
        local status=$?
        if [ "$status" -eq 0 ]; then
             echo -e "${GREEN}[DONE]${NC} Задача '${description}' завершена успешно."
        else
             echo -e "${RED}[FAIL]${NC} Задача '${description}' завершилась с ошибкой $status."
             return $status # Сохраняем код ошибки
        fi
    ) &
    # Сохраняем PID и описание для дальнейшего ожидания
    TASK_PIDS["$func_name"]=$!
    TASK_DESCRIPTIONS["$func_name"]="$description"
}

wait_for_tasks() {
    log "Ожидание завершения параллельных задач..."
    local overall_exit_code=0

    # Ожидаем завершения всех фоновых процессов
    for func_name in "${!TASK_PIDS[@]}"; do
        local pid=${TASK_PIDS["$func_name"]}
        local description=${TASK_DESCRIPTIONS["$func_name"]}

        # Bash 'wait' вернет код выхода подоболочки
        wait "$pid"
        local status=$?

        if [ "$status" -ne 0 ]; then
            # Ошибка уже была залогирована функцией start_task
            overall_exit_code=1
        fi
    done

    if [ "$overall_exit_code" -ne 0 ]; then
        error "Один или несколько модулей безопасности завершились с ошибкой!"
    else
        log "Все параллельные задачи завершены успешно."
    fi
    return $overall_exit_code
}


send_telegram() {
    # Переменные TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID должны быть загружены из config.conf
    local message="$1"
    local server_message="*Сервер: ${SERVER_NAME}*\n${message}"

    # Запускаем curl в фоне, чтобы не блокировать выполнение скрипта
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${server_message}" \
        -d "parse_mode=Markdown" > /dev/null 2>&1 &
}

finalize() {
    log "Завершение настройки..."

    # Обновляем всё
    apt update && apt upgrade -y

    # Перезапускаем сервисы, которые могли быть изменены
    systemctl restart fail2ban 2>/dev/null || true
    systemctl restart auditd 2>/dev/null || true
    systemctl restart rsyslog 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || true

    # Финальное сообщение в Telegram
    local ip=$(hostname -I | awk '{print $1}')
    local message="✅ *Установка Защиты Завершена*

🖥️ Server: ${SERVER_NAME}
🔗 IP: ${ip}
📅 Time: $(date)
🛡️ Установлены: Fail2Ban, Auditd, UFW, RKHunter, ClamAV, Honeypot (:${HONEYPOT_PORT}), Защита логов.

🔐 *Следующие шаги:*
1. Проверьте /etc/ssh/sshd_config.
2. Проверьте бэкапы: ${BACKUP_DIR_BASE}.
3. Мониторьте уведомления в Telegram."

    send_telegram "$message"

    echo "========================================="
    echo "✅ НАСТРОЙКА ЗАВЕРШЕНА!"
    echo "========================================="
    echo "Сделано:"
    echo "1. Fail2Ban с уведомлениями в Telegram"
    echo "2. Защищенные логи (chattr +a)"
    echo "3. Фаервол UFW"
    echo "4. Мониторинг аудита (auditd)"
    echo "5. SSH Honeypot на порту ${HONEYPOT_PORT}"
    echo "6. Ежедневные отчеты в Telegram"
    echo "7. Инструменты: rkhunter, clamav, aide"
    echo ""
    echo "⚠️  Проверь конфигурацию SSH: /etc/ssh/sshd_config"
    echo "📱 Будут приходить уведомления в Telegram"
    echo "========================================="
}