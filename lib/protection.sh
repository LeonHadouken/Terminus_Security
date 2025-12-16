#!/bin/bash
# ==============================================
# PROTECTION FUNCTIONS
# Настройка Fail2Ban, Auditd, Защита логов
# ==============================================

setup_fail2ban() {
    log "Установка и настройка Fail2Ban..."
    apt install -y fail2ban

    # Копируем базовую конфигурацию
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

    # Настройка уведомлений в Telegram через Fail2Ban Action
    local ACTION_FILE="/etc/fail2ban/action.d/telegram.conf"

    # Создаем action file
    cat > $ACTION_FILE << EOF
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = curl -s -X POST https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage -d chat_id=${TELEGRAM_CHAT_ID} -d text="❌ *Fail2Ban BAN* на ${SERVER_NAME}! IP: <ip> забанен на <bantime> секунд. Причина: <failures> попыток. Фильтр: <name>." -d parse_mode=Markdown
actionunban = curl -s -X POST https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage -d chat_id=${TELEGRAM_CHAT_ID} -d text="✅ *Fail2Ban UNBAN* на ${SERVER_NAME}! IP: <ip> разбанен. Фильтр: <name>." -d parse_mode=Markdown
EOF

    # Применяем Telegram-действие к SSH
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    # Активация и настройка sshd
    sed -i 's/^#\[sshd\]/\[sshd\]\n\nenabled = true/' "$JAIL_LOCAL"
    # Меняем bantime и findtime на более агрессивные
    sed -i 's/^bantime = 10m/bantime = 1h/g' "$JAIL_LOCAL"
    sed -i 's/^findtime = 10m/findtime = 5m/g' "$JAIL_LOCAL"
    sed -i 's/^maxretry = 5/maxretry = 3/g' "$JAIL_LOCAL"

    # Добавляем действие Telegram
    if ! grep -q "action = telegram" "$JAIL_LOCAL"; then
        sed -i "/^\[sshd\]/a action = \n    sshd-ddos\n    %(action_mwl)s\n    telegram" "$JAIL_LOCAL"
    fi

    # Добавляем фильтр для Nginx (если установлен)
    if command -v nginx &> /dev/null; then
        log "Настройка фильтра Nginx для защиты от HTTP-атак..."
        if ! grep -q "\[nginx-http-auth\]" "$JAIL_LOCAL"; then
            echo -e "\n[nginx-http-auth]\nenabled = true\nport = http,https\nlogpath = %(nginx_error_log)s\nmaxretry = 3\nbantime = 1h\naction = %(action_mwl)s\n    telegram" >> "$JAIL_LOCAL"
        fi
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "Fail2Ban настроен и запущен с уведомлениями в Telegram."
}

secure_logs() {
    log "Защита критических логов от удаления (chattr +a)..."

    local LOG_FILES=(
        /var/log/syslog
        /var/log/auth.log
        /var/log/kern.log
        /var/log/dmesg
        /var/log/boot.log
    )

    for file in "${LOG_FILES[@]}"; do
        if [ -f "$file" ]; then
            chattr +a "$file"
            #log "Установлен атрибут '+a' (только добавление) для $file"
        fi
    done

    log "Критические логи защищены от удаления. Для изменения требуется 'chattr -a <file>'."
}

setup_audit() {
    log "Настройка системного аудита (Auditd)..."
    apt install -y auditd audispd-plugins

    # Создаем базовый набор правил для мониторинга
    local RULES_FILE="/etc/audit/rules.d/99-custom-security.conf"

    cat > $RULES_FILE << 'EOF'
# ИММУТАБЕЛЬНОСТЬ: Должно быть в начале
-D

# 1. Мониторинг изменений критических файлов (UID=0, SUID/SGID)
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# 2. Мониторинг настроек сети
-w /etc/hosts -p wa -k network_config
-w /etc/network -p wa -k network_config
-w /etc/resolv.conf -p wa -k network_config

# 3. Мониторинг доступа к конфигам SSH
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /root/.ssh/authorized_keys -p wa -k ssh_root_keys

# 4. Мониторинг попыток доступа к логам
-w /var/log/audit/ -p wa -k audit_logs

# 5. Мониторинг системных вызовов, связанных с изменением времени
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S stime -k time_change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time_change

# 6. Блокируем любые изменения в правилах (Должно быть в конце)
-e 2
EOF

    # Загружаем правила
    augenrules --load

    # Проверка, что Auditd запущен
    systemctl enable auditd
    systemctl restart auditd

    log "Auditd настроен. Мониторятся критические изменения файлов и системные вызовы."
}