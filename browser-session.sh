#!/bin/bash

export MOZ_ENABLE_WAYLAND=0
export NO_AT_BRIDGE=1
export XDG_RUNTIME_DIR="/tmp/runtime-${USER:-browser}"
export HOME="${HOME:-/home/${USER:-browser}}"
export MOZ_DISABLE_GMP_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
export DBUS_SESSION_BUS_ADDRESS="autolaunch:"

# KasmVNC sets DISPLAY=:1 for xstartup; default it if somehow unset.
# (No XAUTHORITY handling needed — Xvnc manages its own auth cookie.)
: "${DISPLAY:=:1}"
export DISPLAY
echo "[browser-session] DISPLAY=${DISPLAY:-<unset>}" >&2

# Firefox performance tuning -- disable GPU features in container
export MOZ_WEBRENDER=0
export MOZ_GLX_TEST=0

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Dummy audio sink so <video> with an audio track plays instead of stalling
# on "no audio device". KasmVNC open-source cannot forward audio to your
# browser tab, so playback is silent — the sink just keeps Firefox's media
# pipeline happy. Best-effort: continue without audio if pulse fails.
if [ "${ENABLE_VIDEO:-true}" = "true" ]; then
    if command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
        pactl load-module module-null-sink sink_name=dummy >/dev/null 2>&1 || true
        pactl set-default-sink dummy >/dev/null 2>&1 || true
    fi
fi

dbus-daemon --session 2>&1 &
dbus_pid="$!"
sleep 0.2
if ! kill -0 "$dbus_pid" 2>/dev/null; then
    echo "[browser-session] WARNING: dbus-daemon failed to start. Firefox may degrade." >&2
fi

# Ensure Firefox profile exists before launching
PROFILE_DIR="${HOME}/.mozilla/firefox/default-release"

# --- Dynamic resource allocation based on available memory ---
# Detect memory limit from cgroup v2, cgroup v1, or fallback to /proc/meminfo
# Always use the lowest value between cgroup limit and host RAM so a container
# with an unlimited cgroup still caps to its actual allocation.
_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
_mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
if [ -n "$_mem_max" ] && [ "$_mem_max" != "max" ]; then
    _cgroup_kb=$((_mem_max / 1024))
    if [ "$_cgroup_kb" -lt "$_mem_kb" ]; then
        _mem_kb=$_cgroup_kb
    fi
else
    _mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    case "$_mem_limit" in
        ''|max|9223372036854771712) ;;
        *)
            _cgroup_kb=$((_mem_limit / 1024))
            if [ "$_cgroup_kb" -lt "$_mem_kb" ]; then
                _mem_kb=$_cgroup_kb
            fi
            ;;
    esac
fi
_mem_mb=$((_mem_kb / 1024))

# dom.ipc.processCount: override via FIREFOX_PROCESSES env var
# Compare in KB to avoid truncation loss for containers < 1 GiB
if [ -z "${FIREFOX_PROCESSES:-}" ]; then
    if [ "$_mem_kb" -lt 1048576 ]; then
        FIREFOX_PROCESSES=1
    elif [ "$_mem_kb" -lt 2097152 ]; then
        FIREFOX_PROCESSES=2
    elif [ "$_mem_kb" -lt 4194304 ]; then
        FIREFOX_PROCESSES=4
    elif [ "$_mem_kb" -lt 8388608 ]; then
        FIREFOX_PROCESSES=6
    else
        FIREFOX_PROCESSES=8
    fi
fi

# browser.cache.memory.capacity (KB): scale with available memory
if [ -z "${FIREFOX_CACHE_MB:-}" ]; then
    if [ "$_mem_kb" -lt 1048576 ]; then
        FIREFOX_CACHE_MB=32
    elif [ "$_mem_kb" -lt 2097152 ]; then
        FIREFOX_CACHE_MB=64
    elif [ "$_mem_kb" -lt 4194304 ]; then
        FIREFOX_CACHE_MB=128
    elif [ "$_mem_kb" -lt 8388608 ]; then
        FIREFOX_CACHE_MB=256
    else
        FIREFOX_CACHE_MB=512
    fi
fi
_FIREFOX_CACHE_KB=$((FIREFOX_CACHE_MB * 1024))

echo "[browser-session] Memory: ~${_mem_mb}MB | processes: $FIREFOX_PROCESSES | cache: ${FIREFOX_CACHE_MB}MB" >&2

# Video playback (YouTube etc.) needs system-ffmpeg software decode in the
# RDD process + the OpenH264 GMP for WebRTC/H.264. Both were previously
# disabled for CPU savings, which made most <video> show "format not
# supported". ENABLE_VIDEO=true (default) turns them back on; software
# decode costs CPU while video plays, idle tabs cost nothing extra.
# NOTE: no GPU in container, so hardware decode stays off; audio plays
# into a dummy sink (KasmVNC OSS has no audio forwarding → silent video).
if [ "${ENABLE_VIDEO:-true}" = "true" ]; then
    _FFMPEG_ENABLED=true
    _RDD_ENABLED=true
    _OPENH264_ENABLED=true
    _OPENH264_URL="https://aus5.mozilla.org/update/6/%PRODUCT%/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml"
    _AUTOPLAY_DEFAULT=1
    echo "[browser-session] Video playback: enabled (software ffmpeg + OpenH264, silent — no audio forwarding)" >&2
else
    _FFMPEG_ENABLED=false
    _RDD_ENABLED=false
    _OPENH264_ENABLED=false
    _OPENH264_URL=""
    _AUTOPLAY_DEFAULT=5
    echo "[browser-session] Video playback: disabled (ENABLE_VIDEO=false)" >&2
fi

# Always write/overwrite user.js so pref changes take effect on update
mkdir -p "$PROFILE_DIR"
cat > "$PROFILE_DIR/user.js" << EOF
// Performance tuning for container/RDP environment
user_pref("gfx.webrender.enabled", false);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("media.ffmpeg.vaapi.enabled", false);
user_pref("media.ffmpeg.enabled", ${_FFMPEG_ENABLED});
user_pref("media.ffvpx.enabled", ${_FFMPEG_ENABLED});
user_pref("media.rdd-ffmpeg.enabled", ${_FFMPEG_ENABLED});
user_pref("media.rdd-vpx.enabled", ${_FFMPEG_ENABLED});
user_pref("webgl.disabled", true);
user_pref("layers.acceleration.disabled", true);
user_pref("dom.ipc.processCount", ${FIREFOX_PROCESSES});
user_pref("dom.ipc.processCount.webIsolated", 1);
user_pref("media.rdd-process.enabled", ${_RDD_ENABLED});
user_pref("browser.sessionhistory.max_entries", 10);
user_pref("browser.sessionstore.interval", 30000);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 3);
user_pref("browser.sessionstore.privacy_level", 2);
user_pref("browser.sessionhistory.max_total_viewers", 0);
user_pref("browser.sessionrestore.restore_on_demand", true);
user_pref("browser.sessionrestore.restore_pinned_tabs_on_demand", true);
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", ${_FIREFOX_CACHE_KB});
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.startup.blankWindow", false);
user_pref("browser.pagethumbnails.capturing_disabled", true);
user_pref("browser.newtabpage.activity-stream.enabled", false);
user_pref("browser.topsites.contile.enabled", false);
user_pref("browser.casting.enabled", false);
user_pref("network.http.max-connections", 48);
user_pref("network.http.max-persistent-connections-per-server", 6);
user_pref("network.dnsCacheEntries", 256);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.process.enabled", false);
user_pref("network.dnsCacheExpiration", 3600);
user_pref("network.dnsCacheExpirationGracePeriod", 240);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("browser.places.speculativeConnect.enabled", false);
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("accessibility.force_disabled", 1);
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.low_commit_space_threshold_mb", 256);
user_pref("app.update.enabled", false);
user_pref("media.autoplay.default", ${_AUTOPLAY_DEFAULT});
user_pref("media.gmp-gmpopenh264.enabled", ${_OPENH264_ENABLED});
user_pref("media.gmp-manager.url", "${_OPENH264_URL}");
user_pref("media.video_stats.enabled", false);
user_pref("javascript.options.asmjs", true);
user_pref("javascript.options.baselinejit.threshold", 100);
user_pref("javascript.options.ion.threshold", 1000);
user_pref("gfx.font_rendering.opentype_svg.enabled", false);
user_pref("extensions.getAddons.cache.enabled", false);
user_pref("lightweightThemes.update.enabled", false);
user_pref("camera.control.face_detection.enabled", false);
user_pref("clipboard.autocopy", false);
user_pref("general.smoothScroll", false);
user_pref("layout.animation.prefers-reduced-motion", 1);
user_pref("image.animation_mode", "none");
user_pref("image.mem.decode_bytes_at_a_time", 65536);
user_pref("image.mem.surfacecache.max_size_kb", 32768);
user_pref("image.mem.surfacecache.min_expiration_ms", 500);
user_pref("gfx.canvas.accelerated", false);
user_pref("gfx.content.skia-font-cache-size", 5);
user_pref("nglayout.initialpaint.delay", 0);
user_pref("nglayout.initialpaint.delay_in_oopif", 0);
user_pref("content.notify.interval", 100000);

user_pref("network.ssl_tokens_cache_capacity", 1000);
user_pref("security.ssl.enable_ocsp_stapling", false);
user_pref("app.normandy.enabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.coverage.opt-out", true);
user_pref("browser.contentblocking.report.endpoint_url", "");
user_pref("security.sandbox.warn_for_disabled_sandbox", false);
user_pref("security.sandbox.content.level", 1);
EOF

cleanup() {
    # Thaw Firefox so it can exit cleanly
    pkill -CONT -f "firefox" 2>/dev/null || true
    kill "$dbus_pid" >/dev/null 2>&1 || true
    kill "$wm_pid" >/dev/null 2>&1 || true
    pulseaudio --kill >/dev/null 2>&1 || true
    wait "$dbus_pid" 2>/dev/null || true
    wait "$wm_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

openbox &
wm_pid="$!"
sleep 0.3
if ! kill -0 "$wm_pid" 2>/dev/null; then
    echo "[browser-session] WARNING: Openbox failed to start. Firefox may lack window manager." >&2
fi

# Wait for the X server to be ready (poll to handle edge cases on slow hosts).
for _ in $(seq 1 20); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# Log DISPLAY for debugging
echo "[browser-session] DISPLAY=${DISPLAY:-<unset>} PROFILE=$PROFILE_DIR" >&2

set -- ${FIREFOX_ARGS:-}
firefox --no-remote --new-instance --profile "$PROFILE_DIR" "$@" "${FIREFOX_START_URL:-about:blank}" > /tmp/firefox.log 2>&1 &
firefox_pid=$!
echo "$firefox_pid" > /tmp/firefox.pid
echo "[browser-session] Firefox started with PID $firefox_pid" >&2
wait "$firefox_pid"
echo "[browser-session] Firefox exited with code $?" >&2
rm -f /tmp/firefox.pid
