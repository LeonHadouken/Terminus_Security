#!/bin/bash
# ==============================================
# SECURITY TOOLS & BACKUP
# Установка ClamAV, RKHunter, AIDE, Honeypot
# ==============================================

install_security_tools() {
    log "Установка инструментов безопасности..."

    apt install -y \
        rkhunter chkrootkit lynis \
        aide \
        nmap net-tools htop iftop nethogs \
        logwatch ncdu lsof \
        clamav clamav-daemon

    # Инициализация AIDE (обнаружение изменений файлов)
    log "Инициализация AIDE..."
    aideinit 2>/dev/null || true # Игнорируем ошибки, если уже инициализирован
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true

    # Настройка ClamAV
    log "Обновление и запуск ClamAV..."
    freshclam
    systemctl enable clamav-freshclam
    systemctl start clamav-freshclam

    # Ежедневное сканирование на руткиты
    cat > /etc/cron.daily/rkhunter_check << 'EOF'
#!/bin/bash
# Сгенерировано скриптом безопасности
/usr/bin/rkhunter --check --sk
EOF
    chmod +x /etc/cron.daily/rkhunter_check
}

honeypot_setup() {
    log "Настройка легкого honeypot на порту ${HONEYPOT_PORT}..."
    apt install -y openssh-server

    # Создаем фальшивый SSH сервер
    cat > /etc/ssh/sshd_config_honeypot << EOF
Port ${HONEYPOT_PORT}
Protocol 2
ListenAddress 0.0.0.0
LogLevel DEBUG3
PermitRootLogin yes
PasswordAuthentication yes
AllowUsers honeypot
LoginGraceTime 120
MaxAuthTries 100
Match All
    AuthenticationMethods keyboard-interactive
EOF

    # Создаем пользователя honeypot
    if ! id "honeypot" &>/dev/null; then
        useradd -m -s /usr/sbin/nologin honeypot
        echo "honeypot:$(openssl rand -base64 32)" | chpasswd
    fi

    # Сервис для honeypot
    cat > /etc/systemd/system/ssh-honeypot.service << 'EOF'
[Unit]
Description=SSH Honeypot Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -f /etc/ssh/sshd_config_honeypot -D
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ssh-honeypot
    systemctl start ssh-honeypot

    ufw allow ${HONEYPOT_PORT}/tcp comment 'SSH Honeypot'
    log "Honeypot запущен и доступен через UFW на порту ${HONEYPOT_PORT}"
}

backup_configs() {
    log "Создание бэкапов конфигураций..."
    local BACKUP_DIR="${BACKUP_DIR_BASE}/config_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR

    cp -r /etc/ssh $BACKUP_DIR/
    cp -r /etc/fail2ban $BACKUP_DIR/
    cp -r /etc/ufw $BACKUP_DIR/
    cp /etc/pam.d/sshd $BACKUP_DIR/
    cp /etc/audit/rules.d/* $BACKUP_DIR/ 2>/dev/null || true

    tar -czf ${BACKUP_DIR}.tar.gz -C ${BACKUP_DIR_BASE} $(basename $BACKUP_DIR)
    rm -rf $BACKUP_DIR

    log "Бэкап создан: $(basename ${BACKUP_DIR}.tar.gz)"
}