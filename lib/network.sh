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

# === ВАЖНО ===
# Для автоматической передачи SSH-ключа скрипт подключается
# С СЕРВЕРА → НА ВАШ КЛИЕНТ (WSL / Linux / macOS).
# На время выполнения у вас ДОЛЖЕН быть открыт SSH-доступ к клиенту.

echo ""
echo "⚠️  ВНИМАНИЕ: ТРЕБУЕТСЯ SSH-ДОСТУП К ВАШЕМУ КЛИЕНТУ"
echo ""
echo "Перед продолжением:"
echo "1) Откройте НОВОЕ окно терминала НА КЛИЕНТЕ (WSL / Linux / macOS)"
echo "2) Убедитесь, что SSH-сервер запущен:"
echo "   sudo systemctl status ssh || sudo service ssh status"
echo "3) Если SSH не запущен — запустите:"
echo "   sudo systemctl start ssh"
echo "4) Убедитесь, что порт (обычно 22) доступен извне"
echo ""
echo "После этого вернитесь В ЭТО ОКНО и нажмите Enter"
read -r

transfer_ssh_key() {
    log "Автоматическая передача SSH ключа на клиент $YOUR_IP..."

    echo -e "\n=== АВТОМАТИЧЕСКАЯ ПЕРЕДАЧА SSH КЛЮЧА ==="
    echo "Для автоматической настройки доступа нужны данные от вашего клиента."

    read -p "Введите имя пользователя на клиенте (по умолчанию: root): " WSL_USER
    WSL_USER=${WSL_USER:-root}

    read -p "Порт SSH на клиенте (по умолчанию: 22): " WSL_PORT
    WSL_PORT=${WSL_PORT:-22}

    PUBKEY=$(cat /root/.ssh/id_ed25519.pub)

    # Определяем WSL
    if grep -qEi "(Microsoft|WSL)" /proc/version &>/dev/null; then
        log "Обнаружена среда WSL. Автоматический проброс ключа невозможен (NAT/Firewall)."

        CLIENT_IP=$(ip addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
        log "Локальный IP WSL: $CLIENT_IP"

        echo -e "\n=== РУЧНАЯ УСТАНОВКА КЛЮЧА (WSL) ==="
        echo "Выполните на КЛИЕНТЕ (WSL):"
        echo
        echo "mkdir -p ~/.ssh"
        echo "nano ~/.ssh/authorized_keys"
        echo
        echo "Вставьте В КОНЕЦ файла этот ключ:"
        echo "-----------------------------------------"
        echo "$PUBKEY"
        echo "-----------------------------------------"
        echo
        echo "Затем выполните:"
        echo "chmod 700 ~/.ssh"
        echo "chmod 600 ~/.ssh/authorized_keys"
        echo
        echo "После выполнения нажмите ENTER для продолжения..."

        # Ожидание подтверждения пользователя
        read -r

        log "Продолжаем выполнение. Проверьте подключение позже командой:"
        log "ssh -i /root/.ssh/id_ed25519 ${WSL_USER}@${CLIENT_IP} -p ${WSL_PORT}"

        return 0
    fi

    # Обычный Linux-клиент (НЕ WSL)
    read -sp "Введите пароль пользователя '$WSL_USER' на клиенте: " WSL_PASSWORD
    echo ""

    if [[ -z "$WSL_PASSWORD" ]]; then
        warn "Пароль не введен. Переходим к ручной установке ключа."
    else
        if ! command -v sshpass &>/dev/null; then
            apt install -y sshpass
        fi

        SSH_CMD="mkdir -p ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

        log "Пытаюсь передать ключ на ${WSL_USER}@${YOUR_IP}:${WSL_PORT}..."

        if sshpass -p "$WSL_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$WSL_PORT" \
            "${WSL_USER}@${YOUR_IP}" "$SSH_CMD" 2>/dev/null; then
            log "✅ Ключ успешно передан автоматически"
            return 0
        fi
    fi

    # РУЧНОЙ ФОЛЛБЭК (НЕ ОШИБКА)
    warn "Автоматическая передача недоступна. Переход в ручной режим."

    echo -e "\n=== РУЧНАЯ УСТАНОВКА SSH КЛЮЧА ==="
    echo "На КЛИЕНТЕ выполните:"
    echo
    echo "mkdir -p ~/.ssh"
    echo "nano ~/.ssh/authorized_keys"
    echo
    echo "Добавьте этот ключ:"
    echo "-----------------------------------------"
    echo "$PUBKEY"
    echo "-----------------------------------------"
    echo
    echo "Права доступа:"
    echo "chmod 700 ~/.ssh"
    echo "chmod 600 ~/.ssh/authorized_keys"
    echo
    echo "После завершения нажмите ENTER для продолжения..."

    # Ожидание подтверждения
    read -r

    log "Продолжаем выполнение скрипта"
    return 0
}

echo ""
echo "=== ЗАВЕРШЕНИЕ ПРОБРОСА КЛЮЧА ==="
echo "Если вы открывали SSH-доступ ТОЛЬКО для передачи ключа:"
echo ""
echo "1) Вернитесь в окно терминала на клиенте"
echo "2) При необходимости закройте SSH-сервер:"
echo "   sudo systemctl stop ssh"
echo "3) Или просто закройте окно терминала"
echo ""
echo "🔒 Рекомендуется НЕ держать SSH-сервер на клиенте постоянно включённым."
echo ""


clean_traces() {
    log "Очистка следов передачи ключа (history)..."

    # Очистка истории bash
    history -c 2>/dev/null || true
    > ~/.bash_history 2>/dev/null || true

    # Удаление временных переменных паролей
    unset WSL_PASSWORD 2>/dev/null || true
    unset TEMP_PASS 2>/dev/null || true

    # Проверяем доступ к системному лог-файлу
    if [[ -f /var/log/auth.log ]]; then
        if [[ -w /var/log/auth.log ]]; then
            # Оставляем последние 100 строк, если есть права
            tail -100 /var/log/auth.log > /tmp/auth.log.tmp 2>/dev/null || true
            cat /tmp/auth.log.tmp > /var/log/auth.log 2>/dev/null || true
            rm -f /tmp/auth.log.tmp 2>/dev/null || true
            log "✅ /var/log/auth.log очищен, оставлено 100 последних строк"
        else
            warn "⚠️ Нет прав на запись /var/log/auth.log, пропускаем очистку (WSL или защищённый файл)"
        fi
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

    # Сбрасываем все правила
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Проверяем SSH_PORT
    if [[ -z "$SSH_PORT" ]] || ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        error "Неправильный порт SSH: '$SSH_PORT'. Используется порт 22 по умолчанию."
        SSH_PORT=22
    fi

    # Разрешаем SSH только с доверенного IP
    if [[ "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ufw allow from "$YOUR_IP" to any port "$SSH_PORT" proto tcp comment "SSH from trusted IP"
        log "SSH разрешен только для IP: $YOUR_IP:$SSH_PORT"
    else
        # fallback, если IP не указан — открыто для всех
        ufw allow "$SSH_PORT"/tcp comment "SSH (open to all - must fix!)"
        error "IP не указан! SSH открыт для всех! СРОЧНО настройте: sudo ufw allow from ВАШ_IP to any port $SSH_PORT"
        echo -e "\nНажмите ENTER после того как убедитесь в команде и внесли нужные изменения..."
        read -r
    fi

    # Открываем веб-порты
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    # Открываем порт для Honeypot (Cowrie) — открыт для всех
    if [[ -n "$HONEYPOT_PORT" ]] && [[ "$HONEYPOT_PORT" =~ ^[0-9]+$ ]]; then
        ufw allow "$HONEYPOT_PORT"/tcp comment "SSH Honeypot (Cowrie)"
        log "Honeypot порт $HONEYPOT_PORT открыт для всех"
    else
        warn "HONEYPOT_PORT не задан или неверен — Cowrie может не работать!"
    fi

    # Пауза перед включением UFW для проверки правил
    echo -e "\nПроверьте правила UFW. Нажмите ENTER, чтобы применить фаервол..."
    ufw status numbered
    read -r

    # Включаем UFW
    ufw --force enable
    log "Статус UFW после включения:"
    ufw status verbose
}
