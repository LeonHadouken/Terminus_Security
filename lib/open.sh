#!/bin/bash
# lib/open.sh
# Включение входа по паролю для root

CONF_FILE="/etc/ssh/sshd_config"

if [[ ! -f $CONF_FILE ]]; then
    echo "❌ Конфиг SSH не найден!"
    exit 1
fi

echo "🔧 Включаем вход по паролю для root..."
sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" $CONF_FILE
sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" $CONF_FILE

echo "Перезапускаем SSH..."
sudo systemctl restart ssh

echo "✅ Вход по паролю для root включен. Теперь можно подключаться через ssh root@SERVER_IP."
