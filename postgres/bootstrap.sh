#!/usr/bin/env bash
# One-time bootstrap for the server-level Postgres service.
#
# Creates postgres/.env (gitignored — credentials never committed) with a
# generated password, then starts the container. Safe to re-run: an existing
# .env is left untouched.
#
# Requires: docker + docker compose, openssl (for password generation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  password="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
POSTGRES_USER=monitorerp
POSTGRES_PASSWORD=$password
POSTGRES_DB=monitorerp_kb
EOF
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE with a generated password."
else
  echo "$ENV_FILE already exists — leaving it untouched."
fi

(cd "$SCRIPT_DIR" && docker compose up -d)
echo
echo "Postgres is starting. See status with: ./manage.sh status"
