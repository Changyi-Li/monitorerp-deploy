#!/usr/bin/env bash
# Manage all services on this host: Postgres + Keycloak + RAGFlow +
# MonitorERP-KB + the global nginx reverse proxy.
#
# Usage:
#   ./manage.sh          start everything (Postgres, Keycloak, RAGFlow, KB, then nginx)   [default]
#   ./manage.sh up       same as above
#   ./manage.sh down     stop everything (nginx, then KB, then RAGFlow, then Keycloak, then Postgres)
#   ./manage.sh status   show running state of all stacks
#   ./manage.sh logs     tail logs from all stacks
#
# Requires: docker + docker compose, curl (for the health wait).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$SCRIPT_DIR/postgres"
KEYCLOAK_DIR="$SCRIPT_DIR/keycloak"
RAGFLOW_DIR="$SCRIPT_DIR/ragflow"
KB_DIR="$SCRIPT_DIR/kb"
NGINX_DIR="$SCRIPT_DIR/server-nginx"

cd "$SCRIPT_DIR"
cmd="${1:-up}"

case "$cmd" in
  up)
    echo "==> [1/6] Starting Postgres (:5432)..."
    if [ ! -f "$POSTGRES_DIR/.env" ]; then
      echo "  postgres/.env not found — running postgres/bootstrap.sh to create it (generated password)..."
      "$SCRIPT_DIR/postgres/bootstrap.sh"
    else
      (cd "$POSTGRES_DIR" && docker compose up -d)
    fi

    echo "==> [2/6] Starting Keycloak (identity provider, loopback :8081)..."
    KEYCLOAK_STARTED=0
    if [ ! -f "$KEYCLOAK_DIR/.env" ]; then
      echo "  keycloak/.env not found — run ./keycloak/bootstrap.sh first (creates the"
      echo "  admin credentials and the monitorerp_kc database). Skipping the Keycloak stack."
    else
      (cd "$KEYCLOAK_DIR" && docker compose up -d)
      KEYCLOAK_STARTED=1
    fi

    echo "==> [3/6] Starting RAGFlow (web on :8080)..."
    (cd "$RAGFLOW_DIR" && docker compose up -d)

    echo "==> [4/6] Starting MonitorERP-KB (web on :4800)..."
    KB_STARTED=0
    if [ ! -f "$KB_DIR/.env" ]; then
      echo "  kb/.env not found — run ./kb/bootstrap.sh first (interactive: RagFlow"
      echo "  credentials + it writes the admin password once). Skipping the KB stack."
    else
      (cd "$KB_DIR" && docker compose up -d)
      KB_STARTED=1
    fi

    echo "==> [5/6] Starting global nginx reverse proxy (:80)..."
    (cd "$NGINX_DIR" && docker compose up -d)

    echo "==> [6/6] Waiting for services to answer..."
    if [ "$KEYCLOAK_STARTED" -eq 1 ]; then
      echo "  Keycloak on http://127.0.0.1:8081/health/ready..."
      for _ in $(seq 1 30); do
        if curl -sf -o /dev/null http://127.0.0.1:8081/health/ready; then
          echo "  Keycloak is up."
          break
        fi
        sleep 2
      done
    fi

    echo "  RAGFlow on 127.0.0.1:8080..."
    for _ in $(seq 1 30); do
      if curl -sf -o /dev/null http://127.0.0.1:8080; then
        echo "  RAGFlow is up."
        break
      fi
      sleep 2
    done

    if [ "$KB_STARTED" -eq 1 ]; then
      echo "  KB web on 127.0.0.1:4800..."
      for _ in $(seq 1 30); do
        if curl -sf -o /dev/null http://127.0.0.1:4800/auth/sign-in; then
          echo "  KB web is up."
          break
        fi
        sleep 2
      done
    fi

    echo
    echo "All services started."
    echo "  Postgres: 127.0.0.1:5432 (containers reach it by name on the monitorerp-shared network)"
    echo "  Keycloak: https://keycloak.ai.monitorsystem.cn/  (admin console; realm monitorerp)"
    echo "  RAGFlow:  http://<server-ip>/  or  https://ragflow.ai.monitorsystem.cn/  (via nginx)"
    echo "  KB web:   https://kb.ai.monitorsystem.cn/  (via nginx, once the cert is issued)"
    echo "  nginx:    global reverse proxy on :80"
    ;;

  down)
    echo "==> Stopping global nginx..."
    (cd "$NGINX_DIR" && docker compose down)
    echo "==> Stopping MonitorERP-KB..."
    if [ -f "$KB_DIR/.env" ]; then
      (cd "$KB_DIR" && docker compose down)
    else
      echo "  kb/.env not found — nothing to stop."
    fi
    echo "==> Stopping RAGFlow..."
    (cd "$RAGFLOW_DIR" && docker compose down)
    echo "==> Stopping Keycloak..."
    if [ -f "$KEYCLOAK_DIR/.env" ]; then
      (cd "$KEYCLOAK_DIR" && docker compose down)
    else
      echo "  keycloak/.env not found — nothing to stop."
    fi
    echo "==> Stopping Postgres..."
    (cd "$POSTGRES_DIR" && docker compose down)
    echo "All services stopped."
    ;;

  status)
    echo "--- postgres ---"
    (cd "$POSTGRES_DIR" && docker compose ps)
    echo
    if [ -f "$KEYCLOAK_DIR/.env" ]; then
      echo "--- keycloak ---"
      (cd "$KEYCLOAK_DIR" && docker compose ps)
      echo
    fi
    echo "--- ragflow ---"
    (cd "$RAGFLOW_DIR" && docker compose ps)
    echo
    if [ -f "$KB_DIR/.env" ]; then
      echo "--- kb ---"
      (cd "$KB_DIR" && docker compose ps)
      echo
    fi
    echo "--- server-nginx ---"
    (cd "$NGINX_DIR" && docker compose ps)
    ;;

  logs)
    echo "Tailing logs (Ctrl-C to stop)..."
    (cd "$POSTGRES_DIR" && docker compose logs -f --tail=50) &
    if [ -f "$KEYCLOAK_DIR/.env" ]; then
      (cd "$KEYCLOAK_DIR" && docker compose logs -f --tail=50) &
    fi
    (cd "$RAGFLOW_DIR" && docker compose logs -f --tail=50) &
    if [ -f "$KB_DIR/.env" ]; then
      (cd "$KB_DIR" && docker compose logs -f --tail=50) &
    fi
    (cd "$NGINX_DIR" && docker compose logs -f --tail=50) &
    wait
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 [up|down|status|logs]"
    exit 1
    ;;
esac
