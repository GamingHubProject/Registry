#!/usr/bin/env bash
# Gaming Hub Platform installer
# https://github.com/GamingHubProject/GamingHub
#
# Downloads a release of the standalone Gaming Hub platform, builds the
# self-contained production Docker image (Dockerfile.prod — no bind mount,
# no manual composer/npm step), starts it against PostgreSQL, optionally
# fronts it with a Caddy reverse proxy for a domain with automatic HTTPS,
# and creates the first administrator account.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/GamingHubProject/Registry/main/scripts/install-gaming-hub.sh | bash
# or download it first and run it locally — recommended if you want to read
# it before piping it into a shell, which is always a reasonable thing to do.

set -Eeuo pipefail

INSTALLER_VERSION="0.1.003"
REPO_OWNER="GamingHubProject"
REPO_NAME="GamingHub"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
DEFAULT_INSTALL_DIR="/opt/gaming-hub"
CADDY_IMAGE="caddy:2.11.4-alpine"
COMPOSE_BASE="docker-compose.prod.yml"
COMPOSE_CADDY_FILE="docker-compose.caddy.yml"
CADDY_CONFIG_DIR="docker/caddy"
DOMAIN_CONFIG_FILE=".gaming-hub-domain"
INSTALLED_REF_FILE=".gaming-hub-installed-ref"

STEP=0
TOTAL_STEPS=9

step() {
    STEP=$((STEP + 1))
    printf '\n\033[1;36m[%s/%s] %s\033[0m\n' "$STEP" "$TOTAL_STEPS" "$1"
}

info() { printf '\033[0;32m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# Every prompt below reads from /dev/tty rather than stdin specifically
# so `curl ... | bash` still works from a real interactive terminal (the
# pipe consumes stdin, but /dev/tty is still the human's keyboard). That
# same design means an unattended run — no controlling terminal at all
# (an agent, cron, CI) — can't be detected by checking stdin; /dev/tty
# itself has to be probed. Confirmed for real: opening it outright fails
# ("No such device or address") in exactly that unattended case, so this
# is computed once, up front, rather than re-checked per prompt.
if exec 3<>/dev/tty 2>/dev/null; then
    HAS_TTY=1
    exec 3<&-
else
    HAS_TTY=0
fi

ask_default() {
    local prompt="$1" default_value="$2" answer
    read -r -p "${prompt} [${default_value}]: " answer </dev/tty
    printf '%s' "${answer:-$default_value}"
}

ask_yes_no() {
    local prompt="$1" default_answer="${2:-y}" answer
    local suffix="[Y/n]"
    [[ "$default_answer" == "n" ]] && suffix="[y/N]"
    read -r -p "${prompt} ${suffix}: " answer </dev/tty
    answer="${answer:-$default_answer}"
    [[ "$answer" =~ ^[Yy] ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

random_secret() {
    local length="${1:-32}"
    if command_exists openssl; then
        openssl rand -hex "$length"
    else
        head -c "$length" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

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

get_env_value() {
    local file="$1" key="$2" value
    [[ -f "$file" ]] || return 0
    value="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file")"
    # Trim whitespace unconditionally — this also self-heals values that were
    # written with a stray leading space by older, buggy versions of this
    # installer (e.g. "DB_USERNAME= gaming_hub" baked into an existing .env).
    value="$(trim "$value")"
    # Normalize away one layer of surrounding double quotes, regardless of
    # whether the value was originally stored quoted or bare.
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:-1}"
        value="$(trim "$value")"
    fi
    printf '%s' "$value"
}

# Sets the global COMPOSE_ARGS array to the explicit -f flags for this
# install. Every "docker compose" call must use "${COMPOSE_ARGS[@]}" instead
# of a bare --env-file .env — a downloaded install directory contains BOTH
# docker-compose.yml (dev) and docker-compose.prod.yml (prod, what this
# script actually builds/runs), and without an explicit -f, Compose's
# default file-discovery silently picks the dev one: wrong image, a
# hardcoded dev DB password, and a bind mount over the built image. That
# mismatch crashes the app container the moment its entrypoint tries to
# migrate with the wrong credentials — the exact "container ... is not
# running" failure this fixes.
compose_args() {
    # -p ties every "docker compose" call to this specific instance's own
    # project — without it, two installs on the same host (e.g. this
    # default "prod" one and a second "staging" instance elsewhere) would
    # collide on Compose's own default project naming and could end up
    # sharing containers, volumes, or even each other's built image.
    # GAMING_HUB_INSTANCE is always set by this point — either prompted
    # fresh (Install) or read back out of an existing install's own .env
    # (require_existing_install) — but the "prod" fallback still covers a
    # pre-existing install from before this variable existed.
    COMPOSE_ARGS=(-p "gaming-hub-${GAMING_HUB_INSTANCE:-prod}" -f "$COMPOSE_BASE")
    if [[ -f "$DOMAIN_CONFIG_FILE" ]]; then
        COMPOSE_ARGS+=(-f "$COMPOSE_CADDY_FILE")
    fi
}

SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
    command_exists sudo || fail "This installer needs root privileges (or sudo) to install packages and manage Docker."
    SUDO=(sudo)
fi

DOCKER=()
find_docker_command() {
    if command_exists docker; then
        DOCKER=(docker)
        return 0
    fi
    return 1
}

require_existing_install() {
    INSTALL_DIR="$(ask_default "Install directory" "$DEFAULT_INSTALL_DIR")"
    if [[ ! -f "${INSTALL_DIR}/.env" || ! -f "${INSTALL_DIR}/${COMPOSE_BASE}" ]]; then
        fail "No existing Gaming Hub installation found at ${INSTALL_DIR}. Use 'Install or reinstall' first."
    fi
    cd "$INSTALL_DIR"
    # Read back rather than re-prompt — the instance identity was fixed
    # when this directory was first installed (see "Writing configuration"),
    # so Update/HTTPS/admin/Uninstall always target the right one without
    # asking again. "prod" covers an install from before this existed.
    GAMING_HUB_INSTANCE="$(get_env_value .env GAMING_HUB_INSTANCE)"
    export GAMING_HUB_INSTANCE="${GAMING_HUB_INSTANCE:-prod}"
    info "Instance: ${GAMING_HUB_INSTANCE}"
}

# GitHub's /tags API sorts by tag NAME lexicographically, not by creation
# date or version magnitude — confirmed live while migrating to the
# X.Y.ZZZ.NN scheme: a deliberate renumbering means a new-scheme tag's
# leading segments are numerically *smaller* than the old X.Y.Z scheme's
# (e.g. v0.1.006.00 vs. the old v0.6.000), and the API's raw ordering put
# the old scheme's tags first — silently resolving "latest" to a stale
# version. A pure numeric/semver sort across *both* schemes can't fix this
# either: the whole point of a renumbering is that old and new numbers
# aren't meant to compare monotonically. What's actually true is that
# every new-scheme tag was created after every old-scheme one (the
# renumbering happens once; from here on only new-scheme tags get cut) —
# so this prefers any 4-segment (new scheme) tag over every 3-segment (old
# scheme) one, falling back to the old scheme only if no new-scheme tag
# exists yet (e.g. an older copy of this script pointed at an old commit).
# Within each group, `sort -V` (GNU version sort) correctly ranks
# purely-numeric dot-separated tags — verified against the real mixed
# tag list this migration produced, not assumed.
latest_tag() {
    local all_tags new_scheme old_scheme
    all_tags="$(curl -fsSL --proto '=https' \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/tags?per_page=100" 2>/dev/null \
        | grep -o '"name": *"[^"]*"' | sed -E 's/"name": *"//; s/"$//' || true)"

    [[ -z "$all_tags" ]] && return 1

    new_scheme="$(printf '%s\n' "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
    if [[ -n "$new_scheme" ]]; then
        printf '%s' "$new_scheme"
        return 0
    fi

    old_scheme="$(printf '%s\n' "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
    [[ -n "$old_scheme" ]] && printf '%s' "$old_scheme"
}

resolve_ref() {
    local choice="$1"
    if [[ "$choice" == "latest" ]]; then
        LATEST_TAG="$(latest_tag)"
        if [[ -n "${LATEST_TAG:-}" ]]; then
            REF="$LATEST_TAG"
            REF_KIND="tags"
        else
            warn "Could not resolve the latest tag from GitHub's API (rate limited?). Falling back to 'main'."
            REF="main"
            REF_KIND="heads"
        fi
    else
        REF="$choice"
        # Best-effort: try it as a tag first, fall back to branch at download time.
        REF_KIND="tags"
    fi
    info "Using ${REF} (${REF_KIND})."
}

# Reads back the ref this installer recorded after its last successful
# install/update at $INSTALL_DIR — empty if none was ever recorded (a
# fresh directory, or an install done by a version of this script that
# predates this file). Never fails; absence just means "no comparison
# possible," not an error.
#
# The file holds two lines: the ref name, then the commit SHA it resolved
# to at the time (added by record_installed_ref below, to catch a tag
# later being force-moved to a different commit while keeping its name —
# see show_version_diff). A file from an older version of this script has
# only the first line; the SHA line is then simply empty, handled as
# "unknown" rather than an error.
read_installed_ref() {
    if [[ -f "$INSTALLED_REF_FILE" ]]; then
        sed -n '1p' "$INSTALLED_REF_FILE" 2>/dev/null || true
    fi
}

read_installed_ref_sha() {
    if [[ -f "$INSTALLED_REF_FILE" ]]; then
        sed -n '2p' "$INSTALLED_REF_FILE" 2>/dev/null || true
    fi
}

record_installed_ref() {
    local ref="$1" sha
    sha="$(resolve_ref_sha "$ref")"
    printf '%s\n%s\n' "$ref" "$sha" > "$INSTALLED_REF_FILE"
}

# Resolves a tag/branch/SHA to the commit SHA it currently points at right
# now, via GitHub's Commits API — unlike a raw git ref, this transparently
# peels an annotated tag to its underlying commit, so it works the same
# for lightweight and annotated tags alike. Empty output means "couldn't
# resolve" (rate limited, ref doesn't exist, network down); callers must
# treat that as inconclusive, not as an equality/inequality answer.
resolve_ref_sha() {
    local ref="$1"
    curl -fsSL --proto '=https' \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${ref}" 2>/dev/null \
        | grep -m1 '"sha"' | sed -E 's/[^"]*"sha": *"([^"]*)".*/\1/' || true
}

# Shows what's actually different between the currently-installed ref and
# the one about to be installed, using GitHub's real Compare API rather
# than guessing — there's no local .git checkout in a downloaded release
# directory to diff against directly. Prints a short preview and returns
# 1 (nothing to do) when both refs are identical, so the caller can skip
# the rest of the update cleanly instead of re-downloading and rebuilding
# for no reason.
show_version_diff() {
    local previous="$1" target="$2"

    if [[ -z "$previous" ]]; then
        info "No previously recorded version at this install — proceeding to ${target} without a comparison."
        return 0
    fi

    if [[ "$previous" == "$target" ]]; then
        # A matching ref *name* isn't proof there's nothing to update — a
        # tag can be force-moved to point at a different commit (e.g.
        # correcting a missed deployment, exactly what happened to
        # v0.1.006.01) while keeping its name. Resolving $previous by name
        # here would just re-resolve to the tag's *current* (post-move)
        # commit — same problem, one level down — so this instead reads
        # back the commit SHA actually recorded at the last successful
        # install/update (read_installed_ref_sha) and compares that
        # against what the target ref resolves to right now.
        local previous_sha target_sha
        previous_sha="$(read_installed_ref_sha)"
        target_sha="$(resolve_ref_sha "$target")"

        if [[ -z "$previous_sha" ]]; then
            warn "No commit was recorded for the current install (it predates this check) — trusting the name match."
            info "Already on ${target} — nothing to update."
            return 1
        fi

        if [[ -z "$target_sha" ]]; then
            warn "Could not resolve ${target} to a commit to check for a re-pointed tag (rate limited?) — trusting the name match."
            info "Already on ${target} — nothing to update."
            return 1
        fi

        if [[ "$previous_sha" == "$target_sha" ]]; then
            info "Already on ${target} — nothing to update."
            return 1
        fi

        info "${target} now points at a different commit than what's installed — the tag was re-pointed. Treating this as an update."
        # From here on, compare against the actual commit that was
        # installed, not the ref name (which now resolves to the *new*
        # commit and would make the diff below compare a ref against
        # itself).
        previous="$previous_sha"
    fi

    info "Currently installed: ${previous}"
    info "Available:           ${target}"

    local compare ahead_by
    compare="$(curl -fsSL --proto '=https' \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/compare/${previous}...${target}" 2>/dev/null || true)"

    if [[ -z "$compare" ]]; then
        warn "Could not reach GitHub's compare API — proceeding without a change preview."
        return 0
    fi

    ahead_by="$(printf '%s' "$compare" | grep -m1 '"ahead_by"' | sed -E 's/[^0-9]*([0-9]+).*/\1/' || true)"
    if [[ -z "$ahead_by" ]]; then
        warn "Could not parse the compare response (rate limited?) — proceeding without a change preview."
        return 0
    fi

    info "${ahead_by} commit(s) ahead of your current install:"
    # Commit messages come back as JSON strings with literal \n escapes for
    # real newlines, not actual line breaks — a multi-paragraph commit body
    # would otherwise print with raw "\n\n" characters cluttering the
    # preview. Cutting at the first \n keeps just the subject line, which
    # is also all that fits usefully in a one-line bullet anyway.
    printf '%s' "$compare" \
        | grep -o '"message": *"[^"]*"' \
        | sed -E 's/"message": *"//; s/"$//; s/\\n.*//' \
        | sed -E 's/^/  - /; s/^(.{0,90}).*/\1/' \
        | head -10
    return 0
}

download_ref() {
    local kind="$1" ref="$2" url out
    url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/${kind}/${ref}.zip"
    out="${TMP_DIR}/source.zip"
    curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-delay 2 \
        -o "$out" "$url" && printf '%s' "$out"
}

# Downloads $1 (at ref-kind $2) and installs it into $INSTALL_DIR, preserving
# installer-managed files (.env, HTTPS config, the installed-ref marker)
# across the re-download. Leaves the shell in $INSTALL_DIR on success.
download_and_extract() {
    local ref="$1" ref_kind="$2"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    SOURCE_ZIP="$(download_ref "$ref_kind" "$ref" || true)"
    if [[ -z "${SOURCE_ZIP:-}" || ! -s "$SOURCE_ZIP" ]]; then
        if [[ "$ref_kind" == "tags" ]]; then
            warn "Could not download '${ref}' as a tag — trying it as a branch instead."
            SOURCE_ZIP="$(download_ref "heads" "$ref" || true)"
        fi
    fi
    [[ -n "${SOURCE_ZIP:-}" && -s "$SOURCE_ZIP" ]] || fail "Could not download ${REPO_URL} at ref '${ref}'."

    unzip -q "$SOURCE_ZIP" -d "$TMP_DIR"
    SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$SOURCE_ROOT" ]] || fail "Downloaded archive did not contain a source directory."
    [[ -f "$SOURCE_ROOT/artisan" ]] || fail "Downloaded archive does not look like Gaming Hub (no artisan file)."
    [[ -f "$SOURCE_ROOT/$COMPOSE_BASE" ]] || fail "Downloaded archive is missing ${COMPOSE_BASE}."

    info "Downloaded to a temporary directory. Installing into ${INSTALL_DIR}."

    "${SUDO[@]}" mkdir -p "$INSTALL_DIR"
    # Preserve installer-managed files across re-installs/upgrades.
    for keep in .env "$DOMAIN_CONFIG_FILE" "$CADDY_CONFIG_DIR" "$COMPOSE_CADDY_FILE" "$INSTALLED_REF_FILE"; do
        if [[ -e "${INSTALL_DIR}/${keep}" ]]; then
            "${SUDO[@]}" cp -r "${INSTALL_DIR}/${keep}" "${TMP_DIR}/keep-$(basename "$keep")" 2>/dev/null || true
        fi
    done
    "${SUDO[@]}" rsync -a --delete \
        --exclude ".env" \
        --exclude "${DOMAIN_CONFIG_FILE}" \
        --exclude "${CADDY_CONFIG_DIR}" \
        --exclude "${COMPOSE_CADDY_FILE}" \
        --exclude "${INSTALLED_REF_FILE}" \
        "${SOURCE_ROOT}/" "${INSTALL_DIR}/" 2>/dev/null \
        || "${SUDO[@]}" cp -r "${SOURCE_ROOT}/." "${INSTALL_DIR}/"
    for keep in .env "$DOMAIN_CONFIG_FILE" "$CADDY_CONFIG_DIR" "$COMPOSE_CADDY_FILE" "$INSTALLED_REF_FILE"; do
        if [[ -e "${TMP_DIR}/keep-$(basename "$keep")" ]]; then
            "${SUDO[@]}" cp -r "${TMP_DIR}/keep-$(basename "$keep")" "${INSTALL_DIR}/${keep}"
        fi
    done
    "${SUDO[@]}" chown -R "$(id -u)":"$(id -g)" "$INSTALL_DIR" 2>/dev/null || true

    cd "$INSTALL_DIR"
}

# Dumps the PostgreSQL database to $INSTALL_DIR/backups before a migration
# is about to run. Hard-fails (aborts the whole update, touches nothing
# else) rather than warning-and-continuing — unlike uninstall's own backup
# prompt, where the user is already about to delete everything and a
# best-effort backup is better than none, an update's entire point is "not
# without a safety net." Assumes cwd is $INSTALL_DIR and
# DB_USERNAME/DB_DATABASE are already set (from load_existing_env_or_fail).
backup_database() {
    local backup_dir="${INSTALL_DIR}/backups" backup_file
    # SUDO is unconditional for any non-root user (needed elsewhere for
    # apt-get, writing under /opt, etc.), so a bare "sudo mkdir" here would
    # create this directory owned by root even though $INSTALL_DIR itself
    # is already chowned to the invoking user — the very next line's plain,
    # unprivileged "pg_dump > file" redirect then can't write into it.
    # Confirmed for real: first Update on a fresh production install failed
    # here with "Permission denied". Chown it back so the redirect works
    # regardless of whether sudo actually needed to elevate for the mkdir.
    "${SUDO[@]}" mkdir -p "$backup_dir"
    "${SUDO[@]}" chown "$(id -u)":"$(id -g)" "$backup_dir"
    backup_file="${backup_dir}/gaming_hub_$(date +%Y%m%d_%H%M%S).sql"

    step "Backing up database"
    compose_args
    if ! "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec -T postgres \
        pg_dump -U "$DB_USERNAME" "$DB_DATABASE" > "$backup_file" 2>/dev/null; then
        rm -f "$backup_file"
        fail "Database backup failed — aborting before touching anything. Check 'docker compose -f ${COMPOSE_BASE} logs postgres' and try again."
    fi
    if [[ ! -s "$backup_file" ]]; then
        rm -f "$backup_file"
        fail "Database backup produced an empty file — aborting before touching anything. Something is wrong with the database connection; check 'docker compose -f ${COMPOSE_BASE} logs postgres'."
    fi
    info "Backup saved: ${backup_file}"
}

# Builds the app image and brings the stack up. Assumes cwd is $INSTALL_DIR
# and DB_USERNAME/DB_DATABASE/DB_PASSWORD/APP_PORT/EXISTING_APP_KEY are set
# (from either fresh prompts or read back out of an existing .env).
#
# Migrations are never run explicitly here — docker/entrypoint.sh runs
# `php artisan migrate --force` (never --fresh, never --seed) every time the
# app container starts, so every `up -d`/`--force-recreate app` below
# implicitly migrates. That's also why backup_database() (when called by the
# update flow) has to run before this function, not "before migrate" as a
# literal separate command.
build_and_start() {
    compose_args
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env up -d postgres < /dev/null

    printf 'Waiting for PostgreSQL to accept connections'
    PG_READY="no"
    for _ in $(seq 1 30); do
        if "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec -T postgres \
            pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" < /dev/null >/dev/null 2>&1; then
            PG_READY="yes"
            break
        fi
        printf '.'
        sleep 1
    done
    printf '\n'
    [[ "$PG_READY" == "yes" ]] || fail "PostgreSQL did not become ready in time."

    # PostgreSQL only applies POSTGRES_PASSWORD when it first initializes an
    # empty data volume — it silently ignores it on every later start. If
    # .env's DB_PASSWORD ever diverges from what a pre-existing volume
    # actually has (a stale volume from an earlier install, a restored .env,
    # a past bug), every later step fails with an opaque "password
    # authentication failed" deep inside migrate/key-generate. Catch that
    # here instead.
    #
    # The check must go over the compose network to the "postgres" hostname,
    # the same path the app container uses: PostgreSQL's default
    # pg_hba.conf trusts the Unix socket and 127.0.0.1 unconditionally
    # (docker compose exec would always report success regardless of the
    # password), and only enforces scram-sha-256 for connections arriving
    # from another host on the network.
    if ! "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env run --rm -T --no-deps \
        --entrypoint psql -e PGPASSWORD="$DB_PASSWORD" postgres \
        -h postgres -U "$DB_USERNAME" -d "$DB_DATABASE" -c 'SELECT 1' \
        < /dev/null >/dev/null 2>&1; then
        warn "PostgreSQL is up, but the password in .env doesn't match its stored credentials (likely a leftover data volume from an earlier install). Resetting it to match .env..."
        # Reset via the container's own Unix socket, which PostgreSQL trusts
        # unconditionally — this works precisely because it bypasses the
        # check above, letting us fix a mismatch without knowing the old
        # password.
        "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec -T postgres \
            psql -U "$DB_USERNAME" -c "ALTER USER \"${DB_USERNAME}\" WITH PASSWORD '${DB_PASSWORD}';" \
            < /dev/null >/dev/null 2>&1 \
            || fail "Could not authenticate to PostgreSQL or reset its password.
  First, look at what's actually wrong (this usually explains it):
    docker compose -f ${COMPOSE_BASE} logs postgres
  Do NOT run 'docker compose down -v' to work around this unless you have
  confirmed you want to permanently delete ALL data in this install — every
  game, server, and user account. That command destroys the database volume
  irrecoverably; it is not a routine fix. If you truly need a clean slate,
  use this installer's own 'Uninstall Gaming Hub' menu option instead, which
  asks for explicit confirmation before touching data."
        info "PostgreSQL password reset to match .env."
    fi

    # No progress indicator between steps here beyond Docker's own build
    # output, and a first build (or one after a dependency change) genuinely
    # takes several minutes — composer + two separate npm installs, then two
    # Vite builds. Stretches of that (dependency resolution, apt package
    # installs in the base layer) print little or nothing for a while,
    # which reads as a hang to anyone watching the terminal. Say so up
    # front rather than leaving that silence unexplained.
    info "Building the application image — this can take several minutes on a first build or after a dependency change (cached and much faster otherwise)."
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env build app < /dev/null

    if [[ -z "$EXISTING_APP_KEY" ]]; then
        info "Generating a permanent application encryption key."
        APP_KEY_LINE="$("${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env run --rm -T app \
            php artisan key:generate --show < /dev/null 2>/dev/null | grep -m1 '^base64:' || true)"
        [[ -n "$APP_KEY_LINE" ]] || fail "Failed to generate an application key. Run 'docker compose -f ${COMPOSE_BASE} run --rm -T app php artisan key:generate --show' manually to see the underlying error."
        set_env_value .env APP_KEY "$APP_KEY_LINE"
    fi

    # --force-recreate on app AND scheduler: env_file only injects .env's
    # values into a container at creation time, so a plain "up -d" against
    # an already-running, image-unchanged container (e.g. re-running
    # Install with the same ref) would silently keep stale values from
    # whenever it was last created — confirmed by hitting exactly this
    # while diagnosing a real SESSION_DOMAIN/SANCTUM_STATEFUL_DOMAINS bug.
    # scheduler shares app's image tag (see docker-compose.prod.yml) but
    # was missing here entirely — confirmed for real during a production
    # update: the image was rebuilt and app got the new code, but scheduler
    # (never recreated) kept running the old image indefinitely.
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env up -d --force-recreate app scheduler < /dev/null

    printf 'Waiting for Gaming Hub to become available'
    READY="no"
    for _ in $(seq 1 30); do
        if curl -fsS -o /dev/null "http://127.0.0.1:${APP_PORT}/admin/system/login" 2>/dev/null; then
            READY="yes"
            break
        fi
        printf '.'
        sleep 2
    done
    printf '\n'
    [[ "$READY" == "yes" ]] || warn "Gaming Hub did not respond within 60s — check 'docker compose -f ${COMPOSE_BASE} logs app'."
}

# Sets up (or refreshes) the Caddy HTTPS reverse proxy. Assumes cwd is
# $INSTALL_DIR, .env exists, and APP_PORT is set. Sets CONFIGURE_HTTPS
# (yes/no) and, if yes, DOMAIN for the caller's summary.
configure_https() {
    CONFIGURE_HTTPS="no"
    if [[ -f "$DOMAIN_CONFIG_FILE" ]]; then
        CONFIGURE_HTTPS="yes"
        DOMAIN="$(awk -F= '$1 == "DOMAIN" { print $2; exit }' "$DOMAIN_CONFIG_FILE")"
        info "Existing HTTPS configuration found for ${DOMAIN} — refreshing it."
    elif ask_yes_no "Configure a domain with automatic HTTPS (via Caddy) now?" "n"; then
        CONFIGURE_HTTPS="yes"
        DOMAIN="$(ask_default "Domain (without https:// or a path)" "")"
        valid_domain "$DOMAIN" || fail "'${DOMAIN}' doesn't look like a valid domain."
        read -r -p "Certificate contact email (optional): " CERT_EMAIL </dev/tty || true

        if command_exists dig; then
            resolved="$(dig +short "$DOMAIN" 2>/dev/null | tail -n1 || true)"
            [[ -n "$resolved" ]] || warn "The domain does not currently resolve (or DNS lookups aren't working from this host). Caddy cannot obtain a certificate until DNS points here."
        fi
    fi

    if [[ "$CONFIGURE_HTTPS" == "yes" ]]; then
        mkdir -p "$CADDY_CONFIG_DIR"
        if [[ -n "${CERT_EMAIL:-}" ]]; then
            cat > "${CADDY_CONFIG_DIR}/Caddyfile" <<CADDY
{
    email ${CERT_EMAIL}
}

${DOMAIN} {
    reverse_proxy app:8000
}
CADDY
        else
            cat > "${CADDY_CONFIG_DIR}/Caddyfile" <<CADDY
${DOMAIN} {
    reverse_proxy app:8000
}
CADDY
        fi

        # Note: Compose merges list-type keys like `ports` across files
        # rather than letting an override clear them, so app's direct port
        # mapping from ${COMPOSE_BASE} stays published even with Caddy
        # fronting it. Firewall off APP_PORT from the internet if you want
        # HTTPS to be the only path in.
        cat > "$COMPOSE_CADDY_FILE" <<COMPOSE
services:
  caddy:
    image: ${CADDY_IMAGE}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./${CADDY_CONFIG_DIR}:/etc/caddy:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app
volumes:
  caddy_data:
  caddy_config:
COMPOSE

        cat > "$DOMAIN_CONFIG_FILE" <<DOMAINCONF
DOMAIN=${DOMAIN}
EMAIL=${CERT_EMAIL:-}
DOMAINCONF
        chmod 600 "$DOMAIN_CONFIG_FILE"

        set_env_value .env APP_URL "https://${DOMAIN}"
        set_env_value .env SESSION_DOMAIN "$DOMAIN"
        set_env_value .env SANCTUM_STATEFUL_DOMAINS "$DOMAIN"

        compose_args
        "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env config < /dev/null >/dev/null \
            || fail "The combined Gaming Hub and Caddy Compose configuration is invalid."
        "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env up -d --force-recreate app caddy < /dev/null

        info "Caddy will request and renew the TLS certificate automatically once DNS and ports 80/443 are reachable from the internet."
        warn "Note: Gaming Hub is still directly reachable on port ${APP_PORT} (unencrypted) alongside HTTPS. Firewall that port from the internet if you want HTTPS to be the only way in."
        printf 'Check progress with: cd %s && docker compose logs -f caddy\n' "$INSTALL_DIR"
    fi
}

# Ensures the stack is running, then hands off to the app's own interactive
# admin-creation command. Assumes cwd is $INSTALL_DIR.
create_admin_account() {
    compose_args
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env up -d < /dev/null
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec app php artisan gaming-hub:admin < /dev/tty
}

uninstall_gaming_hub() {
    local dir remove_data remove_files confirmation
    dir="$(ask_default "Install directory to uninstall" "$DEFAULT_INSTALL_DIR")"

    if [[ ! -f "${dir}/${COMPOSE_BASE}" ]]; then
        fail "No Gaming Hub installation found at ${dir} (no ${COMPOSE_BASE} there)."
    fi

    printf '\n\033[1;31mThis stops and removes the Gaming Hub containers at %s.\033[0m\n' "$dir"

    remove_data="no"
    ask_yes_no "Also delete the PostgreSQL data volume? This PERMANENTLY destroys the database." "n" \
        && remove_data="yes"

    remove_files="no"
    ask_yes_no "Also delete the install directory itself (${dir}), including .env and secrets?" "n" \
        && remove_files="yes"

    printf '\nThis cannot be undone. Type UNINSTALL to confirm, anything else to cancel: '
    read -r confirmation </dev/tty
    [[ "$confirmation" == "UNINSTALL" ]] || fail "Uninstall cancelled — nothing was changed."

    cd "$dir"
    GAMING_HUB_INSTANCE="$(get_env_value .env GAMING_HUB_INSTANCE)"
    export GAMING_HUB_INSTANCE="${GAMING_HUB_INSTANCE:-prod}"
    info "Instance: ${GAMING_HUB_INSTANCE}"
    compose_args
    if [[ "$remove_data" == "yes" ]]; then
        "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env down -v < /dev/null
    else
        "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env down < /dev/null
        info "Containers removed. The PostgreSQL data volume was kept — reinstalling into the same directory will reuse it."
    fi

    if [[ "$remove_files" == "yes" ]]; then
        cd /
        "${SUDO[@]}" rm -rf "$dir"
        info "Removed ${dir}."
    fi

    printf '\n\033[1;32mGaming Hub has been uninstalled.\033[0m\n'
    exit 0
}

# Loads DB/app settings this action needs out of an existing .env, failing
# clearly if the file looks incomplete (e.g. hand-edited, or from a version
# of this installer that used different keys).
load_existing_env_or_fail() {
    DB_USERNAME="$(get_env_value .env DB_USERNAME)"
    DB_DATABASE="$(get_env_value .env DB_DATABASE)"
    DB_PASSWORD="$(get_env_value .env DB_PASSWORD)"
    APP_PORT="$(get_env_value .env APP_PORT)"
    EXISTING_APP_KEY="$(get_env_value .env APP_KEY)"
    [[ -n "$DB_USERNAME" && -n "$DB_DATABASE" && -n "$DB_PASSWORD" && -n "$APP_PORT" ]] \
        || fail "${INSTALL_DIR}/.env is missing required settings. Use 'Install or reinstall' instead."
}

update_gaming_hub() {
    TOTAL_STEPS=7

    step "Update settings"
    require_existing_install
    load_existing_env_or_fail

    REF_CHOICE="$(ask_default "Version to update to: 'latest' tag, or a branch/tag name" "latest")"
    resolve_ref "$REF_CHOICE"

    PREVIOUS_REF="$(read_installed_ref)"
    if ! show_version_diff "$PREVIOUS_REF" "$REF"; then
        printf '\n\033[1;32mNothing to do.\033[0m\n'
        exit 0
    fi

    ask_yes_no "Update Gaming Hub at ${INSTALL_DIR} to ${REF}?" || fail "Update cancelled."

    backup_database

    step "Downloading Gaming Hub ${REF}"
    download_and_extract "$REF" "$REF_KIND"
    set_env_value .env APP_VERSION "${REF#v}"

    step "Building and starting Gaming Hub"
    build_and_start
    record_installed_ref "$REF"

    step "Refreshing the Geo-IP database"
    # Monthly-cadence data, not install-blocking — this is the update
    # flow's natural "already expected to run periodically" hook rather
    # than adding a whole new cron mechanism just for this one file. A
    # failure here never fails the update itself: the app already
    # degrades gracefully to no country data when this file is missing
    # or stale (see GeoIpLookup), so a warning is the right severity, not
    # a hard stop.
    compose_args
    if ! "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec -T app php artisan gaming-hub:geoip-update < /dev/null; then
        warn "Geo-IP database update failed — country lookups in the audit log will keep using whatever data (if any) is already there. Safe to ignore, or run it again later: docker compose -f ${COMPOSE_BASE} exec app php artisan gaming-hub:geoip-update"
    fi

    printf '\n\033[1;32mGaming Hub updated to %s.\033[0m\n' "$REF"
    exit 0
}

https_only() {
    TOTAL_STEPS=3

    step "Locate installation"
    require_existing_install
    APP_PORT="$(get_env_value .env APP_PORT)"
    [[ -n "$APP_PORT" ]] || fail "${INSTALL_DIR}/.env is missing APP_PORT. Use 'Install or reinstall' instead."
    compose_args
    "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env up -d < /dev/null

    step "HTTPS"
    configure_https

    if [[ "$CONFIGURE_HTTPS" == "yes" ]]; then
        printf '\n\033[1;32mHTTPS is set up: https://%s\033[0m\n' "$DOMAIN"
    else
        info "No changes made."
    fi
    exit 0
}

admin_only() {
    TOTAL_STEPS=3

    step "Locate installation"
    require_existing_install

    step "Administrator account"
    create_admin_account

    printf '\n\033[1;32mDone.\033[0m\n'
    exit 0
}

printf '\033[1;35mGaming Hub Platform Installer v%s\033[0m\n' "$INSTALLER_VERSION"
printf '%s\n' "$REPO_URL"

# ---------------------------------------------------------------------------
step "Checking system requirements"
# ---------------------------------------------------------------------------

for cmd in curl unzip; do
    if ! command_exists "$cmd"; then
        warn "'$cmd' is required and was not found."
        if command_exists apt-get; then
            "${SUDO[@]}" apt-get update -y && "${SUDO[@]}" apt-get install -y "$cmd"
        elif command_exists pacman; then
            "${SUDO[@]}" pacman -S --needed --noconfirm "$cmd"
        else
            fail "Please install '$cmd' manually and re-run this script."
        fi
    fi
done

if ! find_docker_command; then
    warn "Docker was not found."
    if ask_yes_no "Install Docker and the Docker Compose plugin now?"; then
        if command_exists apt-get; then
            "${SUDO[@]}" apt-get update -y
            "${SUDO[@]}" apt-get install -y docker.io docker-compose-v2
        elif command_exists pacman; then
            "${SUDO[@]}" pacman -S --needed --noconfirm docker docker-compose docker-buildx
        else
            fail "Unsupported distribution — install Docker manually from https://docs.docker.com/engine/install/ and re-run."
        fi
        "${SUDO[@]}" systemctl enable --now docker 2>/dev/null || true
    else
        fail "Docker is required. Install it and re-run this script."
    fi
    find_docker_command || fail "Docker installation did not complete successfully."
fi

if ! "${DOCKER[@]}" compose version < /dev/null >/dev/null 2>&1 && ! "${SUDO[@]}" "${DOCKER[@]}" compose version < /dev/null >/dev/null 2>&1; then
    warn "Docker Compose plugin was not found."
    if command_exists apt-get; then
        "${SUDO[@]}" apt-get install -y docker-compose-v2
    elif command_exists pacman; then
        "${SUDO[@]}" pacman -S --needed --noconfirm docker-compose
    fi
fi
"${DOCKER[@]}" compose version < /dev/null >/dev/null 2>&1 || DOCKER=("${SUDO[@]}" "${DOCKER[@]}")
"${DOCKER[@]}" compose version < /dev/null >/dev/null 2>&1 || fail "Docker Compose is required and could not be found or installed."

info "Docker and Docker Compose are available."

# ---------------------------------------------------------------------------
step "Choose an action"
# ---------------------------------------------------------------------------

printf '\n  1) Install or reinstall Gaming Hub\n'
printf '  2) Update Gaming Hub to a newer version\n'
printf '  3) Configure HTTPS (set up or change a domain)\n'
printf '  4) Create or update an administrator account\n'
printf '  5) Uninstall Gaming Hub\n'
printf '  6) Exit\n\n'
MENU_CHOICE="$(ask_default "Selection" "1")"
case "$MENU_CHOICE" in
    2) update_gaming_hub ;;
    3) https_only ;;
    4) admin_only ;;
    5) uninstall_gaming_hub ;;
    6) exit 0 ;;
    *) ;;
esac

# ---------------------------------------------------------------------------
step "Installation settings"
# ---------------------------------------------------------------------------

INSTALL_DIR="$(ask_default "Install directory" "$DEFAULT_INSTALL_DIR")"
EXISTING_INSTALL="no"
if [[ -f "${INSTALL_DIR}/.env" && -f "${INSTALL_DIR}/${COMPOSE_BASE}" ]]; then
    EXISTING_INSTALL="yes"
    info "Existing installation detected at ${INSTALL_DIR} — settings below default to its current values."
fi

# Identifies this install's own Compose project (gaming-hub-<instance>) so
# a second install elsewhere on the same host — a staging copy, a
# different game's deployment — never collides with this one on
# containers, volumes, or the built image. Stored in .env below so
# Update/HTTPS/admin/Uninstall can read it back without asking again.
DEFAULT_INSTANCE="$(get_env_value "${INSTALL_DIR}/.env" GAMING_HUB_INSTANCE)"
GAMING_HUB_INSTANCE="$(ask_default "Instance name" "${DEFAULT_INSTANCE:-prod}")"
[[ "$GAMING_HUB_INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "Instance name must be lowercase letters, digits, and hyphens only (e.g. prod, staging, palworld)."
export GAMING_HUB_INSTANCE

REF_CHOICE="$(ask_default "Version to install: 'latest' tag, or a branch/tag name" "latest")"
resolve_ref "$REF_CHOICE"

DEFAULT_PORT="$(get_env_value "${INSTALL_DIR}/.env" APP_PORT)"
APP_PORT="$(ask_default "Public HTTP port (used directly unless you configure a domain below)" "${DEFAULT_PORT:-8000}")"
valid_port "$APP_PORT" || fail "Invalid port: ${APP_PORT}"
if command_exists ss && ss -ltnH "sport = :${APP_PORT}" 2>/dev/null | grep -q .; then
    warn "Port ${APP_PORT} looks like it's already in use on this host."
fi

# Login sessions are cookie-based (Sanctum), and Sanctum only treats a
# request as cookie-authenticated if its Origin/Referer host matches
# SANCTUM_STATEFUL_DOMAINS below — so this needs to be the actual
# host/IP browsers will use, not a guess. Wrong if left hardcoded to
# "localhost" for anyone reaching the server via its LAN IP or a real
# hostname without going through the HTTPS/domain flow below (which
# already asks for and uses a real DOMAIN instead of this prompt).
DEFAULT_ACCESS_HOST="$(get_env_value "${INSTALL_DIR}/.env" APP_URL)"
DEFAULT_ACCESS_HOST="${DEFAULT_ACCESS_HOST#http://}"
DEFAULT_ACCESS_HOST="${DEFAULT_ACCESS_HOST#https://}"
DEFAULT_ACCESS_HOST="${DEFAULT_ACCESS_HOST%%:*}"
ACCESS_HOST="$(ask_default "Hostname or IP this server will be accessed at (e.g. a LAN IP if accessed from other devices)" "${DEFAULT_ACCESS_HOST:-localhost}")"

DEFAULT_APP_NAME="$(get_env_value "${INSTALL_DIR}/.env" APP_NAME)"
APP_NAME="$(ask_default "Site name" "${DEFAULT_APP_NAME:-Gaming Hub}")"

DEFAULT_DB_NAME="$(get_env_value "${INSTALL_DIR}/.env" DB_DATABASE)"
if [[ -z "$DEFAULT_DB_NAME" ]]; then
    DEFAULT_DB_NAME="gaming_hub"
    [[ "$GAMING_HUB_INSTANCE" != "prod" ]] && DEFAULT_DB_NAME="gaming_hub_${GAMING_HUB_INSTANCE}"
fi
DB_DATABASE="$(ask_default "PostgreSQL database name" "$DEFAULT_DB_NAME")"
DEFAULT_DB_USER="$(get_env_value "${INSTALL_DIR}/.env" DB_USERNAME)"
DB_USERNAME="$(ask_default "PostgreSQL username" "${DEFAULT_DB_USER:-gaming_hub}")"

EXISTING_DB_PASSWORD="$(get_env_value "${INSTALL_DIR}/.env" DB_PASSWORD)"
if [[ -n "$EXISTING_DB_PASSWORD" ]]; then
    DB_PASSWORD="$EXISTING_DB_PASSWORD"
    info "Reusing the existing PostgreSQL password."
elif ask_yes_no "Generate a secure PostgreSQL password automatically?"; then
    DB_PASSWORD="$(random_secret 24)"
else
    read -r -s -p "PostgreSQL password: " DB_PASSWORD </dev/tty
    printf '\n'
    [[ -n "$DB_PASSWORD" ]] || fail "A PostgreSQL password is required."
fi

EXISTING_APP_KEY="$(get_env_value "${INSTALL_DIR}/.env" APP_KEY)"

SYSTEM_TIMEZONE="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
DEFAULT_TZ="$(get_env_value "${INSTALL_DIR}/.env" APP_TIMEZONE)"
APP_TIMEZONE="$(ask_default "Application timezone" "${DEFAULT_TZ:-$SYSTEM_TIMEZONE}")"

printf '\n\033[1;35mSummary\033[0m\n'
printf '  Instance:           %s\n' "$GAMING_HUB_INSTANCE"
printf '  Install directory:  %s\n' "$INSTALL_DIR"
printf '  Version:            %s\n' "$REF"
printf '  Access host:        %s\n' "$ACCESS_HOST"
printf '  HTTP port:          %s\n' "$APP_PORT"
printf '  Site name:          %s\n' "$APP_NAME"
printf '  Database:           %s (user: %s)\n' "$DB_DATABASE" "$DB_USERNAME"
printf '  Timezone:           %s\n\n' "$APP_TIMEZONE"
ask_yes_no "Continue?" || fail "Installation cancelled."

# ---------------------------------------------------------------------------
step "Downloading Gaming Hub ${REF}"
# ---------------------------------------------------------------------------

download_and_extract "$REF" "$REF_KIND"

# ---------------------------------------------------------------------------
step "Writing configuration"
# ---------------------------------------------------------------------------

HAD_EXISTING_ENV=0
[[ -f .env ]] && HAD_EXISTING_ENV=1
[[ -f .env ]] || cp .env.example .env
set_env_value .env GAMING_HUB_INSTANCE "$GAMING_HUB_INSTANCE"
set_env_value .env APP_NAME "\"${APP_NAME}\""
set_env_value .env APP_ENV production
set_env_value .env APP_TIMEZONE "$APP_TIMEZONE"
set_env_value .env APP_PORT "$APP_PORT"
set_env_value .env APP_URL "http://${ACCESS_HOST}:${APP_PORT}"
set_env_value .env DB_CONNECTION pgsql
set_env_value .env DB_HOST postgres
set_env_value .env DB_PORT 5432
set_env_value .env DB_DATABASE "$DB_DATABASE"
set_env_value .env DB_USERNAME "$DB_USERNAME"
set_env_value .env DB_PASSWORD "$DB_PASSWORD"
# SESSION_DOMAIN stays blank on purpose: ACCESS_HOST may be a bare LAN
# IP, and some browsers silently drop cookies whose explicit Domain
# attribute is an IP address. Leaving it unset makes Laravel issue a
# host-only cookie instead, which is valid for any host (IP, hostname,
# or localhost) and is exactly right for a single-host deployment.
#
# SANCTUM_STATEFUL_DOMAINS has no such hazard and does need a real
# value: Sanctum only treats a request as cookie-authenticated (needed
# for the SPA's session-based login) if its Origin/Referer host matches
# an entry here, so leaving it blank silently breaks SPA login on every
# install that doesn't go through the HTTPS/domain flow below (which
# sets it from a real DOMAIN instead). If configure_https runs later it
# overwrites both this and SESSION_DOMAIN with that real domain.
set_env_value .env SESSION_DOMAIN ""

EXISTING_SANCTUM_DOMAINS="$(get_env_value .env SANCTUM_STATEFUL_DOMAINS)"
if [[ "$HAS_TTY" -eq 0 && "$HAD_EXISTING_ENV" -eq 1 && -n "$EXISTING_SANCTUM_DOMAINS" ]]; then
    # Confirmed for real (three times) — an unattended reinstall/update
    # (no /dev/tty, see HAS_TTY above) silently answers the ACCESS_HOST
    # prompt with whatever APP_URL's host happens to be, which is *not*
    # necessarily every domain SANCTUM_STATEFUL_DOMAINS has legitimately
    # accumulated (e.g. a LAN IP added by hand, or by a prior interactive
    # run, alongside "localhost"). Overwriting a real multi-value list
    # with a single freshly-guessed one on every unattended run silently
    # broke SPA login for anyone using the dropped domain. A fresh
    # install (HAD_EXISTING_ENV=0, nothing to lose) still gets a real
    # computed value below, same as an interactive run.
    warn "No interactive terminal detected — keeping the existing SANCTUM_STATEFUL_DOMAINS (${EXISTING_SANCTUM_DOMAINS}) instead of overwriting it with a guessed ${ACCESS_HOST}:${APP_PORT}. Run this installer interactively (menu option 1) if that value actually needs to change."
else
    set_env_value .env SANCTUM_STATEFUL_DOMAINS "${ACCESS_HOST}:${APP_PORT}"
fi
# config('app.version'), read by Manager's VersionResolver to check an
# extension's "requires: gaming-hub-platform" constraint — left unset,
# it falls back to the literal string "dev", which isn't valid semver
# and throws the moment any package manifest declares such a constraint.
set_env_value .env APP_VERSION "${REF#v}"
chmod 600 .env

# ---------------------------------------------------------------------------
step "Building and starting Gaming Hub"
# ---------------------------------------------------------------------------

build_and_start
record_installed_ref "$REF"

# ---------------------------------------------------------------------------
step "Seeding baseline data"
# ---------------------------------------------------------------------------

# Unconditional and independent of the optional admin-account step below —
# roles and the capability vocabulary must exist regardless of whether an
# admin account gets created right now. DatabaseSeeder creates no user of
# its own (a hardcoded, publicly-known default admin account is a real
# vulnerability, not a convenience), so this is always safe to run.
compose_args
"${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" --env-file .env exec -T app php artisan db:seed --force < /dev/null

# ---------------------------------------------------------------------------
step "HTTPS (optional)"
# ---------------------------------------------------------------------------

configure_https

# ---------------------------------------------------------------------------
step "Administrator account"
# ---------------------------------------------------------------------------

if ask_yes_no "Create (or update) an administrator account now?"; then
    create_admin_account
fi

# ---------------------------------------------------------------------------
printf '\n\033[1;32mGaming Hub is installed.\033[0m\n\n'
if [[ "$CONFIGURE_HTTPS" == "yes" ]]; then
    printf '  https://%s\n' "$DOMAIN"
    printf '  https://%s/admin/system\n\n' "$DOMAIN"
else
    printf '  http://SERVER-IP:%s\n' "$APP_PORT"
    printf '  http://SERVER-IP:%s/admin/system\n\n' "$APP_PORT"
fi
printf 'Useful commands (from %s):\n' "$INSTALL_DIR"
printf '  docker compose -f %s logs -f app        # follow app logs\n' "$COMPOSE_BASE"
printf '  docker compose -f %s exec app php artisan gaming-hub:admin  # add/promote an admin\n' "$COMPOSE_BASE"
printf '  docker compose -f %s restart app         # restart after config changes\n\n' "$COMPOSE_BASE"
printf 'Configuration (including the database password and app key) lives in %s/.env — keep it safe.\n' "$INSTALL_DIR"
printf 'Re-run this installer any time for: updates, HTTPS setup, or creating another admin account.\n'
