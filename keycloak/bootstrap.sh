#!/usr/bin/env bash
# One-time bootstrap for the Keycloak service.
#
# Creates keycloak/.env (gitignored — credentials never committed) with the
# bootstrap admin credentials (generated password) and the server Postgres
# password (Keycloak reuses the server-level Postgres role), ensures the
# monitorerp_kc database exists in server-postgres, then starts the container.
#
# Safe to re-run: an existing .env is left untouched, except that a
# KC_DB_PASSWORD missing from an old .env is appended (the production-mode
# switch requires it).
#
# Requires: docker + docker compose, openssl (for password generation).
# Must run after postgres/bootstrap.sh — server-postgres must be up, because
# the monitorerp_kc database is created here on first run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
POSTGRES_ENV="$SCRIPT_DIR/../postgres/.env"

# --- DB credentials come from the server Postgres bootstrap ------------------
if [ ! -f "$POSTGRES_ENV" ]; then
  echo "ERROR: $POSTGRES_ENV not found." >&2
  echo "  Run ./postgres/bootstrap.sh first — Keycloak reuses the server" >&2
  echo "  Postgres and its credentials only exist in that file." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$POSTGRES_ENV"
POSTGRES_USER="${POSTGRES_USER:?missing POSTGRES_USER in $POSTGRES_ENV}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?missing POSTGRES_PASSWORD in $POSTGRES_ENV}"

# --- server-postgres must be up (needed for the psql call below) --------------
if ! docker exec server-postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
  echo "ERROR: server-postgres is not accepting connections." >&2
  echo "  Start it first: ./manage.sh up  (or ./postgres/bootstrap.sh on first init)." >&2
  exit 1
fi

# --- ensure the Keycloak database exists --------------------------------------
echo "==> Ensuring the monitorerp_kc database exists in server-postgres..."
if docker exec server-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='monitorerp_kc'" | grep -q 1; then
  echo "  monitorerp_kc already exists."
else
  docker exec server-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "CREATE DATABASE monitorerp_kc OWNER $POSTGRES_USER"
  echo "  Created monitorerp_kc."
fi

# --- write keycloak/.env ------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  password="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$password
KC_DB_PASSWORD=$POSTGRES_PASSWORD
EOF
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE with a generated admin password."
else
  if ! grep -q '^KC_DB_PASSWORD=' "$ENV_FILE"; then
    echo "  Appending KC_DB_PASSWORD to the existing $ENV_FILE (required for production mode)..."
    echo "KC_DB_PASSWORD=$POSTGRES_PASSWORD" >> "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  echo "$ENV_FILE already exists — leaving it untouched."
fi

(cd "$SCRIPT_DIR" && docker compose up -d)
echo
echo "Keycloak is starting. Console: https://keycloak.ai.monitorsystem.cn/admin"
echo "  (admin / see $ENV_FILE). Realm 'monitorerp' is imported on first boot"
echo "  from realms/monitorerp.json; next: see README.md for the OIDC wiring."
