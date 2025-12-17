#!/bin/bash
# ==============================================
# NETWORK & SSH HARDENING - ИСПРАВЛЕННАЯ ЛОГИКА
# ==============================================

setup_ssh_keys() {
    log "Подготовка SSH на СЕРВЕРЕ (prod)..."

    # --- Серверная часть ---
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    log "Сервер готов принимать клиентские ключи"

    echo ""
    echo "=================================================="
    echo "⚠️  ВНИМАНИЕ: КЛЮЧ ДОЛЖЕН БЫТЬ СОЗДАН НА КЛИЕНТЕ (WSL)"
    echo "=================================================="
    echo ""
    echo "ВЫПОЛНИ НА СВОЁМ ПК (WSL):"
    echo ""
    echo "1) Сгенерируй ключ (ЕСЛИ ЕГО ЕЩЁ НЕТ):"
    echo "   ssh-keygen -t ed25519 -a 100"
    echo ""
    echo "   Просто нажимай ENTER (путь по умолчанию)"
    echo ""
    echo "2) Скопируй публичный ключ:"
    echo "   cat ~/.ssh/id_ed25519.pub"
    echo ""
    echo "3) Скопируй ВЕСЬ вывод (одна строка)"
    echo ""
    echo "4) ВЕРНИСЬ СЮДА и вставь ключ"
    echo ""
    echo "=================================================="
    echo ""

    read -p "Нажми ENTER когда будешь готов вставить ключ"
}

transfer_ssh_key() {
    log "Добавление SSH ключа клиента (WSL)..."

    echo ""
    echo "ВСТАВЬ ПУБЛИЧНЫЙ КЛЮЧ ИЗ WSL"
    echo "Формат: ssh-ed25519 AAAA... user@wsl"
    echo "Ctrl+D — завершить ввод"
    echo ""

    local CLIENT_KEY=""
    while IFS= read -r line; do
        CLIENT_KEY+="$line"
    done

    if [[ -z "$CLIENT_KEY" ]]; then
        error "❌ Ключ не введён. Остановка."
        exit 1
    fi

    if ! [[ "$CLIENT_KEY" =~ ^ssh-ed25519\  ]]; then
        error "❌ Это НЕ ssh-ed25519 ключ"
        exit 1
    fi

    if grep -qxF "$CLIENT_KEY" /root/.ssh/authorized_keys; then
        warn "Ключ уже существует"
    else
        echo "$CLIENT_KEY" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        log "✅ Ключ клиента добавлен"
    fi

    echo ""
    echo "🔍 ПРОВЕРЬ ДОСТУП ПРЯМО СЕЙЧАС!"
    echo ""
    echo "В НОВОМ терминале WSL выполни:"
    echo "ssh root@$(hostname -I | awk '{print $1}')"
    echo ""
    echo "ЕСЛИ ВХОД УСПЕШЕН — возвращайся сюда"
    echo ""

    read -p "Нажми ENTER для продолжения (ЕСЛИ ВХОД ПРОВЕРЕН!)"
}

clean_traces() {
    log "Очистка следов..."

    # Очистка истории bash
    history -c 2>/dev/null || true
    > ~/.bash_history 2>/dev/null || true

    # Удаляем только переменные из этого скрипта
    unset WSL_PASSWORD 2>/dev/null || true

    # НЕ очищаем системные логи - это подозрительно и может мешать аудиту
    # Вместо этого просто логируем
    log "История bash очищена"
}

setup_ssh_hardening() {
    log "Жесткая настройка SSH..."

    # Проверяем, есть ли хотя бы один ключ для доступа
    if [[ ! -f /root/.ssh/authorized_keys ]] || [[ ! -s /root/.ssh/authorized_keys ]]; then
        error "❌ В authorized_keys нет ключей! Вы заблокируете себя!"
        echo ""
        echo "=== КРИТИЧЕСКАЯ ОШИБКА ==="
        echo "Добавьте хотя бы один ключ клиента перед продолжением!"
        echo "Выполните вручную:"
        echo "mkdir -p /root/.ssh"
        echo "nano /root/.ssh/authorized_keys"
        echo "Добавьте строку: ssh-ed25519 AAA... ваш_ключ"
        echo ""
        read -p "Продолжить? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    # Создаем бэкап
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        error "❌ authorized_keys ПУСТ — доступ будет потерян"
        exit 1
    fi
    # НАСТРОЙКА SSH ДЛЯ БЕЗОПАСНОСТИ
    cat > /etc/ssh/sshd_config << EOF
# ========================
# БЕЗОПАСНАЯ КОНФИГУРАЦИЯ SSH
# Автоматически настроено $(date)
# ========================

# Основные настройки
Port ${SSH_PORT}
Protocol 2
ListenAddress 0.0.0.0
AddressFamily inet

# = АУТЕНТИФИКАЦИЯ =
# ТОЛЬКО по ключу
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM no

# = ПОЛЬЗОВАТЕЛИ =
# Разрешаем доступ только по ключу
PermitRootLogin prohibit-password
# Если хотите запретить root совсем, используйте:
# PermitRootLogin no

# = ЗАЩИТА ОТ БРУТФОРСА =
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# = ДОПОЛНИТЕЛЬНАЯ БЕЗОПАСНОСТЬ =
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
TCPKeepAlive yes
Compression no
UseDNS no

# = ЛОГИРОВАНИЕ =
SyslogFacility AUTH
LogLevel VERBOSE
PrintLastLog yes

# = КРИПТОГРАФИЯ =
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.org
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# = ПОДСИСТЕМЫ =
Subsystem sftp internal-sftp -f AUTHPRIV -l INFO
EOF

    # Проверяем синтаксис
    if sshd -t; then
        systemctl restart ssh
        log "✅ SSH сервер перезапущен с безопасными настройками"

        # Проверяем статус
        if systemctl is-active --quiet ssh; then
            log "✅ SSH сервер работает"

            # Показываем информацию о ключах
            echo ""
            echo "=== ИНФОРМАЦИЯ О SSH ==="
            echo "Доступные ключи: $(wc -l < /root/.ssh/authorized_keys)"
            echo "Порт SSH: $SSH_PORT"
            echo "IP сервера: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
            echo ""
            echo "Для подключения используйте:"
            echo "ssh root@$(curl -s ifconfig.me || hostname -I | awk '{print $1}') -p $SSH_PORT -i ~/.ssh/id_ed25519"
            echo ""
        else
            error "❌ SSH сервер не запустился! Возвращаем бэкап..."
            cp /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S) /etc/ssh/sshd_config
            systemctl restart ssh
            return 1
        fi
    else
        error "❌ Ошибка в конфигурации SSH!"
        return 1
    fi
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

    # Проверяем YOUR_IP
    if [[ -z "$YOUR_IP" ]] || ! [[ "$YOUR_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "❌ YOUR_IP не указан или неверный: '$YOUR_IP'"
        echo ""
        echo "=== КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ ==="
        echo "Если продолжить, SSH порт $SSH_PORT будет ЗАКРЫТ для всех!"
        echo "Вы заблокируете себя на сервере!"
        echo ""
        echo "Правильный YOUR_IP можно узнать: curl ifconfig.me"
        echo ""
        read -p "Прервать настройку? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
        # Если продолжаем, порт SSH будет закрыт - это страховка от ошибок
    else
        # Разрешаем SSH ТОЛЬКО с вашего IP
        ufw allow from "$YOUR_IP" to any port "$SSH_PORT" proto tcp comment "SSH - только с моего IP"
        log "✅ SSH порт $SSH_PORT открыт ТОЛЬКО для $YOUR_IP"
    fi

    # Веб-порты для всех
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    # Honeypot порт для всех
    if [[ -n "$HONEYPOT_PORT" ]] && [[ "$HONEYPOT_PORT" =~ ^[0-9]+$ ]]; then
        ufw allow "$HONEYPOT_PORT"/tcp comment "SSH Honeypot (Cowrie) - для всех"
        log "✅ Honeypot порт $HONEYPOT_PORT открыт для ВСЕХ"
    fi

    # Показываем правила перед применением
    echo ""
    echo "=== ПРАВИЛА UFW ДЛЯ ПРОВЕРКИ ==="
    echo "Эти правила будут применены:"
    echo "-------------------------------"
    ufw status verbose
    echo "-------------------------------"

    # ВАЖНАЯ ПРОВЕРКА
    echo ""
    echo "=== ВАЖНАЯ ПРОВЕРКА ==="
    echo "Ваш IP: $YOUR_IP"
    echo "Порт SSH: $SSH_PORT"
    echo ""
    echo "Убедитесь, что $YOUR_IP — это ваш РЕАЛЬНЫЙ текущий IP!"
    echo "Иначе вы будете заблокированы!"
    echo ""

    read -p "Всё верно? Включить UFW? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ufw --force enable
        log "✅ UFW включен"

        # Сохраняем правила
        ufw status numbered > "/root/ufw-rules-$(date +%Y%m%d_%H%M%S).txt"

        # Показываем итог
        echo ""
        echo "=== ИТОГ НАСТРОЙКИ ==="
        echo "Порт $SSH_PORT открыт только для: $YOUR_IP"
        echo "Порт $HONEYPOT_PORT открыт для всех (honeypot)"
        echo "Порты 80, 443 открыты для всех (веб)"
        echo ""
        echo "Для подключения к серверу используйте:"
        echo "ssh root@$(curl -s ifconfig.me) -p $SSH_PORT -i ~/.ssh/id_ed25519"
    else
        warn "UFW не включен. Включите вручную: sudo ufw enable"
    fi
}

# Дополнительная функция для аварийного доступа
emergency_ufw_fix() {
    echo ""
    echo "=== АВАРИЙНЫЙ ДОСТУП ==="
    echo "Если вы заблокировали себя, выполните на сервере:"
    echo ""
    echo "1. Через веб-консоль провайдера или:"
    echo "   sudo ufw delete allow from $YOUR_IP to any port $SSH_PORT"
    echo "   sudo ufw allow 22/tcp"
    echo "   sudo ufw reload"
    echo ""
    echo "2. Или временно отключите UFW:"
    echo "   sudo ufw disable"
    echo ""
}