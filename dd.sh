#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  Marzban deploy helper — nginx + haproxy + acme.sh + WARP + sysctl tuning
#  Supports wildcard certificates via Cloudflare DNS-01 challenge
#  Designed for non-interactive (automation-friendly) execution
# ============================================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ─── Defaults ───────────────────────────────────────────────────────────────

ACME_EMAIL=""
MARZBAN_DIR="/opt/marzban"
MARZBAN_ENV="${MARZBAN_DIR}/.env"
MARZBAN_COMPOSE="${MARZBAN_DIR}/docker-compose.yml"
CERT_DIR="/var/lib/marzban/certs"
RESOLVED_CONF="/etc/systemd/resolved.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
NGINX_CFG="/etc/nginx/nginx.conf"
ACME_HOME="/root/.acme.sh"
UVICORN_PORT="10000"
REALITY_PORT="12000"

CF_TOKEN=""
CF_KEY=""
CF_EMAIL=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""
DASH_DOMAIN=""
SELF_STEAL_DOMAIN=""
CF_AUTH_MODE=""
WILDCARD=false
WILDCARD_BASE_DOMAIN=""
SKIP_WARP=false
SKIP_CRON=false

# ─── Colored output ────────────────────────────────────────────────────────

log_info()  { printf '\e[92m[INFO]\e[0m  %s\n' "$*"; }
log_ok()    { printf '\e[92m[OK]\e[0m    %s\n' "$*"; }
log_warn()  { printf '\e[93m[WARN]\e[0m  %s\n' "$*"; }
log_error() { printf '\e[91m[ERROR]\e[0m %s\n' "$*" >&2; }
log_step()  { printf '\n\e[96m══ %s ══\e[0m\n' "$*"; }

# ─── Usage / help ──────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage:
  dd.sh --dash-domain <domain> --ss-domain <domain> [OPTIONS]

Required:
  --dash-domain   <domain>   Dashboard / subscription domain (e.g. panel.example.com)
  --ss-domain     <domain>   Self-steal (camouflage) domain (e.g. cover.example.com)
  --acme-email    <email>    Real email for Let's Encrypt registration

Cloudflare DNS-01 (required for wildcard certs):
  Method 1 — Global API Key (simpler):
    --cf-key        <key>      Global API Key (37 chars, from CF profile)
    --cf-email      <email>    Cloudflare account email

  Method 2 — Scoped API Token:
    --cf-token      <token>    API Token (40 chars, with DNS:Edit + Zone:Read)
    --cf-account-id <id>       Account ID (use this OR --cf-zone-id)
    --cf-zone-id    <id>       Zone ID (more reliable for scoped tokens)

  --wildcard                   Issue wildcard certificate (*.domain)

Optional:
  --marzban-dir   <path>     Marzban install directory (default: /opt/marzban)
  --uvicorn-port  <port>     Uvicorn listen port (default: 10000)
  --reality-port  <port>     Reality backend port (default: 12000)
  --skip-warp                Skip Cloudflare WARP installation
  --skip-cron                Skip crontab setup
  -h, --help                 Show this help

Examples:
  # Standalone certificate (HTTP-01)
  dd.sh --dash-domain panel.example.com --ss-domain cover.example.com \
        --acme-email "your@email.com"

  # Wildcard via Global API Key (simplest)
  dd.sh --dash-domain panel.example.com --ss-domain cover.example.com \
        --acme-email "your@email.com" \
        --cf-key "your_global_api_key" --cf-email "cf@email.com" --wildcard

  # Wildcard via Scoped API Token + Zone ID
  dd.sh --dash-domain panel.example.com --ss-domain cover.example.com \
        --acme-email "your@email.com" \
        --cf-token "your_api_token" --cf-zone-id "your_zone_id" --wildcard
USAGE
    exit 0
}

# ─── Argument parsing ──────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dash-domain)    DASH_DOMAIN="$2";      shift 2 ;;
            --ss-domain)      SELF_STEAL_DOMAIN="$2"; shift 2 ;;
            --cf-token)       CF_TOKEN="$2";          shift 2 ;;
            --cf-key)         CF_KEY="$2";            shift 2 ;;
            --cf-email)       CF_EMAIL="$2";          shift 2 ;;
            --cf-account-id)  CF_ACCOUNT_ID="$2";     shift 2 ;;
            --cf-zone-id)     CF_ZONE_ID="$2";        shift 2 ;;
            --acme-email)     ACME_EMAIL="$2";        shift 2 ;;
            --marzban-dir)    MARZBAN_DIR="$2";       shift 2 ;;
            --uvicorn-port)   UVICORN_PORT="$2";      shift 2 ;;
            --reality-port)   REALITY_PORT="$2";      shift 2 ;;
            --wildcard)       WILDCARD=true;           shift   ;;
            --skip-warp)      SKIP_WARP=true;          shift   ;;
            --skip-cron)      SKIP_CRON=true;          shift   ;;
            -h|--help)        usage ;;
            *)
                log_error "Unknown argument: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$DASH_DOMAIN" || -z "$SELF_STEAL_DOMAIN" ]]; then
        log_error "--dash-domain and --ss-domain are required."
        usage
    fi

    if [[ -z "$ACME_EMAIL" ]]; then
        log_error "--acme-email is required (a real email for Let's Encrypt registration)."
        exit 1
    fi

    if [[ "$WILDCARD" == true ]]; then
        if [[ -n "$CF_KEY" && -n "$CF_EMAIL" ]]; then
            CF_AUTH_MODE="global_key"
            log_info "Using Cloudflare Global API Key"
        elif [[ -n "$CF_TOKEN" ]]; then
            CF_AUTH_MODE="api_token"
            if [[ -z "$CF_ACCOUNT_ID" && -z "$CF_ZONE_ID" ]]; then
                log_error "--cf-account-id or --cf-zone-id is required with --cf-token."
                exit 1
            fi
            log_info "Using Cloudflare API Token"
        else
            log_error "Wildcard requires Cloudflare auth. Use either:"
            log_error "  --cf-key <global_key> --cf-email <email>  (Global API Key)"
            log_error "  --cf-token <token> --cf-zone-id <id>      (Scoped API Token)"
            exit 1
        fi
    fi

    MARZBAN_ENV="${MARZBAN_DIR}/.env"
    MARZBAN_COMPOSE="${MARZBAN_DIR}/docker-compose.yml"

    ACME_DASH_DIR="${ACME_HOME}/${DASH_DOMAIN}_ecc"
    ACME_SS_DIR="${ACME_HOME}/${SELF_STEAL_DOMAIN}_ecc"
    ACME_DM_FC="${ACME_DASH_DIR}/fullchain.cer"
    ACME_DM_KEY="${ACME_DASH_DIR}/${DASH_DOMAIN}.key"
    ACME_SS_FC="${ACME_SS_DIR}/fullchain.cer"
    ACME_SS_KEY="${ACME_SS_DIR}/${SELF_STEAL_DOMAIN}.key"

    if [[ "$WILDCARD" == true ]]; then
        local base_domain
        base_domain=$(echo "$DASH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        ACME_DASH_DIR="${ACME_HOME}/${base_domain}_ecc"
        ACME_DM_FC="${ACME_DASH_DIR}/fullchain.cer"
        ACME_DM_KEY="${ACME_DASH_DIR}/${base_domain}.key"
        ACME_SS_DIR="$ACME_DASH_DIR"
        ACME_SS_FC="$ACME_DM_FC"
        ACME_SS_KEY="$ACME_DM_KEY"
        WILDCARD_BASE_DOMAIN="$base_domain"
    fi
}

# ─── Root check ─────────────────────────────────────────────────────────────

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

# ─── Helpers ────────────────────────────────────────────────────────────────

apt_install() {
    apt-get install -y -o Dpkg::Options::="--force-confold" \
                       -o Dpkg::Options::="--force-confdef" "$@"
}

sysctl_set() {
    local key="$1" value="$2"
    if grep -qE "^\s*${key}\s*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" /etc/sysctl.conf
    else
        echo "${key} = ${value}" >> /etc/sysctl.conf
    fi
}

env_set() {
    local key="$1" value="$2" file="${3:-$MARZBAN_ENV}"
    if grep -qE "^\s*${key}\s*=" "$file" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

# ─── Install base packages ─────────────────────────────────────────────────

install_base_packages() {
    log_step "Installing base packages"
    apt-get update -qq
    apt_install curl gnupg2 ca-certificates lsb-release ubuntu-keyring \
                cron socat jq
}

# ─── Install & configure acme.sh ───────────────────────────────────────────

install_acme() {
    log_step "Installing acme.sh"
    if [[ ! -d "$ACME_HOME" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
    else
        log_info "acme.sh already installed, upgrading..."
        "$ACME_HOME/acme.sh" --upgrade
    fi

    local acme_conf="${ACME_HOME}/account.conf"
    if [[ -f "$acme_conf" ]]; then
        sed -i "/^ACCOUNT_EMAIL=/d" "$acme_conf"
        echo "ACCOUNT_EMAIL='${ACME_EMAIL}'" >> "$acme_conf"
        log_info "Forced email in account.conf: ${ACME_EMAIL}"
    fi

    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
    "$ACME_HOME/acme.sh" --register-account -m "$ACME_EMAIL" || true
    log_info "ACME account registered with email: ${ACME_EMAIL}"
}

# ─── Issue certificates ────────────────────────────────────────────────────

cert_is_valid() {
    local cert_file="$1"
    [[ -f "$cert_file" && -s "$cert_file" ]] || return 1
    openssl x509 -checkend 86400 -noout -in "$cert_file" 2>/dev/null
}

issue_certificates() {
    log_step "Issuing SSL certificates"
    mkdir -p "$CERT_DIR"

    if [[ "$WILDCARD" == true ]]; then
        issue_wildcard_cert
    else
        issue_standalone_certs
    fi

    if [[ -s "$ACME_DM_KEY" && -s "$ACME_DM_FC" ]]; then
        log_info "Certificates OK:"
        log_info "  Key : ${ACME_DM_KEY}"
        log_info "  Cert: ${ACME_DM_FC}"
    else
        log_error "Certificates are missing after issuance."
        log_error "Check acme.sh log: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi
}

issue_standalone_certs() {
    if cert_is_valid "$ACME_DM_FC"; then
        log_info "Dashboard cert already valid, skipping issue"
    else
        log_info "Issuing standalone certificate for ${DASH_DOMAIN}"
        "$ACME_HOME/acme.sh" --issue --standalone \
            -d "$DASH_DOMAIN" || true
    fi

    if cert_is_valid "$ACME_SS_FC"; then
        log_info "SS cert already valid, skipping issue"
    else
        log_info "Issuing standalone certificate for ${SELF_STEAL_DOMAIN}"
        "$ACME_HOME/acme.sh" --issue --standalone \
            -d "$SELF_STEAL_DOMAIN" || true
    fi
}

cf_curl() {
    if [[ "$CF_AUTH_MODE" == "global_key" ]]; then
        curl -s "$@" -H "X-Auth-Key: ${CF_KEY}" -H "X-Auth-Email: ${CF_EMAIL}" -H "Content-Type: application/json"
    else
        curl -s "$@" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json"
    fi
}

verify_cloudflare_api() {
    log_info "Verifying Cloudflare API access (mode: ${CF_AUTH_MODE})..."

    local verify_check
    if [[ "$CF_AUTH_MODE" == "global_key" ]]; then
        verify_check=$(cf_curl -X GET "https://api.cloudflare.com/client/v4/user")
    else
        verify_check=$(cf_curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify")
    fi

    local verify_ok
    verify_ok=$(echo "$verify_check" | jq -r '.success // false')

    if [[ "$verify_ok" != "true" ]]; then
        log_error "Cloudflare authentication FAILED."
        log_error "API response: $(echo "$verify_check" | jq -r '.errors[0].message // .errors // "unknown"')"
        if [[ "$CF_AUTH_MODE" == "api_token" ]]; then
            log_error "Token length: ${#CF_TOKEN} chars (expected: 40)"
        fi
        return 1
    fi

    if [[ "$CF_AUTH_MODE" == "global_key" ]]; then
        log_ok "Global API Key is valid (user: ${CF_EMAIL})"
    else
        log_ok "API Token is valid: $(echo "$verify_check" | jq -r '.result.status')"
    fi

    local zone_id="${CF_ZONE_ID}"
    if [[ -z "$zone_id" ]]; then
        log_info "No Zone ID provided, looking up zone for ${1}..."
        local zones
        zones=$(cf_curl -X GET "https://api.cloudflare.com/client/v4/zones?name=${1}")
        zone_id=$(echo "$zones" | jq -r '.result[0].id // empty')
        if [[ -z "$zone_id" ]]; then
            log_error "Cannot find zone '${1}' via API. Provide --cf-zone-id explicitly."
            return 1
        fi
        CF_ZONE_ID="$zone_id"
        log_ok "Found zone: ${1} (${zone_id})"
    else
        local zone_check
        zone_check=$(cf_curl -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}")
        local zone_ok
        zone_ok=$(echo "$zone_check" | jq -r '.success // false')
        if [[ "$zone_ok" != "true" ]]; then
            log_error "Cannot access Zone ID ${zone_id}"
            log_error "API response: $(echo "$zone_check" | jq -r '.errors[0].message // .errors // "unknown"')"
            return 1
        fi
        log_ok "Zone access confirmed: $(echo "$zone_check" | jq -r '.result.name') (${zone_id})"
    fi

    local dns_test
    dns_test=$(cf_curl -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=TXT&per_page=1")
    local dns_ok
    dns_ok=$(echo "$dns_test" | jq -r '.success // false')
    if [[ "$dns_ok" == "true" ]]; then
        log_ok "DNS read access confirmed"
    else
        log_error "Cannot read DNS records."
        log_error "API response: $(echo "$dns_test" | jq -r '.errors[0].message // .errors // "unknown"')"
        return 1
    fi

    return 0
}

setup_cf_credentials() {
    local acme_conf="${ACME_HOME}/account.conf"
    [[ ! -f "$acme_conf" ]] && return

    sed -i '/^SAVED_CF_Token=/d; /^SAVED_CF_Account_ID=/d; /^SAVED_CF_Zone_ID=/d; /^SAVED_CF_Key=/d; /^SAVED_CF_Email=/d' "$acme_conf"

    if [[ "$CF_AUTH_MODE" == "global_key" ]]; then
        echo "SAVED_CF_Key='${CF_KEY}'" >> "$acme_conf"
        echo "SAVED_CF_Email='${CF_EMAIL}'" >> "$acme_conf"
        export CF_Key="$CF_KEY"
        export CF_Email="$CF_EMAIL"
        log_info "Set Cloudflare Global API Key credentials"
    else
        echo "SAVED_CF_Token='${CF_TOKEN}'" >> "$acme_conf"
        [[ -n "$CF_ACCOUNT_ID" ]] && echo "SAVED_CF_Account_ID='${CF_ACCOUNT_ID}'" >> "$acme_conf"
        [[ -n "$CF_ZONE_ID" ]]    && echo "SAVED_CF_Zone_ID='${CF_ZONE_ID}'" >> "$acme_conf"
        export CF_Token="$CF_TOKEN"
        [[ -n "$CF_ACCOUNT_ID" ]] && export CF_Account_ID="$CF_ACCOUNT_ID"
        [[ -n "$CF_ZONE_ID" ]]    && export CF_Zone_ID="$CF_ZONE_ID"
        log_info "Set Cloudflare API Token credentials"
    fi
}

issue_wildcard_cert() {
    local base_domain
    base_domain=$(echo "$DASH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    log_info "Issuing wildcard certificate for *.${base_domain} via Cloudflare DNS-01"

    if ! verify_cloudflare_api "$base_domain"; then
        log_error "Cloudflare API verification failed. Cannot issue wildcard certificate."
        exit 1
    fi

    setup_cf_credentials

    local wild_cert="${ACME_HOME}/${base_domain}_ecc/fullchain.cer"
    if cert_is_valid "$wild_cert"; then
        log_info "Wildcard cert already valid, skipping issue"
    else
        if ! "$ACME_HOME/acme.sh" --issue --dns dns_cf \
            -d "${base_domain}" \
            -d "*.${base_domain}" \
            --log; then
            log_error "Failed to issue wildcard cert."
            log_error "See log: ${ACME_HOME}/acme.sh.log"
            return 1
        fi
    fi

    log_info "Wildcard cert covers both ${DASH_DOMAIN} and ${SELF_STEAL_DOMAIN}"
}

# ─── Install nginx from official repo ──────────────────────────────────────

install_nginx() {
    log_step "Installing nginx (official repo)"

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

    local codename
    codename=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-noble}}"))

    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${codename} nginx
EOF

    cat > /etc/apt/preferences.d/99-nginx <<EOF
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

    apt-get update -qq
    apt_install nginx
}

# ─── Configure nginx ───────────────────────────────────────────────────────

configure_nginx() {
    log_step "Configuring nginx"

    cat > "$NGINX_CFG" <<NGINXEOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

error_log /var/log/nginx/error.log;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    log_format proxlog '\$status (\$proxy_protocol_addr) \$remote_user [\$time_local]';
    access_log /var/log/nginx/access.log proxlog;

    gzip on;

    server {
        access_log off;
        listen 127.0.0.1:8081;
        return 204;
    }

    server {
        listen 127.0.0.1:8001 ssl http2 default_server proxy_protocol;
        server_name _;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_reject_handshake on;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 3m;
        ssl_session_cache shared:SSL:3m;

        access_log /var/log/nginx/access.log proxlog;
    }

    server {
        listen 127.0.0.1:8001 ssl http2 proxy_protocol;
        server_name ${SELF_STEAL_DOMAIN};

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_certificate ${ACME_SS_FC};
        ssl_certificate_key ${ACME_SS_KEY};

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";
        ssl_prefer_server_ciphers on;

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 valid=60s;
        resolver_timeout 2s;

        auth_basic "Access restricted, enter login & password";
        auth_basic_user_file /etc/nginx/.htpasswd;

        root /var/mysite;
        index index.html;
    }
}
NGINXEOF

    log_info "nginx config written to ${NGINX_CFG}"
}

# ─── Install & configure haproxy ───────────────────────────────────────────

install_haproxy() {
    log_step "Installing haproxy"
    apt_install haproxy
}

configure_haproxy() {
    log_step "Configuring haproxy"

    cat > "$HAPROXY_CFG" <<HAEOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

    ca-base ${ACME_SS_DIR}
    crt-base ${ACME_SS_DIR}

    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

listen front
    mode tcp
    bind *:443

    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl is_dashboard req.ssl_sni -i end ${DASH_DOMAIN}

    tcp-request content accept if HTTP

    use_backend panel  if is_dashboard
    use_backend reality if !is_dashboard

backend reality
    mode tcp
    server srv1 127.0.0.1:${REALITY_PORT}

backend panel
    mode tcp
    server srv1 127.0.0.1:${UVICORN_PORT}
HAEOF

    log_info "haproxy config written to ${HAPROXY_CFG}"
}

# ─── Install Cloudflare WARP ───────────────────────────────────────────────

install_warp() {
    if [[ "$SKIP_WARP" == true ]]; then
        log_warn "Skipping WARP installation (--skip-warp)"
        return 0
    fi

    log_step "Installing Cloudflare WARP"

    local codename
    codename=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-noble}}"))

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

    apt-get update -qq
    apt_install cloudflare-warp

    if ! warp-cli --accept-tos registration new 2>/dev/null; then
        log_warn "WARP registration already exists or failed, continuing..."
    fi
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 9091
    warp-cli --accept-tos connect || true

    log_info "WARP configured in proxy mode on port 9091"
}

# ─── Sysctl tuning ─────────────────────────────────────────────────────────

tune_sysctl() {
    log_step "Applying sysctl tuning (BBR, disable IPv6)"

    sysctl_set "net.ipv6.conf.all.disable_ipv6" "1"
    sysctl_set "net.core.default_qdisc" "fq"
    sysctl_set "net.ipv4.tcp_congestion_control" "bbr"

    sysctl -p
    log_info "sysctl applied"
}

# ─── Configure DNS (systemd-resolved) ──────────────────────────────────────

configure_dns() {
    log_step "Configuring DNS resolver"

    if [[ ! -f "$RESOLVED_CONF" ]]; then
        log_warn "${RESOLVED_CONF} not found, skipping DNS config"
        return 0
    fi

    cp -n "$RESOLVED_CONF" "${RESOLVED_CONF}.bak" 2>/dev/null || true

    sed -i '/^#\?DNS=/d; /^#\?FallbackDNS=/d' "$RESOLVED_CONF"
    {
        echo "DNS=1.1.1.1 1.0.0.1"
        echo "FallbackDNS=77.88.8.8 77.88.8.1"
    } >> "$RESOLVED_CONF"

    systemctl restart systemd-resolved || true
    log_info "DNS set to 1.1.1.1 / 1.0.0.1"
}

# ─── Marzban .env ──────────────────────────────────────────────────────────

configure_marzban_env() {
    log_step "Configuring Marzban .env"

    if [[ ! -f "$MARZBAN_ENV" ]]; then
        log_warn "${MARZBAN_ENV} not found — creating"
        mkdir -p "$(dirname "$MARZBAN_ENV")"
        touch "$MARZBAN_ENV"
    fi

    env_set "UVICORN_PORT"              "\"${UVICORN_PORT}\""
    env_set "SUB_PROFILE_TITLE"         "\"BLACKTEMPLE VPN BR\""
    env_set "SUB_UPDATE_INTERVAL"       "\"2\""
    env_set "XRAY_SUBSCRIPTION_URL_PREFIX" "\"https://${DASH_DOMAIN}\""
    env_set "UVICORN_SSL_KEYFILE"       "\"${ACME_DM_KEY}\""
    env_set "UVICORN_SSL_CERTFILE"      "\"${ACME_DM_FC}\""

    log_info "Marzban .env updated"
    log_info "  UVICORN_SSL_KEYFILE  = ${ACME_DM_KEY}"
    log_info "  UVICORN_SSL_CERTFILE = ${ACME_DM_FC}"
}

# ─── Add ACME volume to docker-compose ─────────────────────────────────────

add_acme_volume() {
    log_step "Adding ACME cert volume to docker-compose"

    if [[ ! -f "$MARZBAN_COMPOSE" ]]; then
        log_warn "docker-compose.yml not found at ${MARZBAN_COMPOSE}, skipping"
        return 0
    fi

    local acme_dir="$ACME_DASH_DIR"

    local volume_entry="${acme_dir}:${acme_dir}"
    if grep -qF "$volume_entry" "$MARZBAN_COMPOSE" 2>/dev/null; then
        log_info "Volume already present in docker-compose.yml"
        return 0
    fi

    if command -v yq &>/dev/null; then
        yq eval ".services.marzban.volumes += [\"${volume_entry}\"]" -i "$MARZBAN_COMPOSE"
    else
        sed -i "/volumes:/a\\      - ${volume_entry}" "$MARZBAN_COMPOSE"
    fi

    log_info "Added volume: ${volume_entry}"
}

# ─── Crontab for Marzban restart ───────────────────────────────────────────

setup_crontab() {
    if [[ "$SKIP_CRON" == true ]]; then
        log_warn "Skipping crontab setup (--skip-cron)"
        return 0
    fi

    log_step "Setting up crontab"

    local new_cmd='sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/SauceScripts/main/sauceban.sh)" @ restart'
    local current
    current=$(crontab -l 2>/dev/null || true)

    local plain_lines
    plain_lines=$(printf '%s\n' "$current" | awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ {print}')
    local count
    count=$(printf '%s\n' "$plain_lines" | grep -c . || true)

    if [[ "$count" -gt 1 ]]; then
        log_warn "Crontab has ${count} active entries — not modifying"
        return 0
    fi
    if [[ "$count" -eq 0 ]]; then
        log_warn "Crontab is empty — nothing to base schedule on"
        return 0
    fi

    local first_line schedule
    first_line=$(printf '%s\n' "$plain_lines" | head -1)

    case "$first_line" in
        [[:space:]]*@*)
            schedule=$(printf '%s\n' "$first_line" | awk '{print $1}')
            ;;
        *)
            schedule=$(printf '%s\n' "$first_line" | awk '{printf "%s %s %s %s %s", $1,$2,$3,$4,$5}')
            ;;
    esac

    local new_line="${schedule} ${new_cmd}"

    if printf '%s\n' "$current" | grep -Fxq "$new_line"; then
        log_info "Crontab entry already exists"
        return 0
    fi

    local tmp
    tmp=$(mktemp /tmp/cron.XXXXXX)
    printf '%s\n\n%s\n' "$current" "$new_line" > "$tmp"

    if crontab "$tmp"; then
        log_info "Added crontab: ${new_line}"
    else
        log_error "Failed to install crontab"
    fi
    rm -f "$tmp"
}

# ─── Harden nginx.service (auto-restart) ──────────────────────────────────

harden_nginx_service() {
    log_step "Hardening nginx.service"

    local service_file=""
    local paths=(
        "/etc/systemd/system/nginx.service"
        "/lib/systemd/system/nginx.service"
        "/usr/lib/systemd/system/nginx.service"
    )

    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            service_file="$p"
            break
        fi
    done

    if [[ -z "$service_file" ]]; then
        log_warn "nginx.service not found — skipping hardening"
        return 0
    fi

    log_info "Found unit file: ${service_file}"

    local -A params=(
        [Restart]="on-failure"
        [RestartSec]="5s"
        [StartLimitInterval]="60s"
        [StartLimitBurst]="3"
    )

    for key in "${!params[@]}"; do
        if grep -qE "^\s*${key}=" "$service_file"; then
            log_info "${key} already set — skipping"
        else
            sed -i "/^\[Service\]/a ${key}=${params[$key]}" "$service_file"
            log_info "Added ${key}=${params[$key]}"
        fi
    done

    systemctl daemon-reload
}

# ─── Restart services ──────────────────────────────────────────────────────

restart_services() {
    log_step "Restarting services"

    systemctl enable nginx
    systemctl restart nginx   && log_info "nginx restarted"
    systemctl restart haproxy && log_info "haproxy restarted"

    if command -v marzban &>/dev/null; then
        marzban restart -n && log_info "marzban restarted"
    else
        log_warn "marzban CLI not found — skip restart (do it manually)"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    require_root

    log_step "Starting deployment"
    log_info "Dashboard domain : ${DASH_DOMAIN}"
    log_info "Self-steal domain: ${SELF_STEAL_DOMAIN}"
    log_info "Wildcard mode    : ${WILDCARD}"
    log_info "WARP             : $(if $SKIP_WARP; then echo 'skip'; else echo 'install'; fi)"

    install_base_packages
    install_acme
    issue_certificates
    install_nginx
    configure_nginx
    install_haproxy
    configure_haproxy
    install_warp
    tune_sysctl
    configure_dns
    configure_marzban_env
    add_acme_volume
    setup_crontab
    harden_nginx_service
    restart_services

    log_step "Deployment complete"
    log_info "Dashboard : https://${DASH_DOMAIN}"
    log_info "Certs     : ${CERT_DIR}/"
    log_info "Nginx cfg : ${NGINX_CFG}"
    log_info "HAProxy   : ${HAPROXY_CFG}"
}

main "$@"
