#!/bin/bash

DASH_DOMAIN=""
KEY_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -dash-domain)
            DASH_DOMAIN="$2"
            shift 2
            ;;
        -key-domain)
            KEY_DOMAIN="$2"
            shift 2
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$DASH_DOMAIN" || -z "$KEY_DOMAIN" ]]; then
    echo "Использование: $0 -dash-domain DASH_DOMAIN -key-domain KEY_DOMAIN"
    exit 1
fi

CADDY_DIR="/opt/caddy"


mkdir -p $CADDY_DIR

cat > $CADDY_DIR/Caddyfile <<EOF
$KEY_DOMAIN {
    @api {
        path /api/*
    }

    reverse_proxy @api unix//dev/shm/xhttp.socket {
        flush_interval -1

        transport http {
            versions h2c
            read_buffer 8192
        }
    }

    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}

$DASH_DOMAIN {
	reverse_proxy 120.0.0.1:8000 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}
}
EOF

cat > $CADDY_DIR/docker-compose.yml <<EOF
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    network_mode: host
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile
      - /var/www:/var/www
      - /dev/shm:/dev/shm
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF

docker compose -f /opt/caddy/docker-compose.yml up -d && docker compose -f /opt/caddy/docker-compose.yml logs -f --tail=100


