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
INSTANCE_REGISTRY="$BASE_DIR/.gaming-hub-instances"

# Set by resolve_instance() before any of Install/Update/Admin/Uninstall
# run — every use below is a placeholder until then.
INSTANCE=""
APP_PORT=8010
SPA_PORT=5173
PG_PORT=5432
DB_NAME="gaming_hub"
PROJECT_NAME="gaming-hub-dev"
APP_URL="http://localhost:8010"
SPA_URL="http://localhost:5173"
ENV_FILE="$PLATFORM_DIR/.env"
SPA_PID_FILE="$PLATFORM_DIR/spa/.vite-dev.dev.pid"

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

ask_default() {
    local prompt="$1" default_value="$2" answer
    read -r -p "${prompt} [${default_value}]: " answer </dev/tty
    printf '%s' "${answer:-$default_value}"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# In-place set (replacing the first match, appending if absent) — ported
# from the production installer's own helper of the same name.
set_env_value() {
    local file="$1" key="$2" value temporary
    value="$(trim "$3")"
    temporary="$(mktemp)"
    if [[ -f "$file" ]]; then
        awk -v key="$key" -v value="$value" '
            BEGIN { replaced = 0 }
            index($0, key "=") == 1 {
                if (!replaced) { print key "=" value; replaced = 1 }
                next
            }
            { print }
            END { if (!replaced) print key "=" value }
        ' "$file" > "$temporary"
    else
        printf '%s=%s\n' "$key" "$value" > "$temporary"
    fi
    mv "$temporary" "$file"
}

# Runs a noisy, fire-and-forget command (composer/npm/docker/artisan) in the
# background, showing a spinner instead of letting its output scroll by, and
# dumping the captured log only if it fails. Returns the command's real exit
# status so existing "run_step ... || fail '...'" call sites keep their own
# specific error message — this never calls fail() itself.
#
# Not used for commands whose output is actually consumed (git log, curl
# API responses) or that need a real interactive terminal (gaming-hub:admin).
run_step() {
    local description="$1"; shift
    local logfile exit_status=0
    logfile="$(mktemp)"

    ( "$@" ) </dev/null >"$logfile" 2>&1 &
    local pid=$!

    local spin='|/-\' i=0
    printf '%s ' "$description"
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf '\r\033[K%s %s' "$description" "${spin:$i:1}"
        sleep 0.2
    done

    wait "$pid" || exit_status=$?

    if [[ $exit_status -eq 0 ]]; then
        printf '\r\033[K\033[0;32m%s\033[0m done\n' "$description"
    else
        printf '\r\033[K\033[1;31m%s FAILED\033[0m\n' "$description"
        printf '\n--- log: %s ---\n' "$description"
        cat "$logfile"
        printf -- '--- end log ---\n\n'
    fi

    rm -f "$logfile"
    return "$exit_status"
}

COMPOSE_CMD=()
require_docker() {
    command -v docker >/dev/null 2>&1 || fail "Docker is required — install it first: https://docs.docker.com/engine/install/"
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
    else
        fail "Docker Compose is required alongside Docker."
    fi
}

compose() {
    (
        cd "$PLATFORM_DIR" &&
        GAMING_HUB_APP_PORT="$APP_PORT" \
        GAMING_HUB_SPA_PORT="$SPA_PORT" \
        GAMING_HUB_PG_PORT="$PG_PORT" \
        GAMING_HUB_DB_NAME="$DB_NAME" \
        GAMING_HUB_ENV_FILE="$ENV_FILE" \
        "${COMPOSE_CMD[@]}" -p "$PROJECT_NAME" "$@"
    )
}

# Dumps the local dev database to $BACKUP_DIR before a migration is about to
# run. Hard-fails (aborts before touching anything else) rather than
# warning-and-continuing, matching the production installer's
# backup_database() — an update's entire point is "not without a safety
# net." Unlike Uninstall's own best-effort backup prompt (where the user is
# already about to delete everything), there's no "continue anyway" here.
backup_database() {
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"

    step "Backing up database"
    if ! compose exec -T postgres pg_dump -U gaming_hub "$DB_NAME" > "$backup_file" 2>/dev/null; then
        rm -f "$backup_file"
        fail "Database backup failed — aborting before touching anything. Check 'docker compose logs postgres' and try again."
    fi
    if [[ ! -s "$backup_file" ]]; then
        rm -f "$backup_file"
        fail "Database backup produced an empty file — aborting before touching anything. Something is wrong with the database connection; check 'docker compose logs postgres'."
    fi
    info "Backup saved: $backup_file"
}

# Shows commits available in $1's current branch that aren't pulled yet, git
# fetch/log against the real clone — no GitHub API needed (and no rate
# limits to hit) since, unlike the production installer's downloaded release
# zip, this script always has a real .git checkout to diff against directly.
# Returns 0 when there's something to show (or the check itself couldn't run,
# so the caller should attempt the update anyway) and 1 only when confirmed
# already up to date.
check_pending_commits() {
    local dir="$1" label branch ahead
    label="$(basename "$dir")"
    (
        cd "$dir" || { warn "Could not access $dir"; exit 0; }
        branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        if [[ -z "$branch" ]] || ! git fetch --quiet origin "$branch" 2>/dev/null; then
            warn "${label}: could not check for updates (network issue?) — will attempt anyway."
            exit 0
        fi
        ahead="$(git rev-list --count "HEAD..origin/${branch}" 2>/dev/null || echo 0)"
        if [[ "$ahead" -eq 0 ]]; then
            info "${label}: already up to date."
            exit 1
        fi
        info "${label}: ${ahead} commit(s) available:"
        git log --oneline "HEAD..origin/${branch}" | sed -E 's/^/  - /' | head -10
        exit 0
    )
}

# ---------------------------------------------------------------------------
# Multi-instance support — several independent installs from the same
# checkout, each with its own ports/database/Compose project (e.g. "dev",
# "staging", "palworld"). All instances share $PLATFORM_DIR (one codebase,
# bind-mounted into every instance's own containers) — they don't need
# separate git clones, just separate runtime config.
# ---------------------------------------------------------------------------

# Looks up $1's port offset in $INSTANCE_REGISTRY, assigning and persisting
# the next free one (current max + 10, starting at 10) if this name hasn't
# been seen before. 0 is never handed out here — it's permanently reserved
# for "dev" (see resolve_instance), even on a registry that predates this
# feature and has no literal "dev" line in it.
resolve_instance_offset() {
    local name="$1" offset max
    mkdir -p "$BASE_DIR"
    touch "$INSTANCE_REGISTRY"

    offset="$(awk -v n="$name" '$1 == n { print $2; exit }' "$INSTANCE_REGISTRY")"
    if [[ -n "$offset" ]]; then
        printf '%s' "$offset"
        return 0
    fi

    max="$(awk '{ if ($2+0 > m) m = $2+0 } END { print m+0 }' "$INSTANCE_REGISTRY")"
    offset=$(( max < 10 ? 10 : max + 10 ))
    printf '%s %s\n' "$name" "$offset" >> "$INSTANCE_REGISTRY"
    printf '%s' "$offset"
}

# Prompts for an instance name and populates every instance-scoped global
# (APP_PORT, SPA_PORT, PG_PORT, DB_NAME, PROJECT_NAME, APP_URL, SPA_URL,
# ENV_FILE, SPA_PID_FILE) from it. Must run before any of Install/Update/
# Admin/Uninstall touch Docker or .env. $require_existing (pass "yes" from
# Update/Uninstall) fails clearly on a name never seen in the registry
# instead of silently registering a typo as a brand-new instance.
resolve_instance() {
    local require_existing="${1:-no}"

    INSTANCE="$(ask_default "Instance name" "dev")"
    [[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || fail "Instance name must be lowercase letters, digits, and hyphens only (e.g. dev, staging, palworld)."

    if [[ "$require_existing" == "yes" && "$INSTANCE" != "dev" ]]; then
        mkdir -p "$BASE_DIR"; touch "$INSTANCE_REGISTRY"
        grep -q "^${INSTANCE} " "$INSTANCE_REGISTRY" \
            || fail "Instance '${INSTANCE}' was never installed. Known instances: dev $(cut -d' ' -f1 "$INSTANCE_REGISTRY" | tr '\n' ' ')"
    fi

    local offset
    if [[ "$INSTANCE" == "dev" ]]; then
        # The original, pre-multi-instance default: bare .env, bare
        # "gaming_hub" database, offset 0 — matching every install that
        # predates this feature exactly, so nothing already running under
        # plain "dev" needs any migration.
        offset=0
        ENV_FILE="$PLATFORM_DIR/.env"
        DB_NAME="gaming_hub"
    else
        offset="$(resolve_instance_offset "$INSTANCE")"
        ENV_FILE="$PLATFORM_DIR/.env.${INSTANCE}"
        DB_NAME="gaming_hub_${INSTANCE}"
    fi

    APP_PORT=$((8010 + offset))
    SPA_PORT=$((5173 + offset))
    PG_PORT=$((5432 + offset))
    PROJECT_NAME="gaming-hub-${INSTANCE}"
    APP_URL="http://localhost:${APP_PORT}"
    SPA_URL="http://localhost:${SPA_PORT}"
    SPA_PID_FILE="$PLATFORM_DIR/spa/.vite-dev.${INSTANCE}.pid"

    info "Instance '${INSTANCE}': app=${APP_PORT} spa=${SPA_PORT} db=${DB_NAME} project=${PROJECT_NAME}"
}

# ---------------------------------------------------------------------------
# SPA dev server (spa/, separate Vite + React project — see Priority 16B)
# ---------------------------------------------------------------------------

# The PID file is written INSIDE the container at /app/spa/.vite-dev.pid,
# which the bind mount makes visible here at $SPA_PID_FILE too. Checking
# liveness still has to go back through the container, though: the PID it
# names is only meaningful inside the container's own PID namespace, not on
# the host. kill -0 is a shell builtin in sh/dash/bash alike, so this needs
# no ps/pkill binary — neither exists in the app image.
#
# The captured PID is a setsid process-group leader, not just npm's own
# wrapper PID — confirmed by testing that a plain "npm run dev &" followed
# by "kill $!" only ever killed npm itself. npm run dev spawns a further sh
# -c 'vite ...' child, which spawns the actual node/vite process serving
# the port two layers down; killing just the top PID left that real server
# alive and still bound to 5173. setsid at launch makes the whole chain one
# process group, so killing the negative PID (the group) takes all of it
# down together instead of orphaning the actual server underneath.
# File names are per-instance ($INSTANCE) even though every instance's
# container bind-mounts the same shared $PLATFORM_DIR/spa — without that,
# two instances' containers would collide on the exact same host path for
# their own separate dev-server processes.
spa_is_running() {
    [[ -f "$SPA_PID_FILE" ]] || return 1
    compose exec -T app sh -c "kill -0 \"\$(cat /app/spa/.vite-dev.${INSTANCE}.pid)\" 2>/dev/null" </dev/null
}

spa_stop() {
    if [[ -f "$SPA_PID_FILE" ]]; then
        compose exec -T app sh -c "kill -- -\"\$(cat /app/spa/.vite-dev.${INSTANCE}.pid)\" 2>/dev/null || true" </dev/null
        rm -f "$SPA_PID_FILE"
    fi
}

spa_start() {
    run_step "Installing SPA dependencies (npm ci)" compose exec -T -w /app/spa app npm ci

    step "Starting the SPA dev server"
    local attempt ready="no"
    for attempt in 1 2; do
        # VITE_API_BASE_URL points this instance's SPA at its own backend
        # port — without it the client.ts default (localhost:8010) would
        # have every instance's SPA calling the "dev" instance's API.
        compose exec -d -w /app/spa app sh -c \
            "VITE_API_BASE_URL=${APP_URL} setsid npm run dev -- --host 0.0.0.0 > vite-dev.${INSTANCE}.log 2>&1 < /dev/null & echo \$! > .vite-dev.${INSTANCE}.pid"

        for _ in $(seq 1 15); do
            if curl -fsS -o /dev/null "$SPA_URL" 2>/dev/null; then
                ready="yes"
                break
            fi
            sleep 1
        done
        [[ "$ready" == "yes" ]] && break
        # A detached `exec -d` launch has occasionally not taken — seen
        # once as its shell becoming a zombie with an empty log, no
        # npm/vite process ever actually starting. Not reproduced when
        # spa_start is called on its own outside a fresh-install run, so
        # this looks like a transient exec timing issue rather than a
        # logic bug; one retry is cheap insurance against it either way.
        [[ "$attempt" -eq 1 ]] && warn "First attempt to start the SPA dev server didn't respond — retrying once."
    done

    if [[ "$ready" == "yes" ]]; then
        info "SPA dev server running: $SPA_URL"
    else
        warn "SPA dev server did not respond after 2 attempts — check: docker compose exec app cat spa/vite-dev.${INSTANCE}.log"
    fi
}

# ---------------------------------------------------------------------------
# Option 1: Install
# ---------------------------------------------------------------------------
install_gaming_hub() {
    resolve_instance
    require_docker
    mkdir -p "$BASE_DIR"

    # "Existing" is per-instance, not per-checkout: the codebase at
    # $PLATFORM_DIR is shared across every instance, but each instance's
    # own .env file only exists once that specific instance has actually
    # been installed before.
    if [[ -f "$ENV_FILE" ]]; then
        step "Existing install detected"
        if ! ask_yes_no "An existing '${INSTANCE}' install was found. Preserve its existing data?" "y"; then
            printf '\nThis permanently deletes the local database and everything in it.\n'
            printf 'Type WIPE to confirm, anything else to cancel: '
            read -r confirmation </dev/tty
            [[ "$confirmation" == "WIPE" ]] || fail "Cancelled — nothing was changed."
            step "Wiping existing data"
            # Scoped to this instance only — compose() always passes -p
            # "$PROJECT_NAME", so this can never touch another instance's
            # containers/volume even though they share the same checkout.
            compose down --volumes 2>/dev/null || true
            info "Existing data wiped."
        fi
    fi

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
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$PLATFORM_DIR/.env.example" "$ENV_FILE"
    else
        info "$(basename "$ENV_FILE") already exists — leaving it untouched."
    fi

    step "Configuring .env for local development"
    # .env.example ships placeholder values meant for the production
    # installer's real-domain case (example.com) — copying those as-is
    # here breaks session-cookie auth outright, since the cookie's Domain
    # attribute would never match the host the browser actually connected
    # to. Local dev is always plain http://localhost, so there's no
    # legitimate case where these three should be anything else — always
    # correct them, whether .env was just freshly copied or already
    # existed (self-heals a previously-broken install too).
    set_env_value "$ENV_FILE" APP_URL "$APP_URL"
    set_env_value "$ENV_FILE" SESSION_DOMAIN "localhost"
    set_env_value "$ENV_FILE" SANCTUM_STATEFUL_DOMAINS "localhost:${APP_PORT},localhost:${SPA_PORT}"
    # docker-compose.yml's environment: block sets DB_DATABASE too, but that
    # never reaches actual HTTP requests: "php artisan serve" spawns the
    # real request-handling "php -S" child with a minimal, hardcoded env
    # (just APP_ENV/PATH — confirmed via /proc/<pid>/environ), not the
    # container's full environment. That child falls back to whatever
    # DB_DATABASE is written in this file, so it has to be correct here too
    # — otherwise every instance except the one whose file happens to
    # already say "gaming_hub" silently serves requests against the wrong
    # database while artisan/tinker/migrate (no serve subprocess involved)
    # look completely fine.
    set_env_value "$ENV_FILE" DB_DATABASE "$DB_NAME"

    step "Starting Docker Compose (instance '${INSTANCE}', port ${APP_PORT})"
    # --force-recreate on app/scheduler specifically: this file mount only
    # takes effect at container-creation time. A plain "up -d" against an
    # already-running container (the common case when re-running Install
    # over an existing checkout) does nothing to an unchanged container —
    # confirmed by hitting exactly this while fixing the .env bug above:
    # editing the file and even restarting the app inside the container
    # left the stale mount/env in place until the container itself was
    # recreated. postgres is deliberately left out of the force-recreate —
    # these env changes don't concern it, and recreating it unnecessarily
    # risks its own startup/connection dance.
    run_step "docker compose up -d" compose up -d
    run_step "recreating app/scheduler for the current .env" compose up -d --force-recreate app scheduler

    step "Installing PHP dependencies"
    run_step "composer install" compose run --rm app composer install

    step "Building frontend assets"
    run_step "npm install" compose run --rm -e HOME=/tmp app npm install
    run_step "npm run build" compose run --rm -e HOME=/tmp app npm run build

    step "Setting the application key (if not already set)"
    if ! grep -q '^APP_KEY=base64:' "$ENV_FILE" 2>/dev/null; then
        run_step "php artisan key:generate" compose run --rm app php artisan key:generate --force
    fi

    step "Running migrations"
    run_step "php artisan migrate" compose run --rm app php artisan migrate --force

    step "Seeding the database"
    # DatabaseSeeder creates roles and the capability vocabulary only — it
    # deliberately creates no user. A hardcoded, publicly-known default
    # admin account is a real vulnerability, not a convenience.
    run_step "php artisan db:seed" compose run --rm app php artisan db:seed --force

    step "SPA dev server"
    if spa_is_running; then
        info "SPA dev server already running: $SPA_URL"
    else
        spa_start
    fi

    step "Administrator account"
    if ask_yes_no "Create an administrator account now?" "y"; then
        # gaming-hub:admin prompts for name/email/password itself — no
        # separate prompt logic needed here, and no plaintext password
        # ends up in shell history this way. Deliberately NOT run through
        # run_step: it's interactive, and backgrounding it would hide its
        # prompts entirely.
        compose run --rm app php artisan gaming-hub:admin
    else
        info "Skipped — run this later to create one: docker compose run --rm app php artisan gaming-hub:admin"
    fi

    echo
    info "Install complete — instance '${INSTANCE}'."
    echo "  App:   $APP_URL"
    echo "  Admin: $APP_URL/admin"
    echo "  SPA:   $SPA_URL"
}

# ---------------------------------------------------------------------------
# Option 2: Update
# ---------------------------------------------------------------------------
update_gaming_hub() {
    resolve_instance "yes"
    require_docker
    [[ -d "$PLATFORM_DIR/.git" ]] || fail "gaming-hub isn't installed at $PLATFORM_DIR — run Install first."
    [[ -f "$ENV_FILE" ]] || fail "Instance '${INSTANCE}' is registered but has no $(basename "$ENV_FILE") — run Install for it first."

    step "Checking for updates"
    local platform_pending="no" core_pending="no"
    check_pending_commits "$PLATFORM_DIR" && platform_pending="yes"
    if [[ -d "$CORE_DIR/.git" ]]; then
        check_pending_commits "$CORE_DIR" && core_pending="yes"
    fi

    if [[ "$platform_pending" == "no" && "$core_pending" == "no" ]]; then
        printf '\n\033[1;32mNothing to update.\033[0m\n'
        exit 0
    fi

    ask_yes_no "Proceed with update?" "y" || fail "Update cancelled."

    backup_database

    step "Pulling latest code"
    (cd "$PLATFORM_DIR" && git pull --ff-only)
    if [[ -d "$CORE_DIR/.git" ]]; then
        (cd "$CORE_DIR" && git pull --ff-only)
    fi

    step "Updating PHP dependencies"
    run_step "composer install" compose run --rm app composer install
    # gaming-hub tracks gaminghubproject/core via its own dev-main branch,
    # not a version constraint composer install alone would bump — a plain
    # install only ever honours what's already in composer.lock. This is
    # the one explicit step that actually pulls in newer Core commits.
    run_step "composer update gaminghubproject/core" compose run --rm app composer update gaminghubproject/core --no-interaction

    step "Rebuilding frontend assets"
    run_step "npm install" compose run --rm -e HOME=/tmp app npm install
    run_step "npm run build" compose run --rm -e HOME=/tmp app npm run build

    step "Running migrations"
    run_step "php artisan migrate" compose run --rm app php artisan migrate --force

    step "Configuring .env for local development"
    # Self-heals an install from before this fix existed — same reasoning
    # as the Install flow's own copy of this step.
    set_env_value "$ENV_FILE" APP_URL "$APP_URL"
    set_env_value "$ENV_FILE" SESSION_DOMAIN "localhost"
    set_env_value "$ENV_FILE" SANCTUM_STATEFUL_DOMAINS "localhost:${APP_PORT},localhost:${SPA_PORT}"
    set_env_value "$ENV_FILE" DB_DATABASE "$DB_NAME"

    step "Restarting Docker Compose"
    # down + up (not just up -d) recreates every container, which is also
    # what makes docker-compose.yml's env_file directive actually pick up
    # the .env values just written above — an already-running container
    # keeps whatever it was created with regardless of file edits.
    run_step "docker compose down" compose down
    run_step "docker compose up -d" compose up -d

    step "Restarting the SPA dev server"
    # Always restart on Update, not just "start if not running" — the pull
    # above may have changed spa/package.json, and a running Vite process
    # won't pick up newly installed dependencies on its own.
    spa_stop
    spa_start

    echo
    info "Update complete — instance '${INSTANCE}' — $APP_URL"
    info "SPA: $SPA_URL"
}

# ---------------------------------------------------------------------------
# Option 3: Create admin account
# ---------------------------------------------------------------------------
create_admin() {
    resolve_instance "yes"
    require_docker
    [[ -f "$ENV_FILE" ]] || fail "Instance '${INSTANCE}' isn't installed — run Install first."

    step "Create or promote an administrator account (instance '${INSTANCE}')"
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
    resolve_instance "yes"
    require_docker
    [[ -d "$PLATFORM_DIR" ]] || fail "Nothing found at $PLATFORM_DIR."

    if ask_yes_no "Back up the '${INSTANCE}' database before uninstalling?" "y"; then
        mkdir -p "$BACKUP_DIR"
        local backup_file="$BACKUP_DIR/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"
        step "Backing up database to $backup_file"
        if compose exec -T postgres pg_dump -U gaming_hub "$DB_NAME" > "$backup_file"; then
            info "Backup saved: $backup_file"
        else
            warn "Backup failed (is the postgres container running?) — continuing anyway."
            rm -f "$backup_file"
        fi
    fi

    echo
    printf 'Type UNINSTALL to confirm removing the "%s" instance'"'"'s Docker containers, anything else to cancel: ' "$INSTANCE"
    read -r confirmation </dev/tty
    [[ "$confirmation" == "UNINSTALL" ]] || fail "Uninstall cancelled — nothing was changed."

    step "Removing Docker containers (instance '${INSTANCE}')"
    if ask_yes_no "Also delete the database volume? This permanently destroys all data not backed up above." "n"; then
        compose down --volumes
    else
        compose down
    fi

    if [[ "$INSTANCE" != "dev" ]]; then
        mkdir -p "$BASE_DIR"; touch "$INSTANCE_REGISTRY"
        grep -v "^${INSTANCE} " "$INSTANCE_REGISTRY" > "${INSTANCE_REGISTRY}.tmp" 2>/dev/null || true
        mv "${INSTANCE_REGISTRY}.tmp" "$INSTANCE_REGISTRY"
        rm -f "$ENV_FILE"
        info "Removed instance '${INSTANCE}' from the registry and deleted $(basename "$ENV_FILE")."
    fi

    echo
    info "Docker containers removed."
    echo "Source code at $PLATFORM_DIR and $CORE_DIR is shared across every instance and was left in place."
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

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main
fi
