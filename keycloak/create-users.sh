#!/usr/bin/env bash
# Create users in the Keycloak monitorerp realm from a CSV manifest.
#
# Usage:
#   ./keycloak/create-users.sh                  # default CSV: keycloak/data/monitorerp-internal-users.csv
#   ./keycloak/create-users.sh --file path.csv  # another manifest
#   ./keycloak/create-users.sh --dry-run        # validate + plan only, no changes
#
# Runs on the production server (Keycloak must be up). Reads the master-realm
# admin credentials from keycloak/.env (created by keycloak/bootstrap.sh) and
# drives kcadm.sh inside the Keycloak container with --no-config (no state,
# fresh authentication per run). Override the container name with
# KEYCLOAK_CONTAINER if it ever changes.
#
# Design (settled in review):
#   * one email per line; a leading non-email line is treated as a header;
#     blank lines are skipped; any other malformed line is a hard error
#     (pre-validation, before any API call)
#   * username = email (email is the login identifier); the name is parsed
#     from the local part: steve.li@... -> firstName "Steve", lastName "Li"
#     (dot-segments, each capitalized; 3+ segments join with a space)
#   * enabled=true, emailVerified=true (admin-provisioned accounts)
#   * temporary password generated per user (realm policy: >=10 chars, a
#     digit, a special char, must not contain the username), printed in a
#     final handoff block — there is no SMTP, so this IS the delivery
#   * existing users: skipped; in-file duplicates: first occurrence wins
#   * per-row API failures: reported and counted, non-zero exit at the end;
#     authentication/infrastructure errors: abort immediately
#   * --dry-run: read-only — prints the exact plan including the passwords
#     that would be generated, makes zero changes, exits 0
#
# Requires: docker, openssl; the keycloak container running.

set -euo pipefail

# Keep POSIX paths (e.g. /opt/keycloak/bin/kcadm.sh) intact when this script is
# run from Git-Bash/MSYS on Windows for testing; ignored on the Linux server.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CSV="$SCRIPT_DIR/data/monitorerp-internal-users.csv"
ENV_FILE="$SCRIPT_DIR/.env"
KC_CONTAINER="${KEYCLOAK_CONTAINER:-keycloak}"
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
SPECIALS='!@#$%^&*'

CSV_FILE="$DEFAULT_CSV"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: create-users.sh [--file path.csv] [--dry-run]

  --file path.csv   CSV manifest (default: keycloak/data/monitorerp-internal-users.csv)
  --dry-run         validate + print the plan, make no changes
  -h, --help        this help

Environment:
  KEYCLOAK_CONTAINER   Keycloak container name (default: keycloak)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      CSV_FILE="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2; exit 1 ;;
  esac
done

# --- master-realm admin credentials from keycloak/.env -----------------------
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found — run ./keycloak/bootstrap.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:?missing KC_BOOTSTRAP_ADMIN_USERNAME in $ENV_FILE}"
ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:?missing KC_BOOTSTRAP_ADMIN_PASSWORD in $ENV_FILE}"

# --- the Keycloak container must be up ---------------------------------------
if ! docker exec "$KC_CONTAINER" true 2>/dev/null; then
  echo "ERROR: the '$KC_CONTAINER' container is not running — start it first (./manage.sh up)." >&2
  exit 1
fi

kcadm() {
  # kcadm.sh parses global options only after the subcommand.
  docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@" \
    --no-config --server http://localhost:8080 --realm master \
    --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"
}

# --- read + pre-validate the CSV ----------------------------------------------
if [ ! -f "$CSV_FILE" ]; then
  echo "ERROR: $CSV_FILE not found." >&2
  exit 1
fi
mapfile -t LINES < "$CSV_FILE"
ROWS=()
saw_email=0
for raw in "${LINES[@]}"; do
  line="${raw//$'\r'/}"
  line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
  line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
  [ -z "$line" ] && continue
  if [[ "$line" =~ $EMAIL_RE ]]; then
    ROWS+=("$line")
    saw_email=1
  elif [ "$saw_email" -eq 0 ]; then
    : # header row (first non-blank, non-email line) — skipped
  else
    echo "ERROR: line is not a valid email (and not the header): $line" >&2
    echo "  Fix $CSV_FILE and re-run." >&2
    exit 1
  fi
done
if [ "${#ROWS[@]}" -eq 0 ]; then
  echo "ERROR: no emails found in $CSV_FILE." >&2
  exit 1
fi

# --- helpers -------------------------------------------------------------------
capitalize() { # foo -> Foo
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" \
                "$(printf '%s' "${1:1}" | tr '[:upper:]' '[:lower:]')"
}

parse_name() { # steve.li@x.com -> FIRST|LAST (dot-segments, capitalized)
  local local_part="${1%%@*}" first="" rest="" seg
  local -a segs
  IFS='.' read -r -a segs <<< "$local_part"
  first="$(capitalize "${segs[0]}")"
  for ((i = 1; i < ${#segs[@]}; i++)); do
    [ -n "$rest" ] && rest="$rest "
    rest+="$(capitalize "${segs[$i]}")"
  done
  printf '%s|%s' "$first" "$rest"
}

pick_special() { # one random char from SPECIALS
  local idx
  idx="$(openssl rand 1 | od -An -tu1 | tr -d ' ')"
  printf '%s' "${SPECIALS:$(( idx % ${#SPECIALS} )):1}"
}

generate_password() { # compliant with the realm policy: >=10 chars, digit,
                      # special char, must not contain the username
  local pw digit spec
  pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 10)"
  # guaranteed digit and special (never empty: 'tr' can return nothing)
  digit="$(openssl rand -base64 12 | tr -dc '0-9' | head -c 1)"
  [ -n "$digit" ] || digit='7'
  spec="$(pick_special)"
  printf '%s%s%s' "$pw" "$digit" "$spec"
}

# --- process -------------------------------------------------------------------
declare -A SEEN
CREATED=0
SKIPPED=0
FAILED=0
declare -a HANDOFF=()

for email in "${ROWS[@]}"; do
  if [ -n "${SEEN[$email]:-}" ]; then
    echo "SKIPPED (duplicate in file): $email"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  SEEN[$email]=1

  # exists? (read-only; an API failure here aborts the whole run)
  if ! out="$(kcadm get users -r monitorerp -q username="$email" --fields username 2>&1)"; then
    echo "ERROR: Keycloak admin API failed — is the admin password in $ENV_FILE still current?" >&2
    echo "  $out" >&2
    exit 1
  fi
  if [[ "$out" == *'"username"'* ]]; then
    echo "SKIPPED (exists): $email"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  name="$(parse_name "$email")"
  FIRST="${name%%|*}"
  LAST="${name#*|}"
  pw="$(generate_password)"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'WOULD CREATE: %-38s %s %s (temp pw: %s)\n' "$email" "$FIRST" "$LAST" "$pw"
    CREATED=$((CREATED + 1))
    continue
  fi

  # Create with the temporary credential embedded — atomic: a password that
  # violates the realm policy fails the whole create (no orphan users).
  if ! out="$(kcadm create users -r monitorerp \
        -s username="$email" -s email="$email" \
        -s firstName="$FIRST" -s lastName="$LAST" \
        -s enabled=true -s emailVerified=true \
        -s "credentials=[{\"type\":\"password\",\"value\":\"$pw\",\"temporary\":true}]" 2>&1)"; then
    if [[ "$out" == *"exists"* ]]; then
      echo "SKIPPED (exists, created concurrently): $email"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    echo "FAILED: $email — $out" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  # verify the user back (created != created correctly). kcadm pretty-prints
  # JSON with spaces around ':', so match whitespace-tolerantly. A temporary
  # credential surfaces as the UPDATE_PASSWORD required action.
  if ! out="$(kcadm get users -r monitorerp -q username="$email" --fields username,enabled,emailVerified,requiredActions 2>&1)" \
     || ! printf '%s' "$out" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true' \
     || ! printf '%s' "$out" | grep -q '"emailVerified"[[:space:]]*:[[:space:]]*true' \
     || ! printf '%s' "$out" | grep -q 'UPDATE_PASSWORD'; then
    echo "FAILED: $email — verification failed (user exists, but check it in the console)." >&2
    echo "  $out" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  printf 'CREATE ok: %-38s %s %s\n' "$email" "$FIRST" "$LAST"
  HANDOFF+=("$email|$pw")
  CREATED=$((CREATED + 1))
done

# --- report --------------------------------------------------------------------
echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=================== DRY RUN — no changes made ==================="
  echo "Would create: $CREATED   Would skip: $SKIPPED"
  exit 0
fi

echo "================= TEMP PASSWORDS — hand these out ================="
for entry in "${HANDOFF[@]}"; do
  printf '%-38s %s\n' "${entry%%|*}" "${entry#*|}"
done
echo "==================================================================="
echo "Created: $CREATED   Skipped: $SKIPPED   Failed: $FAILED"

[ "$FAILED" -eq 0 ]
