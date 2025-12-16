#!/bin/bash
# ==============================================
# SECURITY TOOLS & BACKUP v2.0
# Установка ClamAV, RKHunter, AIDE, Honeypot (Cowrie в Docker)
# ==============================================

install_security_tools() {
    log "Установка инструментов безопасности..."

    apt install -y \
        rkhunter chkrootkit lynis \
        aide \
        nmap net-tools htop iftop nethogs \
        logwatch ncdu lsof \
        clamav clamav-daemon

    # ВНИМАНИЕ: AIDE инициализацию нужно выполнять ВРУЧНУЮ после установки
    # aideinit --force && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    log "AIDE установлен. Запустите ВРУЧНУЮ после настройки: aideinit --force"

    # Настройка ClamAV - исправленное имя сервиса
    log "Обновление и запуск ClamAV..."
    freshclam
    systemctl enable clamav-freshclam.timer  # ИСПРАВЛЕНО: правильное имя таймера
    systemctl start clamav-freshclam.timer

    # Ежедневное сканирование на руткиты - исправленная команда для cron
    cat > /etc/cron.daily/rkhunter_check << 'EOF'
#!/bin/bash
# Сгенерировано скриптом безопасности
/usr/bin/rkhunter --check --cronjob --quiet  # ИСПРАВЛЕНО: правильные флаги для cron
EOF
    chmod +x /etc/cron.daily/rkhunter_check
}

honeypot_setup() {
    log "Настройка продвинутого honeypot Cowrie на порту ${HONEYPOT_PORT}..."

    # Установка Docker если нет
    if ! command -v docker &> /dev/null; then
        log "Установка Docker..."
        apt install -y docker.io docker-compose
        systemctl enable docker
        systemctl start docker
    fi

    # Создание конфигурации для Cowrie
    local COWRIE_DIR="/opt/cowrie"
    mkdir -p $COWRIE_DIR

    # Docker Compose конфиг для Cowrie
    cat > $COWRIE_DIR/docker-compose.yml << EOF
version: '3.8'
services:
  cowrie:
    image: cowrie/cowrie:latest
    container_name: ssh_honeypot
    restart: always
    ports:
      - "${HONEYPOT_PORT}:2222"  # Внешний порт -> внутренний порт Cowrie
    volumes:
      - ./cowrie-data:/cowrie/cowrie-git/var
      - ./cowrie-logs:/cowrie/cowrie-git/log
    environment:
      - COWRIE_SSH_ENABLED=true
      - COWRIE_TELNET_ENABLED=false
      - COWRIE_SSH_PORT=2222
      - COWRIE_JSONLOG_ENABLED=true
    cap_add:
      - NET_ADMIN
    security_opt:
      - seccomp:unconfined
EOF

    # Запуск Cowrie
    cd $COWRIE_DIR
    docker-compose up -d

    # Настройка брандмауэра для honeypot порта
    ufw allow ${HONEYPOT_PORT}/tcp comment 'SSH Honeypot (Cowrie)'

    # Создание Telegram бота для мониторинга Cowrie
    create_cowrie_telegram_bot

    # Запуск мониторинга PCAP трафика
    start_pcap_monitoring

    log "Honeypot Cowrie запущен в Docker на порту ${HONEYPOT_PORT}"
    log "Логи: $COWRIE_DIR/cowrie-logs/"
    log "Данные: $COWRIE_DIR/cowrie-data/"
}

create_cowrie_telegram_bot() {
    log "Создание Telegram бота для мониторинга Cowrie..."

    local BOT_SCRIPT="/usr/local/bin/cowrie_telegram_bot.py"

    cat > $BOT_SCRIPT << 'EOF'
#!/usr/bin/env python3
import json
import time
import subprocess
import os
from datetime import datetime

TELEGRAM_BOT_TOKEN = "${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID = "${TELEGRAM_CHAT_ID}"
COWRIE_LOG_DIR = "/opt/cowrie/cowrie-logs"
PCAP_DIR = "/opt/cowrie/pcaps"

def send_telegram(message, parse_mode="Markdown"):
    """Отправка сообщения в Telegram"""
    cmd = [
        'curl', '-s', '-X', 'POST',
        f'https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage',
        '-d', f'chat_id={TELEGRAM_CHAT_ID}',
        '-d', f'text={message}',
        '-d', f'parse_mode={parse_mode}'
    ]
    subprocess.run(cmd, capture_output=True)

def get_ip_info(ip):
    """Получение информации об IP"""
    try:
        cmd = ['curl', '-s', f'http://ip-api.com/json/{ip}']
        result = subprocess.run(cmd, capture_output=True, text=True)
        info = json.loads(result.stdout)
        return {
            'country': info.get('country', 'N/A'),
            'city': info.get('city', 'N/A'),
            'org': info.get('org', 'N/A'),
            'as': info.get('as', 'N/A')
        }
    except:
        return {'country': 'N/A', 'city': 'N/A', 'org': 'N/A', 'as': 'N/A'}

def monitor_cowrie_logs():
    """Мониторинг логов Cowrie"""
    json_log = os.path.join(COWRIE_LOG_DIR, "cowrie.json")
    if not os.path.exists(json_log):
        return

    # Читаем последние события
    with open(json_log, 'r') as f:
        lines = f.readlines()
        if not lines:
            return

        # Обрабатываем последние 10 событий
        for line in lines[-10:]:
            try:
                event = json.loads(line.strip())
                event_id = event.get('eventid', '')
                src_ip = event.get('src_ip', '')
                session = event.get('session', '')

                if event_id == "cowrie.login.success":
                    username = event.get('username', 'N/A')
                    password = event.get('password', 'N/A')
                    ip_info = get_ip_info(src_ip)

                    msg = (f"🔓 *Успешный вход в Honeypot!*\n"
                           f"*Время:* `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`\n"
                           f"*IP:* `{src_ip}`\n"
                           f"*Страна:* `{ip_info['country']}`\n"
                           f"*Город:* `{ip_info['city']}`\n"
                           f"*Провайдер:* `{ip_info['org']}`\n"
                           f"*Учетка:* `{username}` / `{password}`\n"
                           f"*Сессия:* `{session}`")
                    send_telegram(msg)

                elif event_id == "cowrie.command.input":
                    command = event.get('input', 'N/A')
                    msg = (f"💻 *Команда в honeypot*\n"
                           f"*IP:* `{src_ip}`\n"
                           f"*Команда:* `{command}`\n"
                           f"*Сессия:* `{session}`")
                    send_telegram(msg)

                elif event_id == "cowrie.session.file_download":
                    url = event.get('url', 'N/A')
                    sha256 = event.get('shasum', 'N/A')
                    msg = (f"📥 *Скачан файл!*\n"
                           f"*IP:* `{src_ip}`\n"
                           f"*URL:* `{url}`\n"
                           f"*SHA256:* `{sha256}`\n"
                           f"*Сессия:* `{session}`")
                    send_telegram(msg)

            except json.JSONDecodeError:
                continue

if __name__ == "__main__":
    monitor_cowrie_logs()
EOF

    # Делаем скрипт исполняемым и подставляем переменные
    chmod +x $BOT_SCRIPT
    sed -i "s/\${TELEGRAM_BOT_TOKEN}/$TELEGRAM_BOT_TOKEN/g" $BOT_SCRIPT
    sed -i "s/\${TELEGRAM_CHAT_ID}/$TELEGRAM_CHAT_ID/g" $BOT_SCRIPT

    # Добавляем в cron каждые 5 минут
    (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/python3 $BOT_SCRIPT") | crontab -

    log "Telegram бот для Cowrie настроен и добавлен в cron"
}

start_pcap_monitoring() {
    log "Настройка захвата PCAP трафика для юридических доказательств..."

    # Установка tcpdump если нет
    apt install -y tcpdump

    local PCAP_DIR="/opt/cowrie/pcaps"
    mkdir -p $PCAP_DIR

    # Сервис для автоматического захвата трафика
    cat > /etc/systemd/system/honeypot-pcap.service << EOF
[Unit]
Description=Honeypot PCAP Capture Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/sbin/tcpdump -i any port ${HONEYPOT_PORT} -s 0 -w ${PCAP_DIR}/honeypot_%Y%m%d_%H%M%S.pcap -G 3600
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Сервис для ротации старых PCAP файлов (храним 30 дней)
    cat > /etc/cron.daily/cleanup-old-pcaps << 'EOF'
#!/bin/bash
find /opt/cowrie/pcaps -name "*.pcap" -mtime +30 -delete
EOF
    chmod +x /etc/cron.daily/cleanup-old-pcaps

    systemctl daemon-reload
    systemctl enable honeypot-pcap
    systemctl start honeypot-pcap

    log "PCAP захват трафика honeypot запущен. Файлы: $PCAP_DIR/"
    log "PCAP файлы хранятся 30 дней для юридических доказательств"
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

    # Добавляем бэкап конфигов Cowrie
    if [ -d "/opt/cowrie" ]; then
        cp -r /opt/cowrie/docker-compose.yml $BACKUP_DIR/ 2>/dev/null || true
    fi

    tar -czf ${BACKUP_DIR}.tar.gz -C ${BACKUP_DIR_BASE} $(basename $BACKUP_DIR)
    rm -rf $BACKUP_DIR

    log "Бэкап создан: $(basename ${BACKUP_DIR}.tar.gz)"
}