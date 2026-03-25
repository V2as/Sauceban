#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  Marzban repair tool — auto-detects and fixes broken dd.sh installations
#  Run without arguments for automatic detection, or pass args to override
# ============================================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ─── Defaults ───────────────────────────────────────────────────────────────

MARZBAN_DIR="/opt/marzban"
CERT_DIR="/var/lib/marzban/certs"
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
WILDCARD=false
DRY_RUN=false

ERRORS=0
FIXED=0

# ─── Colored output ────────────────────────────────────────────────────────

log_info()  { printf '\e[92m[INFO]\e[0m  %s\n' "$*"; }
log_ok()    { printf '\e[92m[OK]\e[0m    %s\n' "$*"; }
log_warn()  { printf '\e[93m[WARN]\e[0m  %s\n' "$*"; }
log_error() { printf '\e[91m[ERROR]\e[0m %s\n' "$*"; }
log_fix()   { printf '\e[95m[FIX]\e[0m   %s\n' "$*"; }
log_step()  { printf '\n\e[96m══ %s ══\e[0m\n' "$*"; }
log_detect(){ printf '\e[94m[AUTO]\e[0m  %s\n' "$*"; }

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage:
  dd-fix.sh [OPTIONS]

Auto-detects and repairs a broken Marzban installation.
When run without arguments, reads config from .env, nginx, haproxy, acme.sh.

All arguments are optional (auto-detected if omitted):
  --dash-domain   <domain>   Override dashboard domain
  --ss-domain     <domain>   Override self-steal domain
  --wildcard                 Force wildcard mode
  --cf-key        <key>      Cloudflare Global API Key
  --cf-email      <email>    Cloudflare account email
  --cf-token      <token>    Cloudflare API Token
  --cf-account-id <id>       Cloudflare Account ID
  --cf-zone-id    <id>       Cloudflare Zone ID
  --marzban-dir   <path>     Marzban directory (default: /opt/marzban)
  --uvicorn-port  <port>     Uvicorn port (default: 10000)
  --reality-port  <port>     Reality backend port (default: 12000)
  --dry-run                  Show what would be fixed without changing anything
  -h, --help                 Show this help

Examples:
  dd-fix.sh                  # auto-detect everything and fix
  dd-fix.sh --dry-run        # auto-detect, show issues, don't fix
  dd-fix.sh --dash-domain panel.example.com  # override one value
USAGE
    exit 0
}

# ─── Argument parsing ──────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dash-domain)    DASH_DOMAIN="$2";       shift 2 ;;
            --ss-domain)      SELF_STEAL_DOMAIN="$2"; shift 2 ;;
            --cf-token)       CF_TOKEN="$2";          shift 2 ;;
            --cf-key)         CF_KEY="$2";            shift 2 ;;
            --cf-email)       CF_EMAIL="$2";          shift 2 ;;
            --cf-account-id)  CF_ACCOUNT_ID="$2";     shift 2 ;;
            --cf-zone-id)     CF_ZONE_ID="$2";        shift 2 ;;
            --marzban-dir)    MARZBAN_DIR="$2";       shift 2 ;;
            --uvicorn-port)   UVICORN_PORT="$2";      shift 2 ;;
            --reality-port)   REALITY_PORT="$2";      shift 2 ;;
            --wildcard)       WILDCARD=true;            shift   ;;
            --dry-run)        DRY_RUN=true;             shift   ;;
            -h|--help)        usage ;;
            *)
                log_error "Unknown argument: $1"
                usage
                ;;
        esac
    done

    MARZBAN_ENV="${MARZBAN_DIR}/.env"
    MARZBAN_COMPOSE="${MARZBAN_DIR}/docker-compose.yml"
}

# ─── Auto-detection ────────────────────────────────────────────────────────

auto_detect() {
    log_step "Auto-detecting configuration"

    # Dash domain from .env
    if [[ -z "$DASH_DOMAIN" && -f "$MARZBAN_ENV" ]]; then
        local sub_url
        sub_url=$(grep -E '^\s*XRAY_SUBSCRIPTION_URL_PREFIX\s*=' "$MARZBAN_ENV" 2>/dev/null \
            | head -1 | sed 's/.*=\s*//' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//" | xargs)
        if [[ -n "$sub_url" ]]; then
            DASH_DOMAIN=$(echo "$sub_url" | sed 's|https\?://||' | sed 's|/.*||')
            log_detect "Dashboard domain from .env: ${DASH_DOMAIN}"
        fi
    fi

    # Dash domain from haproxy
    if [[ -z "$DASH_DOMAIN" && -f "$HAPROXY_CFG" ]]; then
        DASH_DOMAIN=$(grep -oP 'req\.ssl_sni\s+-i\s+end\s+\K\S+' "$HAPROXY_CFG" 2>/dev/null | head -1)
        if [[ -n "$DASH_DOMAIN" ]]; then
            log_detect "Dashboard domain from haproxy: ${DASH_DOMAIN}"
        fi
    fi

    # SS domain from nginx
    if [[ -z "$SELF_STEAL_DOMAIN" && -f "$NGINX_CFG" ]]; then
        SELF_STEAL_DOMAIN=$(grep -oP 'server_name\s+\K[^;_\s]+' "$NGINX_CFG" 2>/dev/null \
            | grep -v '^_$' | head -1)
        if [[ -n "$SELF_STEAL_DOMAIN" ]]; then
            log_detect "SS domain from nginx: ${SELF_STEAL_DOMAIN}"
        fi
    fi

    # SS domain from acme.sh directories
    if [[ -z "$SELF_STEAL_DOMAIN" && -n "$DASH_DOMAIN" ]]; then
        local base
        base=$(echo "$DASH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        for dir in "${ACME_HOME}"/*_ecc; do
            local name
            name=$(basename "$dir" | sed 's/_ecc$//')
            if [[ "$name" != "$base" && "$name" != "$DASH_DOMAIN" && "$name" == *"${base}" ]]; then
                SELF_STEAL_DOMAIN="$name"
                log_detect "SS domain from acme.sh: ${SELF_STEAL_DOMAIN}"
                break
            fi
        done
    fi

    # Wildcard detection from acme.sh
    if [[ "$WILDCARD" == false && -n "$DASH_DOMAIN" ]]; then
        local base
        base=$(echo "$DASH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        if [[ -d "${ACME_HOME}/${base}_ecc" && ! -d "${ACME_HOME}/${DASH_DOMAIN}_ecc" ]]; then
            WILDCARD=true
            log_detect "Wildcard mode detected (found ${base}_ecc, no ${DASH_DOMAIN}_ecc)"
        fi
    fi

    # UVICORN_PORT from .env
    if [[ -f "$MARZBAN_ENV" ]]; then
        local port
        port=$(grep -E '^\s*UVICORN_PORT\s*=' "$MARZBAN_ENV" 2>/dev/null \
            | head -1 | sed 's/.*=\s*//' | sed 's/^"//;s/"$//' | xargs)
        if [[ -n "$port" ]]; then
            UVICORN_PORT="$port"
            log_detect "Uvicorn port from .env: ${UVICORN_PORT}"
        fi
    fi

    # REALITY_PORT from haproxy
    if [[ -f "$HAPROXY_CFG" ]]; then
        local rport
        rport=$(grep -A1 'backend reality' "$HAPROXY_CFG" 2>/dev/null \
            | grep -oP '127\.0\.0\.1:\K\d+' | head -1)
        if [[ -n "$rport" ]]; then
            REALITY_PORT="$rport"
            log_detect "Reality port from haproxy: ${REALITY_PORT}"
        fi
    fi

    # CF credentials from acme.sh account.conf
    local acme_conf="${ACME_HOME}/account.conf"
    if [[ -f "$acme_conf" ]]; then
        if [[ -z "$CF_KEY" ]]; then
            CF_KEY=$(grep -oP "^SAVED_CF_Key='\K[^']+" "$acme_conf" 2>/dev/null || true)
            [[ -n "$CF_KEY" ]] && log_detect "CF Key from account.conf"
        fi
        if [[ -z "$CF_EMAIL" ]]; then
            CF_EMAIL=$(grep -oP "^SAVED_CF_Email='\K[^']+" "$acme_conf" 2>/dev/null || true)
            [[ -n "$CF_EMAIL" ]] && log_detect "CF Email from account.conf"
        fi
        if [[ -z "$CF_TOKEN" ]]; then
            CF_TOKEN=$(grep -oP "^SAVED_CF_Token='\K[^']+" "$acme_conf" 2>/dev/null || true)
            [[ -n "$CF_TOKEN" ]] && log_detect "CF Token from account.conf"
        fi
        if [[ -z "$CF_ACCOUNT_ID" ]]; then
            CF_ACCOUNT_ID=$(grep -oP "^SAVED_CF_Account_ID='\K[^']+" "$acme_conf" 2>/dev/null || true)
            [[ -n "$CF_ACCOUNT_ID" ]] && log_detect "CF Account ID from account.conf"
        fi
        if [[ -z "$CF_ZONE_ID" ]]; then
            CF_ZONE_ID=$(grep -oP "^SAVED_CF_Zone_ID='\K[^']+" "$acme_conf" 2>/dev/null || true)
            [[ -n "$CF_ZONE_ID" ]] && log_detect "CF Zone ID from account.conf"
        fi
    fi

    # Validate minimum required detection
    if [[ -z "$DASH_DOMAIN" ]]; then
        log_error "Could not detect dashboard domain. Pass --dash-domain manually."
        exit 1
    fi
    if [[ -z "$SELF_STEAL_DOMAIN" ]]; then
        log_error "Could not detect SS domain. Pass --ss-domain manually."
        exit 1
    fi
}

# ─── Compute derived paths ─────────────────────────────────────────────────

compute_paths() {
    if [[ "$WILDCARD" == true ]]; then
        BASE_DOMAIN=$(echo "$DASH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        ACME_DASH_DIR="${ACME_HOME}/${BASE_DOMAIN}_ecc"
        ACME_DM_FC="${ACME_DASH_DIR}/fullchain.cer"
        ACME_DM_KEY="${ACME_DASH_DIR}/${BASE_DOMAIN}.key"
    else
        BASE_DOMAIN=""
        ACME_DASH_DIR="${ACME_HOME}/${DASH_DOMAIN}_ecc"
        ACME_DM_FC="${ACME_DASH_DIR}/fullchain.cer"
        ACME_DM_KEY="${ACME_DASH_DIR}/${DASH_DOMAIN}.key"
    fi
    ACME_SS_DIR="${ACME_HOME}/${SELF_STEAL_DOMAIN}_ecc"
}

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

get_codename() {
    lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-noble}}")
}

env_get() {
    local key="$1" file="${2:-$MARZBAN_ENV}"
    grep -E "^\s*${key}\s*=" "$file" 2>/dev/null \
        | head -1 \
        | sed "s/^\s*${key}\s*=\s*//" \
        | sed 's/^"\(.*\)"$/\1/' \
        | sed "s/^'\(.*\)'$/\1/" \
        | xargs
}

env_set() {
    local key="$1" value="$2" file="${3:-$MARZBAN_ENV}"
    if grep -qE "^\s*${key}\s*=" "$file" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

check_env_value() {
    local key="$1" expected="$2" label="$3"
    local current
    current=$(env_get "$key")

    if [[ "$current" == "$expected" ]]; then
        log_ok "${label}: ${current}"
        return 0
    else
        ERRORS=$((ERRORS + 1))
        if [[ -z "$current" ]]; then
            log_error "${label}: NOT SET (expected: ${expected})"
        else
            log_error "${label}: '${current}' (expected: '${expected}')"
        fi
        return 1
    fi
}

fix_env_value() {
    local key="$1" value="$2" label="$3"
    if [[ "$DRY_RUN" == true ]]; then
        log_fix "[dry-run] Would set ${key} = \"${value}\""
    else
        env_set "$key" "\"${value}\""
        log_fix "Set ${key} = \"${value}\""
        FIXED=$((FIXED + 1))
    fi
}

# ─── 1. Check certificates ─────────────────────────────────────────────────

check_certificates() {
    log_step "Checking certificates"

    if [[ -d "$ACME_DASH_DIR" ]]; then
        log_ok "ACME directory exists: ${ACME_DASH_DIR}"

        if [[ -f "$ACME_DM_KEY" && -s "$ACME_DM_KEY" ]]; then
            log_ok "Key file exists: ${ACME_DM_KEY}"
        else
            ERRORS=$((ERRORS + 1))
            log_error "Key file MISSING or empty: ${ACME_DM_KEY}"
        fi

        if [[ -f "$ACME_DM_FC" && -s "$ACME_DM_FC" ]]; then
            log_ok "Cert file exists: ${ACME_DM_FC}"
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "$ACME_DM_FC" 2>/dev/null | cut -d= -f2)
            if [[ -n "$expiry" ]]; then
                log_info "  Expires: ${expiry}"
                if openssl x509 -checkend 86400 -noout -in "$ACME_DM_FC" 2>/dev/null; then
                    log_ok "  Certificate is valid (not expiring within 24h)"
                else
                    ERRORS=$((ERRORS + 1))
                    log_error "  Certificate is EXPIRED or expiring within 24h"
                fi
            fi
        else
            ERRORS=$((ERRORS + 1))
            log_error "Cert file MISSING or empty: ${ACME_DM_FC}"
        fi
    else
        ERRORS=$((ERRORS + 1))
        log_error "ACME directory MISSING: ${ACME_DASH_DIR}"
    fi

    if [[ -d "$ACME_SS_DIR" ]]; then
        log_ok "ACME SS directory exists: ${ACME_SS_DIR}"
    else
        ERRORS=$((ERRORS + 1))
        log_error "ACME SS directory MISSING: ${ACME_SS_DIR}"
    fi
}

fix_certificates() {
    log_step "Fixing certificates"

    if [[ -f "$ACME_DM_KEY" && -s "$ACME_DM_KEY" && -f "$ACME_DM_FC" && -s "$ACME_DM_FC" ]]; then
        if openssl x509 -checkend 86400 -noout -in "$ACME_DM_FC" 2>/dev/null; then
            log_info "Certificates are OK, skipping re-issue"
            return 0
        fi
    fi

    if [[ -d "$ACME_DASH_DIR" ]]; then
        log_info "ACME directory exists but certs are broken/expired — try renew"
        if [[ "$DRY_RUN" == true ]]; then
            log_fix "[dry-run] Would renew certificate"
            return 0
        fi
        "$ACME_HOME/acme.sh" --renew -d "${WILDCARD:+${BASE_DOMAIN:-$DASH_DOMAIN}}" \
            ${WILDCARD:+-d "*.${BASE_DOMAIN}"} --force || true
        FIXED=$((FIXED + 1))
    else
        log_warn "ACME directory missing — cannot fix certs automatically"
        log_warn "Re-run dd.sh to issue new certificates"
    fi

    if [[ ! -d "$ACME_SS_DIR" ]]; then
        log_warn "SS cert directory missing — re-run dd.sh to issue"
    fi
}

# ─── 2. Check .env ─────────────────────────────────────────────────────────

check_env() {
    log_step "Checking Marzban .env"

    if [[ ! -f "$MARZBAN_ENV" ]]; then
        ERRORS=$((ERRORS + 1))
        log_error ".env NOT FOUND at ${MARZBAN_ENV}"
        return 1
    fi

    log_ok ".env exists: ${MARZBAN_ENV}"

    local need_fix=false

    check_env_value "UVICORN_PORT"              "$UVICORN_PORT"                "UVICORN_PORT"              || need_fix=true
    check_env_value "UVICORN_SSL_KEYFILE"       "${ACME_DM_KEY}"               "UVICORN_SSL_KEYFILE"       || need_fix=true
    check_env_value "UVICORN_SSL_CERTFILE"      "${ACME_DM_FC}"                "UVICORN_SSL_CERTFILE"      || need_fix=true
    check_env_value "XRAY_SUBSCRIPTION_URL_PREFIX" "https://${DASH_DOMAIN}"    "XRAY_SUBSCRIPTION_URL_PREFIX" || need_fix=true

    if [[ "$need_fix" == true ]]; then
        return 1
    fi
    return 0
}

fix_env() {
    log_step "Fixing Marzban .env"

    if [[ ! -f "$MARZBAN_ENV" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_fix "[dry-run] Would create ${MARZBAN_ENV}"
        else
            mkdir -p "$(dirname "$MARZBAN_ENV")"
            touch "$MARZBAN_ENV"
            log_fix "Created ${MARZBAN_ENV}"
        fi
    fi

    local current

    current=$(env_get "UVICORN_PORT")
    [[ "$current" != "$UVICORN_PORT" ]] && fix_env_value "UVICORN_PORT" "$UVICORN_PORT" "UVICORN_PORT"

    current=$(env_get "UVICORN_SSL_KEYFILE")
    [[ "$current" != "${ACME_DM_KEY}" ]] && fix_env_value "UVICORN_SSL_KEYFILE" "${ACME_DM_KEY}" "UVICORN_SSL_KEYFILE"

    current=$(env_get "UVICORN_SSL_CERTFILE")
    [[ "$current" != "${ACME_DM_FC}" ]] && fix_env_value "UVICORN_SSL_CERTFILE" "${ACME_DM_FC}" "UVICORN_SSL_CERTFILE"

    current=$(env_get "XRAY_SUBSCRIPTION_URL_PREFIX")
    [[ "$current" != "https://${DASH_DOMAIN}" ]] && fix_env_value "XRAY_SUBSCRIPTION_URL_PREFIX" "https://${DASH_DOMAIN}" "XRAY_SUBSCRIPTION_URL_PREFIX"
}

# ─── 3. Check nginx ────────────────────────────────────────────────────────

check_nginx() {
    log_step "Checking nginx"

    if ! command -v nginx &>/dev/null; then
        ERRORS=$((ERRORS + 1))
        log_error "nginx is NOT installed"
        return 1
    fi
    log_ok "nginx is installed"

    if ! systemctl is-active --quiet nginx; then
        ERRORS=$((ERRORS + 1))
        log_error "nginx is NOT running"
    else
        log_ok "nginx is running"
    fi

    if [[ ! -f "$NGINX_CFG" ]]; then
        ERRORS=$((ERRORS + 1))
        log_error "nginx config not found: ${NGINX_CFG}"
        return 1
    fi

    local need_fix=false

    if grep -q "server_name ${SELF_STEAL_DOMAIN};" "$NGINX_CFG"; then
        log_ok "nginx: SS domain correct (${SELF_STEAL_DOMAIN})"
    else
        ERRORS=$((ERRORS + 1))
        log_error "nginx: SS domain NOT found in config"
        need_fix=true
    fi

    local expected_cert="${ACME_SS_DIR}/fullchain.cer"
    if grep -qF "$expected_cert" "$NGINX_CFG"; then
        log_ok "nginx: SS cert path correct"
    else
        ERRORS=$((ERRORS + 1))
        log_error "nginx: SS cert path incorrect (expected: ${expected_cert})"
        need_fix=true
    fi

    local expected_key="${ACME_SS_DIR}/${SELF_STEAL_DOMAIN}.key"
    if grep -qF "$expected_key" "$NGINX_CFG"; then
        log_ok "nginx: SS key path correct"
    else
        ERRORS=$((ERRORS + 1))
        log_error "nginx: SS key path incorrect (expected: ${expected_key})"
        need_fix=true
    fi

    if [[ "$need_fix" == true ]]; then
        return 1
    fi
    return 0
}

install_nginx() {
    log_fix "Installing nginx from official repo..."

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

    local codename
    codename=$(get_codename)

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
    log_fix "nginx installed"
    FIXED=$((FIXED + 1))
}

write_nginx_config() {
    local ss_cert_dir="${ACME_HOME}/${SELF_STEAL_DOMAIN}_ecc"

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

    log_format proxlog '\\\$status (\\\$proxy_protocol_addr) \\\$remote_user [\\\$time_local]';
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

        ssl_certificate ${ss_cert_dir}/fullchain.cer;
        ssl_certificate_key ${ss_cert_dir}/${SELF_STEAL_DOMAIN}.key;

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
}

fix_nginx() {
    log_step "Fixing nginx"

    if [[ "$DRY_RUN" == true ]]; then
        if ! command -v nginx &>/dev/null; then
            log_fix "[dry-run] Would install nginx from official repo"
        fi
        log_fix "[dry-run] Would rewrite ${NGINX_CFG} with correct domains and cert paths"
        return 0
    fi

    if ! command -v nginx &>/dev/null; then
        install_nginx
    fi

    write_nginx_config

    if nginx -t 2>/dev/null; then
        log_fix "nginx config rewritten and syntax OK"
        FIXED=$((FIXED + 1))
    else
        log_error "nginx config rewritten but syntax test FAILED — check manually"
    fi

    systemctl enable nginx 2>/dev/null || true
}

# ─── 4. Check haproxy ──────────────────────────────────────────────────────

check_haproxy() {
    log_step "Checking haproxy"

    if ! command -v haproxy &>/dev/null; then
        ERRORS=$((ERRORS + 1))
        log_error "haproxy is NOT installed"
        return 1
    fi
    log_ok "haproxy is installed"

    if ! systemctl is-active --quiet haproxy; then
        ERRORS=$((ERRORS + 1))
        log_error "haproxy is NOT running"
    else
        log_ok "haproxy is running"
    fi

    if [[ ! -f "$HAPROXY_CFG" ]]; then
        ERRORS=$((ERRORS + 1))
        log_error "haproxy config not found: ${HAPROXY_CFG}"
        return 1
    fi

    local need_fix=false

    if grep -qF "$DASH_DOMAIN" "$HAPROXY_CFG"; then
        log_ok "haproxy: dashboard domain present (${DASH_DOMAIN})"
    else
        ERRORS=$((ERRORS + 1))
        log_error "haproxy: dashboard domain NOT found in config"
        need_fix=true
    fi

    if grep -qF "127.0.0.1:${UVICORN_PORT}" "$HAPROXY_CFG"; then
        log_ok "haproxy: panel backend port correct (${UVICORN_PORT})"
    else
        ERRORS=$((ERRORS + 1))
        log_error "haproxy: panel backend port incorrect (expected ${UVICORN_PORT})"
        need_fix=true
    fi

    if grep -qF "127.0.0.1:${REALITY_PORT}" "$HAPROXY_CFG"; then
        log_ok "haproxy: reality backend port correct (${REALITY_PORT})"
    else
        ERRORS=$((ERRORS + 1))
        log_error "haproxy: reality backend port incorrect (expected ${REALITY_PORT})"
        need_fix=true
    fi

    if [[ "$need_fix" == true ]]; then
        return 1
    fi
    return 0
}

fix_haproxy() {
    log_step "Fixing haproxy"

    if [[ "$DRY_RUN" == true ]]; then
        if ! command -v haproxy &>/dev/null; then
            log_fix "[dry-run] Would install haproxy"
        fi
        log_fix "[dry-run] Would rewrite ${HAPROXY_CFG} with correct domains and ports"
        return 0
    fi

    if ! command -v haproxy &>/dev/null; then
        log_fix "Installing haproxy..."
        apt-get update -qq
        apt_install haproxy
        log_fix "haproxy installed"
        FIXED=$((FIXED + 1))
    fi

    local ss_cert_dir="${ACME_HOME}/${SELF_STEAL_DOMAIN}_ecc"

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

    ca-base ${ss_cert_dir}
    crt-base ${ss_cert_dir}

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

    log_fix "haproxy config rewritten"
    FIXED=$((FIXED + 1))
    systemctl enable haproxy 2>/dev/null || true
}

# ─── 5. Check docker-compose volumes ──────────────────────────────────────

check_compose_volumes() {
    log_step "Checking docker-compose volumes"

    if [[ ! -f "$MARZBAN_COMPOSE" ]]; then
        ERRORS=$((ERRORS + 1))
        log_error "docker-compose.yml NOT found at ${MARZBAN_COMPOSE}"
        return 1
    fi
    log_ok "docker-compose.yml exists"

    local volume_entry="${ACME_DASH_DIR}:${ACME_DASH_DIR}"
    if grep -qF "$volume_entry" "$MARZBAN_COMPOSE"; then
        log_ok "ACME volume present: ${volume_entry}"
    else
        ERRORS=$((ERRORS + 1))
        log_error "ACME volume MISSING: ${volume_entry}"
        return 1
    fi
    return 0
}

fix_compose_volumes() {
    log_step "Fixing docker-compose volumes"

    if [[ ! -f "$MARZBAN_COMPOSE" ]]; then
        log_error "docker-compose.yml not found — cannot fix"
        return 1
    fi

    local volume_entry="${ACME_DASH_DIR}:${ACME_DASH_DIR}"

    if grep -qF "$volume_entry" "$MARZBAN_COMPOSE"; then
        log_info "Volume already present"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_fix "[dry-run] Would add volume: ${volume_entry}"
        return 0
    fi

    if command -v yq &>/dev/null; then
        yq eval ".services.marzban.volumes += [\"${volume_entry}\"]" -i "$MARZBAN_COMPOSE"
    else
        sed -i "/volumes:/a\\      - ${volume_entry}" "$MARZBAN_COMPOSE"
    fi

    log_fix "Added volume: ${volume_entry}"
    FIXED=$((FIXED + 1))
}

# ─── 6. Restart services ──────────────────────────────────────────────────

restart_services() {
    log_step "Restarting services"

    if [[ "$DRY_RUN" == true ]]; then
        log_fix "[dry-run] Would restart nginx, haproxy, marzban"
        return 0
    fi

    if command -v nginx &>/dev/null && systemctl is-enabled --quiet nginx 2>/dev/null; then
        systemctl restart nginx && log_info "nginx restarted" || log_error "nginx restart failed"
    fi

    if command -v haproxy &>/dev/null && systemctl is-enabled --quiet haproxy 2>/dev/null; then
        systemctl restart haproxy && log_info "haproxy restarted" || log_error "haproxy restart failed"
    fi

    if command -v marzban &>/dev/null; then
        marzban restart -n && log_info "marzban restarted" || log_error "marzban restart failed"
    else
        log_warn "marzban CLI not found — restart manually"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    require_root
    auto_detect
    compute_paths

    log_step "Marzban Repair Tool"
    log_info "Dashboard domain : ${DASH_DOMAIN}"
    log_info "Self-steal domain: ${SELF_STEAL_DOMAIN}"
    log_info "Wildcard mode    : ${WILDCARD}"
    log_info "Dry run          : ${DRY_RUN}"
    if [[ "$WILDCARD" == true ]]; then
        log_info "Base domain      : ${BASE_DOMAIN}"
    fi
    log_info "ACME dash dir    : ${ACME_DASH_DIR}"
    log_info "ACME SS dir      : ${ACME_SS_DIR}"
    log_info "Cert key         : ${ACME_DM_KEY}"
    log_info "Cert fullchain   : ${ACME_DM_FC}"

    # ── Phase 1: Diagnose ──
    log_step "PHASE 1: DIAGNOSTICS"

    local certs_ok=true env_ok=true nginx_ok=true haproxy_ok=true compose_ok=true
    check_certificates       || certs_ok=false
    check_env                || env_ok=false
    check_nginx              || nginx_ok=false
    check_haproxy            || haproxy_ok=false
    check_compose_volumes    || compose_ok=false

    if [[ $ERRORS -eq 0 ]]; then
        log_step "ALL CHECKS PASSED"
        log_info "Nothing to fix. Installation looks correct."
        exit 0
    fi

    log_step "Found ${ERRORS} problem(s)"

    # ── Phase 2: Fix ──
    log_step "PHASE 2: REPAIRS"

    local need_restart=false

    if [[ "$certs_ok" == false ]]; then
        fix_certificates && need_restart=true
    fi

    if [[ "$nginx_ok" == false ]]; then
        fix_nginx && need_restart=true
    fi

    if [[ "$haproxy_ok" == false ]]; then
        fix_haproxy && need_restart=true
    fi

    if [[ "$env_ok" == false ]]; then
        fix_env && need_restart=true
    fi

    if [[ "$compose_ok" == false ]]; then
        fix_compose_volumes && need_restart=true
    fi

    # ── Phase 3: Restart ──
    if [[ "$need_restart" == true ]]; then
        restart_services
    fi

    # ── Summary ──
    log_step "SUMMARY"
    log_info "Problems found : ${ERRORS}"
    log_info "Fixes applied  : ${FIXED}"

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "Dry-run mode — no changes were made. Remove --dry-run to apply fixes."
    fi

    if [[ $FIXED -gt 0 || "$DRY_RUN" == true ]]; then
        exit 0
    elif [[ $ERRORS -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
