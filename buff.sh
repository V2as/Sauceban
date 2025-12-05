SUB_PROFILE_TITLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -sub-name)
            SUB_PROFILE_TITLE="$2"
            shift 2
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# ======================================================================================================== #
#                            .ENV ДЛЯ MARZBAN                                                              #
# ======================================================================================================== #

echo "SUB_PROFILE_TITLE=\"$SUB_PROFILE_TITLE\"" >> /opt/marzban/.env
echo 'SUB_UPDATE_INTERVAL = "1"' >> /opt/marzban/.env

# ======================================================================================================== #
#                            РЕЗОЛВ НА 1.1.1.1                                                             #
# ======================================================================================================== #

CONF_FILE="/etc/systemd/resolved.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "Ошибка: файл $CONF_FILE не найден!"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: скрипт должен быть запущен с правами root!"
    exit 1
fi

cp "$CONF_FILE" "${CONF_FILE}.bak" && echo "Создана резервная копия: ${CONF_FILE}.bak"

sed -i '/^#\?DNS=/d' "$CONF_FILE"
sed -i '/^#\?FallbackDNS=/d' "$CONF_FILE"

echo "DNS=1.1.1.1 1.0.0.1" >> "$CONF_FILE"
echo "FallbackDNS=77.88.8.8 77.88.8.1" >> "$CONF_FILE"

echo "Настройки DNS добавлены в $CONF_FILE"

systemctl restart systemd-resolved && echo "Служба systemd-resolved перезапущена"

echo "Проверка статуса:"
systemctl status --no-pager systemd-resolved


echo "Текущие DNS:"
resolvectl dns

# ======================================================================================================== #
#                            BBR и FQ                                                                      #
# ======================================================================================================== #

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

