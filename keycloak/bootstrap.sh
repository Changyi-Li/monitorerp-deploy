#!/usr/bin/env bash
# One-time bootstrap for the Keycloak service.
#
# Creates keycloak/.env (gitignored — credentials never committed) with the
# bootstrap admin credentials (generated password), then starts the container.
# Safe to re-run: an existing .env is left untouched.
#
# Requires: docker + docker compose, openssl (for password generation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  password="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$password
EOF
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE with a generated admin password."
else
  echo "$ENV_FILE already exists — leaving it untouched."
fi

(cd "$SCRIPT_DIR" && docker compose up -d)
echo
echo "Keycloak is starting. Console: http://127.0.0.1:8081 (admin / see $ENV_FILE)"
