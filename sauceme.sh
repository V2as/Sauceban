#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="marzban"
fi
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10

colorized_echo() {
    local color=$1
    local text=$2

    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}


detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update -qq
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y
        $PKG_MANAGER install -y epel-release
    elif [ "$OS" == "Fedora"* ]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update
    elif [ "$OS" == "Arch" ]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package () {
    if [ -z $PKG_MANAGER ]; then
        detect_and_update_package_manager
    fi

    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" "$PACKAGE"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Fedora"* ]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Arch" ]; then
        $PKG_MANAGER -S --noconfirm "$PACKAGE"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"

    # Путь к конфигурационному файлу
    CONFIG_FILE="/etc/docker/daemon.json"

    echo "Начинаю настройку registry-mirrors..."

    # 1. Проверяем, существует ли директория /etc/docker
    if [ ! -d "/etc/docker" ]; then
        sudo mkdir -p /etc/docker
    fi

    # 2. Записываем конфигурацию в файл
    # Используем jq, если нужно аккуратно вставить в существующий JSON,
    # но для простоты перезапишем файл новым конфигом:
    echo '{
        "registry-mirrors": ["https://mirror.gcr.io"]
    }' | sudo tee $CONFIG_FILE > /dev/null

    echo "Конфигурация обновлена в $CONFIG_FILE"

    # 3. Перезапускаем демон Docker
    echo "Перезапуск Docker..."
    sudo systemctl restart docker

    # 4. Запускаем Docker Compose
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        echo "Запуск Docker Compose..."
        sudo docker compose up -d
    else
        echo "Файл docker-compose.yml не найден в текущей директории. Пропускаю шаг 4."
    fi

    echo "Готово!"
}

detect_compose() {
    # Check if docker compose command exists
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

install_marzban_script() {
    FETCH_REPO="V2as/Sauceban"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/sauceme.sh"
    colorized_echo blue "Installing sauceme script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/marzban
    colorized_echo green "sauceme script installed successfully"
}

is_marzban_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                colorized_echo yellow "Skipping invalid line in .env: $key=$value"
            fi
        done < "$ENV_FILE"
    else
        colorized_echo red "Environment file (.env) not found."
        exit 1
    fi

    if [ "$BACKUP_SERVICE_ENABLED" != "true" ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/marzban_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi


    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")


    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.tar.gz"
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" >/dev/null 2>&1 && \
        colorized_echo green "Backup part $custom_filename successfully sent to Telegram." || \
        colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ *Backup Error Notification*\n"
    message+="🌐 *Server IP*: \`${server_ip}\`\n"
    message+="❌ *Errors*:\n\`${error_messages//_/\\_}\`\n"
    message+="⏰ *Time*: \`${error_time}\`"


    message=$(echo -e "$message" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g;s/(/\\(/g;s/)/\\)/g')

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...\n\`[Message truncated]\`"
    fi


    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 && \
    colorized_echo green "Backup error notification sent to Telegram." || \
    colorized_echo red "Failed to send error notification to Telegram."


    if [ -f "$log_file" ]; then
        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* - ${error_time}" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument")

        http_code="${response:(-3)}"
        if [ "$http_code" -eq 200 ]; then
            colorized_echo green "Backup error log sent to Telegram."
        else
            colorized_echo red "Failed to send backup error log to Telegram. HTTP code: $http_code"
            cat /tmp/tg_response.json
        fi
    else
        colorized_echo red "Log file not found: $log_file"
    fi
}





backup_service() {
    local telegram_bot_key=""
    local telegram_chat_id=""
    local cron_schedule=""
    local interval_hours=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
        telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
        cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')

        if [[ "$cron_schedule" == "0 0 * * *" ]]; then
            interval_hours=24
        else
            interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
        fi

        colorized_echo green "====================================="
        colorized_echo green "Current Backup Configuration:"
        colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
        colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
        colorized_echo green "====================================="
        echo "Choose an option:"
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
            1)
                colorized_echo yellow "Starting reconfiguration..."
                remove_backup_service
                ;;
            2)
                colorized_echo yellow "Removing Backup Service..."
                remove_backup_service
                return
                ;;
            3)
                colorized_echo yellow "Exiting..."
                return
                ;;
            *)
                colorized_echo red "Invalid choice. Exiting."
                return
                ;;
        esac
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    while true; do
        printf "Enter your Telegram bot API key: "
        read telegram_bot_key
        if [[ -n "$telegram_bot_key" ]]; then
            break
        else
            colorized_echo red "API key cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Enter your Telegram chat ID: "
        read telegram_chat_id
        if [[ -n "$telegram_chat_id" ]]; then
            break
        else
            colorized_echo red "Chat ID cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Set up the backup interval in hours (1-24):\n"
        read interval_hours

        if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
            colorized_echo red "Invalid input. Please enter a valid number."
            continue
        fi

        if [[ "$interval_hours" -eq 24 ]]; then
            cron_schedule="0 0 * * *"
            colorized_echo green "Setting backup to run daily at midnight."
            break
        fi

        if [[ "$interval_hours" -ge 1 && "$interval_hours" -le 23 ]]; then
            cron_schedule="0 */$interval_hours * * *"
            colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            break
        else
            colorized_echo red "Invalid input. Please enter a number between 1-24."
        fi
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
    } >> "$ENV_FILE"

    colorized_echo green "Backup service configuration saved in $ENV_FILE."

    local backup_command="$(which bash) -c '$APP_NAME backup'"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backups will be sent to Telegram daily (every 24 hours at midnight)."
    else
        colorized_echo cyan "Backups will be sent to Telegram every $interval_hours hour(s)."
    fi
    colorized_echo green "====================================="
}


add_cron_job() {
    local schedule="$1"
    local command="$2"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null > "$temp_cron" || true
    grep -v "$command" "$temp_cron" > "${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
    echo "$schedule $command # marzban-backup-service" >> "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Cron job successfully added."
    else
        colorized_echo red "Failed to add cron job. Please check manually."
    fi
    rm -f "$temp_cron"
}

remove_backup_service() {
    colorized_echo red "in process..."


    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron"

    sed -i '/# marzban-backup-service/d' "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

backup_command() {
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/marzban_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/marzban_backup_error.log"
    > "$log_file"
    echo "Backup Log - $(date)" > "$log_file"

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    mkdir -p "$temp_dir"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                echo "Skipping invalid line in .env: $key=$value" >> "$log_file"
            fi
        done < "$ENV_FILE"
    else
        error_messages+=("Environment file (.env) not found.")
        echo "Environment file (.env) not found." >> "$log_file"
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    if grep -q "image: mariadb" "$COMPOSE_FILE"; then
        db_type="mariadb"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mariadb || echo "mariadb")

    elif grep -q "image: mysql" "$COMPOSE_FILE"; then
        db_type="mysql"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mysql || echo "mysql")

    elif grep -q "SQLALCHEMY_DATABASE_URL = .*sqlite" "$ENV_FILE"; then
        db_type="sqlite"
        sqlite_file=$(grep -Po '(?<=SQLALCHEMY_DATABASE_URL = "sqlite:////).*"' "$ENV_FILE" | tr -d '"')
        if [[ ! "$sqlite_file" =~ ^/ ]]; then
            sqlite_file="/$sqlite_file"
        fi

    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >> "$log_file"
        case $db_type in
            mariadb)
                if ! docker exec "$container_name" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --ignore-database=mysql --ignore-database=performance_schema --ignore-database=information_schema --ignore-database=sys --events --triggers > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MariaDB dump failed.")
                fi
                ;;
            mysql)
                if ! docker exec "$container_name" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" marzban --events --triggers  > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MySQL dump failed.")
                fi
                ;;
            sqlite)
                if [ -f "$sqlite_file" ]; then
                    if ! cp "$sqlite_file" "$temp_dir/db_backup.sqlite" 2>>"$log_file"; then
                        error_messages+=("Failed to copy SQLite database.")
                    fi
                else
                    error_messages+=("SQLite database file not found at $sqlite_file.")
                fi
                ;;
        esac
    fi

    cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file"
    cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file"
    rsync -av --exclude 'xray-core' --exclude 'mysql' "$DATA_DIR/" "$temp_dir/marzban_data/" >>"$log_file" 2>&1

    if ! tar -czf "$backup_file" -C "$temp_dir" .; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >> "$log_file"
    fi

    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        return
    fi
    colorized_echo green "Backup created: $backup_file"
    send_backup_to_telegram "$backup_file"
}



get_xray_core() {
    identify_the_operating_system_and_architecture
    clear

    validate_version() {
        local version="$1"

        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }

    print_menu() {
        clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }

    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")

    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice

        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            break
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done

    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"

    # Check if the required packages are installed
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    if ! command -v wget >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package wget
    fi

    mkdir -p $DATA_DIR/xray-core
    cd $DATA_DIR/xray-core

    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget -q -O "${xray_filename}" "${xray_download_url}"

    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1
    rm "${xray_filename}"
}


install_marzban() {
    local marzban_version=$1
    local database_type=$2
    # Fetch releases
    FILES_URL_PREFIX="https://raw.githubusercontent.com/V2as/Sauceban/master"

    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"

    git clone -b master https://github.com/V2as/Sauceban.git "$APP_DIR"

    colorized_echo blue "Setting up docker-compose.yml"
    docker_file_path="$APP_DIR/docker-compose.yml"

    if [ "$database_type" == "mariadb" ]; then
        cat > "$docker_file_path" <<EOF
services:
  marzban:
    image: v2as/sauceban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /var/lib/marzban/logs:/var/lib/marzban-node
    depends_on:
      mariadb:
        condition: service_healthy

  mariadb:
    image: mariadb:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --bind-address=0.0.0.0                  # Restricts access to localhost for increased security
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days (2 weeks)
      - --innodb-log-file-size=64M                # Sets InnoDB log file size to balance log retention and performance
      - --innodb-log-files-in-group=2             # Uses two log files to balance recovery and disk I/O
      - --innodb-doublewrite=0                    # Disables doublewrite buffer (reduces disk I/O; may increase data loss risk)
      - --general_log=0                           # Disables general query log to reduce disk usage
      - --slow_query_log=1                        # Enables slow query log for identifying performance issues
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 3s
      interval: 10s
      timeout: 5s
      retries: 3
EOF
        echo "----------------------------"
        colorized_echo red "Using MariaDB as database"
        echo "----------------------------"

        # Generate docker-compose
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"
        echo ""
        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://marzban:password@127.0.0.1:3306/marzban"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"

        if [[ -z "$MYSQL_PASSWORD" ]]; then
            prompt_for_marzban_password
        fi

        if [[ -n "$SUDO_USERNAME" ]]; then
            sed -i "s/^# SUDO_USERNAME = \".*\"/SUDO_USERNAME = \"$SUDO_USERNAME\"/" "$APP_DIR/.env"

        fi
        if [[ -n "$SUDO_PASSWORD" ]]; then
            sed -i "s/^# SUDO_PASSWORD = \".*\"/SUDO_PASSWORD = \"$SUDO_PASSWORD\"/" "$APP_DIR/.env"

        fi
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=marzban" >> "$ENV_FILE"
        echo "MYSQL_USER=marzban" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"

        SQLALCHEMY_DATABASE_URL="mysql+pymysql://marzban:${MYSQL_PASSWORD}@127.0.0.1:3306/marzban"

        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"

        colorized_echo green "File saved in $APP_DIR/.env"

    elif [ "$database_type" == "mysql" ]; then
        cat > "$docker_file_path" <<EOF
services:
  marzban:
    image: v2as/sauceban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /var/lib/marzban/logs:/var/lib/marzban-node
    depends_on:
      mysql:
        condition: service_healthy

  mysql:
    image: mysql:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --mysqlx=OFF                             # Disables MySQL X Plugin to save resources if X Protocol isn't used
      - --bind-address=0.0.0.0                  # Restricts access to localhost for increased security
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --log-bin=mysql-bin                       # Enables binary logging for point-in-time recovery
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --innodb-log-file-size=64M                # Sets InnoDB log file size to balance log retention and performance
      - --innodb-log-files-in-group=2             # Uses two log files to balance recovery and disk I/O
      - --general_log=0                           # Disables general query log for lower disk usage
      - --slow_query_log=1                        # Enables slow query log for performance analysis
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "marzban", "--password=\${MYSQL_PASSWORD}"]
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 55

EOF
        echo "----------------------------"
        colorized_echo red "Using MySQL as database"
        echo "----------------------------"
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"

        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://marzban:password@127.0.0.1:3306/marzban"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"


        prompt_for_marzban_password
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=marzban" >> "$ENV_FILE"
        echo "MYSQL_USER=marzban" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"

        SQLALCHEMY_DATABASE_URL="mysql+pymysql://marzban:${MYSQL_PASSWORD}@127.0.0.1:3306/marzban"

        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"

        colorized_echo green "File saved in $APP_DIR/.env"

    else
        echo "----------------------------"
        colorized_echo red "Using SQLite as database"
        echo "----------------------------"
        colorized_echo blue "Fetching compose file"

        curl -sL "$FILES_URL_PREFIX/docker-compose.yml" -o "$docker_file_path"

        if [ "$marzban_version" == "latest" ]; then
            yq -i '.services.marzban.image = "v2as/sauceban:latest"' "$docker_file_path"
        else
            yq -i ".services.marzban.image = \"v2as/sauceban:${marzban_version}\"" "$docker_file_path"
        fi
        echo "Installing $marzban_version version"
        colorized_echo green "File saved in $APP_DIR/docker-compose.yml"


        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"
        sed -i 's~\(SQLALCHEMY_DATABASE_URL = \).*~\1"sqlite:////var/lib/marzban/db.sqlite3"~' "$APP_DIR/.env"






        colorized_echo green "File saved in $APP_DIR/.env"
    fi

    colorized_echo blue "Fetching xray config file"
    curl -sL "$FILES_URL_PREFIX/xray_config.json" -o "$DATA_DIR/xray_config.json"
    colorized_echo green "File saved in $DATA_DIR/xray_config.json"

    colorized_echo green "Marzban's files downloaded successfully"
}

up_marzban() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

follow_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

status_command() {

    # Check if marzban is installed
    if ! is_marzban_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi

    detect_compose

    if ! is_marzban_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi

    echo -n "Status: "
    colorized_echo green "Up"

    json=$($COMPOSE -f $COMPOSE_FILE ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}


prompt_for_marzban_password() {
    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "If you do not enter a custom password, a secure 20-character password will be generated automatically."

    # Запрашиваем ввод пароля
    read -p "Enter the password for the marzban user (or press Enter to generate a secure default password): " MYSQL_PASSWORD

    # Генерация 20-значного пароля, если пользователь оставил поле пустым
    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "This password will be recorded in the .env file for future use."

    # Пауза 3 секунды перед продолжением
    sleep 3
}

install_command() {
    check_running_as_root

    # Default values
    database_type="sqlite"
    marzban_version="latest"
    marzban_version_set="false"
    MYSQL_PASSWORD=""
    SUDO_USERNAME=""
    SUDO_PASSWORD=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --database)
                database_type="$2"
                shift 2
            ;;
            --db-password|--dbpassword)
                MYSQL_PASSWORD="$2"
                shift 2
            ;;
            --sudo-username)
                SUDO_USERNAME="$2"
                shift 2
            ;;
            --sudo-password)
                SUDO_PASSWORD="$2"
                shift 2
            ;;
            --dev)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="dev"
                marzban_version_set="true"
                shift
            ;;
            --version)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="$2"
                marzban_version_set="true"
                shift 2
            ;;
            *)
                echo "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    if is_marzban_installed; then
        colorized_echo yellow "Marzban is already installed at $APP_DIR — overriding"
        rm -rf "$APP_DIR"
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    ensure_docker_mirrors
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    install_marzban_script
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/Gozargah/Marzban/releases"
        if [ "$version" == "latest" ] || [ "$version" == "dev" ]; then
            return 0
        fi

        # Fetch the release data from GitHub API
        response=$(curl -s "$repo_url")

        # Check if the response contains the version tag
        if echo "$response" | jq -e ".[] | select(.tag_name == \"${version}\")" > /dev/null; then
            return 0
        else
            return 1
        fi
    }
    # Check if the version is valid and exists
    if [[ "$marzban_version" == "latest" || "$marzban_version" == "dev" || "$marzban_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$marzban_version"; then
            install_marzban "$marzban_version" "$database_type"
            echo "Installing $marzban_version version"
        else
            echo "Version $marzban_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    up_marzban
#    follow_marzban_logs
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
        '64' | 'x86_64')
            yq_binary="yq_linux_amd64"
            ;;
        'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
            yq_binary="yq_linux_arm"
            ;;
        'arm64-v8a' | 'aarch64')
            yq_binary="yq_linux_arm64"
            ;;
        '32' | 'i386' | 'i686')
            yq_binary="yq_linux_386"
            ;;
        *)
            colorized_echo red "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi


    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi


    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi


    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}


down_marzban() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}



show_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

marzban_cli() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e CLI_PROG_NAME="marzban cli" marzban marzban-cli "$@"
}


is_marzban_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

uninstall_command() {
    check_running_as_root
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall Marzban? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

    detect_compose
    if is_marzban_up; then
        down_marzban
    fi
    uninstall_marzban_script
    uninstall_marzban
    uninstall_marzban_docker_images

    read -p "Do you want to remove Marzban's data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "Marzban uninstalled successfully"
    else
        uninstall_marzban_data_files
        colorized_echo green "Marzban uninstalled successfully"
    fi
}

uninstall_marzban_script() {
    if [ -f "/usr/local/bin/marzban" ]; then
        colorized_echo yellow "Removing marzban script"
        rm "/usr/local/bin/marzban"
    fi
}

uninstall_marzban() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_marzban_docker_images() {
    images=$(docker images | grep marzban | awk '{print $3}')

    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of Marzban"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_marzban_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: sauceban restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }

    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done

    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Sauceban's not installed!"
        exit 1
    fi

    detect_compose

    down_marzban
    up_marzban
    if [ "$no_logs" = false ]; then
        follow_marzban_logs
    fi
    colorized_echo green "Marzban successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: marzban logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }

    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow)
                no_follow=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done

    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_marzban_up; then
        colorized_echo red "Marzban is not up."
        exit 1
    fi

    if [ "$no_follow" = true ]; then
        show_marzban_logs
    else
        follow_marzban_logs
    fi
}

down_command() {

    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_marzban_up; then
        colorized_echo red "Marzban's already down"
        exit 1
    fi

    down_marzban
}

cli_command() {
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_compose

    if ! is_marzban_up; then
        colorized_echo red "Marzban is not up."
        exit 1
    fi

    marzban_cli "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: marzban up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }

    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done

    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_compose

    if is_marzban_up; then
        colorized_echo red "Marzban's already up"
        exit 1
    fi

    up_marzban
    if [ "$no_logs" = false ]; then
        follow_marzban_logs
    fi
}

update_command() {
    check_running_as_root

    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_os
    detect_compose

    if ! command -v git >/dev/null 2>&1; then
        install_package git
    fi
    if ! command -v rsync >/dev/null 2>&1; then
        install_package rsync
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi

    update_marzban_script
    colorized_echo blue "Updating Marzban..."
    update_marzban

    colorized_echo blue "Restarting Marzban's services"
    down_marzban
    up_marzban

    colorized_echo green "Marzban updated successfully"
}

update_marzban_script() {
    FETCH_REPO="V2as/Sauceban"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/sauceme.sh"
    colorized_echo blue "Updating marzban script"

    local tmp_script
    tmp_script=$(mktemp)
    if curl -fsSL "$SCRIPT_URL" -o "$tmp_script"; then
        install -m 755 "$tmp_script" /usr/local/bin/marzban
        colorized_echo green "marzban script updated successfully"
    else
        colorized_echo red "Failed to download marzban script"
    fi
    rm -f "$tmp_script"
}

update_marzban() {
    local current_image
    current_image=$(yq '.services.marzban.image // ""' "$COMPOSE_FILE")
    local has_build
    has_build=$(yq '.services.marzban.build // ""' "$COMPOSE_FILE")

    if [[ -n "$current_image" && "$current_image" != "null" ]]; then
        colorized_echo blue "Current mode: image ($current_image)"
        ensure_docker_mirrors
        colorized_echo blue "Pulling latest image..."
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull marzban

    elif [[ -n "$has_build" && "$has_build" != "null" ]]; then
        local build_source="sauceban"
        if [ -f "$APP_DIR/.build_source" ]; then
            build_source=$(cat "$APP_DIR/.build_source")
        fi

        local repo_url=""
        if [[ "$build_source" == "gozargah" ]]; then
            repo_url="https://github.com/Gozargah/Marzban.git"
        else
            repo_url="https://github.com/V2as/Sauceban.git"
        fi

        local branch="master"
        if [ -f "$APP_DIR/.build_branch" ]; then
            branch=$(cat "$APP_DIR/.build_branch")
        fi

        colorized_echo blue "Current mode: build from $build_source (branch: $branch)"

        local tmp_dir="/tmp/sauceban_update"
        rm -rf "$tmp_dir"
        if ! git clone -b "$branch" "$repo_url" "$tmp_dir"; then
            colorized_echo red "Failed to clone $repo_url"
            rm -rf "$tmp_dir"
            exit 1
        fi

        rsync -av \
            --exclude='docker-compose.yml' \
            --exclude='.env' \
            --exclude='.git' \
            --exclude='.build_source' \
            --exclude='.build_branch' \
            "$tmp_dir/" "$APP_DIR"/
        rm -rf "$tmp_dir"

        ensure_docker_mirrors
        colorized_echo blue "Rebuilding image..."
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" build marzban
    else
        colorized_echo red "Cannot detect installation type from docker-compose.yml"
        exit 1
    fi
}

ensure_docker_mirrors() {
    local DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
    local need_restart=false

    if [ ! -d "/etc/docker" ]; then
        mkdir -p /etc/docker
    fi

    if [ ! -f "$DOCKER_DAEMON_JSON" ]; then
        cat > "$DOCKER_DAEMON_JSON" << 'EOFJSON'
{
    "registry-mirrors": ["https://mirror.gcr.io"]
}
EOFJSON
        need_restart=true
        colorized_echo green "Docker daemon.json created with registry mirrors"
    else
        if command -v jq >/dev/null 2>&1; then
            if ! jq -e '."registry-mirrors"' "$DOCKER_DAEMON_JSON" >/dev/null 2>&1; then
                jq '. + {"registry-mirrors": ["https://mirror.gcr.io"]}' "$DOCKER_DAEMON_JSON" > /tmp/daemon.json.tmp \
                    && mv /tmp/daemon.json.tmp "$DOCKER_DAEMON_JSON"
                need_restart=true
                colorized_echo green "Docker registry mirrors configured"
            fi
        else
            if ! grep -q '"registry-mirrors"' "$DOCKER_DAEMON_JSON"; then
                sed -i 's/}$/,\n    "registry-mirrors": ["https:\/\/mirror.gcr.io"]\n}/' "$DOCKER_DAEMON_JSON"
                need_restart=true
                colorized_echo green "Docker registry mirrors configured"
            fi
        fi
    fi

    if [ "$need_restart" = true ]; then
        systemctl restart docker
        colorized_echo green "Docker daemon restarted to apply configuration"
    fi
}

ensure_docker_dns() {
    ensure_docker_mirrors
}

migrate_help() {
    colorized_echo cyan "Usage: marzban migrate [options]"
    echo ""
    colorized_echo cyan "Switch Marzban to a different source (image or build from repo)."
    colorized_echo cyan "Database and all data are preserved."
    echo ""
    colorized_echo yellow "Options:"
    echo "  --image <image:tag>       Use a pre-built Docker Hub image"
    echo "                            Examples:"
    echo "                              --image v2as/sauceban:latest"
    echo "                              --image gozargah/marzban:latest"
    echo "                              --image gozargah/marzban:v0.5.2"
    echo ""
    echo "  --build <sauceban|gozargah>  Clone repo and build from source"
    echo "                            sauceban  = github.com/V2as/Sauceban"
    echo "                            gozargah  = github.com/Gozargah/Marzban"
    echo ""
    echo "  --branch <name>           Branch to clone (default: master)"
    echo "  -y, --yes                 Skip confirmation prompt"
    echo "  -h, --help                Show this help"
    echo ""
    colorized_echo cyan "Examples:"
    echo "  marzban migrate --image v2as/sauceban:latest"
    echo "  marzban migrate --image gozargah/marzban:v0.5.2"
    echo "  marzban migrate --build sauceban"
    echo "  marzban migrate --build gozargah --branch dev"
    echo "  marzban migrate --image v2as/sauceban:latest -y"
}

migrate_marzban() {
    check_running_as_root

    local mode=""
    local image_name=""
    local build_repo=""
    local branch="master"
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                mode="image"
                image_name="$2"
                shift 2
                ;;
            --build)
                mode="build"
                build_repo="$2"
                shift 2
                ;;
            --branch)
                branch="$2"
                shift 2
                ;;
            -y|--yes)
                force=true
                shift
                ;;
            -h|--help)
                migrate_help
                return 0
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                migrate_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$mode" ]]; then
        colorized_echo red "Error: specify --image <image:tag> or --build <sauceban|gozargah>"
        echo ""
        migrate_help
        exit 1
    fi

    if [[ "$mode" == "image" && -z "$image_name" ]]; then
        colorized_echo red "Error: --image requires image name (e.g. v2as/sauceban:latest)"
        exit 1
    fi

    if [[ "$mode" == "build" && "$build_repo" != "sauceban" && "$build_repo" != "gozargah" ]]; then
        colorized_echo red "Error: --build accepts 'sauceban' or 'gozargah'"
        exit 1
    fi

    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi

    detect_os
    detect_compose

    if [[ "$mode" == "image" ]]; then
        colorized_echo blue "Migrating to image: $image_name"
    else
        colorized_echo blue "Migrating to build from: $build_repo (branch: $branch)"
    fi

    if [[ "$force" != true ]]; then
        read -p "Continue? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted"
            exit 1
        fi
    fi

    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi

    if [[ "$mode" == "image" ]]; then
        migrate_to_image "$image_name"
    else
        migrate_to_build "$build_repo" "$branch"
    fi

    colorized_echo blue "Stopping Marzban container (database stays running)..."
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" stop marzban
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" rm -f marzban

    ensure_docker_mirrors

    if [[ "$mode" == "image" ]]; then
        colorized_echo blue "Pulling $image_name..."
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull marzban
    else
        colorized_echo blue "Building image from source..."
        $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" build marzban
    fi

    colorized_echo blue "Starting Marzban..."
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans

    colorized_echo green "====================================="
    colorized_echo green "  Migration completed successfully!  "
    colorized_echo green "====================================="
    colorized_echo cyan "Database and all data were preserved."
    if [[ "$mode" == "image" ]]; then
        colorized_echo cyan "Marzban is now running from image: $image_name"
    else
        colorized_echo cyan "Marzban is now running from $build_repo build (branch: $branch)"
    fi
}

migrate_to_image() {
    local image_name="$1"

    colorized_echo blue "Updating docker-compose.yml..."
    yq -i 'del(.services.marzban.build)' "$COMPOSE_FILE"
    yq -i 'del(.services.marzban.ipc)' "$COMPOSE_FILE"
    yq -i ".services.marzban.image = \"${image_name}\"" "$COMPOSE_FILE"
    rm -f "$APP_DIR/.build_source" "$APP_DIR/.build_branch"
    colorized_echo green "docker-compose.yml updated (image: $image_name)"
}

migrate_to_build() {
    local repo="$1"
    local branch="$2"
    local repo_url=""
    local tmp_dir="/tmp/sauceban_migrate"

    if [[ "$repo" == "sauceban" ]]; then
        repo_url="https://github.com/V2as/Sauceban.git"
    else
        repo_url="https://github.com/Gozargah/Marzban.git"
    fi

    if ! command -v git >/dev/null 2>&1; then
        install_package git
    fi
    if ! command -v rsync >/dev/null 2>&1; then
        install_package rsync
    fi

    colorized_echo blue "Cloning $repo_url (branch: $branch)..."
    rm -rf "$tmp_dir"
    if ! git clone -b "$branch" "$repo_url" "$tmp_dir"; then
        colorized_echo red "Failed to clone repository"
        rm -rf "$tmp_dir"
        exit 1
    fi

    colorized_echo blue "Copying source files (preserving docker-compose.yml and .env)..."
    rsync -av \
        --exclude='docker-compose.yml' \
        --exclude='.env' \
        --exclude='.git' \
        "$tmp_dir/" "$APP_DIR"/
    rm -rf "$tmp_dir"

    colorized_echo blue "Updating docker-compose.yml..."
    yq -i 'del(.services.marzban.image)' "$COMPOSE_FILE"
    yq -i '.services.marzban.build.context = "."' "$COMPOSE_FILE"
    yq -i '.services.marzban.build.dockerfile = "Dockerfile"' "$COMPOSE_FILE"
    yq -i '.services.marzban.ipc = "host"' "$COMPOSE_FILE"
    echo "$repo" > "$APP_DIR/.build_source"
    echo "$branch" > "$APP_DIR/.build_branch"
    colorized_echo green "docker-compose.yml updated (build from source)"
}

check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
            elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}


edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

usage() {
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           Marzban Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  cli             $(tput sgr0)– Marzban CLI"
    colorized_echo yellow "  install         $(tput sgr0)– Install Marzban"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall Marzban"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install Marzban script"
    colorized_echo yellow "  backup          $(tput sgr0)– Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)– Marzban Backupservice to backup to TG, and a new job in crontab"
    colorized_echo yellow "  core-update     $(tput sgr0)– Update/Change Xray core"
    colorized_echo yellow "  migrate         $(tput sgr0)– Switch Marzban source (image or build)"
    colorized_echo yellow "  tblocker        $(tput sgr0)– Install Xray Torrent Blocker for Marzban"
    colorized_echo yellow "  tblocker-config $(tput sgr0)– Manage tblocker configuration"
    colorized_echo yellow "  log-clean       $(tput sgr0)– Schedule or run access log cleanup"
    colorized_echo yellow "  update-html     $(tput sgr0)– Update custom HTML templates (home & subscription)"
    colorized_echo yellow "  fix-acme        $(tput sgr0)– Fix acme.sh volume in docker-compose (mount entire directory)"
    colorized_echo yellow "  fix-xray-json   $(tput sgr0)– Fix trailing extra braces in xray_config.json and restart"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi editor)"
    colorized_echo yellow "  edit-env        $(tput sgr0)– Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  help            $(tput sgr0)– Show this help message"


    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    colorized_echo blue "================================"
    echo
}

update_core_command() {
    check_running_as_root

    local cli_version=""
    local use_latest=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                cli_version="$2"
                shift 2
            ;;
            --latest)
                use_latest=true
                shift
            ;;
            -h|--help)
                colorized_echo cyan "Usage: marzban core-update [options]"
                echo ""
                echo "OPTIONS:"
                echo "  --version <vX.Y.Z>   Install specific Xray-core version (non-interactive)"
                echo "  --latest             Install the latest Xray-core version (non-interactive)"
                echo "  -h, --help           Show this help message"
                echo ""
                echo "Without options — interactive menu with version selection."
                echo ""
                echo "EXAMPLES:"
                echo "  marzban core-update"
                echo "  marzban core-update --version v24.12.18"
                echo "  marzban core-update --latest"
                exit 0
            ;;
            *)
                colorized_echo red "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    if [ "$use_latest" = true ]; then
        identify_the_operating_system_and_architecture
        detect_os

        if ! command -v curl >/dev/null 2>&1; then
            install_package curl
        fi

        local latest_tag
        latest_tag=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
        if [ -z "$latest_tag" ]; then
            colorized_echo red "Failed to fetch latest Xray-core version."
            exit 1
        fi
        cli_version="$latest_tag"
        colorized_echo blue "Latest Xray-core version: $cli_version"
    fi

    if [ -n "$cli_version" ]; then
        identify_the_operating_system_and_architecture
        detect_os

        if ! command -v curl >/dev/null 2>&1; then
            install_package curl
        fi

        local check_response
        check_response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$cli_version")
        if echo "$check_response" | grep -q '"message": "Not Found"'; then
            colorized_echo red "Version $cli_version does not exist."
            exit 1
        fi

        colorized_echo green "Installing Xray-core $cli_version..."

        if ! command -v unzip >/dev/null 2>&1; then
            install_package unzip
        fi
        if ! command -v wget >/dev/null 2>&1; then
            install_package wget
        fi

        mkdir -p "$DATA_DIR/xray-core"
        cd "$DATA_DIR/xray-core"

        local xray_filename="Xray-linux-$ARCH.zip"
        local xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${cli_version}/${xray_filename}"

        colorized_echo blue "Downloading Xray-core ${cli_version}..."
        wget -q -O "${xray_filename}" "${xray_download_url}"

        colorized_echo blue "Extracting Xray-core..."
        unzip -o "${xray_filename}" >/dev/null 2>&1
        rm -f "${xray_filename}"

        selected_version="$cli_version"
    else
        get_xray_core
    fi

    xray_executable_path="XRAY_EXECUTABLE_PATH=\"/var/lib/marzban/xray-core/xray\""

    if ! grep -q "^XRAY_EXECUTABLE_PATH=" "$ENV_FILE"; then
        echo "${xray_executable_path}" >> "$ENV_FILE"
    else
        sed -i "s~^XRAY_EXECUTABLE_PATH=.*~${xray_executable_path}~" "$ENV_FILE"
    fi

    colorized_echo blue "Restarting Marzban..."
    if restart_command -n >/dev/null 2>&1; then
        colorized_echo green "Marzban successfully restarted!"
    else
        colorized_echo red "Marzban restart failed!"
    fi
    colorized_echo green "Xray-core $selected_version installed successfully."
}

install_tblocker_from_binary() {
    identify_the_operating_system_and_architecture

    local tb_arch=""
    case "$ARCH" in
        '64') tb_arch="amd64" ;;
        'arm64-v8a') tb_arch="arm64" ;;
        *)
            colorized_echo red "Unsupported architecture for tblocker: $ARCH"
            exit 1
        ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi

    local latest_release
    latest_release=$(curl -s https://api.github.com/repos/kutovoys/xray-torrent-blocker/releases/latest | grep tag_name | cut -d '"' -f 4)
    local url="https://github.com/kutovoys/xray-torrent-blocker/releases/download/${latest_release}/xray-torrent-blocker-${latest_release}-linux-${tb_arch}.tar.gz"

    colorized_echo blue "Downloading tblocker ${latest_release}..."
    mkdir -p /opt/tblocker
    curl -sL "$url" -o /tmp/tblocker.tar.gz
    tar -xzf /tmp/tblocker.tar.gz -C /opt/tblocker
    rm -f /tmp/tblocker.tar.gz

    curl -sL https://raw.githubusercontent.com/kutovoys/xray-torrent-blocker/main/tblocker.service \
        -o /etc/systemd/system/tblocker.service

    colorized_echo green "tblocker binary installed to /opt/tblocker/"
}

configure_tblocker_marzban() {
    local firewall="$1"
    local block_duration="$2"
    local webhook_url="$3"
    local webhook_token="$4"
    local config_path="/opt/tblocker/config.yaml"

    if [ -f "$config_path" ]; then
        cp "$config_path" "${config_path}.bak"
        colorized_echo yellow "Existing config backed up to ${config_path}.bak"
    fi

    cat > "$config_path" << 'EOFCONFIG'
LogFile: "/var/lib/marzban/logs/access.log"
BlockDuration: 10
TorrentTag: "TORRENT"
BlockMode: "iptables"
StorageDir: "/opt/tblocker"
UsernameRegex: "^\\d+\\.(.+)$"
BypassIPS:
  - "127.0.0.1"
  - "::1"
EOFCONFIG

    sed -i "s|BlockDuration: 10|BlockDuration: ${block_duration}|" "$config_path"
    sed -i "s|BlockMode: \"iptables\"|BlockMode: \"${firewall}\"|" "$config_path"

    if [ -n "$webhook_url" ]; then
        local token="${webhook_token:-your-token}"
        cat >> "$config_path" << EOFWEBHOOK
SendWebhook: true
WebhookURL: "${webhook_url}"
WebhookTemplate: '{"username":"%s","ip":"%s","server":"%s","action":"%s","duration":%d,"timestamp":"%s"}'
WebhookHeaders:
  Authorization: "Bearer ${token}"
  Content-Type: "application/json"
EOFWEBHOOK
        colorized_echo green "Webhook configured: $webhook_url"
    fi

    colorized_echo green "tblocker configured for Marzban: $config_path"
}

prepare_marzban_for_tblocker() {
    local xray_config="$DATA_DIR/xray_config.json"

    mkdir -p /var/lib/marzban/logs
    colorized_echo green "Log directory ensured: /var/lib/marzban/logs"

    if [ -f "$COMPOSE_FILE" ]; then
        if ! command -v yq >/dev/null 2>&1; then
            install_yq
        fi
        if ! grep -q "marzban-node" "$COMPOSE_FILE"; then
            colorized_echo blue "Adding log volume to Marzban docker-compose.yml..."
            yq -i '.services.marzban.volumes += ["/var/lib/marzban/logs:/var/lib/marzban-node"]' "$COMPOSE_FILE"
            colorized_echo green "Log volume added to docker-compose.yml"
        else
            colorized_echo green "Log volume already present in docker-compose.yml"
        fi
    else
        colorized_echo red "Marzban docker-compose.yml not found at $COMPOSE_FILE"
        return 1
    fi

    if [ -f "$xray_config" ]; then
        if ! command -v jq >/dev/null 2>&1; then
            install_package jq
        fi

        colorized_echo blue "Updating xray config for torrent blocking..."
        local tmp_config="${xray_config}.tmp"

        jq '.log.access = "/var/lib/marzban-node/access.log" |
            .log.error = "/var/lib/marzban-node/error.log"' \
            "$xray_config" > "$tmp_config" && mv "$tmp_config" "$xray_config"

        if ! jq -e '.routing.rules[] | select(.outboundTag == "TORRENT")' "$xray_config" >/dev/null 2>&1; then
            jq '.routing.rules = [{"protocol": ["bittorrent"], "outboundTag": "TORRENT", "type": "field"}] + .routing.rules' \
                "$xray_config" > "$tmp_config" && mv "$tmp_config" "$xray_config"
            colorized_echo green "Bittorrent routing rule added"
        else
            colorized_echo green "Bittorrent routing rule already present"
        fi

        if ! jq -e '.outbounds[] | select(.tag == "TORRENT")' "$xray_config" >/dev/null 2>&1; then
            jq '.outbounds += [{"protocol": "blackhole", "tag": "TORRENT"}]' \
                "$xray_config" > "$tmp_config" && mv "$tmp_config" "$xray_config"
            colorized_echo green "TORRENT blackhole outbound added"
        else
            colorized_echo green "TORRENT outbound already present"
        fi

        colorized_echo green "Xray config updated: $xray_config"
    else
        colorized_echo yellow "Xray config not found at $xray_config"
        colorized_echo yellow "Please manually configure xray for torrent blocking"
    fi

    colorized_echo blue "Configuring logrotate for Marzban logs..."
    cat > /etc/logrotate.d/marzban-xray << 'EOFLOGROTATE'
/var/lib/marzban/logs/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOFLOGROTATE
    colorized_echo green "Logrotate configured for /var/lib/marzban/logs/"
}

install_tblocker() {
    local firewall="iptables"
    local block_duration="10"
    local webhook_url=""
    local webhook_token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --firewall)
                firewall="$2"
                if [[ "$firewall" != "iptables" && "$firewall" != "nft" ]]; then
                    colorized_echo red "Invalid firewall: $firewall. Use 'iptables' or 'nft'."
                    exit 1
                fi
                shift 2
            ;;
            --duration)
                block_duration="$2"
                if ! [[ "$block_duration" =~ ^[0-9]+$ ]]; then
                    colorized_echo red "Invalid duration: $block_duration. Must be a number (minutes)."
                    exit 1
                fi
                shift 2
            ;;
            --webhook-url)
                webhook_url="$2"
                shift 2
            ;;
            --webhook-token)
                webhook_token="$2"
                shift 2
            ;;
            -h|--help)
                colorized_echo cyan "Usage: marzban tblocker [options]"
                echo ""
                echo "OPTIONS:"
                echo "  --firewall <iptables|nft>  Firewall to use for blocking (default: iptables)"
                echo "  --duration <minutes>       Block duration in minutes (default: 10)"
                echo "  --webhook-url <URL>        Webhook URL (enables SendWebhook automatically)"
                echo "  --webhook-token <TOKEN>    Bearer token for webhook Authorization header"
                echo "  -h, --help                 Show this help message"
                echo ""
                echo "EXAMPLES:"
                echo "  marzban tblocker"
                echo "  marzban tblocker --firewall nft --duration 15"
                echo "  marzban tblocker --firewall iptables --duration 30"
                echo "  marzban tblocker --webhook-url https://example.com/hook --webhook-token my-token"
                exit 0
            ;;
            *)
                colorized_echo red "Unknown option: $1"
                colorized_echo yellow "Use 'marzban tblocker --help' for usage information."
                exit 1
            ;;
        esac
    done

    check_running_as_root
    detect_os

    colorized_echo blue "====================================="
    colorized_echo blue "    Xray Torrent Blocker Setup       "
    colorized_echo blue "====================================="
    colorized_echo cyan "  Firewall:       $firewall"
    colorized_echo cyan "  Block duration: ${block_duration} min"
    if [ -n "$webhook_url" ]; then
        colorized_echo cyan "  Webhook URL:    $webhook_url"
        colorized_echo cyan "  Webhook token:  ***"
    fi
    colorized_echo blue "====================================="

    if ! is_marzban_installed; then
        colorized_echo red "Marzban is not installed. Please install Marzban first."
        exit 1
    fi

    if systemctl is-active --quiet tblocker 2>/dev/null; then
        colorized_echo yellow "Stopping existing tblocker service..."
        systemctl stop tblocker
    fi

    colorized_echo blue "Installing tblocker..."
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        apt-get update -qq >/dev/null
        apt-get install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" curl gnupg >/dev/null 2>&1
        curl -s https://repo.remna.dev/xray-tools/public.gpg | gpg --yes --dearmor -o /usr/share/keyrings/openrepo-xray-tools.gpg >/dev/null 2>&1
        echo "deb [arch=any signed-by=/usr/share/keyrings/openrepo-xray-tools.gpg] https://repo.remna.dev/xray-tools/ stable main" > /etc/apt/sources.list.d/openrepo-xray-tools.list
        apt-get update -qq >/dev/null
        apt-get install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" tblocker >/dev/null
        colorized_echo green "tblocker installed from package repository"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]] || [[ "$OS" == "Fedora"* ]]; then
        cat > /etc/yum.repos.d/xray-tools-rpm.repo << 'EOFREPO'
[xray-tools-rpm]
name=xray-tools-rpm
baseurl=https://repo.remna.dev/xray-tools-rpm
enabled=1
repo_gpgcheck=1
gpgkey=https://repo.remna.dev/xray-tools-rpm/public.gpg
EOFREPO
        yum install -y tblocker
        colorized_echo green "tblocker installed from package repository"
    else
        colorized_echo yellow "Package repository not available, installing from binary..."
        install_tblocker_from_binary
    fi

    configure_tblocker_marzban "$firewall" "$block_duration" "$webhook_url" "$webhook_token"
    prepare_marzban_for_tblocker

    colorized_echo blue "Starting tblocker service..."
    systemctl daemon-reload
    systemctl enable tblocker
    systemctl start tblocker

    if systemctl is-active --quiet tblocker; then
        colorized_echo green "tblocker service is running!"
    else
        colorized_echo red "Failed to start tblocker. Check: journalctl -u tblocker -f"
    fi

    colorized_echo blue "Restarting Marzban to apply changes..."
    detect_compose
    down_marzban
    up_marzban

    colorized_echo green "====================================="
    colorized_echo green "  Torrent Blocker setup completed!   "
    colorized_echo green "====================================="
    colorized_echo cyan "tblocker config: /opt/tblocker/config.yaml"
    colorized_echo cyan "tblocker logs:   journalctl -u tblocker -f"
    colorized_echo cyan "tblocker status: systemctl status tblocker"
    if [ -n "$webhook_url" ]; then
        colorized_echo cyan "webhook:         enabled"
    fi
    echo ""
    colorized_echo cyan "To manage webhook after install:"
    colorized_echo cyan "  marzban tblocker-config set-webhook-url <URL>"
    colorized_echo cyan "  marzban tblocker-config set-webhook-token <TOKEN>"
    colorized_echo cyan "  marzban tblocker-config show"
}

tblocker_config_command() {
    check_running_as_root

    local config_path="/opt/tblocker/config.yaml"

    _tbc_set_key() {
        local key="$1" val="$2"
        if grep -q "^${key}:" "$config_path"; then
            sed -i "s|^${key}:.*|${key}: ${val}|" "$config_path"
        else
            echo "${key}: ${val}" >> "$config_path"
        fi
    }

    _tbc_set_quoted() {
        _tbc_set_key "$1" "\"$2\""
    }

    _tbc_set_bool() {
        _tbc_set_key "$1" "$2"
    }

    _tbc_set_int() {
        _tbc_set_key "$1" "$2"
    }

    _tbc_require_value() {
        if [ -z "$1" ]; then
            colorized_echo red "$2 is required."
            echo "Usage: marzban tblocker-config $3"
            exit 1
        fi
    }

    _tbc_done() {
        colorized_echo green "$1"
        colorized_echo yellow "Restart tblocker to apply: systemctl restart tblocker"
    }

    tblocker_config_usage() {
        colorized_echo cyan "Usage: marzban tblocker-config <command> [value]"
        echo ""
        colorized_echo yellow "General:"
        echo "  show                          Show full config"
        echo "  get <KEY>                     Get value of a config key"
        echo "  restart                       Restart tblocker service"
        echo ""
        colorized_echo yellow "Core settings:"
        echo "  set-duration <minutes>        Block duration in minutes (default: 10)"
        echo "  set-firewall <iptables|nft>   Firewall mode for blocking"
        echo "  set-log-file <path>           Path to xray access log"
        echo "  set-torrent-tag <tag>         Tag for torrent detection (default: TORRENT)"
        echo "  set-storage-dir <path>        Directory for blocked IPs storage"
        echo "  set-hostname <name>           Server hostname for webhook"
        echo "  set-username-regex <regex>    Regex to process username from log"
        echo ""
        colorized_echo yellow "Bypass IPs:"
        echo "  add-bypass-ip <IP>            Add IP to bypass list"
        echo "  remove-bypass-ip <IP>         Remove IP from bypass list"
        echo "  list-bypass-ips               Show all bypass IPs"
        echo ""
        colorized_echo yellow "Webhook:"
        echo "  set-webhook-url <URL>         Set WebhookURL (auto-enables webhook)"
        echo "  set-webhook-token <TOKEN>     Set Authorization Bearer token"
        echo "  set-webhook-template <TPL>    Set webhook JSON template"
        echo "  enable-webhook                Enable webhook notifications"
        echo "  disable-webhook               Disable webhook notifications"
        echo ""
        colorized_echo yellow "Examples:"
        echo "  marzban tblocker-config set-duration 30"
        echo "  marzban tblocker-config set-firewall nft"
        echo "  marzban tblocker-config set-webhook-url https://example.com/hook"
        echo "  marzban tblocker-config set-webhook-token my-secret-token"
        echo "  marzban tblocker-config add-bypass-ip 192.168.1.1"
        echo "  marzban tblocker-config set-hostname my-server"
        echo "  marzban tblocker-config set-username-regex '^\\d+\\.(.+)\$'"
        echo "  marzban tblocker-config show"
        echo "  marzban tblocker-config restart"
    }

    if [ ! -f "$config_path" ]; then
        colorized_echo red "tblocker config not found: $config_path"
        colorized_echo yellow "Install tblocker first: marzban tblocker"
        exit 1
    fi

    local command="${1:-}"
    local value="${2:-}"

    case "$command" in

        set-duration)
            _tbc_require_value "$value" "Duration" "set-duration <minutes>"
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
                colorized_echo red "Duration must be a positive number (minutes)."
                exit 1
            fi
            _tbc_set_int "BlockDuration" "$value"
            _tbc_done "BlockDuration set to: ${value} minutes"
        ;;

        set-firewall)
            _tbc_require_value "$value" "Firewall mode" "set-firewall <iptables|nft>"
            if [[ "$value" != "iptables" && "$value" != "nft" ]]; then
                colorized_echo red "Invalid firewall mode. Use 'iptables' or 'nft'."
                exit 1
            fi
            _tbc_set_quoted "BlockMode" "$value"
            _tbc_done "BlockMode set to: $value"
        ;;

        set-log-file)
            _tbc_require_value "$value" "Log file path" "set-log-file <path>"
            _tbc_set_quoted "LogFile" "$value"
            _tbc_done "LogFile set to: $value"
        ;;

        set-torrent-tag)
            _tbc_require_value "$value" "Torrent tag" "set-torrent-tag <tag>"
            _tbc_set_quoted "TorrentTag" "$value"
            _tbc_done "TorrentTag set to: $value"
        ;;

        set-storage-dir)
            _tbc_require_value "$value" "Storage directory" "set-storage-dir <path>"
            _tbc_set_quoted "StorageDir" "$value"
            _tbc_done "StorageDir set to: $value"
        ;;

        set-hostname)
            _tbc_require_value "$value" "Hostname" "set-hostname <name>"
            _tbc_set_quoted "Hostname" "$value"
            _tbc_done "Hostname set to: $value"
        ;;

        set-username-regex)
            _tbc_require_value "$value" "Regex" "set-username-regex <regex>"
            _tbc_set_quoted "UsernameRegex" "$value"
            _tbc_done "UsernameRegex set to: $value"
        ;;

        add-bypass-ip)
            _tbc_require_value "$value" "IP address" "add-bypass-ip <IP>"
            if grep -q "^BypassIPS:" "$config_path"; then
                if grep -q "^  - \"${value}\"" "$config_path"; then
                    colorized_echo yellow "IP $value already in bypass list"
                    return
                fi
                sed -i "/^BypassIPS:/a\\  - \"${value}\"" "$config_path"
            else
                {
                    echo "BypassIPS:"
                    echo "  - \"${value}\""
                } >> "$config_path"
            fi
            _tbc_done "Added bypass IP: $value"
        ;;

        remove-bypass-ip)
            _tbc_require_value "$value" "IP address" "remove-bypass-ip <IP>"
            if grep -q "^  - \"${value}\"" "$config_path"; then
                sed -i "/^  - \"${value}\"$/d" "$config_path"
                _tbc_done "Removed bypass IP: $value"
            else
                colorized_echo yellow "IP $value not found in bypass list"
            fi
        ;;

        list-bypass-ips)
            colorized_echo cyan "Bypass IPs:"
            local in_list=false
            while IFS= read -r line; do
                if echo "$line" | grep -q "^BypassIPS:"; then
                    in_list=true
                    continue
                fi
                if [ "$in_list" = true ]; then
                    if echo "$line" | grep -q "^  - "; then
                        local ip
                        ip=$(echo "$line" | sed 's/^  - "\(.*\)"$/\1/' | sed "s/^  - '\(.*\)'$/\1/" | sed 's/^  - //')
                        echo "  $ip"
                    else
                        break
                    fi
                fi
            done < "$config_path"
            if [ "$in_list" = false ]; then
                colorized_echo yellow "  No BypassIPS configured"
            fi
        ;;

        set-webhook-url)
            _tbc_require_value "$value" "URL" "set-webhook-url <URL>"
            _tbc_set_quoted "WebhookURL" "$value"
            _tbc_set_bool "SendWebhook" "true"
            if ! grep -q "^WebhookTemplate:" "$config_path"; then
                echo "WebhookTemplate: '{\"username\":\"%s\",\"ip\":\"%s\",\"server\":\"%s\",\"action\":\"%s\",\"duration\":%d,\"timestamp\":\"%s\"}'" >> "$config_path"
            fi
            if ! grep -q "^WebhookHeaders:" "$config_path"; then
                {
                    echo "WebhookHeaders:"
                    echo "  Authorization: \"Bearer your-token\""
                    echo "  Content-Type: \"application/json\""
                } >> "$config_path"
            fi
            colorized_echo green "WebhookURL set to: $value"
            _tbc_done "SendWebhook: enabled"
        ;;

        set-webhook-token)
            _tbc_require_value "$value" "Token" "set-webhook-token <TOKEN>"
            if grep -q "^  Authorization:" "$config_path"; then
                sed -i "s|^  Authorization:.*|  Authorization: \"Bearer $value\"|" "$config_path"
            elif grep -q "^WebhookHeaders:" "$config_path"; then
                sed -i "/^WebhookHeaders:/a\\  Authorization: \"Bearer $value\"" "$config_path"
            else
                {
                    echo "WebhookHeaders:"
                    echo "  Authorization: \"Bearer $value\""
                    echo "  Content-Type: \"application/json\""
                } >> "$config_path"
            fi
            _tbc_done "Authorization Bearer token updated"
        ;;

        set-webhook-template)
            _tbc_require_value "$value" "Template" "set-webhook-template <template>"
            if grep -q "^WebhookTemplate:" "$config_path"; then
                sed -i "s|^WebhookTemplate:.*|WebhookTemplate: '$value'|" "$config_path"
            else
                echo "WebhookTemplate: '$value'" >> "$config_path"
            fi
            _tbc_done "WebhookTemplate updated"
        ;;

        enable-webhook)
            _tbc_set_bool "SendWebhook" "true"
            _tbc_done "Webhook enabled"
        ;;

        disable-webhook)
            _tbc_set_bool "SendWebhook" "false"
            _tbc_done "Webhook disabled"
        ;;

        show)
            colorized_echo cyan "=== tblocker config: $config_path ==="
            echo ""
            cat "$config_path"
            echo ""
            if systemctl is-active --quiet tblocker 2>/dev/null; then
                colorized_echo green "Service status: running"
            else
                colorized_echo red "Service status: stopped"
            fi
        ;;

        get)
            _tbc_require_value "$value" "Key" "get <KEY>"
            local result
            result=$(grep "^${value}:" "$config_path" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result"
            else
                colorized_echo red "Key not found: $value"
            fi
        ;;

        restart)
            colorized_echo blue "Restarting tblocker..."
            systemctl restart tblocker
            if systemctl is-active --quiet tblocker; then
                colorized_echo green "tblocker restarted successfully"
            else
                colorized_echo red "tblocker failed to start. Check: journalctl -u tblocker -f"
            fi
        ;;

        -h|--help|"")
            tblocker_config_usage
        ;;

        *)
            colorized_echo red "Unknown command: $command"
            tblocker_config_usage
            exit 1
        ;;
    esac
}

log_clean_command() {
    check_running_as_root

    local ACCESS_LOG="/var/lib/marzban/logs/access.log"
    local ERROR_LOG="/var/lib/marzban/logs/error.log"
    local CRON_TAG="# tblocker-log-clean"
    local interval=""
    local action=""

    log_clean_usage() {
        colorized_echo cyan "Usage: marzban log-clean [options]"
        echo ""
        colorized_echo yellow "Options:"
        echo "  --interval <hours>   Set up periodic log cleanup every N hours (1-24)"
        echo "  --disable            Remove the log cleanup cron job"
        echo "  --status             Show current log cleanup cron schedule"
        echo "  --now                Clean log files right now (one-time)"
        echo "  -h, --help           Show this help message"
        echo ""
        colorized_echo yellow "Cleans both access.log and error.log"
        echo ""
        colorized_echo yellow "Examples:"
        echo "  marzban log-clean --interval 6       # clean every 6 hours"
        echo "  marzban log-clean --interval 24      # clean once a day at midnight"
        echo "  marzban log-clean --now              # clean right now"
        echo "  marzban log-clean --status           # show current schedule"
        echo "  marzban log-clean --disable          # remove scheduled cleanup"
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval)
                interval="$2"
                action="set"
                if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 24 ]; then
                    colorized_echo red "Invalid interval: must be a number between 1 and 24."
                    exit 1
                fi
                shift 2
            ;;
            --disable)
                action="disable"
                shift
            ;;
            --status)
                action="status"
                shift
            ;;
            --now)
                action="now"
                shift
            ;;
            -h|--help)
                log_clean_usage
                exit 0
            ;;
            *)
                colorized_echo red "Unknown option: $1"
                log_clean_usage
                exit 1
            ;;
        esac
    done

    if [ -z "$action" ]; then
        log_clean_usage
        exit 1
    fi

    case "$action" in
        now)
            for logfile in "$ACCESS_LOG" "$ERROR_LOG"; do
                if [ -f "$logfile" ]; then
                    truncate -s 0 "$logfile"
                    colorized_echo green "Cleaned: $logfile"
                else
                    colorized_echo yellow "Not found: $logfile"
                fi
            done
        ;;
        set)
            local cron_cmd="truncate -s 0 $ACCESS_LOG && truncate -s 0 $ERROR_LOG $CRON_TAG"
            local schedule

            if [ "$interval" -eq 24 ]; then
                schedule="0 0 * * *"
            else
                schedule="0 */$interval * * *"
            fi

            local temp_cron
            temp_cron=$(mktemp)
            crontab -l 2>/dev/null > "$temp_cron" || true
            grep -v "$CRON_TAG" "$temp_cron" > "${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
            echo "$schedule $cron_cmd" >> "$temp_cron"

            if crontab "$temp_cron"; then
                if [ "$interval" -eq 24 ]; then
                    colorized_echo green "Log cleanup scheduled: daily at midnight"
                else
                    colorized_echo green "Log cleanup scheduled: every $interval hour(s)"
                fi
                colorized_echo cyan "  Files: access.log, error.log"
            else
                colorized_echo red "Failed to set cron job."
            fi
            rm -f "$temp_cron"
        ;;
        disable)
            local temp_cron
            temp_cron=$(mktemp)
            crontab -l 2>/dev/null > "$temp_cron" || true

            if grep -q "$CRON_TAG" "$temp_cron"; then
                grep -v "$CRON_TAG" "$temp_cron" > "${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
                if crontab "$temp_cron"; then
                    colorized_echo green "Log cleanup cron job removed."
                else
                    colorized_echo red "Failed to update crontab."
                fi
            else
                colorized_echo yellow "No log cleanup cron job found."
            fi
            rm -f "$temp_cron"
        ;;
        status)
            local current
            current=$(crontab -l 2>/dev/null | grep "$CRON_TAG" || true)
            if [ -n "$current" ]; then
                colorized_echo green "Log cleanup is active:"
                echo "  $current"

                local sched
                sched=$(echo "$current" | awk '{print $2}')
                if [ "$sched" = "0" ]; then
                    colorized_echo cyan "  Schedule: daily at midnight"
                else
                    local hrs
                    hrs=$(echo "$sched" | grep -oP '(?<=\*/)\d+' || echo "")
                    if [ -n "$hrs" ]; then
                        colorized_echo cyan "  Schedule: every ${hrs} hour(s)"
                    fi
                fi

                for logfile in "$ACCESS_LOG" "$ERROR_LOG"; do
                    if [ -f "$logfile" ]; then
                        local size
                        size=$(du -h "$logfile" | cut -f1)
                        colorized_echo cyan "  $(basename "$logfile"): $size"
                    fi
                done
            else
                colorized_echo yellow "Log cleanup is not configured."
                colorized_echo cyan "Set it up: marzban log-clean --interval <hours>"
            fi
        ;;
    esac
}

update_html_command() {
    check_running_as_root

    local TEMPLATES_DIR="/var/lib/marzban/templates"
    local GITHUB_RAW="https://raw.githubusercontent.com/V2as/Sauceban/master"

    update_html_usage() {
        colorized_echo cyan "Usage: marzban update-html [options]"
        echo ""
        colorized_echo yellow "Options:"
        echo "  --home               Update only the home page template"
        echo "  --home-variant <1|2> Choose home page variant (default: 1)"
        echo "                         1 = GloMart store disguise (home.html)"
        echo "                         2 = Futuristic redirect to cheapchat.net (home2.html)"
        echo "  --sub                Update only the subscription page template"
        echo "  --all                Update both templates (default)"
        echo "  --status             Show current template status"
        echo "  -h, --help           Show this help message"
        echo ""
        colorized_echo yellow "Templates:"
        echo "  home.html  -> $TEMPLATES_DIR/home/index.html  (variant 1, default)"
        echo "  home2.html -> $TEMPLATES_DIR/home/index.html  (variant 2, redirect)"
        echo "  sub.html   -> $TEMPLATES_DIR/subscription/index.html"
        echo ""
        colorized_echo yellow "Examples:"
        echo "  marzban update-html"
        echo "  marzban update-html --home"
        echo "  marzban update-html --home --home-variant 2"
        echo "  marzban update-html --home-variant 2"
        echo "  marzban update-html --sub"
        echo "  marzban update-html --status"
    }

    local action="all"
    local home_variant="1"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --home)
                action="home"
                shift
            ;;
            --home-variant)
                if [[ -n "$2" ]] && [[ "$2" =~ ^[12]$ ]]; then
                    home_variant="$2"
                    shift 2
                else
                    colorized_echo red "Error: --home-variant requires 1 or 2"
                    update_html_usage
                    exit 1
                fi
            ;;
            --sub)
                action="sub"
                shift
            ;;
            --all)
                action="all"
                shift
            ;;
            --status)
                action="status"
                shift
            ;;
            -h|--help)
                update_html_usage
                exit 0
            ;;
            *)
                colorized_echo red "Unknown option: $1"
                update_html_usage
                exit 1
            ;;
        esac
    done

    if [ "$action" = "status" ]; then
        colorized_echo cyan "=== Custom HTML Templates Status ==="
        for tpl in "home/index.html" "subscription/index.html"; do
            local fpath="$TEMPLATES_DIR/$tpl"
            if [ -f "$fpath" ]; then
                local size
                size=$(du -h "$fpath" | cut -f1)
                local mtime
                mtime=$(stat -c '%y' "$fpath" 2>/dev/null || stat -f '%Sm' "$fpath" 2>/dev/null)
                colorized_echo green "  $tpl: $size (modified: $mtime)"
            else
                colorized_echo yellow "  $tpl: not installed"
            fi
        done

        if grep -q "^CUSTOM_TEMPLATES_DIRECTORY" "$ENV_FILE" 2>/dev/null; then
            colorized_echo green "  CUSTOM_TEMPLATES_DIRECTORY is set in .env"
        else
            colorized_echo yellow "  CUSTOM_TEMPLATES_DIRECTORY is NOT set in .env"
        fi
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        detect_os
        install_package curl
    fi

    mkdir -p "$TEMPLATES_DIR/home"
    mkdir -p "$TEMPLATES_DIR/subscription"

    if [ "$action" = "home" ] || [ "$action" = "all" ]; then
        local home_file="home.html"
        local variant_label="GloMart store disguise"
        if [ "$home_variant" = "2" ]; then
            home_file="home2.html"
            variant_label="Futuristic redirect to cheapchat.net"
        fi
        colorized_echo blue "Downloading home page template (variant $home_variant: $variant_label)..."
        if curl -fsSL "$GITHUB_RAW/$home_file" -o "$TEMPLATES_DIR/home/index.html"; then
            colorized_echo green "Home page updated: $TEMPLATES_DIR/home/index.html (variant $home_variant)"
        else
            colorized_echo red "Failed to download $home_file"
        fi
    fi

    if [ "$action" = "sub" ] || [ "$action" = "all" ]; then
        colorized_echo blue "Downloading subscription page template..."
        if curl -fsSL "$GITHUB_RAW/sub.html" -o "$TEMPLATES_DIR/subscription/index.html"; then
            colorized_echo green "Subscription page updated: $TEMPLATES_DIR/subscription/index.html"
        else
            colorized_echo red "Failed to download sub.html"
        fi
    fi

    if [ -f "$ENV_FILE" ]; then
        if ! grep -q "^CUSTOM_TEMPLATES_DIRECTORY" "$ENV_FILE"; then
            echo "" >> "$ENV_FILE"
            echo "CUSTOM_TEMPLATES_DIRECTORY=\"$TEMPLATES_DIR/\"" >> "$ENV_FILE"
            colorized_echo green "CUSTOM_TEMPLATES_DIRECTORY added to .env"
        else
            colorized_echo green "CUSTOM_TEMPLATES_DIRECTORY already set in .env"
        fi
    else
        colorized_echo yellow ".env file not found at $ENV_FILE"
        colorized_echo yellow "After installing Marzban, add to .env:"
        colorized_echo cyan "  CUSTOM_TEMPLATES_DIRECTORY=\"$TEMPLATES_DIR/\""
    fi

    colorized_echo blue "Restarting Marzban to apply templates..."
    detect_compose
    down_marzban
    up_marzban

    colorized_echo green "====================================="
    colorized_echo green "  HTML templates updated!            "
    colorized_echo green "====================================="
    colorized_echo cyan "Home page:         $TEMPLATES_DIR/home/index.html"
    colorized_echo cyan "Subscription page: $TEMPLATES_DIR/subscription/index.html"
}

fix_acme_command() {
    local ACME_HOME="/root/.acme.sh"
    local ACME_VOLUME="${ACME_HOME}:${ACME_HOME}"

    check_running_as_root

    if ! is_marzban_installed; then
        colorized_echo red "Marzban is not installed!"
        exit 1
    fi

    if [ ! -f "$COMPOSE_FILE" ]; then
        colorized_echo red "docker-compose.yml not found at $COMPOSE_FILE"
        exit 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi

    local old_volumes
    old_volumes=$(yq '.services.marzban.volumes[]' "$COMPOSE_FILE" 2>/dev/null | grep "^${ACME_HOME}/" || true)

    if [ -n "$old_volumes" ]; then
        colorized_echo blue "Removing old acme.sh sub-directory volumes..."
        while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            colorized_echo yellow "  removing: $vol"
            yq -i "del(.services.marzban.volumes[] | select(. == \"$vol\"))" "$COMPOSE_FILE"
        done <<< "$old_volumes"
    fi

    if grep -qF "$ACME_VOLUME" "$COMPOSE_FILE" 2>/dev/null; then
        colorized_echo green "Volume ${ACME_VOLUME} already present — nothing to add."
    else
        colorized_echo blue "Adding volume: ${ACME_VOLUME}"
        yq -i ".services.marzban.volumes += [\"${ACME_VOLUME}\"]" "$COMPOSE_FILE"
        colorized_echo green "Volume added."
    fi

    colorized_echo blue "Restarting Marzban to apply changes..."
    detect_compose
    down_marzban
    up_marzban
    colorized_echo green "Marzban restarted with correct acme.sh volume."
}

# Truncate xray_config.json after the first valid top-level JSON value if the file has
# trailing junk (e.g. duplicate `}` → json "Extra data" / jq "Unmatched '}'").
fix_xray_json_extra_braces_command() {
    check_running_as_root

    local xray_config="${DATA_DIR}/xray_config.json"
    local no_restart=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-restart)
                no_restart=true
                shift
            ;;
            -h|--help)
                colorized_echo cyan "Usage: marzban fix-xray-json [options]"
                echo ""
                echo "Fixes a common corruption: extra closing brace(s) or garbage after valid JSON"
                echo "in ${xray_config} (same error as: json Extra data / jq Unmatched '}')."
                echo ""
                echo "OPTIONS:"
                echo "  --no-restart   Only fix the file, do not restart Marzban"
                echo "  -h, --help     Show this help"
                echo ""
                echo "A backup is written to ${xray_config}.bak before changes."
                exit 0
            ;;
            *)
                colorized_echo red "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    if ! is_marzban_installed; then
        colorized_echo red "Marzban is not installed!"
        exit 1
    fi

    if [ ! -f "$xray_config" ]; then
        colorized_echo red "Xray config not found: $xray_config"
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        colorized_echo red "python3 is required."
        exit 1
    fi

    colorized_echo blue "Checking $xray_config ..."

    local py_ec
    python3 - "$xray_config" <<'PY'
import json
import shutil
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()

try:
    json.loads(raw)
    sys.exit(0)  # already valid
except json.JSONDecodeError as e:
    if e.msg != "Extra data":
        print(f"JSON error: {e.msg} (line {e.lineno}, col {e.colno})", file=sys.stderr)
        sys.exit(2)
    fixed = raw[: e.pos].rstrip()
    try:
        json.loads(fixed)
    except json.JSONDecodeError as e2:
        print(f"Truncate to first value failed: {e2.msg} (line {e2.lineno})", file=sys.stderr)
        sys.exit(3)
    shutil.copy2(path, path + ".bak")
    with open(path, "w", encoding="utf-8") as f:
        f.write(fixed)
        if not fixed.endswith("\n"):
            f.write("\n")
    sys.exit(4)  # fixed
PY
    py_ec=$?

    case "$py_ec" in
        0)
            colorized_echo green "JSON is already valid; nothing to change."
            ;;
        4)
            colorized_echo green "Removed trailing extra data; backup: ${xray_config}.bak"
            ;;
        2|3)
            colorized_echo red "Could not auto-fix xray_config.json. Fix the file manually or restore from .bak"
            exit 1
            ;;
        *)
            colorized_echo red "Unexpected error running Python fixer (exit $py_ec)."
            exit 1
            ;;
    esac

    if [ "$no_restart" = true ]; then
        colorized_echo yellow "Skipped restart (--no-restart)."
        return 0
    fi

    detect_compose
    if ! is_marzban_up; then
        colorized_echo yellow "Marzban stack was down; starting..."
    fi
    colorized_echo blue "Restarting Marzban..."
    down_marzban
    up_marzban
    colorized_echo green "Done."
}

case "$1" in
    up)
        shift; up_command "$@";;
    down)
        shift; down_command "$@";;
    restart)
        shift; restart_command "$@";;
    status)
        shift; status_command "$@";;
    logs)
        shift; logs_command "$@";;
    cli)
        shift; cli_command "$@";;
    backup)
        shift; backup_command "$@";;
    backup-service)
        shift; backup_service "$@";;
    install)
        shift; install_command "$@";;
    update)
        shift; update_command "$@";;
    uninstall)
        shift; uninstall_command "$@";;
    install-script)
        shift; install_marzban_script "$@";;
    core-update)
        shift; update_core_command "$@";;
    migrate)
        shift; migrate_marzban "$@";;
    tblocker)
        shift; install_tblocker "$@";;
    tblocker-config)
        shift; tblocker_config_command "$@";;
    log-clean)
        shift; log_clean_command "$@";;
    update-html)
        shift; update_html_command "$@";;
    fix-acme)
        shift; fix_acme_command "$@";;
    fix-xray-json)
        shift; fix_xray_json_extra_braces_command "$@";;
    edit)
        shift; edit_command "$@";;
    edit-env)
        shift; edit_env_command "$@";;
    help|*)
        usage;;
esac

