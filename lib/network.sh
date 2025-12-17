#!/bin/bash
# ==============================================
# NETWORK & SSH HARDENING - ИСПРАВЛЕННАЯ ЛОГИКА
# ==============================================

setup_ssh_keys() {
    log "Настройка SSH ключей на СЕРВЕРЕ..."

    # Создаем ключ на СЕРВЕРЕ для root (локального доступа)
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        log "Генерация локального SSH ключа Ed25519 для root..."
        ssh-keygen -t ed25519 -a 100 -f /root/.ssh/id_ed25519 -N "" -C "root@${SERVER_NAME}-$(date +%Y%m%d)"
        chmod 600 /root/.ssh/id_ed25519
        chmod 644 /root/.ssh/id_ed25519.pub
    fi

    # Но теперь также создаем ключ для КЛИЕНТА (это важно!)
    echo ""
    echo "=== КЛЮЧ ДЛЯ ДОСТУПА С КЛИЕНТА ==="
    echo "Для доступа к этому серверу с клиента вам нужно:"
    echo "1. Сгенерировать ключ на КЛИЕНТЕ:"
    echo "   ssh-keygen -t ed25519 -a 100"
    echo "2. Скопировать публичный ключ клиента на сервер"
    echo ""

    # Проверяем, есть ли уже ключи клиента
    if [[ -n "$CLIENT_PUB_KEY" ]]; then
        echo "$CLIENT_PUB_KEY" >> /root/.ssh/authorized_keys
        log "✅ Публичный ключ клиента добавлен из переменной CLIENT_PUB_KEY"
    else
        warn "⚠️  CLIENT_PUB_KEY не задан. Вам нужно будет добавить ключ вручную."
    fi

    log "Локальный публичный SSH ключ сервера (для инфо):"
    echo "========================================="
    cat /root/.ssh/id_ed25519.pub
    echo "========================================="

    # Важное предупреждение
    echo ""
    warn "⚠️  ВАЖНО: Этот ключ на сервере — для локального доступа."
    warn "Для подключения к серверу извне нужен ключ, сгенерированный на КЛИЕНТЕ!"
}

transfer_ssh_key() {
    log "Настройка SSH доступа к серверу..."

    echo ""
    echo "=== НАСТРОЙКА SSH ДОСТУПА ==="
    echo "Сейчас вы настраиваете доступ К СЕРВЕРУ."
    echo ""
    echo "Действуйте по инструкции:"
    echo "1. На КЛИЕНТЕ (ваш компьютер) выполните:"
    echo "   ssh-keygen -t ed25519 -a 100"
    echo "2. Скопируйте публичный ключ:"
    echo "   cat ~/.ssh/id_ed25519.pub"
    echo "3. Добавьте его в authorized_keys на сервере"
    echo ""

    read -p "Хотите добавить ключ клиента сейчас? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Введите публичный ключ с клиента (одна строка):"
        echo "Пример: ssh-ed25519 AAAAC3Nz... user@client"
        echo "Ввод (Ctrl+D для завершения):"

        local client_key=""
        while IFS= read -r line; do
            client_key+="$line"
        done

        if [[ -n "$client_key" ]]; then
            # Проверяем формат ключа
            if [[ "$client_key" =~ ^ssh- ]]; then
                mkdir -p /root/.ssh
                chmod 700 /root/.ssh
                touch /root/.ssh/authorized_keys
                grep -qxF "$client_key" /root/.ssh/authorized_keys || echo "$client_key" >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                log "✅ Ключ клиента добавлен в authorized_keys"

                # Сохраняем в переменную для конфига
                if [[ -f /root/ssh_client_keys.txt ]]; then
                    echo "$client_key" >> /root/ssh_client_keys.txt
                else
                    echo "$client_key" > /root/ssh_client_keys.txt
                fi
                chmod 600 /root/ssh_client_keys.txt
            else
                error "❌ Это не похоже на SSH ключ. Формат: ssh-ed25519 AAA..."
            fi
        else
            warn "Ключ не введен"
        fi
    fi

    # ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ
    echo ""
    echo "=== ВНИМАНИЕ: ТЕСТИРОВАНИЕ ДОСТУПА ==="
    echo "Перед продолжением УБЕДИТЕСЬ, что можете подключиться:"
    echo "1. Откройте новый терминал на КЛИЕНТЕ"
    echo "2. Выполните:"
    echo "   ssh root@$(curl -s ifconfig.me) -i ~/.ssh/id_ed25519"
    echo "3. Если подключение успешно — возвращайтесь и нажимайте ENTER"
    echo ""
    read -p "Нажмите ENTER чтобы продолжить (рискуете заблокироваться!)"
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