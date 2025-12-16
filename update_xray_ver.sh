#!/bin/bash
echo 'Xray Core Update'
sleep 2s

echo -e "\e[1m\e[33mСкрипт обновления Xray в Marzban Main\n\e[0m"
sleep 1

# Проверка ОС
if [[ $(uname) != "Linux" ]]; then
    echo "Этот скрипт предназначен только для Linux"
    exit 1
fi

# Проверка архитектуры
if [[ $(uname -m) != "x86_64" ]]; then
    echo "Этот скрипт предназначен только для архитектуры x64"
    exit 1
fi

# Функция загрузки Xray-core
get_xray_core() {
    read -p "Введите версию Xray (например, v1.5.0): " selected_version

    if [[ -z "$selected_version" ]]; then
        echo "Вы не ввели версию. Завершаю выполнение."
        exit 1
    fi

    echo "Выбрана версия: $selected_version"

    # Проверяем наличие unzip
    if ! dpkg -s unzip >/dev/null 2>&1; then
        echo "Установка unzip..."
        apt install -y unzip
    fi

    mkdir -p /var/lib/marzban/xray-core
    cd /var/lib/marzban/xray-core || exit 1

    xray_filename="Xray-linux-64.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo "Скачивание Xray-core версии ${selected_version}..."
    wget -q "${xray_download_url}"

    if [[ $? -ne 0 ]]; then
        echo "Ошибка при скачивании Xray-core версии ${selected_version}. Проверьте введённую версию."
        exit 1
    fi

    echo "Извлечение..."
    unzip -o "${xray_filename}" >/dev/null 2>&1
    rm -f "${xray_filename}"
}

# Обновление Marzban Main
update_marzban_main() {
    get_xray_core
    marzban_folder="/opt/marzban"
    marzban_env_file="${marzban_folder}/.env"
    xray_executable_path='XRAY_EXECUTABLE_PATH="/var/lib/marzban/xray-core/xray"'

    echo "Изменение ядра Marzban..."
    if ! grep -q "^${xray_executable_path}" "$marzban_env_file"; then
        echo "${xray_executable_path}" >> "${marzban_env_file}"
    fi

    echo "Перезапуск Marzban..."
    marzban restart -n

    echo "Установка завершена."
}

# Автоматически выбираем "1 — Marzban Main"
update_marzban_main
