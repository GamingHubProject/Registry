#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="2.9.2-manager-self-verification"
AZURIOM_VERSION="1.2.12"
INSTALL_DIR="/opt/azuriom"
AZURIOM_URL="https://github.com/Azuriom/Azuriom/releases/download/v${AZURIOM_VERSION}/Azuriom-${AZURIOM_VERSION}.zip"
MANAGER_API="https://api.github.com/repos/GamingHubProject/Manager/releases/latest"
MANAGER_RELEASE_TAG_API="https://api.github.com/repos/GamingHubProject/Manager/releases/tags"
MANAGER_RELEASE_MARKER=".gaming-hub-manager-release"
MANAGER_PROVENANCE_REL="storage/app/gaming-hub-manager/self-install-provenance.json"
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


manager_release_metadata() {
    local python_bin="$1"
    local release_json="$2"
    local release_mode="$3"

    "$python_bin" - "$release_json" "$release_mode" <<'PY_MANAGER_RELEASE'
import json, re, sys
from urllib.parse import urlparse

with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)
mode = sys.argv[2]

if release.get("draft"):
    raise SystemExit("draft releases cannot be installed")
if mode == "latest" and release.get("prerelease"):
    raise SystemExit("latest release is unexpectedly marked prerelease")

assets = [a for a in release.get("assets", []) if a.get("state") == "uploaded"]
packages = [
    a for a in assets
    if re.fullmatch(r"gaming-hub-manager-v[^/]+\.zip", str(a.get("name", "")))
]
if len(packages) != 1:
    raise SystemExit("expected exactly one uploaded Manager package ZIP")
package = packages[0]
package_name = str(package.get("name", ""))

def official_asset_api(value):
    parsed = urlparse(str(value or ""))
    return (
        parsed.scheme == "https"
        and parsed.netloc == "api.github.com"
        and parsed.path.startswith("/repos/GamingHubProject/Manager/releases/assets/")
    )

if not official_asset_api(package.get("url")):
    raise SystemExit("Manager package asset API URL is not official")

# Trust-order fallback after GitHub's own digest:
# exact per-asset sidecar, then SHA256SUMS from the same release.
checksum = None
checksum_kind = ""
for name, kind in [
    (package_name + ".sha256", "exact_checksum_sidecar"),
    ("SHA256SUMS", "sha256sums"),
    ("SHA256SUMS.txt", "sha256sums"),
]:
    matches = [a for a in assets if a.get("name") == name]
    if len(matches) > 1:
        raise SystemExit("duplicate checksum assets")
    if matches:
        checksum = matches[0]
        checksum_kind = kind
        break

if checksum is not None and not official_asset_api(checksum.get("url")):
    raise SystemExit("Manager checksum asset API URL is not official")

fields = [
    str(release.get("tag_name", "")),
    str(release.get("id", "")),
    str(package.get("id", "")),
    package_name,
    str(package.get("url", "")),
    str(package.get("digest") or ""),
    str(package.get("size") or ""),
    "1" if release.get("prerelease") else "0",
    str(checksum.get("id", "") if checksum else ""),
    str(checksum.get("name", "") if checksum else ""),
    str(checksum.get("url", "") if checksum else ""),
    checksum_kind,
]
print("\t".join(fields))
PY_MANAGER_RELEASE
}

manager_checksum_from_asset() {
    local python_bin="$1"
    local checksum_file="$2"
    local checksum_kind="$3"
    local package_name="$4"

    "$python_bin" - "$checksum_file" "$checksum_kind" "$package_name" <<'PY_MANAGER_CHECKSUM'
import re, sys
path, kind, package_name = sys.argv[1:]
text = open(path, encoding="utf-8", errors="strict").read()
allow_bare = kind == "exact_checksum_sidecar"
found = []
for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    m = re.fullmatch(r"([a-fA-F0-9]{64})\s+\*?(.+)", line)
    if m and m.group(2).strip() == package_name:
        found.append(m.group(1).lower())
        continue
    m = re.fullmatch(r"SHA256\s*\((.+)\)\s*=\s*([a-fA-F0-9]{64})", line, re.I)
    if m and m.group(1).strip() == package_name:
        found.append(m.group(2).lower())
        continue
    if allow_bare and re.fullmatch(r"[a-fA-F0-9]{64}", line):
        found.append(line.lower())
found = sorted(set(found))
if len(found) != 1:
    raise SystemExit("checksum asset does not contain exactly one SHA-256 for the downloaded asset")
print(found[0])
PY_MANAGER_CHECKSUM
}

manager_validate_archive() {
    local python_bin="$1"
    local archive="$2"

    "$python_bin" - "$archive" <<'PY_MANAGER_ARCHIVE'
import json, re, stat, sys, zipfile
archive = sys.argv[1]
with zipfile.ZipFile(archive) as z:
    names = set()
    for info in z.infolist():
        name = info.filename
        if not name or "\\" in name or name.startswith("/") or "\x00" in name:
            raise SystemExit("unsafe archive path")
        parts = [p for p in name.rstrip("/").split("/") if p]
        if not parts or parts[0] != "gaming-hub-manager" or any(p in (".", "..") for p in parts):
            raise SystemExit("archive must contain only the gaming-hub-manager package root")
        mode = (info.external_attr >> 16) & 0xFFFF
        if mode and stat.S_ISLNK(mode):
            raise SystemExit("symbolic links are not allowed in the Manager archive")
        file_type = stat.S_IFMT(mode) if mode else 0
        if file_type and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise SystemExit("special filesystem entries are not allowed in the Manager archive")
        if name in names:
            raise SystemExit("duplicate archive entry")
        names.add(name)

    plugin_name = "gaming-hub-manager/plugin.json"
    extension_name = "gaming-hub-manager/gaming-hub-extension.json"
    if plugin_name not in names or extension_name not in names:
        raise SystemExit("Manager package manifests are missing")

    plugin = json.loads(z.read(plugin_name))
    extension = json.loads(z.read(extension_name))

version = str(plugin.get("version", ""))
if plugin.get("id") != "gaming-hub-manager":
    raise SystemExit("Manager plugin id is invalid")
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", version):
    raise SystemExit("Manager plugin version is invalid")
if extension.get("id") != "gaming-hub-manager" or str(extension.get("version", "")) != version:
    raise SystemExit("Manager extension manifest identity/version mismatch")
package = extension.get("package") or {}
if package.get("plugin_directory") != "gaming-hub-manager":
    raise SystemExit("Manager plugin directory contract is invalid")

# Deliberately do NOT derive plugin version from GitHub tag or asset filename.
# plugin.json / gaming-hub-extension.json are the installed-version authority.
print(version)
PY_MANAGER_ARCHIVE
}

manager_directory_hash() {
    local python_bin="$1"
    local package_dir="$2"

    "$python_bin" - "$package_dir" <<'PY_MANAGER_DIRECTORY_HASH'
import hashlib, os, sys
root = os.path.realpath(sys.argv[1])
if not os.path.isdir(root) or os.path.islink(sys.argv[1]):
    raise SystemExit("Manager package directory is unavailable")
files = []
for current, dirs, names in os.walk(root, topdown=True, followlinks=False):
    for name in dirs:
        path = os.path.join(current, name)
        if os.path.islink(path):
            raise SystemExit("symbolic link rejected while hashing Manager directory")
    for name in names:
        path = os.path.join(current, name)
        if os.path.islink(path):
            raise SystemExit("symbolic link rejected while hashing Manager directory")
        if os.path.isfile(path):
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            files.append((relative, path))
files.sort(key=lambda item: item[0])
combined = hashlib.sha256()
for relative, path in files:
    content = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            content.update(chunk)
    size = os.path.getsize(path)
    combined.update(relative.encode("utf-8") + b"\0" + str(size).encode("ascii") + b"\0" + content.hexdigest().encode("ascii") + b"\n")
print(combined.hexdigest())
PY_MANAGER_DIRECTORY_HASH
}

manager_write_provenance() {
    local python_bin="$1"
    local provenance_path="$2"
    local package_dir="$3"
    local version="$4"
    local directory_hash="$5"

    "${SUDO[@]}" "$python_bin" - "$provenance_path" "$package_dir" "$version" "$directory_hash" \
        "$MANAGER_RELEASE_TAG" "$MANAGER_RELEASE_ID" "$MANAGER_ASSET_NAME" "$MANAGER_ASSET_ID" \
        "$MANAGER_EXPECTED_SHA256" "$MANAGER_CHECKSUM_SOURCE" "${MANAGER_CHECKSUM_ASSET_NAME:-}" \
        "${MANAGER_CHECKSUM_FORMAT:-}" <<'PY_MANAGER_PROVENANCE'
import datetime, json, os, re, tempfile, sys
(
    provenance_path, package_dir, version, directory_hash, release_tag, release_id,
    asset_name, asset_id, asset_sha256, checksum_source, checksum_asset_name, checksum_format,
) = sys.argv[1:]
package_real = os.path.realpath(package_dir)
parent = os.path.dirname(provenance_path)
os.makedirs(parent, mode=0o700, exist_ok=True)
parent_real = os.path.realpath(parent)
try:
    if os.path.commonpath([package_real, parent_real]) == package_real:
        raise SystemExit("provenance path must be outside the Manager package directory")
except ValueError:
    pass
if checksum_source not in {"github_asset_digest", "checksum_asset"}:
    raise SystemExit("unsupported provenance checksum source")
if not re.fullmatch(r"[a-fA-F0-9]{64}", asset_sha256):
    raise SystemExit("invalid provenance asset SHA-256")
if not re.fullmatch(r"[a-fA-F0-9]{64}", directory_hash):
    raise SystemExit("invalid provenance directory hash")
if checksum_source == "checksum_asset" and not checksum_asset_name:
    raise SystemExit("checksum_asset provenance requires checksum_asset_name")
record = {
    "schema": 1,
    "package_id": "gaming-hub-manager",
    "version": version,
    "repository": "https://github.com/GamingHubProject/Manager",
    "release_tag": release_tag,
    "release_id": int(release_id),
    "asset_name": asset_name,
    "asset_id": int(asset_id),
    "asset_sha256": asset_sha256.lower(),
    "checksum_source": checksum_source,
    "directory_hash": directory_hash.lower(),
    "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "installer": "gaming-hub-manager-official-installer",
}
if checksum_source == "checksum_asset":
    record["checksum_asset_name"] = checksum_asset_name
    if checksum_format:
        record["checksum_format"] = checksum_format
fd, temporary = tempfile.mkstemp(prefix=".self-install-provenance.", suffix=".tmp", dir=parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, provenance_path)
    os.chmod(provenance_path, 0o600)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY_MANAGER_PROVENANCE
}

manager_prepare_verified_release() {
    local python_bin="$1"
    local release_api="$2"
    local release_mode="$3"
    local work_dir="$4"

    mkdir -p "$work_dir" || return 1
    local release_json="$work_dir/release.json"
    local checksum_file="$work_dir/checksum.txt"

    if ! curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: Gaming-Hub-Manager-Installer' \
        -H 'Cache-Control: no-cache, no-store' \
        -H 'Pragma: no-cache' \
        "$release_api" -o "$release_json"; then
        return 1
    fi

    local metadata
    metadata="$(manager_release_metadata "$python_bin" "$release_json" "$release_mode")" || return 1
    IFS=$'\t' read -r \
        MANAGER_RELEASE_TAG MANAGER_RELEASE_ID MANAGER_ASSET_ID MANAGER_ASSET_NAME \
        MANAGER_ASSET_API MANAGER_ASSET_DIGEST MANAGER_ASSET_SIZE MANAGER_RELEASE_PRERELEASE \
        MANAGER_CHECKSUM_ASSET_ID MANAGER_CHECKSUM_ASSET_NAME MANAGER_CHECKSUM_ASSET_API MANAGER_CHECKSUM_KIND \
        <<< "$metadata"

    [[ -n "$MANAGER_RELEASE_TAG" ]] || return 1
    [[ "$MANAGER_RELEASE_ID" =~ ^[0-9]+$ ]] || return 1
    [[ "$MANAGER_ASSET_ID" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$MANAGER_ASSET_NAME" && -n "$MANAGER_ASSET_API" ]] || return 1

    if ! curl --proto '=https' --proto-redir '=https' -fL --retry 3 --retry-delay 2 \
        -H 'Accept: application/octet-stream' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: Gaming-Hub-Manager-Installer' \
        -H 'Cache-Control: no-cache, no-store' \
        -H 'Pragma: no-cache' \
        "$MANAGER_ASSET_API" -o "$work_dir/manager.zip"; then
        return 1
    fi

    local actual_size
    actual_size="$(stat -c '%s' "$work_dir/manager.zip")" || return 1
    if [[ "$MANAGER_ASSET_SIZE" =~ ^[0-9]+$ ]] && [[ "$actual_size" != "$MANAGER_ASSET_SIZE" ]]; then
        warn "Manager release size verification failed (expected ${MANAGER_ASSET_SIZE}, received ${actual_size})."
        return 1
    fi

    MANAGER_EXPECTED_SHA256=""
    MANAGER_CHECKSUM_SOURCE=""
    MANAGER_CHECKSUM_FORMAT=""
    if [[ "$MANAGER_ASSET_DIGEST" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then
        MANAGER_EXPECTED_SHA256="${BASH_REMATCH[1],,}"
        MANAGER_CHECKSUM_SOURCE="github_asset_digest"
    elif [[ "$MANAGER_CHECKSUM_ASSET_ID" =~ ^[0-9]+$ && -n "$MANAGER_CHECKSUM_ASSET_API" && -n "$MANAGER_CHECKSUM_KIND" ]]; then
        if ! curl --proto '=https' --proto-redir '=https' -fL --retry 3 --retry-delay 2 \
            -H 'Accept: application/octet-stream' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -H 'User-Agent: Gaming-Hub-Manager-Installer' \
            "$MANAGER_CHECKSUM_ASSET_API" -o "$checksum_file"; then
            return 1
        fi
        MANAGER_EXPECTED_SHA256="$(manager_checksum_from_asset "$python_bin" "$checksum_file" "$MANAGER_CHECKSUM_KIND" "$MANAGER_ASSET_NAME")" || return 1
        MANAGER_CHECKSUM_SOURCE="checksum_asset"
        MANAGER_CHECKSUM_FORMAT="$MANAGER_CHECKSUM_KIND"
    else
        warn "The Manager release has no approved published SHA-256 source."
        return 1
    fi

    MANAGER_ACTUAL_SHA256="$(sha256sum "$work_dir/manager.zip" | awk '{print tolower($1)}')" || return 1
    if [[ "$MANAGER_ACTUAL_SHA256" != "$MANAGER_EXPECTED_SHA256" ]]; then
        warn "Manager release SHA-256 verification failed."
        return 1
    fi

    MANAGER_RELEASE_VERSION="$(manager_validate_archive "$python_bin" "$work_dir/manager.zip")" || return 1
    if [[ "$MANAGER_RELEASE_TAG" != "v${MANAGER_RELEASE_VERSION}" ]]; then
        warn "Manager release tag ${MANAGER_RELEASE_TAG} does not exactly match plugin version v${MANAGER_RELEASE_VERSION}."
        return 1
    fi
    if [[ "$MANAGER_ASSET_NAME" != "gaming-hub-manager-v${MANAGER_RELEASE_VERSION}.zip" ]]; then
        warn "Manager packaged asset name does not exactly match installed-version contract."
        return 1
    fi
    info "Manager release tag/asset identity verified for plugin ${MANAGER_RELEASE_VERSION}."
    info "Manager release size verified (${actual_size} bytes)."
    info "Manager release SHA-256 verified (${MANAGER_CHECKSUM_SOURCE})."
    info "Manager archive structure and manifests verified."
    return 0
}

manager_write_legacy_marker() {
    local marker_path="$1"
    local version="$2"
    local marker_tmp
    marker_tmp="$(mktemp)"
    cat > "$marker_tmp" <<MARKER
TAG=${MANAGER_RELEASE_TAG}
PLUGIN_VERSION=${version}
ASSET_ID=${MANAGER_ASSET_ID}
ASSET_SHA256=${MANAGER_ACTUAL_SHA256}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER
    "${SUDO[@]}" cp "$marker_tmp" "$marker_path" && "${SUDO[@]}" chmod 644 "$marker_path"
    rm -f "$marker_tmp"
}

if [[ "${GAMING_HUB_INSTALLER_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

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
        fail "Azuriom setup is not finished yet. Complete the automatic or browser setup first, then run this menu option again."
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

enable_gaming_hub_manager() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    find_docker_command || fail "Docker is required to enable Gaming Hub Manager."
    cd "$INSTALL_DIR"

    local app_key
    app_key="$(awk -F= '$1 == "APP_KEY" { sub(/^APP_KEY=/, ""); print; exit }' .env)"
    if [[ -z "$app_key" ]]; then
        fail "Azuriom setup is not finished yet. Complete the automatic or browser setup first, then run this menu option again."
    fi

    printf '\n\033[1;35mGaming Hub Manager\033[0m\n'
    printf 'This enables the Gaming Hub Manager plugin that was downloaded during installation.\n\n'

    local proceed
    read -r -p "Enable Gaming Hub Manager now? [Y/n]: " proceed
    proceed="${proceed:-Y}"
    [[ "$proceed" =~ ^[Yy]$ ]] || { info "Cancelled. Gaming Hub Manager was not enabled. You can enable it later by running this installer again."; return 0; }

    "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager \
        || fail "Gaming Hub Manager could not be enabled."
    "${DOCKER[@]}" compose exec -T app php artisan plugin:cache >/dev/null 2>&1 \
        || warn "Plugin cache rebuild failed; Manager was enabled but run 'php artisan plugin:cache' manually if needed."

    info "Gaming Hub Manager is enabled."
}

azuriom_custom_game_setup() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    find_docker_command || fail "Docker is required to complete the Azuriom installation."
    cd "$INSTALL_DIR"

    local locale
    locale="$(ask_default "Azuriom locale" "en")"
    if [[ ! "$locale" =~ ^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})?$ ]]; then
        fail "Invalid locale code: ${locale}. Use a code such as en, de, fr, or pt_BR."
    fi

    local host_ip=""
    if command_exists ip; then
        host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' || true)"
    fi
    if [[ -z "$host_ip" ]] && command_exists hostname; then
        host_ip="$(hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i !~ /^127\./) {print $i; exit}}' || true)"
    fi
    host_ip="${host_ip:-127.0.0.1}"
    local app_url="http://${host_ip}:${APP_PORT}"

    printf '\n\033[1;35mAutomatic Gaming Hub / Custom Game setup\033[0m\n'
    printf 'Azuriom will be initialized without the browser installer.\n'
    printf '  Game mode: custom\n'
    printf '  Locale:    %s\n' "$locale"
    printf '  APP_URL:   %s\n\n' "$app_url"

    info "Waiting for PostgreSQL to become ready..."
    local attempt
    local db_ready="no"
    for attempt in $(seq 1 30); do
        if "${DOCKER[@]}" compose exec -T db pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" >/dev/null 2>&1; then
            db_ready="yes"
            break
        fi
        sleep 1
    done
    [[ "$db_ready" == "yes" ]] || fail "PostgreSQL did not become ready for automatic Azuriom setup."

    # Mirror Azuriom 1.2.x's Custom Game installer flow without modifying
    # Azuriom source: clear cache, run migrations/seeds, create storage link,
    # set the Custom Game environment, and generate the final application key.
    "${DOCKER[@]}" compose exec -T app php artisan cache:clear
    "${DOCKER[@]}" compose exec -T app php artisan migrate --force --seed

    if ! "${DOCKER[@]}" compose exec -T app php artisan storage:link --relative; then
        "${DOCKER[@]}" compose exec -T app test -L /var/www/azuriom/public/storage \
            || fail "Azuriom storage link could not be created."
        warn "Azuriom storage link already exists; continuing."
    fi

    set_env_value .env APP_ENV "production"
    set_env_value .env APP_DEBUG "false"
    set_env_value .env APP_LOCALE "$locale"
    set_env_value .env APP_URL "$app_url"
    set_env_value .env MAIL_MAILER "array"
    set_env_value .env AZURIOM_GAME "custom"
    chmod 600 .env

    "${DOCKER[@]}" compose exec -T app php artisan key:generate --force >/dev/null
    chmod 600 .env

    local app_key
    app_key="$(awk -F= '$1 == "APP_KEY" { sub(/^APP_KEY=/, ""); print; exit }' .env)"
    [[ -n "$app_key" ]] || fail "Automatic Azuriom setup did not generate APP_KEY."
    grep -q '^AZURIOM_GAME=custom$' .env || fail "Automatic Azuriom setup did not set AZURIOM_GAME=custom."

    if [[ -f "$CREDENTIAL_FILE" ]]; then
        set_env_value "$CREDENTIAL_FILE" APP_URL "$app_url"
        chmod 600 "$CREDENTIAL_FILE"
    fi

    "${DOCKER[@]}" compose exec -T app php artisan optimize:clear

    info "Azuriom initialized successfully as Custom Game."

    printf '\n\033[1;32mAutomatic Gaming Hub setup complete.\033[0m\n'
    printf 'Azuriom game mode: custom\n'
    printf 'Application URL: %s\n' "$app_url"
}


upgrade_manager() {
    [[ -d "$INSTALL_DIR" ]] || fail "No Azuriom installation exists at ${INSTALL_DIR}."
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || fail "${INSTALL_DIR}/docker-compose.yml is missing."
    [[ -f "$INSTALL_DIR/.env" ]] || fail "${INSTALL_DIR}/.env is missing."

    local plugin_dir="$INSTALL_DIR/plugins/gaming-hub-manager"
    local plugin_manifest="$plugin_dir/plugin.json"
    local release_marker="$INSTALL_DIR/$MANAGER_RELEASE_MARKER"
    local provenance_path="$INSTALL_DIR/$MANAGER_PROVENANCE_REL"
    [[ -f "$plugin_manifest" ]] || fail "Gaming Hub Manager is not installed at ${plugin_dir}."

    find_docker_command || fail "Docker is required to upgrade Gaming Hub Manager."
    command_exists curl || fail "curl is required."
    command_exists unzip || fail "unzip is required."
    command_exists sha256sum || fail "sha256sum is required."
    command_exists stat || fail "stat is required."

    local python_bin=""
    if command_exists python3; then python_bin="python3"; elif command_exists python; then python_bin="python"; else fail "Python 3 is required."; fi

    cd "$INSTALL_DIR"
    local app_key
    app_key="$(awk -F= '$1 == "APP_KEY" { sub(/^APP_KEY=/, ""); print; exit }' .env)"
    [[ -n "$app_key" ]] || fail "Azuriom setup is not finished yet. Complete it before upgrading Gaming Hub Manager."
    "${DOCKER[@]}" compose exec -T app php artisan --version >/dev/null 2>&1 \
        || fail "The Azuriom application container is not ready."

    local current_version
    current_version="$("$python_bin" - "$plugin_manifest" <<'PY_CURRENT'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data=json.load(f)
if data.get("id") != "gaming-hub-manager": raise SystemExit("unexpected plugin id")
print(data.get("version", "unknown"))
PY_CURRENT
)" || fail "Could not read the installed Gaming Hub Manager version."

    local installed_release_tag="" installed_asset_id=""
    if [[ -f "$provenance_path" ]]; then
        read -r installed_release_tag installed_asset_id < <("$python_bin" - "$provenance_path" <<'PY_INSTALLED_PROV'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: data=json.load(f)
    if data.get("package_id") == "gaming-hub-manager":
        print(str(data.get("release_tag", "")), str(data.get("asset_id", "")))
except Exception:
    pass
PY_INSTALLED_PROV
)
    fi
    if [[ -z "$installed_release_tag" && -f "$release_marker" ]]; then
        installed_release_tag="$(awk -F= '$1 == "TAG" {print $2; exit}' "$release_marker")"
        installed_asset_id="$(awk -F= '$1 == "ASSET_ID" {print $2; exit}' "$release_marker")"
    fi

    printf '\n\033[1;35mUpgrade Gaming Hub Manager\033[0m\n'
    printf 'Installed plugin version: %s\n' "$current_version"
    [[ -n "$installed_release_tag" ]] && printf 'Installed release tag:    %s\n' "$installed_release_tag"
    printf '\nChoose the Manager release to install:\n'
    printf '  1) Latest stable published release\n'
    printf '  2) Specific release tag\n'
    printf '  3) Cancel\n\n'

    local release_choice release_mode release_api requested_tag=""
    read -r -p "Selection [1]: " release_choice
    release_choice="${release_choice:-1}"
    case "$release_choice" in
        1) release_mode="latest"; release_api="${MANAGER_API}?nocache=$(date +%s)" ;;
        2)
            release_mode="specific"
            while true; do
                read -r -p "Release tag (example: v0.1.4m0.4): " requested_tag
                [[ -n "$requested_tag" && "$requested_tag" != *[[:space:]]* ]] && break
                warn "Enter a release tag without whitespace."
            done
            local encoded_tag
            encoded_tag="$("$python_bin" - "$requested_tag" <<'PY_TAG'
from urllib.parse import quote
import sys
print(quote(sys.argv[1], safe=""))
PY_TAG
)"
            release_api="${MANAGER_RELEASE_TAG_API}/${encoded_tag}?nocache=$(date +%s)"
            ;;
        3) info "Cancelled. Nothing was changed."; return 0 ;;
        *) fail "Invalid release selection." ;;
    esac

    local upgrade_tmp
    upgrade_tmp="$(mktemp -d)"
    if ! manager_prepare_verified_release "$python_bin" "$release_api" "$release_mode" "$upgrade_tmp"; then
        rm -rf "$upgrade_tmp"
        [[ "$release_mode" == "specific" ]] && fail "Could not obtain and verify Manager release ${requested_tag}."
        fail "Could not obtain and verify the latest stable Gaming Hub Manager release."
    fi

    local latest_tag="$MANAGER_RELEASE_TAG" latest_version="$MANAGER_RELEASE_VERSION"
    printf 'Release:           %s\n' "$latest_tag"
    printf 'Release ID:        %s\n' "$MANAGER_RELEASE_ID"
    printf 'Release asset:     %s\n' "$MANAGER_ASSET_NAME"
    printf 'Release asset ID:  %s\n' "$MANAGER_ASSET_ID"
    printf 'Plugin version:    %s\n' "$latest_version"
    [[ "$MANAGER_RELEASE_PRERELEASE" == "1" ]] && warn "The selected release is marked prerelease."
    if [[ "$latest_tag" != "v${latest_version}" && "$latest_tag" != "$latest_version" ]]; then
        info "Release/build tag differs from plugin version; package manifests are the version authority."
    fi

    if [[ "$installed_release_tag" == "$latest_tag" && "$installed_asset_id" == "$MANAGER_ASSET_ID" && "$current_version" == "$latest_version" ]]; then
        info "Gaming Hub Manager release ${latest_tag} is already installed."
        rm -rf "$upgrade_tmp"; return 0
    fi
    if [[ -z "$installed_release_tag" && "$current_version" == "$latest_version" && ( "$latest_tag" == "v${latest_version}" || "$latest_tag" == "$latest_version" ) ]]; then
        info "Gaming Hub Manager is already up to date at ${latest_tag}."
        rm -rf "$upgrade_tmp"; return 0
    fi
    if [[ "$current_version" == "$latest_version" ]]; then
        warn "Same plugin version, different release/build; the selected build will still be installed."
    elif command_exists sort && [[ "$current_version" != "unknown" ]]; then
        local highest_version
        highest_version="$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -n 1)"
        if [[ "$highest_version" == "$current_version" ]]; then
            if [[ "$release_mode" == "specific" ]]; then
                warn "You selected older plugin version ${latest_version}; confirmation will perform an intentional downgrade."
            else
                warn "Installed Manager ${current_version} is newer than latest stable ${latest_version}; no downgrade performed."
                rm -rf "$upgrade_tmp"; return 0
            fi
        fi
    fi

    mkdir -p "$upgrade_tmp/extracted"
    unzip -q "$upgrade_tmp/manager.zip" -d "$upgrade_tmp/extracted" || { rm -rf "$upgrade_tmp"; fail "Could not extract verified Manager ZIP."; }
    local new_plugin_dir="$upgrade_tmp/extracted/gaming-hub-manager"
    [[ -f "$new_plugin_dir/plugin.json" ]] || { rm -rf "$upgrade_tmp"; fail "Verified Manager package did not extract correctly."; }

    printf '\nThe upgrade will:\n'
    printf '  - install release %s (plugin %s);\n' "$latest_tag" "$latest_version"
    printf '  - back up PostgreSQL, Manager files, and existing Manager storage/provenance;\n'
    printf '  - stage the verified package before replacement;\n'
    printf '  - finalize a directory hash and provenance record before success.\n\n'
    local proceed
    read -r -p "Install Gaming Hub Manager release ${latest_tag}? [Y/n]: " proceed
    proceed="${proceed:-Y}"
    [[ "$proceed" =~ ^[Yy]$ ]] || { info "Cancelled. Nothing was changed."; rm -rf "$upgrade_tmp"; return 0; }

    local enabled_before="no"
    if [[ -f "$INSTALL_DIR/plugins/plugins.json" ]] && "$python_bin" - "$INSTALL_DIR/plugins/plugins.json" <<'PY_ENABLED' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data=json.load(f)
raise SystemExit(0 if "gaming-hub-manager" in data else 1)
PY_ENABLED
    then enabled_before="yes"; fi

    local stamp backup_dir storage_dir safe_tag stage_dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    safe_tag="$(printf '%s' "$latest_tag" | tr -c 'A-Za-z0-9._-' '_')"
    backup_dir="$INSTALL_DIR/storage/app/gaming-hub-manager-upgrade-backups/${stamp}-from-${current_version}-to-${safe_tag}"
    storage_dir="$INSTALL_DIR/storage/app/gaming-hub-manager"
    stage_dir="$INSTALL_DIR/plugins/.gaming-hub-manager.upgrade.$$"
    "${SUDO[@]}" mkdir -p "$backup_dir"
    "${SUDO[@]}" cp -a "$plugin_dir" "$backup_dir/plugin"
    [[ -d "$storage_dir" ]] && "${SUDO[@]}" cp -a "$storage_dir" "$backup_dir/storage"
    if ! "${DOCKER[@]}" compose exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | "${SUDO[@]}" tee "$backup_dir/database.sql" >/dev/null; then
        "${SUDO[@]}" rm -rf "$backup_dir"; rm -rf "$upgrade_tmp"; fail "PostgreSQL backup failed. Manager was not changed."
    fi

    "${SUDO[@]}" rm -rf "$stage_dir"
    "${SUDO[@]}" cp -a "$new_plugin_dir" "$stage_dir" || { "${SUDO[@]}" rm -rf "$stage_dir"; rm -rf "$upgrade_tmp"; fail "Manager staging failed before replacement."; }
    local www_uid
    www_uid="$("${DOCKER[@]}" compose exec -T app sh -c 'id -u www-data' 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    if [[ "$www_uid" =~ ^[0-9]+$ ]] && command_exists setfacl; then "${SUDO[@]}" setfacl -R -m "u:${www_uid}:rwX" "$stage_dir" || fail "Could not apply PHP ACL to staged Manager."; fi

    [[ "$enabled_before" == "yes" ]] && "${DOCKER[@]}" compose exec -T app php artisan plugin:disable gaming-hub-manager
    "${SUDO[@]}" rm -rf "$plugin_dir"
    if ! "${SUDO[@]}" mv "$stage_dir" "$plugin_dir"; then
        "${SUDO[@]}" cp -a "$backup_dir/plugin" "$plugin_dir"
        [[ "$enabled_before" == "yes" ]] && "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager >/dev/null 2>&1 || true
        rm -rf "$upgrade_tmp"; fail "Manager replacement failed; previous files restored."
    fi

    # Finalize trusted files + provenance while Manager remains disabled.
    local post_install_ok="yes"
    local installed_after directory_hash
    installed_after="$("$python_bin" - "$plugin_manifest" <<'PY_AFTER'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: print(json.load(f).get("version", "unknown"))
PY_AFTER
)"
    [[ "$installed_after" == "$latest_version" ]] || post_install_ok="no"
    directory_hash="$(manager_directory_hash "$python_bin" "$plugin_dir")" || post_install_ok="no"
    if [[ "$post_install_ok" == "yes" ]]; then manager_write_provenance "$python_bin" "$provenance_path" "$plugin_dir" "$latest_version" "$directory_hash" || post_install_ok="no"; fi

    # Only boot/re-enable the new Manager after provenance exists atomically.
    if [[ "$post_install_ok" == "yes" && "$enabled_before" == "yes" ]]; then "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager || post_install_ok="no"; fi
    if [[ "$post_install_ok" == "yes" ]]; then "${DOCKER[@]}" compose exec -T app php artisan optimize:clear || post_install_ok="no"; fi
    if [[ "$post_install_ok" == "yes" ]]; then "${DOCKER[@]}" compose exec -T app php artisan plugin:cache || post_install_ok="no"; fi

    if [[ "$post_install_ok" != "yes" ]]; then
        warn "Upgrade finalization failed; rolling Manager files and provenance back together."
        [[ "$enabled_before" == "yes" ]] && "${DOCKER[@]}" compose exec -T app php artisan plugin:disable gaming-hub-manager >/dev/null 2>&1 || true
        "${SUDO[@]}" rm -rf "$plugin_dir"
        "${SUDO[@]}" cp -a "$backup_dir/plugin" "$plugin_dir"
        if [[ -f "$backup_dir/storage/self-install-provenance.json" ]]; then
            "${SUDO[@]}" mkdir -p "$(dirname "$provenance_path")"
            "${SUDO[@]}" cp -a "$backup_dir/storage/self-install-provenance.json" "$provenance_path"
        else
            "${SUDO[@]}" rm -f "$provenance_path"
        fi
        [[ "$enabled_before" == "yes" ]] && "${DOCKER[@]}" compose exec -T app php artisan plugin:enable gaming-hub-manager >/dev/null 2>&1 || true
        "${DOCKER[@]}" compose exec -T app php artisan optimize:clear >/dev/null 2>&1 || true
        "${DOCKER[@]}" compose exec -T app php artisan plugin:cache >/dev/null 2>&1 || true
        rm -rf "$upgrade_tmp"
        fail "Upgrade failed during finalization; previous trusted state was restored. Backup: ${backup_dir}"
    fi

    manager_write_legacy_marker "$release_marker" "$latest_version" || warn "Legacy release marker could not be updated; provenance remains authoritative."
    rm -rf "$upgrade_tmp"
    info "Gaming Hub Manager installed successfully: ${latest_tag} (plugin ${latest_version})"
    info "Verified provenance recorded at ${provenance_path}."
    printf 'Backup retained at:\n  %s\n' "$backup_dir"
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

# Save immediately, before downloads/builds. Scope the restrictive umask to
# this private file only so later installation directories do not inherit 0700.
(
    umask 077
    cat > "$CREDENTIAL_FILE" <<CREDS
APP_PORT=${APP_PORT}
APP_TIMEZONE=${APP_TIMEZONE}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
CREDS
    chmod 600 "$CREDENTIAL_FILE"
)
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

# Nginx serves public assets from this bind mount as its unprivileged worker.
# Grant only traversal on the application root; do not make private files
# world-readable and do not recursively broaden permissions.
"${SUDO[@]}" chmod o+x "$INSTALL_DIR"

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

MANAGER_WORK_DIR="$TMP_DIR/manager-release"
if ! manager_prepare_verified_release "$PYTHON_BIN" "${MANAGER_API}?nocache=$(date +%s)" "latest" "$MANAGER_WORK_DIR"; then
    fail "Could not obtain and verify the latest official Gaming Hub Manager release."
fi

mkdir -p "$TMP_DIR/manager"
unzip -q "$MANAGER_WORK_DIR/manager.zip" -d "$TMP_DIR/manager" \
    || fail "Could not extract the verified Manager release ZIP."
MANAGER_SOURCE_DIR="$TMP_DIR/manager/gaming-hub-manager"
[[ -f "$MANAGER_SOURCE_DIR/plugin.json" ]] || fail "Verified Manager ZIP did not extract correctly."
MANAGER_PLUGIN_VERSION="$MANAGER_RELEASE_VERSION"

mkdir -p plugins
MANAGER_FINAL_DIR="$INSTALL_DIR/plugins/gaming-hub-manager"
MANAGER_STAGE_DIR="$INSTALL_DIR/plugins/.gaming-hub-manager.installing.$$"
"${SUDO[@]}" rm -rf "$MANAGER_STAGE_DIR"
"${SUDO[@]}" cp -a "$MANAGER_SOURCE_DIR" "$MANAGER_STAGE_DIR" \
    || { "${SUDO[@]}" rm -rf "$MANAGER_STAGE_DIR"; fail "Manager staging copy failed; no Manager installation was activated."; }
[[ ! -e "$MANAGER_FINAL_DIR" ]] \
    || { "${SUDO[@]}" rm -rf "$MANAGER_STAGE_DIR"; fail "Manager destination already exists during fresh installation."; }
"${SUDO[@]}" mv "$MANAGER_STAGE_DIR" "$MANAGER_FINAL_DIR" \
    || { "${SUDO[@]}" rm -rf "$MANAGER_STAGE_DIR"; fail "Manager staging activation failed."; }

MANAGER_DIRECTORY_HASH="$(manager_directory_hash "$PYTHON_BIN" "$MANAGER_FINAL_DIR")" \
    || { "${SUDO[@]}" rm -rf "$MANAGER_FINAL_DIR"; fail "Manager final directory integrity hashing failed."; }
MANAGER_PROVENANCE_PATH="$INSTALL_DIR/$MANAGER_PROVENANCE_REL"
if ! manager_write_provenance "$PYTHON_BIN" "$MANAGER_PROVENANCE_PATH" "$MANAGER_FINAL_DIR" "$MANAGER_PLUGIN_VERSION" "$MANAGER_DIRECTORY_HASH"; then
    "${SUDO[@]}" rm -rf "$MANAGER_FINAL_DIR"
    "${SUDO[@]}" rm -f "$MANAGER_PROVENANCE_PATH"
    fail "Manager provenance finalization failed; incomplete Manager installation removed."
fi
manager_write_legacy_marker "$INSTALL_DIR/$MANAGER_RELEASE_MARKER" "$MANAGER_PLUGIN_VERSION" \
    || warn "Legacy release marker could not be written; provenance remains authoritative."

info "Gaming Hub Manager ${MANAGER_RELEASE_TAG} (plugin ${MANAGER_PLUGIN_VERSION}) installed from verified asset ${MANAGER_ASSET_ID}."
info "Verified external-install provenance recorded at ${MANAGER_PROVENANCE_PATH}."

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

# The Nginx image is not built from a Dockerfile, so its UID can be resolved
# the same way as the PHP container's, without starting the stack first.
# Nginx and PHP-FPM commonly come from different base images (Alpine vs.
# Debian, or different upstream images entirely) and do NOT share a UID
# convention, so both must be granted access explicitly.
NGINX_WORKER_UID="$(
    "${DOCKER[@]}" compose run --rm --no-deps --entrypoint sh nginx -c 'id -u nginx' 2>/dev/null \
        | tail -n 1 \
        | tr -d '[:space:]'
)"
[[ "$NGINX_WORKER_UID" =~ ^[0-9]+$ ]] || fail "Could not determine the Nginx worker UID."

"${SUDO[@]}" setfacl -R -m "u:${WWW_UID}:rwX" -m "u:${NGINX_WORKER_UID}:rwX" "$INSTALL_DIR"
"${SUDO[@]}" find "$INSTALL_DIR" -type d -exec setfacl -m "d:u:${WWW_UID}:rwX" -m "d:u:${NGINX_WORKER_UID}:rwX" {} +

info "Azuriom is writable by the PHP container and readable by the Nginx worker without chmod 777."

# -----------------------------------------------------------------------------
# Step 7: Validate and start
# -----------------------------------------------------------------------------
step "Validating and starting containers"

"${DOCKER[@]}" compose config >/dev/null
"${DOCKER[@]}" compose up -d

"${DOCKER[@]}" compose exec -T nginx nginx -t

verify_nginx_worker_read() {
    local container_path="$1"
    "${DOCKER[@]}" compose exec -T --user "$NGINX_WORKER_UID" nginx \
        sh -c 'test -r "$1"' sh "$container_path"
}

http_asset_200() {
    local asset="$1"
    local url="http://127.0.0.1:${APP_PORT}${asset}"
    local code=""
    local attempt

    for attempt in $(seq 1 20); do
        code="$(curl -sS --noproxy '*' --connect-timeout 2 --max-time 5 \
            -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$code" == "200" ]]; then
            info "HTTP 200: ${asset}"
            return 0
        fi
        sleep 1
    done

    fail "Static asset ${asset} returned HTTP ${code:-request-failed}; expected 200."
}

# Root execution is the only world permission intentionally required.
ROOT_MODE="$(stat -c '%a' "$INSTALL_DIR")"
(( (8#${ROOT_MODE} & 1) == 1 )) \
    || fail "${INSTALL_DIR} is not traversable by the Nginx worker (other execute bit missing)."

ENV_MODE="$(stat -c '%a' "$INSTALL_DIR/.env")"
(( (8#${ENV_MODE} & 7) == 0 )) \
    || fail ".env is accessible through world/other permission bits: ${ENV_MODE}."

CREDENTIAL_MODE="$(stat -c '%a' "$CREDENTIAL_FILE")"
[[ "$CREDENTIAL_MODE" == "600" ]] \
    || fail "Credential file permissions changed unexpectedly: ${CREDENTIAL_MODE}; expected 600."

for container_path in \
    /var/www/azuriom/public/index.php \
    /var/www/azuriom/public/build/assets/admin.css \
    /var/www/azuriom/public/build/assets/admin.js \
    /var/www/azuriom/public/assets/svg/azuriom-text-white.svg
do
    verify_nginx_worker_read "$container_path" \
        || fail "Nginx worker UID ${NGINX_WORKER_UID} cannot read ${container_path}."
done

if verify_nginx_worker_read /var/www/azuriom/.env; then
    fail "Nginx worker UID ${NGINX_WORKER_UID} can read the private Azuriom .env file."
fi

"${DOCKER[@]}" compose exec -T app test -f /var/www/azuriom/public/index.php \
    || fail "PHP-FPM cannot see /var/www/azuriom/public/index.php."
"${DOCKER[@]}" compose exec -T --user "$WWW_UID" app \
    sh -c 'test -w /var/www/azuriom/storage && test -w /var/www/azuriom/bootstrap/cache' \
    || fail "PHP www-data UID ${WWW_UID} does not retain required write access."

for asset in \
    /build/assets/admin.css \
    /build/assets/admin.js \
    /assets/svg/azuriom-text-white.svg
do
    http_asset_200 "$asset"
done

if "${DOCKER[@]}" compose logs --no-color nginx 2>&1 | grep -q 'Permission denied'; then
    fail "Nginx log contains a permission-denied error after static-asset verification."
fi

info "Static assets are readable by the Nginx worker and served successfully."

printf 'Verifying permissions survive a Docker Compose restart...\n'
"${DOCKER[@]}" compose restart

for asset in \
    /build/assets/admin.css \
    /build/assets/admin.js \
    /assets/svg/azuriom-text-white.svg
do
    http_asset_200 "$asset"
done

if "${DOCKER[@]}" compose logs --no-color nginx 2>&1 | grep -q 'Permission denied'; then
    fail "Nginx log contains a permission-denied error after Docker Compose restart."
fi

info "Containers restarted and Nginx/PHP permissions verified."

# -----------------------------------------------------------------------------
# Step 8: Finish Azuriom setup
# -----------------------------------------------------------------------------
step "Finishing Azuriom setup"

printf '\nThe Docker installation is ready.\n'
printf 'Azuriom is now being initialized automatically as Gaming Hub Custom Game\n'
printf '(this replaces visiting http://SERVER-IP:%s/, clicking Continue on the\n' "$APP_PORT"
printf 'Azuriom install page, and opening /install/game/custom by hand).\n'

azuriom_custom_game_setup

printf '\nCredentials are stored at:\n'
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

# Asked regardless of the reverse-proxy answer above.
create_admin_login

# Asked regardless of the admin-account answer above.
enable_gaming_hub_manager
