#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="2.5-manager-upgrade-api"
AZURIOM_VERSION="1.2.12"
INSTALL_DIR="/opt/azuriom"
AZURIOM_URL="https://github.com/Azuriom/Azuriom/releases/download/v${AZURIOM_VERSION}/Azuriom-${AZURIOM_VERSION}.zip"
MANAGER_API="https://api.github.com/repos/GamingHubProject/Manager/releases/latest"
CREDENTIAL_FILE="${HOME}/.azuriom-install-credentials"
CADDY_IMAGE="caddy:2.11.4-alpine"
PROXY_COMPOSE_FILE="docker-compose.proxy.yml"
CADDY_CONFIG_DIR="docker/caddy"
DOMAIN_CONFIG_FILE=".azuriom-domain"

STEP=0
TOTAL_STEPS=8

step() {
    STEP=$((STEP + 1))
    printf '\n\033[1;36m[%s/%s] %s\033[0m\n' "$STEP" "$TOTAL_STEPS" "$1"
}

info() {
    printf '\033[0;32m%s\033[0m\n' "$1"
}

warn() {
    printf '\033[1;33m%s\033[0m\n' "$1"
}

fail() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2
    exit 1
}

ask_default() {
    local prompt="$1"
    local default_value="$2"
    local answer
    read -r -p "${prompt} [${default_value}]: " answer
    printf '%s' "${answer:-$default_value}"
}

valid_identifier() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local temporary

    temporary="$(mktemp)"

    if [[ -f "$file" ]]; then
        awk -v key="$key" -v value="$value" '
            BEGIN { replaced = 0 }
            index($0, key "=") == 1 {
                if (!replaced) {
                    print key "=" value
                    replaced = 1
                }
                next
            }
            { print }
            END {
                if (!replaced) {
                    print key "=" value
                }
            }
        ' "$file" > "$temporary"
    else
        printf '%s=%s\n' "$key" "$value" > "$temporary"
    fi

    mv "$temporary" "$file"
}

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    command_exists sudo || fail "sudo is required."
    SUDO=(sudo)
fi

clear
printf '\033[1;35mGaming Hub Manager - Azuriom Installer\033[0m\n'
printf 'Installer version: %s\n' "$INSTALLER_VERSION"
printf 'Official Azuriom %s + PostgreSQL + latest stable Gaming Hub Manager\n' "$AZURIOM_VERSION"
printf '\nAzuriom is downloaded unchanged from its official GitHub release.\n'
printf 'Gaming Hub Manager is added only as a separate plugin.\n\n'

find_docker_command() {
    if ! command_exists docker; then
        return 1
    fi

    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
        return 0
    fi

    if "${SUDO[@]}" docker info >/dev/null 2>&1; then
        DOCKER=("${SUDO[@]}" docker)
        return 0
    fi

    return 1
}

azuriom_resources_exist() {
    if [[ -e "$INSTALL_DIR" ]]; then
        return 0
    fi

    if ! find_docker_command; then
        return 1
    fi

    local container
    for container in azuriom_nginx azuriom_app azuriom_db azuriom_caddy; do
        if "${DOCKER[@]}" container inspect "$container" >/dev/null 2>&1; then
            return 0
        fi
    done

    if "${DOCKER[@]}" volume inspect azuriom_db_data >/dev/null 2>&1; then
        return 0
    fi

    if "${DOCKER[@]}" network inspect azuriom_azuriom >/dev/null 2>&1; then
        return 0
    fi

    return 1
}


configure_domain_https() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    find_docker_command || fail "Docker is required to configure the reverse proxy."

    printf '\n\033[1;35mDomain, HTTPS, and reverse proxy\033[0m\n'
    printf 'This uses the official Caddy container as the HTTPS reverse proxy.\n'
    printf 'Before certificates can be issued:\n'
    printf '  - the domain must point to this server;\n'
    printf '  - public TCP ports 80 and 443 must reach this machine.\n\n'

    local current_domain=""
    if [[ -f "$INSTALL_DIR/$DOMAIN_CONFIG_FILE" ]]; then
        current_domain="$(awk -F= '$1 == "DOMAIN" { print $2; exit }' "$INSTALL_DIR/$DOMAIN_CONFIG_FILE")"
    fi

    local default_domain="${current_domain:-example.com}"
    local domain
    while true; do
        domain="$(ask_default "Domain without https:// or a path" "$default_domain")"
        domain="${domain,,}"

        if valid_domain "$domain"; then
            break
        fi

        warn "Enter a normal hostname such as hub.example.com. Do not include https://, a port, wildcard, or path."
    done

    local current_email=""
    if [[ -f "$INSTALL_DIR/$DOMAIN_CONFIG_FILE" ]]; then
        current_email="$(awk -F= '$1 == "EMAIL" { print $2; exit }' "$INSTALL_DIR/$DOMAIN_CONFIG_FILE")"
    fi

    local email
    while true; do
        read -r -p "Certificate contact email${current_email:+ [${current_email}]} (optional): " email
        email="${email:-$current_email}"

        if [[ -z "$email" || "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            break
        fi

        warn "Enter a valid email address or leave it empty."
    done

    if command_exists getent; then
        local resolved
        resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ', ' - || true)"
        if [[ -n "$resolved" ]]; then
            info "DNS currently resolves ${domain} to: ${resolved}"
        else
            warn "The domain does not currently resolve on this machine. Caddy cannot obtain a public certificate until DNS is correct."
        fi
    fi

    local existing_caddy="no"
    if "${DOCKER[@]}" container inspect azuriom_caddy >/dev/null 2>&1; then
        existing_caddy="yes"
    fi

    if [[ "$existing_caddy" == "no" ]] && command_exists ss; then
        local port
        for port in 80 443; do
            if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
                fail "Host port ${port} is already in use. Stop the existing web proxy or configure Azuriom through that proxy instead."
            fi
        done
    fi

    local proceed
    read -r -p "Create/update the managed HTTPS reverse proxy now? [Y/n]: " proceed
    proceed="${proceed:-Y}"
    [[ "$proceed" =~ ^[Yy]$ ]] || { info "Cancelled. Nothing was changed."; return 0; }

    cd "$INSTALL_DIR"

    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp .env ".env.before-domain-${stamp}"
    if [[ -f "$CADDY_CONFIG_DIR/Caddyfile" ]]; then
        cp "$CADDY_CONFIG_DIR/Caddyfile" "$CADDY_CONFIG_DIR/Caddyfile.before-${stamp}"
    fi

    mkdir -p "$CADDY_CONFIG_DIR"

    if [[ -n "$email" ]]; then
        cat > "$CADDY_CONFIG_DIR/Caddyfile" <<CADDY
{
    email ${email}
}

${domain} {
    encode zstd gzip
    reverse_proxy nginx:80
}
CADDY
    else
        cat > "$CADDY_CONFIG_DIR/Caddyfile" <<CADDY
${domain} {
    encode zstd gzip
    reverse_proxy nginx:80
}
CADDY
    fi

    cat > "$PROXY_COMPOSE_FILE" <<COMPOSE
services:
  caddy:
    image: ${CADDY_IMAGE}
    container_name: azuriom_caddy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./${CADDY_CONFIG_DIR}:/etc/caddy:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - azuriom
    depends_on:
      - nginx

volumes:
  caddy_data:
  caddy_config:
COMPOSE

    set_env_value .env APP_URL "https://${domain}"
    set_env_value .env COMPOSE_FILE "docker-compose.yml:${PROXY_COMPOSE_FILE}"
    chmod 600 .env

    cat > "$DOMAIN_CONFIG_FILE" <<DOMAINCONF
DOMAIN=${domain}
EMAIL=${email}
PROXY=caddy
DOMAINCONF
    chmod 600 "$DOMAIN_CONFIG_FILE"

    if [[ -f "$CREDENTIAL_FILE" ]]; then
        set_env_value "$CREDENTIAL_FILE" APP_URL "https://${domain}"
        chmod 600 "$CREDENTIAL_FILE"
    fi

    "${DOCKER[@]}" compose config >/dev/null || fail "The combined Azuriom and Caddy Compose configuration is invalid."
    "${DOCKER[@]}" compose pull caddy
    "${DOCKER[@]}" compose run --rm --no-deps caddy \
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    "${DOCKER[@]}" compose up -d --force-recreate caddy

    "${DOCKER[@]}" compose exec -T app php artisan optimize:clear >/dev/null 2>&1 \
        || warn "Azuriom cache cleanup could not run yet. This is normal before browser setup is complete."

    info "Managed HTTPS reverse proxy configured for https://${domain}"
    printf '\nCaddy will request and renew the TLS certificate automatically once DNS and ports 80/443 are reachable.\n'
    printf 'Check its status with:\n'
    printf '  cd %s && docker compose logs --tail=100 caddy\n' "$INSTALL_DIR"
}

create_admin_login() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    find_docker_command || fail "Docker is required to create the Azuriom administrator."

    cd "$INSTALL_DIR"

    local app_key
    app_key="$(awk -F= '$1 == "APP_KEY" { sub(/^APP_KEY=/, ""); print; exit }' .env)"
    if [[ -z "$app_key" ]]; then
        fail "Azuriom browser setup is not finished yet. Finish the browser installer first, then run this menu option again."
    fi

    if ! "${DOCKER[@]}" compose exec -T app php artisan --version >/dev/null 2>&1; then
        fail "The Azuriom application container is not ready. Start it first with: cd ${INSTALL_DIR} && docker compose up -d"
    fi

    printf '\n\033[1;35mCreate Azuriom administrator login\033[0m\n'
    printf 'This uses Azuriom\047s built-in user:create --admin command.\n'
    printf 'It creates a verified administrator account and can also be used to recover admin access.\n\n'

    local proceed
    read -r -p "Create a new administrator account now? [Y/n]: " proceed
    proceed="${proceed:-Y}"
    [[ "$proceed" =~ ^[Yy]$ ]] || { info "Cancelled. Nothing was changed."; return 0; }

    "${DOCKER[@]}" compose exec app php artisan user:create --admin

    info "Administrator account created."
    printf 'You can now sign in at:\n'

    local app_url
    app_url="$(awk -F= '$1 == "APP_URL" { sub(/^APP_URL=/, ""); print; exit }' .env)"
    if [[ -n "$app_url" ]]; then
        printf '  %s/login\n' "${app_url%/}"
    else
        printf '  /login\n'
    fi
}


upgrade_manager() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    local plugin_dir="$INSTALL_DIR/plugins/gaming-hub-manager"
    local plugin_manifest="$plugin_dir/plugin.json"
    [[ -f "$plugin_manifest" ]] || fail "Gaming Hub Manager is not installed at ${plugin_dir}."

    find_docker_command || fail "Docker is required to upgrade Gaming Hub Manager."
    command_exists curl || fail "curl is required."
    command_exists unzip || fail "unzip is required."
    command_exists sha256sum || fail "sha256sum is required."
    command_exists stat || fail "stat is required."

    local python_bin=""
    if command_exists python3; then
        python_bin="python3"
    elif command_exists python; then
        python_bin="python"
    else
        fail "Python 3 is required."
    fi

    cd "$INSTALL_DIR"

    local app_key
    app_key="$(awk -F= '$1 == "APP_KEY" { sub(/^APP_KEY=/, ""); print; exit }' .env)"
    [[ -n "$app_key" ]] || fail "Azuriom browser setup is not finished yet. Finish it before upgrading Gaming Hub Manager."

    if ! "${DOCKER[@]}" compose exec -T app php artisan --version >/dev/null 2>&1; then
        fail "The Azuriom application container is not ready. Start it first with: cd ${INSTALL_DIR} && docker compose up -d"
    fi

    local current_version
    current_version="$("$python_bin" - "$plugin_manifest" <<'PY_CURRENT'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if data.get("id") != "gaming-hub-manager":
    raise SystemExit("unexpected plugin id")
print(data.get("version", "unknown"))
PY_CURRENT
)" || fail "Could not read the installed Gaming Hub Manager version."

    printf '\n\033[1;35mUpgrade Gaming Hub Manager\033[0m\n'
    printf 'Installed version: %s\n' "$current_version"
    printf 'Checking the official GamingHubProject/Manager stable release...\n'

    local upgrade_tmp
    upgrade_tmp="$(mktemp -d)"

    if ! curl -fsSL --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: Gaming-Hub-Manager-Installer' \
        -H 'Cache-Control: no-cache, no-store' \
        -H 'Pragma: no-cache' \
        "${MANAGER_API}?nocache=$(date +%s)" \
        -o "$upgrade_tmp/release.json"; then
        rm -rf "$upgrade_tmp"
        fail "Could not query the latest Gaming Hub Manager release."
    fi

    local release_info
    release_info="$("$python_bin" - "$upgrade_tmp/release.json" <<'PY_RELEASE'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest release is not stable")

assets = [
    a for a in release.get("assets", [])
    if a.get("state") == "uploaded"
    and re.fullmatch(r"gaming-hub-manager-v[^/]+\.zip", a.get("name", ""))
]
if len(assets) != 1:
    raise SystemExit("expected exactly one Manager ZIP asset")

asset = assets[0]
print("\t".join([
    str(release.get("tag_name", "")),
    str(asset.get("url", "")),
    str(asset.get("browser_download_url", "")),
    str(asset.get("digest") or ""),
    str(asset.get("size") or ""),
    str(asset.get("id") or ""),
]))
PY_RELEASE
)" || {
        rm -rf "$upgrade_tmp"
        fail "Could not resolve exactly one stable gaming-hub-manager-v*.zip release asset."
    }

    local latest_tag asset_api_url browser_url asset_digest asset_size asset_id
    IFS=$'\t' read -r latest_tag asset_api_url browser_url asset_digest asset_size asset_id <<< "$release_info"

    [[ -n "$latest_tag" && -n "$asset_api_url" && -n "$asset_id" ]] || {
        rm -rf "$upgrade_tmp"
        fail "The latest Manager release metadata is incomplete."
    }

    printf 'Release:           %s\n' "$latest_tag"
    printf 'Release asset ID:  %s\n' "$asset_id"

    # Download by immutable GitHub release-asset API ID instead of the browser filename URL.
    # This prevents a recently replaced same-name release asset from being served from an
    # older browser/CDN cache while the API already advertises the new digest.
    if ! curl -fL --retry 3 --retry-delay 2 \
        -H 'Accept: application/octet-stream' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: Gaming-Hub-Manager-Installer' \
        -H 'Cache-Control: no-cache, no-store' \
        -H 'Pragma: no-cache' \
        "$asset_api_url" \
        -o "$upgrade_tmp/manager.zip"; then
        rm -rf "$upgrade_tmp"
        fail "Could not download ${latest_tag} from GitHub release asset ${asset_id}."
    fi

    local actual_size
    actual_size="$(stat -c '%s' "$upgrade_tmp/manager.zip")"
    if [[ "$asset_size" =~ ^[0-9]+$ ]] && [[ "$actual_size" != "$asset_size" ]]; then
        rm -rf "$upgrade_tmp"
        fail "Manager release size verification failed (expected ${asset_size} bytes, received ${actual_size})."
    fi
    info "Release size verified (${actual_size} bytes)."

    if [[ "$asset_digest" == sha256:* ]]; then
        local expected_sha actual_sha
        expected_sha="${asset_digest#sha256:}"
        actual_sha="$(sha256sum "$upgrade_tmp/manager.zip" | awk '{print $1}')"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            rm -rf "$upgrade_tmp"
            fail "Manager release SHA-256 verification failed (expected ${expected_sha}, received ${actual_sha})."
        fi
        info "Release SHA-256 verified."
    else
        warn "GitHub did not provide a SHA-256 digest for this release asset."
    fi

    mkdir -p "$upgrade_tmp/extracted"
    if ! unzip -q "$upgrade_tmp/manager.zip" -d "$upgrade_tmp/extracted"; then
        rm -rf "$upgrade_tmp"
        fail "Could not extract the Manager release ZIP."
    fi

    local new_plugin_dir="$upgrade_tmp/extracted/gaming-hub-manager"
    local new_manifest="$new_plugin_dir/plugin.json"
    [[ -f "$new_manifest" ]] || {
        rm -rf "$upgrade_tmp"
        fail "Manager ZIP does not contain gaming-hub-manager/plugin.json."
    }

    local new_manifest_info latest_version new_plugin_id
    new_manifest_info="$("$python_bin" - "$new_manifest" <<'PY_MANIFEST'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print("\t".join([str(data.get("id", "")), str(data.get("version", ""))]))
PY_MANIFEST
)" || {
        rm -rf "$upgrade_tmp"
        fail "Could not read the downloaded Manager plugin manifest."
    }

    IFS=$'\t' read -r new_plugin_id latest_version <<< "$new_manifest_info"

    [[ "$new_plugin_id" == "gaming-hub-manager" ]] || {
        rm -rf "$upgrade_tmp"
        fail "Downloaded ZIP has an unexpected plugin id: ${new_plugin_id:-missing}."
    }
    [[ -n "$latest_version" ]] || {
        rm -rf "$upgrade_tmp"
        fail "Downloaded Manager manifest has no version."
    }
    [[ "$latest_tag" == "v${latest_version}" || "$latest_tag" == "$latest_version" ]] || {
        rm -rf "$upgrade_tmp"
        fail "Release tag ${latest_tag} does not match plugin version ${latest_version}."
    }

    printf 'Latest stable:    %s\n' "$latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        info "Gaming Hub Manager is already up to date."
        rm -rf "$upgrade_tmp"
        return 0
    fi

    if command_exists sort && [[ "$current_version" != "unknown" ]]; then
        local highest_version
        highest_version="$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -n 1)"
        if [[ "$highest_version" == "$current_version" ]]; then
            warn "The installed Manager (${current_version}) is newer than the latest stable release (${latest_version}). No downgrade was performed."
            rm -rf "$upgrade_tmp"
            return 0
        fi
    fi

    printf '\nThe upgrade will:\n'
    printf '  - back up the PostgreSQL database;\n'
    printf '  - back up plugins/gaming-hub-manager;\n'
    printf '  - back up storage/app/gaming-hub-manager when present;\n'
    printf '  - replace only Gaming Hub Manager;\n'
    printf '  - preserve whether the Manager plugin is currently enabled.\n\n'

    local proceed
    read -r -p "Upgrade Gaming Hub Manager ${current_version} -> ${latest_version}? [Y/n]: " proceed
    proceed="${proceed:-Y}"
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        info "Cancelled. Nothing was changed."
        rm -rf "$upgrade_tmp"
        return 0
    fi

    local enabled_before="no"
    if [[ -f "$INSTALL_DIR/plugins/plugins.json" ]]; then
        if "$python_bin" - "$INSTALL_DIR/plugins/plugins.json" <<'PY_ENABLED' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    enabled = json.load(f)
if isinstance(enabled, dict):
    present = "gaming-hub-manager" in enabled
else:
    present = "gaming-hub-manager" in enabled
raise SystemExit(0 if present else 1)
PY_ENABLED
        then
            enabled_before="yes"
        fi
    fi

    local stamp backup_dir storage_dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$INSTALL_DIR/storage/app/gaming-hub-manager-upgrade-backups/${stamp}-from-${current_version}-to-${latest_version}"
    storage_dir="$INSTALL_DIR/storage/app/gaming-hub-manager"

    "${SUDO[@]}" mkdir -p "$backup_dir"
    "${SUDO[@]}" cp -a "$plugin_dir" "$backup_dir/plugin"

    if [[ -d "$storage_dir" ]]; then
        "${SUDO[@]}" cp -a "$storage_dir" "$backup_dir/storage"
    fi

    if ! "${DOCKER[@]}" compose exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
        | "${SUDO[@]}" tee "$backup_dir/database.sql" >/dev/null; then
        "${SUDO[@]}" rm -rf "$backup_dir"
        rm -rf "$upgrade_tmp"
        fail "PostgreSQL backup failed. Manager was not changed."
    fi

    info "Upgrade backup created at ${backup_dir}"

    if [[ "$enabled_before" == "yes" ]]; then
        if ! "${DOCKER[@]}" compose exec -T app php artisan plugin:disable gaming-hub-manager; then
            rm -rf "$upgrade_tmp"
            fail "Could not disable Gaming Hub Manager. The backup is preserved at ${backup_dir}."
        fi
    fi

    local replacement_ok="yes"
    "${SUDO[@]}" rm -rf "$plugin_dir" || replacement_ok="no"
    if [[ "$replacement_ok" == "yes" ]]; then
        "${SUDO[@]}" cp -a "$new_plugin_dir" "$plugin_dir" || replacement_ok="no"
    fi

    if [[ "$replacement_ok" == "yes" ]]; then
        local www_uid
        www_uid="$("${DOCKER[@]}" compose exec -T app sh -c 'id -u www-data' 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
        if [[ "$www_uid" =~ ^[0-9]+$ ]] && command_exists setfacl; then
            "${SUDO[@]}" setfacl -R -m "u:${www_uid}:rwX" "$plugin_dir" || replacement_ok="no"
        fi
    fi

    if [[ "$replacement_ok" != "yes" ]]; then
        warn "Manager file replacement failed. Restoring the previous plugin files."
        "${SUDO[@]}" rm -rf "$plugin_dir"
        "${SUDO[@]}" cp -a "$backup_dir/plugin" "$plugin_dir"
        if [[ "$enabled_before" == "yes" ]]; then
            "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager >/dev/null 2>&1 || true
        fi
        rm -rf "$upgrade_tmp"
        fail "Upgrade failed and the previous Manager files were restored."
    fi

    if [[ "$enabled_before" == "yes" ]]; then
        if ! "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager; then
            warn "The new Manager could not be enabled. Restoring the previous version."
            "${SUDO[@]}" rm -rf "$plugin_dir"
            "${SUDO[@]}" cp -a "$backup_dir/plugin" "$plugin_dir"
            "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager >/dev/null 2>&1 || true
            "${DOCKER[@]}" compose exec -T app php artisan optimize:clear >/dev/null 2>&1 || true
            "${DOCKER[@]}" compose exec -T app php artisan plugin:cache >/dev/null 2>&1 || true
            rm -rf "$upgrade_tmp"
            fail "Upgrade failed during plugin enable; the previous Manager files were restored. Database and storage backups remain at ${backup_dir}."
        fi
    fi

    if ! "${DOCKER[@]}" compose exec -T app php artisan optimize:clear; then
        warn "Application cache cleanup failed. The Manager files were upgraded, but run 'php artisan optimize:clear' manually."
    fi
    if ! "${DOCKER[@]}" compose exec -T app php artisan plugin:cache; then
        warn "Plugin cache rebuild failed. Run 'php artisan plugin:cache' manually."
    fi

    local installed_after
    installed_after="$("$python_bin" - "$plugin_manifest" <<'PY_AFTER'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("version", "unknown"))
PY_AFTER
)"
    [[ "$installed_after" == "$latest_version" ]] || {
        rm -rf "$upgrade_tmp"
        fail "Upgrade verification failed: expected ${latest_version}, found ${installed_after}. Backup: ${backup_dir}"
    }

    rm -rf "$upgrade_tmp"
    info "Gaming Hub Manager upgraded successfully: ${current_version} -> ${latest_version}"
    printf 'Backup retained at:\n  %s\n' "$backup_dir"
    if [[ "$enabled_before" == "yes" ]]; then
        printf 'Manager was enabled before the upgrade and is enabled again.\n'
    else
        printf 'Manager was disabled before the upgrade and remains disabled.\n'
    fi
}

remove_existing_installation() {
    local action_name="$1"

    warn "This will permanently delete:"
    printf '  - %s\n' "$INSTALL_DIR"
    printf '  - Azuriom containers and network\n'
    printf '  - PostgreSQL volume azuriom_db_data\n'
    printf '  - Azuriom users, settings, uploads and plugin data\n'
    printf '  - %s\n\n' "$CREDENTIAL_FILE"

    local confirmation
    read -r -p "Type ${action_name} to continue: " confirmation

    if [[ "$confirmation" != "$action_name" ]]; then
        info "Cancelled. Nothing was deleted."
        exit 0
    fi

    if find_docker_command; then
        if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            (
                cd "$INSTALL_DIR"
                "${DOCKER[@]}" compose down -v --remove-orphans
            ) || warn "Compose cleanup was incomplete; trying direct Docker cleanup."
        fi

        "${DOCKER[@]}" rm -f azuriom_nginx azuriom_app azuriom_db azuriom_caddy >/dev/null 2>&1 || true
        "${DOCKER[@]}" volume rm azuriom_db_data azuriom_caddy_data azuriom_caddy_config >/dev/null 2>&1 || true
        "${DOCKER[@]}" network rm azuriom_azuriom >/dev/null 2>&1 || true
    else
        warn "Docker is unavailable. Removing files only; Docker resources may need manual cleanup."
    fi

    "${SUDO[@]}" rm -rf "$INSTALL_DIR"
    rm -f "$CREDENTIAL_FILE"
    info "Existing Azuriom installation removed."
}

select_action() {
    printf '\033[1mChoose an action:\033[0m\n'
    printf '  1) Install a new Azuriom instance\n'
    printf '  2) Reinstall / clean reset (deletes existing data)\n'
    printf '  3) Configure or change domain, HTTPS, and reverse proxy\n'
    printf '  4) Create first/admin login\n'
    printf '  5) Upgrade Gaming Hub Manager\n'
    printf '  6) Uninstall completely (deletes existing data)\n'
    printf '  7) Exit\n\n'

    local choice
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) ACTION="install" ;;
        2) ACTION="reinstall" ;;
        3) ACTION="configure_https" ;;
        4) ACTION="create_admin" ;;
        5) ACTION="upgrade_manager" ;;
        6) ACTION="uninstall" ;;
        7) ACTION="exit" ;;
        *) fail "Invalid selection. Run the installer again." ;;
    esac
}

select_action

if [[ "$ACTION" == "exit" ]]; then
    info "Nothing changed."
    exit 0
fi

if [[ "$ACTION" == "configure_https" ]]; then
    azuriom_resources_exist || fail "No existing Azuriom installation was found. Install Azuriom first."
    configure_domain_https
    exit 0
fi

if [[ "$ACTION" == "create_admin" ]]; then
    azuriom_resources_exist || fail "No existing Azuriom installation was found. Install Azuriom first."
    create_admin_login
    exit 0
fi

if [[ "$ACTION" == "upgrade_manager" ]]; then
    azuriom_resources_exist || fail "No existing Azuriom installation was found. Install Azuriom first."
    upgrade_manager
    exit 0
fi

if [[ "$ACTION" == "install" ]] && azuriom_resources_exist; then
    warn "An existing installation was found at ${INSTALL_DIR}."
    printf '\n  1) Reinstall it from scratch\n'
    printf '  2) Uninstall it completely\n'
    printf '  3) Exit without changes\n\n'

    read -r -p "Selection [3]: " existing_choice
    existing_choice="${existing_choice:-3}"

    case "$existing_choice" in
        1) ACTION="reinstall" ;;
        2) ACTION="uninstall" ;;
        3) info "Nothing changed."; exit 0 ;;
        *) fail "Invalid selection. Run the installer again." ;;
    esac
fi

if [[ "$ACTION" == "reinstall" ]]; then
    if azuriom_resources_exist; then
        remove_existing_installation "RESET"
    else
        info "No previous installation was found; continuing with a fresh install."
    fi
elif [[ "$ACTION" == "uninstall" ]]; then
    if ! azuriom_resources_exist; then
        info "No Azuriom installation was found. Nothing to uninstall."
        exit 0
    fi

    remove_existing_installation "UNINSTALL"
    printf '\nAzuriom and Gaming Hub Manager were completely uninstalled.\n'
    exit 0
fi

# -----------------------------------------------------------------------------
# Step 1: Detect system and install prerequisites
# -----------------------------------------------------------------------------
step "Checking system requirements"

if command_exists pacman; then
    DISTRO_FAMILY="arch"
    PYTHON_BIN="python"
    info "Detected Arch/CachyOS-style system."

    "${SUDO[@]}" pacman -Sy --needed --noconfirm \
        ca-certificates curl unzip python acl openssl

elif command_exists apt-get; then
    DISTRO_FAMILY="ubuntu"
    PYTHON_BIN="python3"
    info "Detected Ubuntu/Debian-style system."

    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y \
        ca-certificates curl unzip python3 acl openssl
else
    fail "This installer currently supports Arch/CachyOS and Ubuntu/Debian."
fi

if ! command_exists docker; then
    warn "Docker is not installed."
    read -r -p "Install Docker and Docker Compose now? [Y/n]: " INSTALL_DOCKER
    INSTALL_DOCKER="${INSTALL_DOCKER:-Y}"

    if [[ ! "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
        fail "Docker is required."
    fi

    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        "${SUDO[@]}" pacman -S --needed --noconfirm \
            docker docker-compose docker-buildx
    else
        "${SUDO[@]}" apt-get install -y docker.io docker-compose-v2
    fi
fi

if ! docker compose version >/dev/null 2>&1 && ! "${SUDO[@]}" docker compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 is missing. Installing it."
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        "${SUDO[@]}" pacman -S --needed --noconfirm docker-compose
    else
        "${SUDO[@]}" apt-get install -y docker-compose-v2
    fi
fi

"${SUDO[@]}" systemctl enable --now docker

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif "${SUDO[@]}" docker info >/dev/null 2>&1; then
    DOCKER=("${SUDO[@]}" docker)
else
    fail "Docker is installed, but the Docker daemon is unavailable."
fi

info "Docker is ready."

# -----------------------------------------------------------------------------
# Step 2: Ask configuration
# -----------------------------------------------------------------------------
step "Installation settings"

while true; do
    APP_PORT="$(ask_default "Public HTTP port" "8086")"
    if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]] || (( APP_PORT < 1 || APP_PORT > 65535 )); then
        warn "Enter a port between 1 and 65535."
        continue
    fi

    if command_exists ss && ss -ltnH "sport = :${APP_PORT}" 2>/dev/null | grep -q .; then
        warn "Port ${APP_PORT} is already in use."
        continue
    fi
    break
done

while true; do
    DB_DATABASE="$(ask_default "PostgreSQL database name" "azuriom")"
    valid_identifier "$DB_DATABASE" && break
    warn "Use only letters, numbers, and underscores."
done

while true; do
    DB_USERNAME="$(ask_default "PostgreSQL username" "azuriom")"
    valid_identifier "$DB_USERNAME" && break
    warn "Use only letters, numbers, and underscores."
done

SYSTEM_TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-UTC}"
APP_TIMEZONE="$(ask_default "Application timezone" "$SYSTEM_TIMEZONE")"

read -r -p "Generate a secure PostgreSQL password automatically? [Y/n]: " AUTO_PASSWORD
AUTO_PASSWORD="${AUTO_PASSWORD:-Y}"

if [[ "$AUTO_PASSWORD" =~ ^[Yy]$ ]]; then
    DB_PASSWORD="$(openssl rand -hex 24)"
    info "Generated a secure database password."
else
    while true; do
        read -r -s -p "PostgreSQL password (minimum 16 characters): " DB_PASSWORD
        printf '\n'
        if (( ${#DB_PASSWORD} >= 16 )) && [[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]]; then
            break
        fi
        warn "Use at least 16 characters: letters, numbers, dot, underscore, tilde or hyphen."
    done
fi

# Save immediately, before downloads/builds.
umask 077
cat > "$CREDENTIAL_FILE" <<CREDS
APP_PORT=${APP_PORT}
APP_TIMEZONE=${APP_TIMEZONE}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
CREDS
chmod 600 "$CREDENTIAL_FILE"
info "Credentials saved to ${CREDENTIAL_FILE}"

printf '\nSelected settings:\n'
printf '  Install directory: %s\n' "$INSTALL_DIR"
printf '  HTTP port:         %s\n' "$APP_PORT"
printf '  Database:          %s\n' "$DB_DATABASE"
printf '  Database user:     %s\n' "$DB_USERNAME"
printf '  Timezone:          %s\n' "$APP_TIMEZONE"
printf '  Password:          saved in %s\n' "$CREDENTIAL_FILE"

if [[ -e "$INSTALL_DIR" ]]; then
    fail "${INSTALL_DIR} already exists. This installer will not overwrite an existing installation."
fi

# -----------------------------------------------------------------------------
# Step 3: Download official Azuriom
# -----------------------------------------------------------------------------
step "Downloading official Azuriom ${AZURIOM_VERSION}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --retry 3 --retry-delay 2 \
    "$AZURIOM_URL" \
    -o "$TMP_DIR/azuriom.zip"

mkdir -p "$TMP_DIR/azuriom"
unzip -q "$TMP_DIR/azuriom.zip" -d "$TMP_DIR/azuriom"

ARTISAN_PATH="$(find "$TMP_DIR/azuriom" -maxdepth 3 -type f -name artisan -print -quit)"
[[ -n "$ARTISAN_PATH" ]] || fail "The Azuriom archive does not contain artisan."

AZURIOM_ROOT="$(dirname "$ARTISAN_PATH")"
[[ -f "$AZURIOM_ROOT/LICENSE" ]] || fail "The official Azuriom LICENSE file is missing."
[[ -f "$AZURIOM_ROOT/docker-compose.yml" ]] || fail "The official docker-compose.yml is missing."
[[ -f "$AZURIOM_ROOT/docker/nginx.conf" ]] || fail "The official docker/nginx.conf is missing."

"${SUDO[@]}" mkdir -p "$INSTALL_DIR"
"${SUDO[@]}" cp -a "$AZURIOM_ROOT/." "$INSTALL_DIR/"
"${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"

cd "$INSTALL_DIR"
cp docker-compose.yml docker-compose.yml.upstream
cp .env.example .env

info "Official Azuriom files installed in ${INSTALL_DIR}."

# -----------------------------------------------------------------------------
# Step 4: Configure official Docker setup
# -----------------------------------------------------------------------------
step "Configuring Docker and PostgreSQL"

export APP_PORT APP_TIMEZONE DB_DATABASE DB_USERNAME DB_PASSWORD

"$PYTHON_BIN" <<'PY'
from pathlib import Path
import os

compose = Path("docker-compose.yml")
text = compose.read_text()

replacements = {
    '"8000:80"': '"${APP_PORT}:80"',
    '- DB_DATABASE=azuriom': '- DB_DATABASE=${DB_DATABASE}',
    '- DB_USERNAME=azuriom': '- DB_USERNAME=${DB_USERNAME}',
    '- DB_PASSWORD=password': '- DB_PASSWORD=${DB_PASSWORD}',
    'POSTGRES_DB: azuriom': 'POSTGRES_DB: ${DB_DATABASE}',
    'POSTGRES_USER: azuriom': 'POSTGRES_USER: ${DB_USERNAME}',
    'POSTGRES_PASSWORD: password': 'POSTGRES_PASSWORD: ${DB_PASSWORD}',
}

for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f"Expected upstream Compose line not found: {old}")
    text = text.replace(old, new, 1)

compose.write_text(text)

# The upstream Nginx config uses $realpath_root for SCRIPT_FILENAME.
# With the shared bind mount, Nginx and PHP-FPM can resolve that path
# differently, causing PHP-FPM to answer "File not found.". Use the
# fixed path that both containers share instead.
nginx_path = Path("docker/nginx.conf")
nginx_text = nginx_path.read_text()
old_script_filename = "fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;"
new_script_filename = "fastcgi_param SCRIPT_FILENAME /var/www/azuriom/public$fastcgi_script_name;"

if old_script_filename not in nginx_text:
    raise SystemExit(
        "Expected upstream Nginx SCRIPT_FILENAME line was not found: "
        + old_script_filename
    )

nginx_path.write_text(nginx_text.replace(old_script_filename, new_script_filename, 1))

env_path = Path(".env")
env_lines = env_path.read_text().splitlines()
values = {
    "APP_TIMEZONE": os.environ["APP_TIMEZONE"],
    "DB_CONNECTION": "pgsql",
    "DB_HOST": "db",
    "DB_PORT": "5432",
    "DB_DATABASE": os.environ["DB_DATABASE"],
    "DB_USERNAME": os.environ["DB_USERNAME"],
    "DB_PASSWORD": os.environ["DB_PASSWORD"],
}

out = []
seen = set()
for line in env_lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in values:
            out.append(f"{key}={values[key]}")
            seen.add(key)
            continue
    out.append(line)

for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}")

out.append(f"APP_PORT={os.environ['APP_PORT']}")
env_path.write_text("\n".join(out) + "\n")
PY

chmod 600 .env

for required in '${APP_PORT}' '${DB_DATABASE}' '${DB_USERNAME}' '${DB_PASSWORD}'; do
    grep -qF "$required" docker-compose.yml || fail "Compose configuration patch failed for ${required}."
done

grep -qF 'fastcgi_param SCRIPT_FILENAME /var/www/azuriom/public$fastcgi_script_name;' docker/nginx.conf \
    || fail "Nginx PHP script path patch failed."

info "Port, PostgreSQL, and Nginx PHP path settings configured."

# -----------------------------------------------------------------------------
# Step 5: Download Manager
# -----------------------------------------------------------------------------
step "Downloading latest stable Gaming Hub Manager"

MANAGER_URL="$({
    curl -fsSL --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: Gaming-Hub-Manager-Installer' \
        "$MANAGER_API"
} | "$PYTHON_BIN" -c '
import json, re, sys
release = json.load(sys.stdin)
assets = [
    a["browser_download_url"]
    for a in release.get("assets", [])
    if a.get("state") == "uploaded"
    and re.fullmatch(r"gaming-hub-manager-v[^/]+\.zip", a.get("name", ""))
]
if len(assets) != 1:
    raise SystemExit(1)
print(assets[0])
')" || fail "Could not find exactly one packaged gaming-hub-manager-v*.zip release asset."

curl -fL --retry 3 --retry-delay 2 \
    "$MANAGER_URL" \
    -o "$TMP_DIR/manager.zip"

mkdir -p "$TMP_DIR/manager"
unzip -q "$TMP_DIR/manager.zip" -d "$TMP_DIR/manager"

[[ -f "$TMP_DIR/manager/gaming-hub-manager/plugin.json" ]] \
    || fail "Manager ZIP does not contain gaming-hub-manager/plugin.json."

mkdir -p plugins
cp -a "$TMP_DIR/manager/gaming-hub-manager" plugins/gaming-hub-manager

info "Gaming Hub Manager plugin files installed."

# -----------------------------------------------------------------------------
# Step 6: Build and permissions
# -----------------------------------------------------------------------------
step "Building Azuriom and setting permissions"

"${DOCKER[@]}" compose build app

WWW_UID="$(
    "${DOCKER[@]}" compose run --rm --no-deps --entrypoint sh app -c 'id -u www-data' 2>/dev/null \
        | tail -n 1 \
        | tr -d '[:space:]'
)"

[[ "$WWW_UID" =~ ^[0-9]+$ ]] || fail "Could not determine the container www-data UID."

"${SUDO[@]}" setfacl -R -m "u:${WWW_UID}:rwX" "$INSTALL_DIR"
"${SUDO[@]}" find "$INSTALL_DIR" -type d -exec setfacl -m "d:u:${WWW_UID}:rwX" {} +

info "Azuriom is writable by the PHP container without chmod 777."

# -----------------------------------------------------------------------------
# Step 7: Validate and start
# -----------------------------------------------------------------------------
step "Validating and starting containers"

"${DOCKER[@]}" compose config >/dev/null
"${DOCKER[@]}" compose up -d

"${DOCKER[@]}" compose exec -T nginx nginx -t
"${DOCKER[@]}" compose exec -T nginx test -f /var/www/azuriom/public/index.php \
    || fail "Nginx cannot see /var/www/azuriom/public/index.php."
"${DOCKER[@]}" compose exec -T app test -f /var/www/azuriom/public/index.php \
    || fail "PHP-FPM cannot see /var/www/azuriom/public/index.php."

info "Containers started and Nginx/PHP file paths verified."

# -----------------------------------------------------------------------------
# Step 8: Finish
# -----------------------------------------------------------------------------
step "Installation ready"

printf '\nOpen Azuriom in your browser:\n'
printf '  http://SERVER-IP:%s\n\n' "$APP_PORT"
printf 'Use these values in the Azuriom browser installer:\n'
printf '  Driver:   PostgreSQL\n'
printf '  Host:     db\n'
printf '  Port:     5432\n'
printf '  Database: %s\n' "$DB_DATABASE"
printf '  Username: %s\n' "$DB_USERNAME"
printf '  Password: %s\n\n' "$DB_PASSWORD"
printf 'After Azuriom setup:\n'
printf '  - If you selected Custom Game, run this installer again and choose menu option 4\n'
printf '    to create your first administrator login.\n'
printf '  - Then sign in and enable Gaming Hub Manager under:\n'
printf '    Administration -> Extensions -> Plugins -> Gaming Hub Manager\n\n' 
printf 'Credentials are stored at:\n'
printf '  %s\n\n' "$CREDENTIAL_FILE"
printf 'Project directory:\n'
printf '  %s\n' "$INSTALL_DIR"

printf '\n'
read -r -p "Configure a domain with automatic HTTPS and a managed reverse proxy now? [y/N]: " CONFIGURE_HTTPS_NOW
CONFIGURE_HTTPS_NOW="${CONFIGURE_HTTPS_NOW:-N}"

if [[ "$CONFIGURE_HTTPS_NOW" =~ ^[Yy]$ ]]; then
    configure_domain_https
else
    printf '\nYou can configure or change the domain later by running this installer again\n'
    printf 'and selecting menu option 3.\n'
fi
