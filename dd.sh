#!/usr/bin/env bash
set -euo pipefail

DD_VERSION="2.7.0-20260907"

# ============================================================================
#  Marzban deploy helper — nginx + haproxy + acme.sh + sysctl tuning
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
# WARP is opt-in. It used to be installed unconditionally, which cost every
# panel ~172 packages and about a gigabyte: on noble the cloudflare-warp deb
# hard-Depends on the GTK/WebKit/Mesa/LLVM stack, so --no-install-recommends
# does not help. Panels never used it — their xray configs (xray_routes) have
# no outbound on 127.0.0.1:9091; only PROXY-role servers do, and those are
# provisioned separately. The install window it added is what let a provider
# reboot land in the middle of a deploy.
WITH_WARP=false
SKIP_CRON=false
LOG_FILE="/root/dd.log"
# Basic-auth credentials for the self-steal site; generated when absent.
HTPASSWD_FILE="/etc/nginx/.htpasswd"
SELF_STEAL_ROOT="/var/mysite"

# ─── Colored output ────────────────────────────────────────────────────────

log_info()  { printf '\e[92m[INFO]\e[0m  %s\n' "$*"; }
log_ok()    { printf '\e[92m[OK]\e[0m    %s\n' "$*"; }
log_warn()  { printf '\e[93m[WARN]\e[0m  %s\n' "$*"; }
log_error() { printf '\e[91m[ERROR]\e[0m %s\n' "$*" >&2; }
log_step()  { printf '\n\e[96m══ %s ══\e[0m\n' "$*"; }

# ─── File logging with timestamps ─────────────────────────────────────────

setup_logging() {
    : > "$LOG_FILE"
    exec 3>&1
    exec > >(
        tee >(
            sed -u $'s/\x1b\\[[0-9;]*m//g' |
            while IFS= read -r line; do
                printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
            done >> "$LOG_FILE"
        ) >&3
    ) 2>&1
}

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
  --with-warp                Install Cloudflare WARP (off by default: pulls the
                             whole GTK/WebKit stack and panels do not use it)
  --skip-warp                Accepted and ignored — WARP is already off
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
            --with-warp)      WITH_WARP=true;          shift   ;;
            --skip-warp)      WITH_WARP=false;         shift   ;;
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

# Deploys start seconds after the VM finishes booting, while cloud-init,
# apt-news, esm-cache and unattended-upgrades are still holding the dpkg lock.
# Without this, the first apt-get dies with "Could not get lock" and set -e
# aborts the whole deploy before nginx is ever installed.
wait_for_apt() {
    local deadline=$((SECONDS + 300)) announced=false
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
                /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ $SECONDS -ge $deadline ]]; then
            log_warn "apt lock still held after 300s — proceeding anyway"
            return 0
        fi
        if [[ "$announced" == false ]]; then
            announced=true
            log_info "Waiting for another apt/dpkg process to finish…"
        fi
        sleep 3
    done
}

apt_update() {
    wait_for_apt
    apt-get update -qq
}

apt_install() {
    wait_for_apt
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
    apt_update
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

# CA fallback chain, shared by both issue paths (standalone and DNS-01).
# An empty entry means "acme.sh default CA", set to Let's Encrypt in
# install_acme. Names must exist in CA_NAMES inside acme.sh.
ACME_CA_SERVERS=("" "zerossl")
ACME_CA_LABELS=("Let's Encrypt" "ZeroSSL")

# An unknown --server value is NOT rejected by acme.sh: _selectServer falls back
# to using the string itself as the ACME directory URL, so curl cannot resolve
# such a "host" and fails with error 6. acme.sh treats that as a temporary
# outage and retries — _initAPI 10 times every 10s, plus up to 20 nonce attempts
# with backoff up to 20s — so a dead CA costs tens of minutes per domain and
# floods the log with "Could not get nonce" instead of reporting the problem.
#
# This is exactly what happened with Buypass: the free service was shut down and
# the CA was removed from acme.sh, while this script kept asking for it. Skip any
# CA the installed acme.sh does not know, so dropping a CA upstream degrades into
# one clear warning instead of a silent stall.
acme_supports_ca() {
    local name="$1"
    [[ -z "$name" ]] && return 0

    local known
    known=$(sed -n '/^CA_NAMES=/,/^"/p' "${ACME_HOME}/acme.sh" 2>/dev/null || true)
    # Unparseable list — assume supported rather than skipping every fallback.
    [[ -z "$known" ]] && return 0

    grep -qiwF -- "$name" <<<"$known"
}

cert_is_valid() {
    local cert_file="$1"
    [[ -f "$cert_file" && -s "$cert_file" ]] || return 1
    # -checkend prints "Certificate will not expire" on stdout; only the exit
    # status matters here and the message just clutters the deploy log.
    openssl x509 -checkend 86400 -noout -in "$cert_file" >/dev/null 2>&1
}

issue_certificates() {
    log_step "Issuing SSL certificates"
    mkdir -p "$CERT_DIR"

    if [[ "$WILDCARD" == true ]]; then
        issue_wildcard_cert || true
    else
        issue_standalone_certs || true
    fi

    # Both certificates matter, and until now only the dashboard one was
    # checked. The self-steal cert goes straight into nginx.conf, so an empty
    # or missing fullchain.cer (acme.sh interrupted mid-write) produced a
    # config nginx refuses to load — "PEM_read_bio_X509_AUX() failed … no
    # start line" — while dd.sh reported success and moved on.
    local bad=()
    cert_is_valid "$ACME_DM_FC" || bad+=("dashboard ${DASH_DOMAIN}: ${ACME_DM_FC}")
    cert_is_valid "$ACME_SS_FC" || bad+=("self-steal ${SELF_STEAL_DOMAIN}: ${ACME_SS_FC}")

    if [[ ${#bad[@]} -gt 0 ]]; then
        log_error "No valid certificate after issuance attempt:"
        local entry
        for entry in "${bad[@]}"; do
            log_error "  ${entry}"
        done
        log_error "If rate-limited, wait until the retry time shown above."
        log_error "Check acme.sh log: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi

    log_info "Certificates OK:"
    log_info "  Dashboard : ${ACME_DM_FC}"
    log_info "  Self-steal: ${ACME_SS_FC}"
}

issue_cert_with_fallback() {
    local domain="$1"
    local acme_dir="${ACME_HOME}/${domain}_ecc"
    local cert_file="${acme_dir}/fullchain.cer"

    if cert_is_valid "$cert_file"; then
        log_info "Certificate for ${domain} already valid, skipping"
        return 0
    fi

    local prev_label=""

    for i in "${!ACME_CA_SERVERS[@]}"; do
        local server="${ACME_CA_SERVERS[$i]}"
        local label="${ACME_CA_LABELS[$i]}"
        local args=(--issue --standalone -d "$domain" --log)

        if ! acme_supports_ca "$server"; then
            log_warn "acme.sh does not know CA '${server}' — skipping ${label}"
            continue
        fi

        if [[ -n "$server" ]]; then
            log_warn "${prev_label} failed for ${domain} — trying ${label}"
            "$ACME_HOME/acme.sh" --register-account --server "$server" -m "$ACME_EMAIL" 2>&1 || true
            args+=(--server "$server" --force)
        else
            log_info "Issuing certificate for ${domain} via ${label}"
        fi

        local rc=0
        "$ACME_HOME/acme.sh" "${args[@]}" 2>&1 || rc=$?

        if [[ $rc -eq 0 ]] || cert_is_valid "$cert_file"; then
            [[ $rc -ne 0 ]] && log_warn "acme.sh exit ${rc}, but valid cert exists — OK"
            log_ok "Certificate for ${domain} issued via ${label}"
            return 0
        fi

        prev_label="$label"
    done

    log_error "All CAs failed for ${domain}. Check: ${ACME_HOME}/acme.sh.log"
    return 1
}

issue_standalone_certs() {
    issue_cert_with_fallback "$DASH_DOMAIN"
    issue_cert_with_fallback "$SELF_STEAL_DOMAIN"
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
        log_info "Wildcard cert already valid (not expired), skipping issue"
        log_info "Wildcard cert covers both ${DASH_DOMAIN} and ${SELF_STEAL_DOMAIN}"
        return 0
    fi

    local prev_label=""

    for i in "${!ACME_CA_SERVERS[@]}"; do
        local server="${ACME_CA_SERVERS[$i]}"
        local label="${ACME_CA_LABELS[$i]}"
        local args=(--issue --dns dns_cf -d "${base_domain}" -d "*.${base_domain}" --log)

        if ! acme_supports_ca "$server"; then
            log_warn "acme.sh does not know CA '${server}' — skipping ${label}"
            continue
        fi

        if [[ -n "$server" ]]; then
            log_warn "${prev_label} failed — trying ${label}"
            "$ACME_HOME/acme.sh" --register-account --server "$server" -m "$ACME_EMAIL" 2>&1 || true
            args+=(--server "$server" --force)
        else
            log_info "Trying ${label}..."
        fi

        local rc=0
        "$ACME_HOME/acme.sh" "${args[@]}" 2>&1 || rc=$?

        if [[ $rc -eq 0 ]] || cert_is_valid "$wild_cert"; then
            [[ $rc -ne 0 ]] && log_warn "acme.sh exit ${rc}, but valid cert exists — OK"
            log_info "Wildcard cert covers both ${DASH_DOMAIN} and ${SELF_STEAL_DOMAIN}"
            return 0
        fi

        prev_label="$label"
    done

    log_error "Failed to issue wildcard cert with all CAs."
    log_error "See log: ${ACME_HOME}/acme.sh.log"
    return 1
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

    apt_update
    apt_install nginx
}

# ─── Self-steal site content ──────────────────────────────────────────────
#
# nginx.conf below points the camouflage vhost at $SELF_STEAL_ROOT and guards
# it with $HTPASSWD_FILE, but nothing ever created either. nginx starts anyway
# (auth_basic_user_file is opened lazily, per request), so the breakage only
# showed up as 500s on the self-steal domain — exactly the domain that is
# supposed to look like an ordinary site to a censor.

prepare_self_steal_site() {
    log_step "Preparing self-steal site"

    mkdir -p "$SELF_STEAL_ROOT"
    if [[ ! -s "${SELF_STEAL_ROOT}/index.html" ]]; then
        cat > "${SELF_STEAL_ROOT}/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>It works</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:system-ui,sans-serif;margin:8vh auto;max-width:40rem;padding:0 1rem;color:#222}</style>
</head>
<body><h1>It works</h1><p>This site is under construction.</p></body>
</html>
HTMLEOF
        log_info "Created ${SELF_STEAL_ROOT}/index.html"
    else
        log_info "${SELF_STEAL_ROOT}/index.html already present, keeping it"
    fi
    chown -R www-data:www-data "$SELF_STEAL_ROOT" 2>/dev/null || true

    if [[ -s "$HTPASSWD_FILE" ]]; then
        log_info "${HTPASSWD_FILE} already present, keeping it"
        return 0
    fi

    # openssl is already a dependency of the acme.sh step, so generate the
    # hash with it rather than pulling in apache2-utils for htpasswd(1).
    local user="site" pass hash
    pass=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
    hash=$(openssl passwd -apr1 "$pass")
    printf '%s:%s\n' "$user" "$hash" > "$HTPASSWD_FILE"
    chmod 640 "$HTPASSWD_FILE"
    chown root:www-data "$HTPASSWD_FILE" 2>/dev/null || true
    log_info "Created ${HTPASSWD_FILE} (user: ${user}, password: ${pass})"
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
        listen 127.0.0.1:8001 ssl default_server proxy_protocol;
        http2 on;
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
        listen 127.0.0.1:8001 ssl proxy_protocol;
        http2 on;
        server_name ${SELF_STEAL_DOMAIN};

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_certificate ${ACME_SS_FC};
        ssl_certificate_key ${ACME_SS_KEY};

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";
        ssl_prefer_server_ciphers on;

        resolver 1.1.1.1 valid=60s;
        resolver_timeout 2s;

        auth_basic "Access restricted, enter login & password";
        auth_basic_user_file ${HTPASSWD_FILE};

        root ${SELF_STEAL_ROOT};
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
    # defaults above are mode http; without this haproxy warns on every start
    # that 'option httplog' is unusable here and silently falls back to tcplog.
    option tcplog
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

# WARP is an egress helper for PROXY-role servers, not for panels, so it is
# off unless --with-warp is passed. When it is requested, no step here may
# abort the deploy: the panel works fine without WARP, and this used to be the
# longest, most failure-prone part of the run. Every warp-cli call gets a
# timeout — the CLI blocks indefinitely when warp-svc is not up yet.
install_warp() {
    if [[ "$WITH_WARP" != true ]]; then
        log_info "Skipping WARP (not requested; pass --with-warp to install)"
        return 0
    fi

    log_step "Installing Cloudflare WARP"

    local codename
    codename=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-noble}}"))

    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; then
        log_warn "Cannot fetch Cloudflare signing key — skipping WARP"
        return 0
    fi

    cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

    if ! apt_update || ! apt_install cloudflare-warp; then
        log_warn "cloudflare-warp did not install — continuing without WARP"
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        apt_update || true
        return 0
    fi

    # warp-svc must be accepting connections before warp-cli says anything
    # useful; without the wait the first call fails and the rest cascade.
    systemctl enable --now warp-svc 2>/dev/null || true
    local deadline=$((SECONDS + 60))
    while ! timeout 5 warp-cli --accept-tos status >/dev/null 2>&1; do
        if [[ $SECONDS -ge $deadline ]]; then
            log_warn "warp-svc did not become ready in 60s — continuing without WARP"
            return 0
        fi
        sleep 2
    done

    timeout 60 warp-cli --accept-tos registration new >/dev/null 2>&1 \
        || log_warn "WARP registration already exists or failed, continuing..."
    timeout 30 warp-cli --accept-tos mode proxy      || log_warn "warp-cli mode proxy failed"
    timeout 30 warp-cli --accept-tos proxy port 9091 || log_warn "warp-cli proxy port failed"
    timeout 60 warp-cli --accept-tos connect         || log_warn "warp-cli connect failed"

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

    local volume_entry="${ACME_HOME}:${ACME_HOME}"
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

# Both configs are generated from templates above, so a broken one is a bug in
# this script rather than operator error — but it used to surface only as a
# dead service long after dd.sh reported success. Validate first and print the
# validator's own message, which names the offending directive and line.
restart_services() {
    log_step "Restarting services"

    local failed=()

    if nginx -t; then
        systemctl enable nginx >/dev/null 2>&1 || true
        if systemctl restart nginx; then
            log_ok "nginx restarted"
        else
            failed+=("nginx failed to start: $(systemctl is-active nginx)")
        fi
    else
        failed+=("nginx config is invalid (see 'nginx -t' output above)")
    fi

    if haproxy -c -f "$HAPROXY_CFG" >/dev/null; then
        systemctl enable haproxy >/dev/null 2>&1 || true
        if systemctl restart haproxy; then
            log_ok "haproxy restarted"
        else
            failed+=("haproxy failed to start: $(systemctl is-active haproxy)")
        fi
    else
        failed+=("haproxy config is invalid (see 'haproxy -c' output above)")
    fi

    if command -v marzban &>/dev/null; then
        if marzban restart -n; then
            log_ok "marzban restarted"
        else
            failed+=("marzban restart failed")
        fi
    else
        failed+=("marzban CLI not found — panel is not installed")
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Services did not come up cleanly:"
        local entry
        for entry in "${failed[@]}"; do
            log_error "  ${entry}"
        done
        return 1
    fi
}

# ─── Post-deploy verification ──────────────────────────────────────────────
#
# The caller (mass_installer) only sees dd.sh's exit code, so "finished" has to
# mean "the node can actually serve traffic". Checked here rather than trusted:
# haproxy owns :443, nginx answers the self-steal vhost, marzban listens on the
# uvicorn port and both certificates parse.

port_is_open() {
    ss -tln 2>/dev/null | grep -qE "[:.]${1}\s"
}

# marzban restart returns as soon as compose is done, but uvicorn only binds
# after mariadb passes its health check and xray starts — about 20s on a small
# VM. Polling instead of a fixed sleep keeps a healthy node from being reported
# as broken while still failing fast when it really is.
wait_for_ports() {
    local deadline=$((SECONDS + 120))
    while :; do
        if port_is_open 443 && port_is_open 8001 && port_is_open "$UVICORN_PORT"; then
            return 0
        fi
        [[ $SECONDS -ge $deadline ]] && return 1
        sleep 3
    done
}

verify_deployment() {
    log_step "Verifying deployment"

    local problems=()

    wait_for_ports || true

    port_is_open 443 \
        || problems+=("nothing is listening on :443 (haproxy down?)")
    port_is_open "$UVICORN_PORT" \
        || problems+=("nothing is listening on :${UVICORN_PORT} (marzban down?)")
    port_is_open 8001 \
        || problems+=("nothing is listening on :8001 (nginx self-steal vhost down?)")

    local svc
    for svc in nginx haproxy; do
        systemctl is-active --quiet "$svc" || problems+=("${svc} is not active")
    done

    cert_is_valid "$ACME_DM_FC" || problems+=("dashboard certificate invalid: ${ACME_DM_FC}")
    cert_is_valid "$ACME_SS_FC" || problems+=("self-steal certificate invalid: ${ACME_SS_FC}")

    [[ -s "$HTPASSWD_FILE" ]] || problems+=("${HTPASSWD_FILE} missing — self-steal site returns 500")
    [[ -s "${SELF_STEAL_ROOT}/index.html" ]] || problems+=("${SELF_STEAL_ROOT}/index.html missing")

    grep -qE "^\s*UVICORN_SSL_CERTFILE\s*=" "$MARZBAN_ENV" 2>/dev/null \
        || problems+=("UVICORN_SSL_CERTFILE not set in ${MARZBAN_ENV}")

    if [[ ${#problems[@]} -gt 0 ]]; then
        log_error "Deployment finished with problems:"
        local entry
        for entry in "${problems[@]}"; do
            log_error "  ${entry}"
        done
        return 1
    fi

    log_ok "All checks passed: haproxy :443, nginx :8001, marzban :${UVICORN_PORT}, certs valid"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    require_root
    setup_logging
    trap 'sleep 0.5' EXIT

    log_step "Starting deployment (dd.sh v${DD_VERSION})"
    log_info "Dashboard domain : ${DASH_DOMAIN}"
    log_info "Self-steal domain: ${SELF_STEAL_DOMAIN}"
    log_info "Wildcard mode    : ${WILDCARD}"
    log_info "WARP             : $(if $WITH_WARP; then echo 'install'; else echo 'skip'; fi)"

    install_base_packages
    install_acme
    issue_certificates
    install_nginx
    prepare_self_steal_site
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
    verify_deployment

    log_step "Deployment complete"
    log_info "Dashboard : https://${DASH_DOMAIN}"
    log_info "Certs     : ${CERT_DIR}/"
    log_info "Nginx cfg : ${NGINX_CFG}"
    log_info "HAProxy   : ${HAPROXY_CFG}"
    log_info "Install log: ${LOG_FILE}"
}

main "$@"
