#!/usr/bin/env bash
# Start/stop a throwaway ohmypi gateway on 127.0.0.1:9325 for app testing,
# as a transient systemd user unit (survives the shell, never touches the
# production gateway on 9315). It reads the gateway's own auth-token file at
# runtime; this script never reads or prints it.
#   dev/test-gateway.sh start|stop|status
set -euo pipefail
GW="$HOME/projects/ohmypi-gateway"
UNIT=ohmypi-android-testgw
PORT=9325
case "${1:-status}" in
  start)
    if systemctl --user is-active --quiet "$UNIT"; then echo "already running"; exit 0; fi
    systemd-run --user --unit="$UNIT" --collect \
      -p WorkingDirectory="$GW" \
      -E PATH="$HOME/.bun/bin:/usr/local/bin:/usr/bin" \
      "$GW/.venv/bin/uvicorn" gateway.main:app --host 127.0.0.1 --port "$PORT" \
      --no-access-log --ws-ping-interval 20 --ws-ping-timeout 20
    for _ in $(seq 20); do
      curl -fs -o /dev/null "http://127.0.0.1:$PORT/healthz" && { echo "up on $PORT"; exit 0; }
      sleep 0.5
    done
    echo "did not come up; journalctl --user -u $UNIT" >&2; exit 1 ;;
  stop) systemctl --user stop "$UNIT" && echo stopped ;;
  status) systemctl --user is-active "$UNIT" || true
          curl -s -o /dev/null -w "healthz %{http_code}\n" "http://127.0.0.1:$PORT/healthz" || true ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
