#!/usr/bin/env bash
# moto.sh start|stop|reset|status -- a local AWS emulator for plans and applies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${MOTO_PORT:-5000}"
URL="http://127.0.0.1:$PORT"
PIDFILE="$ROOT/.moto.pid"
LOG="$ROOT/.moto.log"
BIN="$ROOT/.venv/bin/moto_server"
[ -x "$BIN" ] || BIN="$(command -v moto_server || true)"

up() { curl -fsS -o /dev/null "$URL/moto-api/" 2>/dev/null; }

case "${1:-}" in
  start)
    if up; then echo "moto already up at $URL"; exit 0; fi
    [ -n "$BIN" ] || { echo "moto_server not found -- run: make setup" >&2; exit 1; }
    nohup "$BIN" -H 127.0.0.1 -p "$PORT" >"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    for _ in $(seq 1 50); do up && { echo "moto up at $URL"; exit 0; }; sleep 0.2; done
    echo "moto did not come up; see $LOG" >&2; exit 1
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"; echo "moto stopped"
    ;;
  reset)
    # Wipes every emulated resource, so each pipeline run starts from an empty account.
    curl -fsS -X POST "$URL/moto-api/reset" >/dev/null
    ;;
  status)
    up && echo "up at $URL" || { echo "down"; exit 1; }
    ;;
  *) echo "usage: $0 start|stop|reset|status" >&2; exit 2 ;;
esac
