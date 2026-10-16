#!/bin/bash
set -euo pipefail

# firefox-web entrypoint. Runs as the unprivileged user (image defaults to
# USER browser); no root needed because KasmVNC's Xvnc binds an unprivileged
# port and manages its own session (no root sesman like xrdp).
#
# If started as root (e.g. `docker run --user root`), the user is created if
# missing, owned paths are fixed, and the session is re-exec'd as that user.
# Dropping privileges needs CAP_SETUID/CAP_SETGID — with the default
# `cap_drop: [ALL]` compose file, just run as the image user (default).

user="${BROWSER_USER:-browser}"

if [ "$(id -u)" -eq 0 ]; then
    if ! id "$user" >/dev/null 2>&1; then
        echo "[entrypoint] creating user $user" >&2
        addgroup --gid 1000 "$user" 2>/dev/null || true
        adduser --disabled-password --gecos "" --uid 1000 --ingroup "$user" --shell /bin/bash "$user" 2>/dev/null || \
            useradd -m -u 1000 -g 1000 -s /bin/bash "$user"
    fi
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -z "$home" ] && home="/home/$user"
    mkdir -p "$home"
    chown "$user:$(id -gn "$user")" "$home"
    export BROWSER_USER="$user" HOME="$home" USER="$user"
    echo "[entrypoint] re-exec as $user" >&2
    exec runuser -u "$user" -- /usr/local/bin/entrypoint.sh "$@"
fi

# --- from here on we are the unprivileged session user ---
if [ "${BROWSER_USER:-}" != "$(id -un)" ] && [ -n "${BROWSER_USER:-}" ]; then
    echo "[entrypoint] WARNING: BROWSER_USER=$BROWSER_USER ignored (running as $(id -un))." >&2
    echo "[entrypoint] WARNING: run the container as that user for persistence." >&2
fi
export HOME="${HOME:-/home/$(id -un)}"
export USER="$(id -un)"

if [ -z "${VNC_PASSWORD:-}" ] && [ "${DISABLE_VNC_AUTH:-false}" != "true" ]; then
    echo "ERROR: VNC_PASSWORD must be set (or set DISABLE_VNC_AUTH=true on a trusted network/VPN only)" >&2
    exit 1
fi

# Optional no-auth mode for trusted networks (e.g. Tailscale-only access):
# mobile browsers cache HTTP Basic Auth per-tab and often drop it when the
# app is backgrounded, forcing a re-login on every return. Disabling Kasm
# Basic Auth removes all logins entirely. WARNING: anyone who can reach
# port 6901 gets full browser access — only use behind Tailscale/SSH/VPN
# with the port bound to localhost or a private interface.
DISABLE_VNC_AUTH="${DISABLE_VNC_AUTH:-false}"
EXTRA_VNCSERVER_ARGS=""
if [ "$DISABLE_VNC_AUTH" = "true" ]; then
    echo "[entrypoint] WARNING: DISABLE_VNC_AUTH=true — Kasm login disabled, anyone with network access can use the browser" >&2
    EXTRA_VNCSERVER_ARGS="-disableBasicAuth"
fi

VNC_PORT="${VNC_PORT:-6901}"
RESOLUTION="${RESOLUTION:-1280x1024}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

VNC_DIR="$HOME/.vnc"
PASSWD_FILE="$HOME/.kasmpasswd"
CERT_PEM="$VNC_DIR/self.pem"
CERT_KEY="$VNC_DIR/self.key"

mkdir -p "$HOME/.config/openbox" "$VNC_DIR"
chmod 700 "$VNC_DIR" 2>/dev/null || true

# Openbox autostart (background colour only — session is launched via xstartup)
cat > "$HOME/.config/openbox/autostart" <<'EOF'
xsetroot -solid '#202124' &
EOF

# Pre-create Firefox profile directory and profiles.ini.
# NOTE: docker-compose.yml mounts the named volume at /home/browser.
# If BROWSER_USER is customised, update the volume mount to match
# (e.g. firefox-profile:/home/<user>), otherwise the profile will be
# ephemeral and live on the container overlay.
if [ "$HOME" != "/home/browser" ]; then
    echo "[entrypoint] WARNING: HOME=$HOME but the default volume mounts /home/browser." >&2
    echo "[entrypoint] WARNING: update docker-compose.yml volumes to firefox-profile:$HOME for persistence." >&2
fi
FF_PROFILE="$HOME/.mozilla/firefox"
mkdir -p "$FF_PROFILE/default-release"
chmod -R 700 "$HOME/.mozilla" 2>/dev/null || true
cat > "$FF_PROFILE/profiles.ini" <<PINI
[General]
StartWithLastProfile=1

[Profile0]
Name=default-release
IsRelative=1
Path=default-release
Default=1
PINI

# machine-id enables the D-Bus session bus. Best-effort: /var is tmpfs and
# may not be writable for the unprivileged user; dbus still starts without it.
mkdir -p /var/lib/dbus 2>/dev/null || true
if [ ! -f /var/lib/dbus/machine-id ]; then
    { dbus-uuidgen > /var/lib/dbus/machine-id; } 2>/dev/null || true
fi

# Self-signed TLS cert for the KasmVNC HTTPS/WebSocket listener (if missing).
if [ ! -f "$CERT_PEM" ] || [ ! -f "$CERT_KEY" ]; then
    echo "[entrypoint] generating self-signed TLS certificate" >&2
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$CERT_KEY" -out "$CERT_PEM" -days 3650 -nodes \
        -subj "/CN=firefox-web" 2>/dev/null
    chmod 600 "$CERT_KEY"
    chmod 644 "$CERT_PEM"
fi

# KasmVNC credentials are separate OS-level users: the web login user is
# always kasm_user, set non-interactively from VNC_PASSWORD on every start
# so password changes take effect on container restart. Skipped entirely
# when DISABLE_VNC_AUTH=true.
PASSWD_BIN="$(command -v kasmvncpasswd || command -v vncpasswd || true)"
if [ "$DISABLE_VNC_AUTH" = "true" ]; then
    rm -f "$PASSWD_FILE"
    touch "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
else
    if [ -z "$PASSWD_BIN" ]; then
        echo "ERROR: neither kasmvncpasswd nor vncpasswd found" >&2
        exit 1
    fi
    "$PASSWD_BIN" -d -u kasm_user "$PASSWD_FILE" >/dev/null 2>&1 || true
    printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | "$PASSWD_BIN" -u kasm_user -w -r "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
fi

# Render per-user KasmVNC config from the template.
sed -e "s|__VNC_PORT__|$VNC_PORT|g" \
    -e "s|__CERT_PEM__|$CERT_PEM|g" \
    -e "s|__CERT_KEY__|$CERT_KEY|g" \
    -e "s|__WIDTH__|$WIDTH|g" \
    -e "s|__HEIGHT__|$HEIGHT|g" \
    -e "s|__PASSWD_FILE__|$PASSWD_FILE|g" \
    /etc/kasmvnc/kasmvnc.yaml.template > "$VNC_DIR/kasmvnc.yaml"
chmod 600 "$VNC_DIR/kasmvnc.yaml"

# xstartup is executed by vncserver with DISPLAY already set to :1.
cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
exec /usr/local/bin/browser-session.sh
EOF
chmod +x "$HOME/.vnc/xstartup"
# Marker left by select-de.sh when "manually edit xstartup" is chosen — tells
# vncserver never to prompt for a desktop environment (belt & suspenders next
# to `command_line.prompt: false` in kasmvnc.yaml).
touch "$HOME/.vnc/.de-was-selected"

# Run the watchdog — it only signals Firefox processes and checks TCP state.
# /tmp/firefox.pid is written by browser-session.sh once Firefox starts.
/usr/local/bin/web-watchdog.sh &

echo "[entrypoint] starting vncserver :1 (geometry ${WIDTH}x${HEIGHT}, port $VNC_PORT)" >&2
# shellcheck disable=SC2086
vncserver :1 \
    -geometry "${WIDTH}x${HEIGHT}" \
    -depth 24 \
    -websocketPort "$VNC_PORT" \
    $EXTRA_VNCSERVER_ARGS \
    </dev/null

# vncserver daemonizes; supervise Xvnc in the foreground so the container
# lives with the session and `restart:` recovers it if Xvnc dies.
XVNC_PID=""
for _ in $(seq 1 30); do
    XVNC_PID=$(pgrep -x Xvnc 2>/dev/null | head -1 || true)
    [ -n "$XVNC_PID" ] && break
    sleep 0.5
done
if [ -z "$XVNC_PID" ]; then
    echo "ERROR: Xvnc failed to start; see $VNC_DIR/*.log" >&2
    cat "$VNC_DIR"/*.log 2>/dev/null || true
    exit 1
fi
echo "[entrypoint] Xvnc running as PID $XVNC_PID" >&2

cleanup() {
    echo "[entrypoint] stopping session" >&2
    vncserver -kill :1 >/dev/null 2>&1 || kill "$XVNC_PID" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

while kill -0 "$XVNC_PID" 2>/dev/null; do
    sleep 5
done
echo "[entrypoint] Xvnc exited; container stopping" >&2
exit 1
