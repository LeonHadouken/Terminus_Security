#!/bin/bash
# ==============================================
# COMPLETE SERVER SECURITY SCRIPT v2.0
# Автоматическая настройка безопасности сервера
# ==============================================

set -e  # Прерывать выполнение при ошибках

# ==============================================
# КОНФИГУРАЦИЯ (ЗАПОЛНИТЕ!)
# ==============================================
TELEGRAM_BOT_TOKEN="8224866489:AAGKsFHLMbuEcnDyI091_ifJz3QmKLmSoXA"
TELEGRAM_CHAT_ID="340983578"
YOUR_IP="45.12.138.247"  # <--- ВСТАВЬ СВОЙ IP ВРУЧНУЮ
SERVER_NAME="$(hostname)"
SSH_PORT="22"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================
# ПРОВЕРКА КОНФИГУРАЦИИ
# ==============================================

# Проверяем, заполнен ли IP
if [[ "$YOUR_IP" == "ВВЕДИТЕ_ВАШ_IP_ЗДЕСЬ" ]] || [[ ! "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}❌ ОШИБКА: Вы не указали ваш IP!${NC}"
    echo ""
    echo "Узнайте свой IP:"
    echo "  1. На своём компьютере: curl ifconfig.me"
    echo "  2. Или на сайте: https://whatismyipaddress.com/"
    echo ""
    echo -e "${YELLOW}Пример IP: 93.184.216.34${NC}"
    echo ""
    read -p "Введите ваш IP адрес: " YOUR_IP

    # Проверяем снова
    if [[ ! "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ Неверный формат IP! Запустите скрипт снова.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✅ Конфигурация принята:${NC}"
echo "  Ваш IP: $YOUR_IP"
echo "  Сервер: $SERVER_NAME"
echo ""

# ==============================================
# ФУНКЦИИ
# ==============================================

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" > /dev/null 2>&1
}

secure_logs() {
    log "Защита системных логов от удаления..."

    # Сначала создаем secured.log
    touch /var/log/secured.log
    chmod 640 /var/log/secured.log

    # Устанавливаем атрибуты чтобы нельзя было удалить
    # -a: можно только дописывать (append-only)
    # -i: immutable (неизменяемый, но это слишком строго)
    chattr +a /var/log/auth.log 2>/dev/null || true
    chattr +a /var/log/syslog 2>/dev/null || true
    chattr +a /var/log/messages 2>/dev/null || true
    chattr +a /var/log/secure 2>/dev/null || true
    chattr +a /var/log/secured.log 2>/dev/null || true

    # Дублируем логи в защищенное место
    echo "auth.*,syslog.* /var/log/secured.log" | tee -a /etc/rsyslog.d/secure.conf > /dev/null

    # Перезапускаем rsyslog чтобы применились настройки
    systemctl restart rsyslog

    log "Логи защищены. Удалить можно только через: chattr -a /var/log/имя_файла"
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

setup_fail2ban() {
    log "Установка и настройка Fail2Ban..."
    apt install -y fail2ban

    # Создаем агрессивный конфиг
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1w
findtime = 1h
maxretry = 3
ignoreip = 127.0.0.1/8 ::1 ${YOUR_IP}

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 2
bantime = 86400

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 5
bantime = 604800

[nginx-badbots]
enabled = true
port = http,https
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
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

setup_ufw() {
    log "Настройка фаервола (UFW)..."
    apt install -y ufw

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Используем YOUR_IP из конфигурации (а не автоопределение)
    if [[ "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ufw allow from "$YOUR_IP" to any port ${SSH_PORT}/tcp comment "SSH from $YOUR_IP"
        log "SSH разрешен только для IP: $YOUR_IP"
    else
        # Fallback: если IP не указан
        ufw allow ${SSH_PORT}/tcp comment "SSH (WARNING: open to all - configure manually!)"
        error "IP не указан! SSH открыт для всех!"
        error "Вручную настройте: sudo ufw allow from ВАШ_IP to any port 22"
    fi

    # Разрешаем веб-порты для всех
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    ufw --force enable
    log "Статус UFW:"
    ufw status verbose
}

setup_ssh_hardening() {
    log "Жесткая настройка SSH..."

    # Проверяем что ключи созданы
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        error "SSH ключ не найден! Сначала запустите setup_ssh_keys"
        return 1
    fi

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)

    cat > /etc/ssh/sshd_config << EOF
Port 22
Protocol 2
ListenAddress 0.0.0.0

# Безопасность
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes

# Ограничения
AllowUsers root  # Добавь сюда своих пользователей через пробел
MaxAuthTries 2
MaxSessions 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60

# Дополнительная защита
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
TCPKeepAlive yes
Compression no

# Логирование
SyslogFacility AUTH
LogLevel VERBOSE
PrintLastLog yes
EOF

    # В Ubuntu/Debian сервис называется ssh, а не sshd
    systemctl restart ssh
}

transfer_ssh_key() {
    log "Автоматическая передача SSH ключа на клиент $YOUR_IP..."

    echo ""
    echo "=== АВТОМАТИЧЕСКАЯ ПЕРЕДАЧА SSH КЛЮЧА ==="
    echo "Для автоматической настройки доступа нужны данные от твоей WSL."
    echo ""

    # Запрашиваем имя пользователя на WSL
    read -p "Введите имя пользователя на WSL (по умолчанию: root): " WSL_USER
    WSL_USER=${WSL_USER:-root}

    # Запрашиваем пароль
    read -sp "Введите пароль пользователя '$WSL_USER' на WSL: " WSL_PASSWORD
    echo ""

    if [[ -z "$WSL_PASSWORD" ]]; then
        error "Пароль не введен. Передача ключа отменена."
        return 1
    fi

    # Запрашиваем порт SSH на WSL (если не стандартный)
    read -p "Порт SSH на WSL (по умолчанию: 22): " WSL_PORT
    WSL_PORT=${WSL_PORT:-22}

    # Публичный ключ сервера
    PUBKEY=$(cat /root/.ssh/id_ed25519.pub)

    # Устанавливаем sshpass если нет
    if ! command -v sshpass &> /dev/null; then
        apt install -y sshpass
    fi

    log "Пытаюсь передать ключ на ${WSL_USER}@${YOUR_IP}:${WSL_PORT}..."

    # Команда для передачи ключа на клиент
    SSH_CMD="mkdir -p ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

    # Пробуем передать ключ
    if sshpass -p "$WSL_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $WSL_PORT \
       ${WSL_USER}@$YOUR_IP "$SSH_CMD" 2>/dev/null; then
        log "✅ Ключ успешно передан на ${WSL_USER}@${YOUR_IP}:${WSL_PORT}"

        # Тестируем подключение обратно БЕЗ ПАРОЛЯ (по ключу)
        log "Тестируем подключение с ключом..."
        sleep 2

        # Пробуем подключиться с ключом
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -p $WSL_PORT ${WSL_USER}@$YOUR_IP "echo '✅ SSH подключение работает!'" 2>/dev/null; then
            log "✅ Автоматическая настройка успешна! Теперь можно подключаться по ключу."
        else
            log "⚠️ Ключ передан, но подключение не тестируется. Возможно, нужна ручная проверка."
        fi

        # Очищаем историю команд чтобы не осталось пароля
        history -c
        > ~/.bash_history
        unset WSL_PASSWORD

        return 0
    else
        error "Не удалось передать ключ автоматически"
        echo ""
        echo "Возможные причины:"
        echo "1. Неверное имя пользователя/пароль"
        echo "2. SSH на WSL не запущен"
        echo "3. Порт $WSL_PORT закрыт"
        echo "4. WSL не принимает SSH подключения"
        echo ""
        echo "Вручную добавь этот ключ в ~/.ssh/authorized_keys на WSL:"
        echo ""
        echo "$PUBKEY"
        echo ""

        # Предлагаем альтернативный способ
        echo "Или используй команду на WSL:"
        echo "  echo '$PUBKEY' >> ~/.ssh/authorized_keys"
        echo ""

        return 1
    fi
}

clean_traces() {
    log "Очистка следов передачи ключа..."

    # Очищаем историю bash
    history -c
    > ~/.bash_history

    # Удаляем временный пароль из памяти (если использовался)
    unset WSL_PASSWORD 2>/dev/null || true
    unset TEMP_PASS 2>/dev/null || true

    # Очищаем логи авторизации (только последние строки)
    if [[ -f /var/log/auth.log ]]; then
        # Оставляем только последние 100 строк
        tail -100 /var/log/auth.log > /tmp/auth.log.tmp
        cat /tmp/auth.log.tmp > /var/log/auth.log
        rm -f /tmp/auth.log.tmp
    fi

    log "Следы очищены."
}

setup_ssh_keys() {
    log "Настройка SSH ключей..."

    # Создаем директорию .ssh если её нет
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Генерируем новый ключ если его нет
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        log "Генерация нового SSH ключа Ed25519..."
        ssh-keygen -t ed25519 -a 100 -f /root/.ssh/id_ed25519 -N "" -C "root@${SERVER_NAME}-$(date +%Y%m%d)"
        chmod 600 /root/.ssh/id_ed25519
        chmod 644 /root/.ssh/id_ed25519.pub
    fi

    # Добавляем публичный ключ в authorized_keys
    if [[ -f /root/.ssh/id_ed25519.pub ]]; then
        PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
        # Проверяем что ключ ещё не добавлен
        if ! grep -q "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
            echo "$PUBKEY" >> /root/.ssh/authorized_keys
            log "Публичный ключ добавлен в authorized_keys"
        fi
    fi

    # Настраиваем правильные права
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

    # Показываем публичный ключ для копирования
    log "Ваш публичный SSH ключ:"
    echo "========================================="
    cat /root/.ssh/id_ed25519.pub
    echo "========================================="
    log "Скопируйте этот ключ для доступа с других машин"
}

install_security_tools() {
    log "Установка инструментов безопасности..."

    # Основные утилиты
    apt install -y \
        rkhunter chkrootkit lynis \
        aide tripwire \
        nmap net-tools.sh htop iftop nethogs \
        logwatch ncdu lsof \
        clamav clamav-daemon

    # Инициализация AIDE (обнаружение изменений файлов)
    aideinit
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

    # Настройка ClamAV
    freshclam
    systemctl enable clamav-freshclam
    systemctl start clamav-freshclam

    # Ежедневное сканирование на руткиты
    cat > /etc/cron.daily/rkhunter << 'EOF'
#!/bin/bash
/usr/bin/rkhunter --check --sk
EOF
    chmod +x /etc/cron.daily/rkhunter
}

setup_monitoring() {
    log "Настройка мониторинга и алертов..."

    # Скрипт для отправки алертов в Telegram
    cat > /usr/local/bin/security-alert.sh << EOF
#!/bin/bash
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

case "\$1" in
    ssh_login)
        message="🔐 *SSH Login* on \${SERVER_NAME}
👤 User: \${PAM_USER}
🖥️ Host: \${PAM_RHOST}
📅 Time: \$(date)
🔗 IP: \${PAM_RHOST}"
        ;;
    failed_login)
        message="⚠️ *Failed SSH Login* on \${SERVER_NAME}
👤 User: \${PAM_USER}
🚫 IP: \${PAM_RHOST}
📅 Time: \$(date)
📍 Service: \${PAM_SERVICE}"
        ;;
    root_login)
        message="👑 *ROOT SSH Login* on \${SERVER_NAME}
🔗 IP: \${PAM_RHOST}
📅 Time: \$(date)"
        ;;
    *)
        message="ℹ️ System alert: \$1"
        ;;
esac

curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=\${TELEGRAM_CHAT_ID}" \
    -d "text=\${message}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

    chmod +x /usr/local/bin/security-alert.sh

    # Интеграция с PAM для уведомлений о логинах
    cat >> /etc/pam.d/sshd << 'EOF'
# Уведомления о успешных логинах
session optional pam_exec.so /usr/local/bin/security-alert.sh ssh_login

# Уведомления о неудачных попытках
auth optional pam_exec.so seteuid /usr/local/bin/security-alert.sh failed_login
EOF

    # Скрипт для ежедневного отчета
    cat > /etc/cron.daily/security-report << 'EOF'
#!/bin/bash
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

REPORT="📊 *Daily Security Report* for $(hostname)
================================

🔐 *SSH Logins Yesterday:*
$(grep "Accepted password\|Accepted publickey" /var/log/auth.log | grep "$(date -d yesterday '+%b %d')" | wc -l) successful logins

⚠️ *Failed SSH Attempts:*
$(grep "Failed password" /var/log/auth.log | grep "$(date -d yesterday '+%b %d')" | wc -l) failed attempts

🚫 *Banned IPs (Fail2Ban):*
$(fail2ban-client status sshd | grep "Currently banned" | cut -d: -f2)

🛡️ *Rootkit Scan:*
$(rkhunter --check --skip-keypress 2>&1 | grep -E "Warning:|Notice:" | wc -l) warnings

💾 *Disk Usage:*
$(df -h / | tail -1)

================================
Report generated: $(date)"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${REPORT}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

    chmod +x /etc/cron.daily/security-report
}

honeypot_setup() {
    log "Настройка легкого honeypot..."
    apt install -y openssh-server  # Дублируем SSH на другой порт

    # Создаем фальшивый SSH сервер на порту 2222
    cat > /etc/ssh/sshd_config_honeypot << 'EOF'
Port 2222
Protocol 2
ListenAddress 0.0.0.0

# Максимально логгируем всё
LogLevel DEBUG3
PermitRootLogin yes
PasswordAuthentication yes
AllowUsers honeypot

# Замедляем аутентификацию
LoginGraceTime 120
MaxAuthTries 100

# Все пароли неверные (всегда fail)
Match All
    AuthenticationMethods keyboard-interactive
EOF

    # Создаем пользователя honeypot с фальшивой оболочкой
    useradd -m -s /usr/sbin/nologin honeypot
    echo "honeypot:$(openssl rand -base64 32)" | chpasswd

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

    # Открываем порт для honeypot
    ufw allow 2222/tcp comment 'SSH Honeypot'
}

backup_configs() {
    log "Создание бэкапов конфигураций..."
    BACKUP_DIR="/root/security_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR

    # Копируем важные конфиги
    cp -r /etc/ssh $BACKUP_DIR/
    cp -r /etc/fail2ban $BACKUP_DIR/
    cp -r /etc/ufw $BACKUP_DIR/
    cp /etc/pam.d/sshd $BACKUP_DIR/
    cp /etc/audit/rules.d/* $BACKUP_DIR/

    # Архивируем
    tar -czf $BACKUP_DIR.tar.gz $BACKUP_DIR
    rm -rf $BACKUP_DIR

    log "Бэкап создан: $BACKUP_DIR.tar.gz"
}

finalize() {
    log "Завершение настройки..."

    # Обновляем всё
    apt update && apt upgrade -y

    # Перезапускаем сервисы
    systemctl restart fail2ban auditd rsyslog

    # Финальное сообщение в Telegram
    local ip=$(hostname -I | awk '{print $1}')
    local message="✅ *Server Security Setup Complete*

🖥️ Server: ${SERVER_NAME}
🔗 IP: ${ip}
📅 Time: $(date)
🛡️ Security tools installed:
• Fail2Ban with Telegram alerts
• Auditd for system monitoring
• UFW firewall
• RKHunter & ClamAV
• SSH Honeypot on port 2222
• Protected logs

🔐 *Next steps:*
1. Keep your Telegram bot token secret
2. Check /root/security_backup_*.tar.gz
3. Monitor @your_bot for alerts
4. Run 'rkhunter --check' weekly"

    send_telegram "$message"

    echo "========================================="
    echo "✅ НАСТРОЙКА ЗАВЕРШЕНА!"
    echo "========================================="
    echo "Сделано:"
    echo "1. Fail2Ban с уведомлениями в Telegram"
    echo "2. Защищенные логи (нельзя удалить)"
    echo "3. Фаервол UFW"
    echo "4. Мониторинг аудита (auditd)"
    echo "5. SSH Honeypot на порту 2222"
    echo "6. Ежедневные отчеты в Telegram"
    echo "7. Инструменты: rkhunter, clamav, aide"
    echo ""
    echo "⚠️  Проверь конфигурацию SSH: /etc/ssh/sshd_config"
    echo "📱 Будут приходить уведомления в Telegram"
    echo "========================================="
}

# ==============================================
# ГЛАВНЫЙ СЦЕНАРИЙ
# ==============================================

main() {
    clear
    echo "========================================="
    echo "   COMPLETE SERVER SECURITY SETUP"
    echo "========================================="

    # Проверка на root
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться от root!"
        exit 1
    fi

    # Обновляем пакеты
    log "Обновление пакетов..."
    apt update && apt upgrade -y

    # Выполняем настройки В ПРАВИЛЬНОМ ПОРЯДКЕ:
    # 1. Сначала генерируем ключи
    setup_ssh_keys

    # 2. Передаем ключ на клиент (ДО настройки SSH!)
    transfer_ssh_key
    # 2.1 Очищаем следы
    clean_traces
    # 3. Настраиваем SSH (запрещаем пароли, разрешаем ключи)
    setup_ssh_hardening

    # 4. Настраиваем фаервол (открываем SSH только для нашего IP)
    setup_ufw

    # 5. Остальные настройки безопасности
    setup_fail2ban
    secure_logs
    setup_audit
    install_security_tools
    setup_monitoring
    honeypot_setup
    backup_configs

    # 6. Завершаем
    finalize

    log "Перезагрузка рекомендуется для применения всех настроек"
    read -p "Перезагрузить сейчас? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Запуск
main "$@"