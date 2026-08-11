#!/usr/bin/env bash
# Manage all services on this host: RAGFlow + the global nginx reverse proxy.
#
# Usage:
#   ./up.sh          start everything (RAGFlow, then nginx)   [default]
#   ./up.sh up       same as above
#   ./up.sh down     stop everything (nginx, then RAGFlow)
#   ./up.sh status   show running state of both stacks
#   ./up.sh logs     tail logs from both stacks
#
# Requires: docker + docker compose, curl (for the health wait).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAGFLOW_DIR="$SCRIPT_DIR/ragflow"
NGINX_DIR="$SCRIPT_DIR/server-nginx"

cd "$SCRIPT_DIR"
cmd="${1:-up}"

case "$cmd" in
  up)
    echo "==> [1/3] Starting RAGFlow (web on :8080)..."
    (cd "$RAGFLOW_DIR" && docker compose up -d)

    echo "==> [2/3] Starting global nginx reverse proxy (:80)..."
    (cd "$NGINX_DIR" && docker compose up -d)

    echo "==> [3/3] Waiting for RAGFlow to answer on 127.0.0.1:8080..."
    for _ in $(seq 1 30); do
      if curl -sf -o /dev/null http://127.0.0.1:8080; then
        echo "RAGFlow is up."
        break
      fi
      sleep 2
    done

    echo
    echo "All services started."
    echo "  RAGFlow:  http://<server-ip>/  or  http://ragflow.ai.monitorsystem.cn/  (via nginx :80)"
    echo "  nginx:    global reverse proxy on :80"
    ;;

  down)
    echo "==> Stopping global nginx..."
    (cd "$NGINX_DIR" && docker compose down)
    echo "==> Stopping RAGFlow..."
    (cd "$RAGFLOW_DIR" && docker compose down)
    echo "All services stopped."
    ;;

  status)
    echo "--- ragflow ---"
    (cd "$RAGFLOW_DIR" && docker compose ps)
    echo
    echo "--- server-nginx ---"
    (cd "$NGINX_DIR" && docker compose ps)
    ;;

  logs)
    echo "Tailing logs (Ctrl-C to stop)..."
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
