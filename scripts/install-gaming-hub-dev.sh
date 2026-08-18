#!/usr/bin/env bash
# Gaming Hub Platform — local dev installer
# https://github.com/GamingHubProject/GamingHub
#
# Interactive menu for setting up/updating/tearing down a LOCAL, HTTP-only
# Docker Compose dev stack from git clones of gaming-hub + gaming-hub-core.
# This is deliberately not the production installer — that one lives in
# the Registry repo (scripts/install-gaming-hub.sh), downloads tagged
# release zips instead of git-cloning, builds the self-contained
# Dockerfile.prod image, and sets up Caddy/HTTPS. This script exists
# because none of that applies to iterating on a local checkout.
#
# Usage: ./install-gaming-hub-dev.sh

set -Eeuo pipefail

BASE_DIR="${GAMING_HUB_BASE_DIR:-$HOME/Documents/ClaudeCode}"
PLATFORM_DIR="$BASE_DIR/gaming-hub"
CORE_DIR="$BASE_DIR/gaming-hub-core"
PLATFORM_REPO="https://github.com/GamingHubProject/GamingHub.git"
CORE_REPO="https://github.com/GamingHubProject/Core.git"
BACKUP_DIR="$BASE_DIR/gaming-hub-backups"
APP_URL="http://localhost:8010"

info()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$1"; }
fail()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }
step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

ask_yes_no() {
    local prompt="$1" default_answer="${2:-y}" answer
    local suffix="[Y/n]"
    [[ "$default_answer" == "n" ]] && suffix="[y/N]"
    read -r -p "${prompt} ${suffix}: " answer </dev/tty
    answer="${answer:-$default_answer}"
    [[ "$answer" =~ ^[Yy] ]]
}

require_docker() {
    command -v docker >/dev/null 2>&1 || fail "Docker is required — install it first: https://docs.docker.com/engine/install/"
    command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1 \
        || fail "Docker Compose is required alongside Docker."
}

compose() {
    (cd "$PLATFORM_DIR" && docker-compose "$@")
}

# ---------------------------------------------------------------------------
# Option 1: Install
# ---------------------------------------------------------------------------
install_gaming_hub() {
    require_docker
    mkdir -p "$BASE_DIR"

    step "Cloning repositories"
    if [[ -d "$PLATFORM_DIR/.git" ]]; then
        info "gaming-hub already cloned at $PLATFORM_DIR — leaving it as-is (use Update instead)."
    else
        git clone "$PLATFORM_REPO" "$PLATFORM_DIR"
    fi
    if [[ -d "$CORE_DIR/.git" ]]; then
        info "gaming-hub-core already cloned at $CORE_DIR — leaving it as-is."
    else
        git clone "$CORE_REPO" "$CORE_DIR"
    fi

    step "Preparing .env"
    if [[ ! -f "$PLATFORM_DIR/.env" ]]; then
        cp "$PLATFORM_DIR/.env.example" "$PLATFORM_DIR/.env"
    else
        info ".env already exists — leaving it untouched."
    fi

    step "Starting Docker Compose (HTTP only, port 8010)"
    compose up -d

    step "Installing PHP dependencies"
    compose run --rm app composer install

    step "Building frontend assets"
    compose run --rm -e HOME=/tmp app npm install
    compose run --rm -e HOME=/tmp app npm run build

    step "Setting the application key (if not already set)"
    if ! grep -q '^APP_KEY=base64:' "$PLATFORM_DIR/.env" 2>/dev/null; then
        compose run --rm app php artisan key:generate --force
    fi

    step "Running migrations"
    compose run --rm app php artisan migrate --force

    step "Seeding the database"
    # DatabaseSeeder creates roles and the capability vocabulary only — it
    # deliberately creates no user. A hardcoded, publicly-known default
    # admin account is a real vulnerability, not a convenience.
    compose run --rm app php artisan db:seed --force

    step "Administrator account"
    if ask_yes_no "Create an administrator account now?" "y"; then
        # gaming-hub:admin prompts for name/email/password itself — no
        # separate prompt logic needed here, and no plaintext password
        # ends up in shell history this way.
        compose run --rm app php artisan gaming-hub:admin
    else
        info "Skipped — run this later to create one: docker-compose run --rm app php artisan gaming-hub:admin"
    fi

    echo
    info "Install complete."
    echo "  App:   $APP_URL"
    echo "  Admin: $APP_URL/admin"
}

# ---------------------------------------------------------------------------
# Option 2: Update
# ---------------------------------------------------------------------------
update_gaming_hub() {
    require_docker
    [[ -d "$PLATFORM_DIR/.git" ]] || fail "gaming-hub isn't installed at $PLATFORM_DIR — run Install first."

    step "Pulling latest code"
    (cd "$PLATFORM_DIR" && git pull --ff-only)
    if [[ -d "$CORE_DIR/.git" ]]; then
        (cd "$CORE_DIR" && git pull --ff-only)
    fi

    step "Updating PHP dependencies"
    compose run --rm app composer install
    # gaming-hub tracks gaminghubproject/core via its own dev-main branch,
    # not a version constraint composer install alone would bump — a plain
    # install only ever honours what's already in composer.lock. This is
    # the one explicit step that actually pulls in newer Core commits.
    compose run --rm app composer update gaminghubproject/core --no-interaction

    step "Rebuilding frontend assets"
    compose run --rm -e HOME=/tmp app npm install
    compose run --rm -e HOME=/tmp app npm run build

    step "Running migrations"
    compose run --rm app php artisan migrate --force

    step "Restarting Docker Compose"
    compose down
    compose up -d

    echo
    info "Update complete — $APP_URL"
}

# ---------------------------------------------------------------------------
# Option 3: Create admin account
# ---------------------------------------------------------------------------
create_admin() {
    require_docker
    [[ -d "$PLATFORM_DIR/.git" ]] || fail "gaming-hub isn't installed at $PLATFORM_DIR — run Install first."

    step "Create or promote an administrator account"
    # gaming-hub:admin prompts for name/email/password itself and re-running
    # it against an existing email promotes that account to Admin instead
    # of creating a duplicate — reusing it here instead of re-implementing
    # prompts (and risking a plaintext password ending up in shell history).
    compose run --rm app php artisan gaming-hub:admin
}

# ---------------------------------------------------------------------------
# Option 4: HTTPS
# ---------------------------------------------------------------------------
setup_https() {
    warn "Skipping — this installer is for local HTTP-only development."
    echo "For a real domain with automatic HTTPS, use the production installer instead:"
    echo "  curl -fsSL https://raw.githubusercontent.com/GamingHubProject/Registry/main/scripts/install-gaming-hub.sh | bash"
}

# ---------------------------------------------------------------------------
# Option 5: Uninstall
# ---------------------------------------------------------------------------
uninstall_gaming_hub() {
    require_docker
    [[ -d "$PLATFORM_DIR" ]] || fail "Nothing found at $PLATFORM_DIR."

    if ask_yes_no "Back up the database before uninstalling?" "y"; then
        mkdir -p "$BACKUP_DIR"
        local backup_file="$BACKUP_DIR/gaming_hub_$(date +%Y%m%d_%H%M%S).sql"
        step "Backing up database to $backup_file"
        if compose exec -T postgres pg_dump -U gaming_hub gaming_hub > "$backup_file"; then
            info "Backup saved: $backup_file"
        else
            warn "Backup failed (is the postgres container running?) — continuing anyway."
            rm -f "$backup_file"
        fi
    fi

    echo
    printf 'Type UNINSTALL to confirm removing the Docker containers, anything else to cancel: '
    read -r confirmation </dev/tty
    [[ "$confirmation" == "UNINSTALL" ]] || fail "Uninstall cancelled — nothing was changed."

    step "Removing Docker containers"
    if ask_yes_no "Also delete the database volume? This permanently destroys all data not backed up above." "n"; then
        compose down --volumes
    else
        compose down
    fi

    echo
    info "Docker containers removed."
    echo "Source code at $PLATFORM_DIR and $CORE_DIR was left in place — delete those directories yourself if you want them gone too."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main() {
    cat <<'EOF'
Gaming Hub Platform — Setup

1. Install (fresh)
2. Update (existing)
3. Create admin account
4. Setup HTTPS (skip for local)
5. Uninstall

EOF
    read -r -p "Select: " choice </dev/tty

    case "$choice" in
        1) install_gaming_hub ;;
        2) update_gaming_hub ;;
        3) create_admin ;;
        4) setup_https ;;
        5) uninstall_gaming_hub ;;
        *) fail "Invalid selection." ;;
    esac
}

main
