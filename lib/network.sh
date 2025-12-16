#!/bin/bash
# ==============================================
# NETWORK & SSH HARDENING
# Настройка SSH, UFW, генерация и передача ключей
# ==============================================

setup_ssh_keys() {
    log "Настройка SSH ключей..."

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        log "Генерация нового SSH ключа Ed25519..."
        ssh-keygen -t ed25519 -a 100 -f /root/.ssh/id_ed25519 -N "" -C "root@${SERVER_NAME}-$(date +%Y%m%d)"
        chmod 600 /root/.ssh/id_ed25519
        chmod 644 /root/.ssh/id_ed25519.pub
    fi

    if [[ -f /root/.ssh/id_ed25519.pub ]]; then
        PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
        if ! grep -q "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
            echo "$PUBKEY" >> /root/.ssh/authorized_keys
            log "Публичный ключ добавлен в authorized_keys"
        fi
    fi

    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

    log "Ваш публичный SSH ключ:"
    echo "========================================="
    cat /root/.ssh/id_ed25519.pub
    echo "========================================="
}

transfer_ssh_key() {
    log "Автоматическая передача SSH ключа на клиент $YOUR_IP..."

    echo -e "\n=== АВТОМАТИЧЕСКАЯ ПЕРЕДАЧА SSH КЛЮЧА ==="
    echo "Для автоматической настройки доступа нужны данные от вашего клиента."

    read -p "Введите имя пользователя на клиенте (по умолчанию: root): " WSL_USER
    WSL_USER=${WSL_USER:-root}

    read -sp "Введите пароль пользователя '$WSL_USER' на клиенте: " WSL_PASSWORD
    echo ""

    if [[ -z "$WSL_PASSWORD" ]]; then
        error "Пароль не введен. Передача ключа отменена."
        return 1
    fi

    read -p "Порт SSH на клиенте (по умолчанию: 22): " WSL_PORT
    WSL_PORT=${WSL_PORT:-22}

    PUBKEY=$(cat /root/.ssh/id_ed25519.pub)

    if ! command -v sshpass &> /dev/null; then
        apt install -y sshpass
    fi

    log "Пытаюсь передать ключ на ${WSL_USER}@${YOUR_IP}:${WSL_PORT}..."

    SSH_CMD="mkdir -p ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

    if sshpass -p "$WSL_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $WSL_PORT \
       ${WSL_USER}@$YOUR_IP "$SSH_CMD" 2>/dev/null; then
        log "✅ Ключ успешно передан на ${WSL_USER}@${YOUR_IP}:${WSL_PORT}"
        # Тестируем подключение обратно
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -p $WSL_PORT ${WSL_USER}@$YOUR_IP "echo '✅ SSH подключение работает!'" 2>/dev/null; then
            log "✅ Автоматическая настройка успешна!"
        else
            warn "⚠️ Ключ передан, но тест подключения не пройден. Проверьте вручную."
        fi
        return 0
    else
        error "Не удалось передать ключ автоматически"
        error "Вручную добавьте этот ключ в ~/.ssh/authorized_keys на вашем клиенте:"
        echo -e "\n$PUBKEY\n"
        return 1
    fi
}

clean_traces() {
    log "Очистка следов передачи ключа (history)..."
    history -c
    > ~/.bash_history
    unset WSL_PASSWORD 2>/dev/null || true
    unset TEMP_PASS 2>/dev/null || true

    if [[ -f /var/log/auth.log ]]; then
        tail -100 /var/log/auth.log > /tmp/auth.log.tmp
        cat /tmp/auth.log.tmp > /var/log/auth.log
        rm -f /tmp/auth.log.tmp
    fi
}

setup_ssh_hardening() {
    log "Жесткая настройка SSH..."

    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        error "SSH ключ не найден! Невозможно настроить SSH без ключа."
        return 1
    fi

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)

    cat > /etc/ssh/sshd_config << EOF
Port ${SSH_PORT}
Protocol 2
ListenAddress 0.0.0.0

# Безопасность
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes

# Ограничения
AllowUsers root  # Добавьте сюда своих пользователей через пробел
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

    systemctl restart ssh
}

setup_ufw() {
    log "Настройка фаервола (UFW)..."
    apt install -y ufw

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    if [[ "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ufw allow from "$YOUR_IP" to any port ${SSH_PORT}/tcp comment "SSH from trusted IP"
        log "SSH разрешен только для IP: $YOUR_IP"
    else
        # Fallback: если IP не указан
        ufw allow ${SSH_PORT}/tcp comment "SSH (open to all - must fix!)"
        error "IP не указан! SSH открыт для всех! СРОЧНО настройте: sudo ufw allow from ВАШ_IP to any port ${SSH_PORT}"
    fi

    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    ufw --force enable
    log "Статус UFW:"
    ufw status verbose
}