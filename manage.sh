#!/usr/bin/env bash
# Manage all services on this host: Postgres + RAGFlow + MonitorERP-KB + the
# global nginx reverse proxy.
#
# Usage:
#   ./manage.sh          start everything (Postgres, RAGFlow, KB, then nginx)   [default]
#   ./manage.sh up       same as above
#   ./manage.sh down     stop everything (nginx, then KB, then RAGFlow, then Postgres)
#   ./manage.sh status   show running state of all stacks
#   ./manage.sh logs     tail logs from all stacks
#
# Requires: docker + docker compose, curl (for the health wait).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$SCRIPT_DIR/postgres"
RAGFLOW_DIR="$SCRIPT_DIR/ragflow"
KB_DIR="$SCRIPT_DIR/kb"
NGINX_DIR="$SCRIPT_DIR/server-nginx"

cd "$SCRIPT_DIR"
cmd="${1:-up}"

case "$cmd" in
  up)
    echo "==> [1/5] Starting Postgres (:5432)..."
    if [ ! -f "$POSTGRES_DIR/.env" ]; then
      echo "  postgres/.env not found — running postgres/bootstrap.sh to create it (generated password)..."
      "$SCRIPT_DIR/postgres/bootstrap.sh"
    else
      (cd "$POSTGRES_DIR" && docker compose up -d)
    fi

    echo "==> [2/5] Starting RAGFlow (web on :8080)..."
    (cd "$RAGFLOW_DIR" && docker compose up -d)

    echo "==> [3/5] Starting MonitorERP-KB (web on :4800)..."
    KB_STARTED=0
    if [ ! -f "$KB_DIR/.env" ]; then
      echo "  kb/.env not found — run ./kb/bootstrap.sh first (interactive: RagFlow"
      echo "  credentials + it writes the admin password once). Skipping the KB stack."
    else
      (cd "$KB_DIR" && docker compose up -d)
      KB_STARTED=1
    fi

    echo "==> [4/5] Starting global nginx reverse proxy (:80)..."
    (cd "$NGINX_DIR" && docker compose up -d)

    echo "==> [5/5] Waiting for RAGFlow to answer on 127.0.0.1:8080..."
    for _ in $(seq 1 30); do
      if curl -sf -o /dev/null http://127.0.0.1:8080; then
        echo "RAGFlow is up."
        break
      fi
      sleep 2
    done

    if [ "$KB_STARTED" -eq 1 ]; then
      echo "==> Waiting for the KB web app to answer on 127.0.0.1:4800..."
      for _ in $(seq 1 30); do
        if curl -sf -o /dev/null http://127.0.0.1:4800/auth/sign-in; then
          echo "KB web is up."
          break
        fi
        sleep 2
      done
    fi

    echo
    echo "All services started."
    echo "  Postgres: 127.0.0.1:5432 (containers reach it by name on the monitorerp-shared network)"
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
