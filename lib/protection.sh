#!/bin/bash
# ==============================================
# CORE PROTECTION MODULE
# Fail2Ban, Auditd, Secure Logging (chattr)
# ==============================================

setup_fail2ban() {
    log "Установка и настройка Fail2Ban..."
    apt install -y fail2ban

    # Создаем агрессивный конфиг
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = 3
ignoreip = 127.0.0.1/8 ::1 ${YOUR_IP}

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = ${F2B_MAXRETRY_SSH}
bantime = 86400

[sshd-ddos]
enabled = true
port = ${SSH_PORT}
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = ${F2B_MAXRETRY_DDOS}
bantime = 604800

[nginx-badbots]
enabled = true
port = http,https
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = ${F2B_MAXRETRY_WEB}
bantime = 86400
EOF

    # Фильтр для SSH DDoS атак
    cat > /etc/fail2ban/filter.d/sshd-ddos.conf << 'EOF'
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?Authentication failure for .* from <HOST>\s*$
            ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
            ^%(__prefix_line)sFailed password for .* from <HOST>\s*$
ignoreregex =
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
}

secure_logs() {
    log "Защита системных логов (chattr +a)..."

    touch /var/log/secured.log
    chmod 640 /var/log/secured.log

    # Устанавливаем атрибут "append-only" (+a)
    chattr +a /var/log/auth.log 2>/dev/null || true
    chattr +a /var/log/syslog 2>/dev/null || true
    chattr +a /var/log/messages 2>/dev/null || true
    chattr +a /var/log/secure 2>/dev/null || true
    chattr +a /var/log/secured.log 2>/dev/null || true

    # Дублируем логи в защищенное место через rsyslog
    echo "auth.*,syslog.* /var/log/secured.log" | tee /etc/rsyslog.d/secure.conf > /dev/null

    systemctl restart rsyslog

    log "Логи защищены. Для удаления нужно снять атрибут: chattr -a /var/log/имя_файла"
}

setup_audit() {
    log "Настройка аудита системы (auditd)..."
    apt install -y auditd audispd-plugins

    cat > /etc/audit/rules.d/security.rules << 'EOF'
# Мониторинг критичных файлов
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd

# Мониторинг команд от root
-a exit,always -F arch=b64 -F euid=0 -S execve -k root_cmds
-a exit,always -F arch=b32 -F euid=0 -S execve -k root_cmds

# Мониторинг удаления логов
-w /var/log/ -p wa -k delete_logs
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/syslog -p wa -k sys_log

# Мониторинг сетевых соединений
-a exit,always -F arch=b64 -S connect -k network_connections
EOF

    systemctl enable auditd
    systemctl restart auditd
}