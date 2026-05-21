#!/usr/bin/env bash
# Zoho Expense Portal — customer install / deploy helper.
#
# Usage:
#   bash install.sh             # interactive: prompts for any missing value
#   bash install.sh --update    # skip prompts, just re-pull and restart
#   bash install.sh --check     # validate prereqs + .env without starting anything
#
# Required env (read from .env if present, else prompted):
#   LICENSE_KEY                  signed by Techcon Solution
#   APP_VERSION_TAG              e.g. v1.4.2-saas   (NEVER :latest)
#   GHCR_USERNAME                your GitHub username
#   GHCR_PAT                     personal access token, scope read:packages
#   ZOHO_CLIENT_ID
#   ZOHO_CLIENT_SECRET
#   ZOHO_REFRESH_TOKEN
#   ZOHO_ORGANIZATION_ID
#   DEFAULT_PAID_THROUGH_ACCOUNT (e.g. "HSBC HK")
#
# Optional (defaults applied):
#   JWT_SECRET                   auto-generated if missing
#   DATABASE_URL                 default talks to the bundled postgres service
#   OLLAMA_HOST                  default host.docker.internal:11434
#   OLLAMA_MODEL                 default qwen3-vl:8b
#   BRAND_NAME, BRAND_LOGO_URL
#
# This script is idempotent: re-running with the same .env produces no
# new state — it pulls the image, restarts the stack, waits for /health.

set -euo pipefail

# ---------- console helpers ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}✓${NC}  $*"; }
warn() { printf '%b\n' "${YELLOW}!${NC}  $*" >&2; }
die()  { printf '%b\n' "${RED}✗${NC}  $*" >&2; exit 1; }

# ---------- argument parsing ----------
MODE=install
for arg in "$@"; do
    case "$arg" in
        --update) MODE=update ;;
        --check)  MODE=check ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | head -n -1; exit 0 ;;
        *) die "Unknown argument: $arg (try --help)" ;;
    esac
done

# ---------- prereq check ----------
say "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "Docker not found — install Docker Desktop first."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not found."
command -v curl >/dev/null 2>&1 || die "curl not found."
ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"
ok "docker compose $(docker compose version --short 2>/dev/null || echo 'present')"

# Optional but recommended.
if curl -s --max-time 2 http://host.docker.internal:11434/api/tags >/dev/null 2>&1 \
    || curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "Ollama reachable on 11434"
else
    warn "Ollama not detected on 11434 — the worker will fail vision OCR until you start it."
    warn "Install: https://ollama.com/download   then:  ollama pull qwen3-vl:8b"
fi

# ---------- compose file presence ----------
[[ -f docker-compose.yml ]] || die "docker-compose.yml not found in $(pwd). Copy customer/docker-compose.example.yml here."

# ---------- .env handling ----------
ENV_FILE=.env
prompt_var() {
    # Usage: prompt_var VAR_NAME "prompt label" [default] [secret]
    local var="$1" label="$2" default="${3:-}" secret="${4:-}"
    local current="${!var:-}"
    if [[ -n "$current" ]]; then return 0; fi
    local input
    if [[ -n "$secret" ]]; then
        read -r -s -p "  $label${default:+ [$default]}: " input; echo
    else
        read -r -p "  $label${default:+ [$default]}: " input
    fi
    input="${input:-$default}"
    [[ -z "$input" ]] && die "$var is required."
    printf -v "$var" '%s' "$input"
}

# Read existing .env values into the shell so prompt_var can skip them.
# Use a tolerant parser — values may be unquoted (with spaces) or quoted.
load_env_safely() {
    local file="$1" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip surrounding single or double quotes if present.
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        export "$key=$val"
    done < "$file"
}
if [[ -f "$ENV_FILE" ]]; then
    say "Reading existing $ENV_FILE"
    load_env_safely "$ENV_FILE"
fi

if [[ "$MODE" == "install" ]]; then
    say "Configuration (anything blank will be prompted)"

    prompt_var LICENSE_KEY        "LICENSE_KEY (provided by Techcon)" "" secret
    prompt_var APP_VERSION_TAG    "Image tag" "v1.4.2-saas"
    prompt_var GHCR_USERNAME      "GitHub username (for docker login)"
    prompt_var GHCR_PAT           "GitHub PAT (read:packages)" "" secret
    prompt_var ZOHO_CLIENT_ID     "ZOHO_CLIENT_ID"
    prompt_var ZOHO_CLIENT_SECRET "ZOHO_CLIENT_SECRET" "" secret
    prompt_var ZOHO_REFRESH_TOKEN "ZOHO_REFRESH_TOKEN" "" secret
    prompt_var ZOHO_ORGANIZATION_ID "ZOHO_ORGANIZATION_ID"
    prompt_var DEFAULT_PAID_THROUGH_ACCOUNT "Default Zoho paid-through account name" "HSBC HK"
    prompt_var OLLAMA_HOST        "Ollama host:port" "host.docker.internal:11434"
    prompt_var OLLAMA_MODEL       "Ollama vision model" "qwen3-vl:8b"

    if [[ -z "${JWT_SECRET:-}" ]]; then
        if command -v openssl >/dev/null 2>&1; then
            JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
            ok "Generated fresh JWT_SECRET (48 random bytes, base64)."
        else
            die "JWT_SECRET missing and openssl unavailable — set JWT_SECRET in .env manually."
        fi
    fi

    DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@db:5432/expenses}"

    # Optional branding (no prompt; pass via env or leave empty for default branding)
    BRAND_NAME="${BRAND_NAME:-}"
    BRAND_LOGO_URL="${BRAND_LOGO_URL:-}"

    # Optional scan
    SCAN_HOST_DIR="${SCAN_HOST_DIR:-}"
    SCAN_DEFAULT_USERNAME="${SCAN_DEFAULT_USERNAME:-scanner}"

    say "Writing $ENV_FILE"
    # Values are double-quoted so spaces and special chars survive a re-source.
    # Escape inner double-quotes by replacing " with \"
    q() { printf '%s' "${1//\"/\\\"}"; }
    cat > "$ENV_FILE" <<EOF
# Zoho Expense Portal — generated by install.sh on $(date -u +%Y-%m-%dT%H:%MZ)
# Do not check this file into source control.

LICENSE_KEY="$(q "$LICENSE_KEY")"
APP_VERSION_TAG="$(q "$APP_VERSION_TAG")"

GHCR_USERNAME="$(q "$GHCR_USERNAME")"
GHCR_PAT="$(q "$GHCR_PAT")"

ZOHO_CLIENT_ID="$(q "$ZOHO_CLIENT_ID")"
ZOHO_CLIENT_SECRET="$(q "$ZOHO_CLIENT_SECRET")"
ZOHO_REFRESH_TOKEN="$(q "$ZOHO_REFRESH_TOKEN")"
ZOHO_ORGANIZATION_ID="$(q "$ZOHO_ORGANIZATION_ID")"

JWT_SECRET="$(q "$JWT_SECRET")"
DATABASE_URL="$(q "$DATABASE_URL")"

OLLAMA_HOST="$(q "$OLLAMA_HOST")"
OLLAMA_MODEL="$(q "$OLLAMA_MODEL")"

DEFAULT_PAID_THROUGH_ACCOUNT="$(q "$DEFAULT_PAID_THROUGH_ACCOUNT")"
PAID_THROUGH_ACCOUNT_MAP="$(q "${PAID_THROUGH_ACCOUNT_MAP:-}")"

BRAND_NAME="$(q "$BRAND_NAME")"
BRAND_LOGO_URL="$(q "$BRAND_LOGO_URL")"

SCAN_HOST_DIR="$(q "$SCAN_HOST_DIR")"
SCAN_DEFAULT_USERNAME="$(q "$SCAN_DEFAULT_USERNAME")"
SCAN_STABILITY_SECONDS="$(q "${SCAN_STABILITY_SECONDS:-3}")"
SCAN_MAX_PER_TICK="$(q "${SCAN_MAX_PER_TICK:-10}")"

CLOUDFLARE_TUNNEL_TOKEN="$(q "${CLOUDFLARE_TUNNEL_TOKEN:-}")"
EOF
    chmod 600 "$ENV_FILE"
    ok "$ENV_FILE written (600 perms)"
fi

# ---------- validation common to install/update/check ----------
say "Validating $ENV_FILE"
load_env_safely "$ENV_FILE"
for v in LICENSE_KEY APP_VERSION_TAG GHCR_USERNAME GHCR_PAT \
         ZOHO_CLIENT_ID ZOHO_CLIENT_SECRET ZOHO_REFRESH_TOKEN ZOHO_ORGANIZATION_ID \
         JWT_SECRET DATABASE_URL DEFAULT_PAID_THROUGH_ACCOUNT; do
    [[ -n "${!v:-}" ]] || die "$v missing from $ENV_FILE"
done
[[ "$APP_VERSION_TAG" != "latest" && "$APP_VERSION_TAG" != ":latest" ]] || die "Refusing to deploy :latest. Pin a specific version tag."
ok "Required env present, APP_VERSION_TAG=$APP_VERSION_TAG"

if [[ "$MODE" == "check" ]]; then
    say "--check mode: nothing started."
    exit 0
fi

# ---------- docker login ----------
say "Logging in to ghcr.io as $GHCR_USERNAME"
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null
ok "GHCR login succeeded"

# ---------- pull + up ----------
say "Pulling image ghcr.io/milotechcon/zoho-expense-portal:$APP_VERSION_TAG"
docker compose pull
ok "Image present"

say "Starting / restarting the stack"
docker compose up -d
ok "Containers up"

# ---------- health wait ----------
say "Waiting for /health (timeout 60s)"
WAITED=0
until curl -fs http://localhost:8000/health >/dev/null 2>&1; do
    sleep 2
    WAITED=$((WAITED + 2))
    if [[ $WAITED -ge 60 ]]; then
        warn "/health didn't respond in 60s. Show recent logs:"
        docker compose logs --tail 40 web
        die "Boot failed. Check the logs above for [license] FATAL or other errors."
    fi
done
ok "/health responding"

# ---------- license-status echo ----------
say "License status from container log"
docker compose logs --since 5m web 2>/dev/null | grep -E '\[license\]' | tail -3 || true

# ---------- final summary ----------
echo
ok "Deployment complete."
echo
echo "Next steps:"
echo "  • Web UI:          http://localhost:8000"
echo "  • Create a user:   docker compose exec web python /app/run_manage.py create-user <name>"
echo "  • Tail worker:     docker compose logs -f worker"
echo "  • Update later:    bash install.sh --update"
echo "  • Reconfigure:     edit .env then rerun without flags"
echo
