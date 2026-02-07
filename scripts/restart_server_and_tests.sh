#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-5000}"
MODE="${1:-all}"

case "$MODE" in
  unit|integration|all) ;;
  *) echo "Usage: $0 [unit|integration|all]"; exit 2 ;;
esac

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" || true
  fi
}
trap cleanup EXIT

stop_server_on_port() {
  if command -v lsof >/dev/null 2>&1; then
    local pid
    pid="$(lsof -ti tcp:"$PORT" || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" || true
      sleep 0.5
    fi
  elif command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" || true
    sleep 0.5
  fi
}

wait_for_port() {
  local retries=40
  local wait=0.5
  for _ in $(seq 1 "$retries"); do
    python - <<PY >/dev/null 2>&1 && return 0
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int("$PORT")))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
    sleep "$wait"
  done
  return 1
}

stop_server_on_port

pushd "$ROOT_DIR/server_python" >/dev/null
PORT="$PORT" HOST="0.0.0.0" python app.py &
SERVER_PID=$!
popd >/dev/null

if ! wait_for_port; then
  echo "Server failed to start on port $PORT"
  exit 1
fi

"$ROOT_DIR/scripts/run_tests.sh" "$MODE"
