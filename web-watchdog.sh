#!/bin/sh
set -eu

FREEZE_ON_DISCONNECT="${FREEZE_ON_DISCONNECT:-true}"
SUSPENDED=0
FF_PIDFILE="/tmp/firefox.pid"
FF_LOG="/tmp/firefox.log"
LOG="/tmp/watchdog.log"
LOG_MAX=1048576
DEBOUNCE=1
ROTATE_INTERVAL=300
ROTATE_COUNT=0

# Thaw Firefox on SIGTERM so it can exit cleanly
# before Docker destroys the container (profile corruption risk).
cleanup() {
    if [ -f "$FF_PIDFILE" ]; then
        FF_PID=$(cat "$FF_PIDFILE" 2>/dev/null || true)
        if [ -n "$FF_PID" ] && kill -0 "$FF_PID" 2>/dev/null; then
            kill -CONT "$FF_PID" 2>/dev/null || true
            echo "$(date) SIGNAL -> thawed Firefox" >> "$LOG"
        fi
    fi
    exit 0
}
trap cleanup TERM INT

echo "watchdog started" > "$LOG"

while true; do
    ROTATE_COUNT=$((ROTATE_COUNT + 1))
    if [ "$ROTATE_COUNT" -ge "$ROTATE_INTERVAL" ]; then
        if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
            tail -c "$LOG_MAX" "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
        fi
        if [ -f "$FF_LOG" ] && [ "$(wc -c < "$FF_LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
            tail -c "$LOG_MAX" "$FF_LOG" > "${FF_LOG}.tmp" 2>/dev/null && mv "${FF_LOG}.tmp" "$FF_LOG"
        fi
        ROTATE_COUNT=0
    fi

    [ -f "$FF_PIDFILE" ] || { sleep 2; continue; }

    # Check that Firefox is still alive — stale PID file may remain if
    # Firefox crashed before rdp-session.sh cleaned it up.
    FF_PID=$(cat "$FF_PIDFILE" 2>/dev/null) || { sleep 2; continue; }
    if ! kill -0 "$FF_PID" 2>/dev/null; then
        echo "$(date) Firefox PID $FF_PID is dead, removing stale PID file" >> "$LOG"
        rm -f "$FF_PIDFILE"
        SUSPENDED=0
        sleep 2
        continue
    fi

    if [ "$FREEZE_ON_DISCONNECT" = "true" ]; then
        if ss -tn state established 2>/dev/null | grep -q ':6901 '; then
            if [ "$SUSPENDED" -eq 1 ]; then
                sleep "$DEBOUNCE"
                if ss -tn state established 2>/dev/null | grep -q ':6901 '; then
                    echo "$(date) CONNECTED -> resume Firefox" >> "$LOG"
                    kill -CONT "$FF_PID" 2>/dev/null || true
                    SUSPENDED=0
                fi
            fi
        else
            if [ "$SUSPENDED" -eq 0 ]; then
                sleep "$DEBOUNCE"
                if ! ss -tn state established 2>/dev/null | grep -q ':6901 '; then
                    echo "$(date) DISCONNECTED -> freeze Firefox" >> "$LOG"
                    kill -STOP "$FF_PID" 2>/dev/null || true
                    SUSPENDED=1
                fi
            fi
        fi
    fi
    sleep 2
done
