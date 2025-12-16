#!/bin/bash
# ==============================================
# MONITORING AND ALERTING
# Настройка PAM-алертов и ежедневных отчетов в Telegram
# ==============================================

setup_monitoring() {
    log "Настройка мониторинга и алертов..."

    # 1. Скрипт для отправки алертов в Telegram
    cat > /usr/local/bin/security-alert.sh << EOF
#!/bin/bash
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
SERVER_NAME="${SERVER_NAME}"

# Переменные PAM: PAM_USER, PAM_RHOST, PAM_SERVICE
case "\$1" in
    ssh_login)
        message="🔐 *Успешный SSH Вход*
👤 User: \${PAM_USER}
🔗 IP: \${PAM_RHOST}
📅 Time: \$(date)"
        ;;
    failed_login)
        message="⚠️ *Неудачная Попытка Входа*
👤 User: \${PAM_USER} (or unknown)
🚫 IP: \${PAM_RHOST}
📍 Service: \${PAM_SERVICE}"
        ;;
    *)
        message="ℹ️ System alert: \$1"
        ;;
esac

curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=\${TELEGRAM_CHAT_ID}" \
    -d "text=*Сервер: \${SERVER_NAME}*\n\${message}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

    chmod +x /usr/local/bin/security-alert.sh

    # 2. Интеграция с PAM для уведомлений о логинах
    # Добавляем только если еще не добавлено
    if ! grep -q "security-alert.sh" /etc/pam.d/sshd; then
        cat >> /etc/pam.d/sshd << 'EOF'
# --- SECURITY ALERT INTEGRATION ---
session optional pam_exec.so /usr/local/bin/security-alert.sh ssh_login
auth optional pam_exec.so seteuid /usr/local/bin/security-alert.sh failed_login
EOF
        log "Добавлена интеграция PAM для SSH."
    else
        warn "Интеграция PAM для SSH уже существует."
    fi

    # 3. Скрипт для ежедневного отчета
    cat > /etc/cron.daily/security-report << 'EOF'
#!/bin/bash
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
SERVER_NAME="${SERVER_NAME}"

# Проверка, есть ли access.log (иначе grep выдаст ошибку)
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
if [[ ! -f "$NGINX_ACCESS_LOG" ]]; then
    NGINX_REPORT="Nginx access log not found."
else
    BADBOTS_COUNT=$(grep "bot" "$NGINX_ACCESS_LOG" | grep "$(date -d yesterday '+%b %d')" | wc -l)
    NGINX_REPORT="🤖 Bad Bots/Traffic: ${BADBOTS_COUNT} hits"
fi


REPORT="📊 *Ежедневный Отчет Безопасности*
================================

🔐 *Успешные SSH Входы (вчера):*
$(grep "Accepted password\|Accepted publickey" /var/log/auth.log | grep "$(date -d yesterday '+%b %d')" | wc -l)

⚠️ *Неудачные Попытки SSH (вчера):*
$(grep "Failed password" /var/log/auth.log | grep "$(date -d yesterday '+%b %d')" | wc -l)

🚫 *Забаненные IP (Fail2Ban):*
$(fail2ban-client status sshd | grep "Currently banned" | cut -d: -f2)

🛡️ *Предупреждения RKHunter:*
$(/usr/bin/rkhunter --check --skip-keypress 2>&1 | grep -E "Warning:" | wc -l) warnings

🌐 *Веб-трафик:*
${NGINX_REPORT}

💾 *Занятость Диска Root:*
$(df -h / | tail -1)

================================
Отчет сгенерирован: $(date)"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=*Сервер: \${SERVER_NAME}*\n${REPORT}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

    chmod +x /etc/cron.daily/security-report
}