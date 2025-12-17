#!/bin/bash
# ==============================================
# MAIN SECURITY EXECUTION SCRIPT v3.1 (Parallel + Menu)
# Автоматическая настройка безопасности сервера
# ==============================================

set -euo pipefail  # строгий режим + защита от неинициализированных переменных

# --- ЗАГРУЗКА КОНФИГУРАЦИИ И БИБЛИОТЕК ---
if [[ ! -f ./config.conf ]] || [[ ! -d ./lib ]]; then
    echo "❌ Ошибка: Отсутствует config.conf или директория lib."
    echo "Убедитесь, что все файлы находятся в директориях, как указано в README.md."
    exit 1
fi

source ./config.conf
source ./lib/ui.sh
source ./lib/network.sh
source ./lib/protection.sh
source ./lib/monitoring.sh
source ./lib/tools.sh

# ==============================================
# ПРОВЕРКА КОНФИГУРАЦИИ
# ==============================================
check_config() {
    if [[ ! "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ ОШИБКА: Вы не указали ваш IP или формат неверный!${NC}"
        read -p "Введите ваш IP адрес: " YOUR_IP
        if [[ ! "$YOUR_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "Неверный формат IP! Запустите скрипт снова."
            exit 1
        fi
        sed -i "s/^YOUR_IP=.*/YOUR_IP=\"$YOUR_IP\"/" config.conf
    fi

    echo -e "${GREEN}✅ Конфигурация принята:${NC}"
    echo "  Ваш IP: $YOUR_IP"
    echo "  Сервер: $SERVER_NAME"
    echo "  Honeypot: $HONEYPOT_PORT"
    echo ""
}

# ==============================================
# МЕНЮ ДЛЯ ВЫБОРА ЭТАПОВ
# ==============================================
show_menu() {
    clear
    echo "========================================="
    echo "   SERVER SECURITY SETUP MENU"
    echo "========================================="
    echo "1) Полная установка (все этапы)"
    echo "2) Этап 1: Сеть и SSH (ключи, фаервол)"
    echo "3) Этап 2: Защита и мониторинг (Fail2Ban, логирование, сканеры)"
    echo "4) Honeypot Cowrie (Docker + PCAP)"
    echo "5) Включить вход по паролю для root (SSH)"
    echo "6) Выход"
    echo "========================================="
    read -rp "Выберите действие [1-6]: " choice

    case $choice in
        1) main_full=true ;;
        2) main_ssh=true ;;
        3) main_protect=true ;;
        4) main_honeypot=true ;;
        5) main_open_password=true ;;
        6) exit 0 ;;
        *) echo "❌ Неверный выбор"; read -rp "ENTER для продолжения..."; show_menu ;;
    esac
}

# ==============================================
# ГЛАВНЫЙ СЦЕНАРИЙ
# ==============================================
main() {
    clear
    echo "========================================="
    echo "   SERVER SECURITY SETUP (PARALLEL + MENU)"
    echo "========================================="

    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться от root!"
        exit 1
    fi

    check_config
    show_menu

    # --- Этап 1: SSH и сеть ---
    if [[ "${main_full:-false}" == true ]] || [[ "${main_ssh:-false}" == true ]]; then
        log "--- [ЭТАП 1/2: SSH и СЕТЬ] ---"
        setup_ssh_keys
        transfer_ssh_key
        clean_traces
        setup_ssh_hardening
        setup_ufw
    fi

    # --- Этап 2: Защита и мониторинг ---
    if [[ "${main_full:-false}" == true ]] || [[ "${main_protect:-false}" == true ]]; then
        log "--- [ЭТАП 2/2: ЗАЩИТА И МОНИТОРИНГ] ---"
        start_task setup_fail2ban "Fail2Ban"
        start_task secure_logs "Защита логов"
        start_task setup_audit "Auditd"
        start_task install_security_tools "Сканеры (RKHunter, ClamAV, AIDE)"
        start_task setup_monitoring "Мониторинг Telegram"
        wait_for_tasks
    fi

    # --- Этап 3: Honeypot ---
    if [[ "${main_full:-false}" == true ]] || [[ "${main_honeypot:-false}" == true ]]; then
        honeypot_setup
    fi

    # --- Включение входа по паролю ---
    if [[ "${main_open_password:-false}" == true ]]; then
        log "Включение входа по паролю для root..."
        bash ./lib/open.sh
        echo -e "\nПроверьте подключение по SSH перед продолжением"
        read -rp "Нажмите ENTER после проверки..."
    fi

    finalize

    # --- Перезагрузка ---
    log "Перезагрузка рекомендуется для применения всех настроек (PAM, SSH, Docker)"
    read -rp "Перезагрузить сейчас? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# ==============================================
# ЗАПУСК
# ==============================================
main "$@"
