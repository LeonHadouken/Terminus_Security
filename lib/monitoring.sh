#!/bin/bash
# ==============================================
# MONITORING FUNCTIONS
# Настройка PAM для алертов и ежедневных отчетов
# ==============================================

# Проверка, запущен ли сервис (для ежедневного отчета)
check_service_status() {
    systemctl is-active --quiet "$1"
    if [ $? -eq 0 ]; then
        echo "✅ $1 (Активен)"
    else
        echo "❌ $1 (Неактивен)"
    fi
}

report_daily_status() {
    local ban_count=$(fail2ban-client status | grep "Currently banned" | awk '{print $NF}')
    local auth_logins=$(grep "Accepted password" /var/log/auth.log | tail -n 5 | wc -l)
    local server_name=$(hostname)
    local ip_address=$(hostname -I | awk '{print $1}')

    # Статус ключевых служб
    local f2b_status=$(check_service_status fail2ban)
    local ufw_status=$(check_service_status ufw)
    local auditd_status=$(check_service_status auditd)

    # Статус Cowrie
    local cowrie_status="❌ Cowrie (Не установлен/Неактивен)"
    if command -v docker &> /dev/null && docker ps -a --format '{{.Names}}' | grep -q 'ssh_honeypot'; then
        if docker ps --format '{{.Names}}' | grep -q 'ssh_honeypot'; then
            cowrie_status="✅ Cowrie (Активен в Docker)"
        else
            cowrie_status="⚠️ Cowrie (Остановлен в Docker)"
        fi
    fi

    # Сборка сообщения
    local message="📋 *Ежедневный Отчет Безопасности - ${server_name}* *--- Общий Статус ---*
    IP: ${ip_address}
    Uptime: $(uptime -p)

    *--- Статус Служб ---*
    ${f2b_status}
    ${ufw_status}
    ${auditd_status}
    ${cowrie_status}

    *--- Метрики ---*
    🚷 Текущих Fail2Ban банов: **${ban_count}**
    👤 Успешных логинов (24ч): ${auth_logins}

    *--- Рекомендация ---*
    Выполните rkhunter --check и lynis audit system для глубокого анализа."

    send_telegram "$message"
}

setup_monitoring() {
    log "Настройка ежедневных отчетов и алертов Telegram..."

    # 1. Настройка PAM для уведомлений (успешный логин)
    local PAM_FILE="/etc/pam.d/sshd"
    local HOOK_LINE='session optional pam_exec.so /usr/local/bin/telegram_login_hook.sh'

    # Создаем скрипт-хук
    cat > /usr/local/bin/telegram_login_hook.sh << EOF
#!/bin/bash
# Отправка уведомления об успешном логине
source ${PWD}/config.conf # Считаем, что config.conf доступен

if [ "\$PAM_TYPE" == "open" ]; then
    SERVER_NAME="${SERVER_NAME}"
    USER="\$PAM_USER"
    RHOST="\$PAM_RHOST"
    TTY="\$PAM_TTY"

    # Формируем сообщение
    MESSAGE="🔑 *Успешный Вход по SSH*
    Пользователь: \`\$USER\`
    IP-адрес: \`\$RHOST\`
    Терминал: \`\$TTY\`
    Время: \`$(date '+%Y-%m-%d %H:%M:%S')\`"

    # Используем функцию send_telegram из lib/ui.sh
    # curl в фоне для асинхронной отправки
    curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=\${TELEGRAM_CHAT_ID}" \
        -d "text=\${MESSAGE}" \
        -d "parse_mode=Markdown" > /dev/null 2>&1 &
fi
EOF

    chmod +x /usr/local/bin/telegram_login_hook.sh

    # Добавляем хук в PAM, если его еще нет
    if ! grep -q "telegram_login_hook.sh" "$PAM_FILE"; then
        sed -i "/# Print the message of the day/i $HOOK_LINE" "$PAM_FILE"
        log "PAM-хук для уведомлений об успешном логине добавлен в ${PAM_FILE}."
    else
        log "PAM-хук уже присутствует в ${PAM_FILE}."
    fi

    # 2. Настройка ежедневного отчета через cron
    cat > /etc/cron.daily/security_daily_report << EOF
#!/bin/bash
# Запускает ежедневный отчет о безопасности
cd ${PWD} # Переходим в каталог скрипта для доступа к библиотекам
source ./lib/monitoring.sh
report_daily_status
EOF

    chmod +x /etc/cron.daily/security_daily_report
    log "Ежедневный отчет настроен (/etc/cron.daily/security_daily_report)."
}