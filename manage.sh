#!/usr/bin/env bash
# Manage all services on this host: Postgres + RAGFlow + the global nginx reverse proxy.
#
# Usage:
#   ./manage.sh          start everything (Postgres, RAGFlow, then nginx)   [default]
#   ./manage.sh up       same as above
#   ./manage.sh down     stop everything (nginx, then RAGFlow, then Postgres)
#   ./manage.sh status   show running state of all stacks
#   ./manage.sh logs     tail logs from all stacks
#
# Requires: docker + docker compose, curl (for the health wait).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$SCRIPT_DIR/postgres"
RAGFLOW_DIR="$SCRIPT_DIR/ragflow"
NGINX_DIR="$SCRIPT_DIR/server-nginx"

cd "$SCRIPT_DIR"
cmd="${1:-up}"

case "$cmd" in
  up)
    echo "==> [1/4] Starting Postgres (:5432)..."
    if [ ! -f "$POSTGRES_DIR/.env" ]; then
      echo "  postgres/.env not found — running postgres/bootstrap.sh to create it (generated password)..."
      "$SCRIPT_DIR/postgres/bootstrap.sh"
    else
      (cd "$POSTGRES_DIR" && docker compose up -d)
    fi

    echo "==> [2/4] Starting RAGFlow (web on :8080)..."
    (cd "$RAGFLOW_DIR" && docker compose up -d)

    echo "==> [3/4] Starting global nginx reverse proxy (:80)..."
    (cd "$NGINX_DIR" && docker compose up -d)

    echo "==> [4/4] Waiting for RAGFlow to answer on 127.0.0.1:8080..."
    for _ in $(seq 1 30); do
      if curl -sf -o /dev/null http://127.0.0.1:8080; then
        echo "RAGFlow is up."
        break
      fi
      sleep 2
    done

    echo
    echo "All services started."
    echo "  Postgres: 127.0.0.1:5432 (containers reach it via host.docker.internal:5432)"
    echo "  RAGFlow:  http://<server-ip>/  or  https://ragflow.ai.monitorsystem.cn/  (via nginx)"
    echo "  nginx:    global reverse proxy on :80"
    ;;

  down)
    echo "==> Stopping global nginx..."
    (cd "$NGINX_DIR" && docker compose down)
    echo "==> Stopping RAGFlow..."
    (cd "$RAGFLOW_DIR" && docker compose down)
    echo "==> Stopping Postgres..."
    (cd "$POSTGRES_DIR" && docker compose down)
    echo "All services stopped."
    ;;

  status)
    echo "--- postgres ---"
    (cd "$POSTGRES_DIR" && docker compose ps)
    echo
    echo "--- ragflow ---"
    (cd "$RAGFLOW_DIR" && docker compose ps)
    echo
    echo "--- server-nginx ---"
    (cd "$NGINX_DIR" && docker compose ps)
    ;;

  logs)
    echo "Tailing logs (Ctrl-C to stop)..."
    (cd "$POSTGRES_DIR" && docker compose logs -f --tail=50) &
    (cd "$RAGFLOW_DIR" && docker compose logs -f --tail=50) &
    (cd "$NGINX_DIR" && docker compose logs -f --tail=50) &
    wait
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 [up|down|status|logs]"
    exit 1
    ;;
esac
