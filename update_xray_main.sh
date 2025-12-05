#!/bin/bash
echo 'Xray Core Update'
sleep 2s

echo -e "\e[1m\e[33mСкрипт автоматически устанавливает последнее ядро Xray в Marzban Main\n\e[0m"
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
    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=4")

    # Получаем массив версий
    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    # Берём САМУЮ ПЕРВУЮ (последнюю) версию
    selected_version="${versions[0]}"
    echo "Автоматически выбрана последняя версия: $selected_version"

    # Проверяем unzip
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
