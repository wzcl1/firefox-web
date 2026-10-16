FROM debian:trixie-slim

# Security note: unlike the RDP variant, nothing here needs root at runtime.
# KasmVNC's Xvnc binds an unprivileged port (6901) and runs fully as the
# unprivileged BROWSER_USER. The image defaults to USER browser, so the
# entrypoint, vncserver, watchdog, Openbox and Firefox all run unprivileged.
# docker-compose.yml applies defense-in-depth: cap_drop ALL with no cap_add.

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    BROWSER_USER=browser \
    VNC_PORT=6901 \
    RESOLUTION=1280x1024 \
    FIREFOX_START_URL=about:blank \
    FIREFOX_ARGS="" \
    FREEZE_ON_DISCONNECT=true \
    DISCONNECT_GRACE_SECONDS=20 \
    DISABLE_VNC_AUTH=false \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Layer 1: system packages + KasmVNC (rarely changes)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        dbus-x11 \
        fonts-dejavu \
        fonts-liberation \
        libasound2 \
        libdbus-glib-1-2 \
        libgtk-3-0 \
        libpulse0 \
        libxt6 \
        iproute2 \
        openbox \
        openssl \
        procps \
        pulseaudio-utils \
        tini \
        wget \
        x11-xserver-utils \
        xauth \
        xdg-utils \
        x11-utils \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Layer 1b: KasmVNC 1.5.0 server (arch-aware, trixie .deb with bookworm fallback)
# TARGETARCH is amd64/arm64, which matches the KasmVNC asset arch names directly.
RUN if [ "$TARGETARCH" = "arm64" ]; then KVNC_ARCH="arm64"; else KVNC_ARCH="amd64"; fi \
    && (wget -O /tmp/kasmvnc.deb "https://github.com/kasmtech/KasmVNC/releases/download/v1.5.0/kasmvncserver_trixie_1.5.0_${KVNC_ARCH}.deb" \
        || wget -O /tmp/kasmvnc.deb "https://github.com/kasmtech/KasmVNC/releases/download/v1.5.0/kasmvncserver_bookworm_1.5.0_${KVNC_ARCH}.deb") \
    && (dpkg -i /tmp/kasmvnc.deb || (apt-get update && apt-get install -yf --no-install-recommends && dpkg -i /tmp/kasmvnc.deb)) \
    && rm -f /tmp/kasmvnc.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Layer 2: Firefox + uBlock (rarely changes, ~250MB cached)
RUN if [ "$TARGETARCH" = "arm64" ]; then FIREFOX_ARCH="linux64-aarch64"; else FIREFOX_ARCH="linux64"; fi \
    && wget -O /tmp/firefox.tar.xz "https://download.mozilla.org/?product=firefox-latest-ssl&os=${FIREFOX_ARCH}&lang=en-US" \
    && tar -xJf /tmp/firefox.tar.xz -C /opt \
    && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
    && rm -f /tmp/firefox.tar.xz \
    && mkdir -p /opt/firefox/distribution/extensions \
    && UBLOCK_URL=$(wget -qO- https://api.github.com/repos/gorhill/uBlock/releases/latest \
         | grep "browser_download_url.*firefox.signed.xpi" \
         | head -1 | cut -d'"' -f4) \
     && if [ -z "$UBLOCK_URL" ]; then echo "ERROR: failed to resolve uBlock Origin download URL" >&2; exit 1; fi \
      && wget -O "/opt/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi" "$UBLOCK_URL" \
      && mkdir -p /opt/firefox/defaults/pref \
      && echo 'pref("security.sandbox.warn_for_disabled_sandbox", false);' > /opt/firefox/defaults/pref/sandbox-prefs.js \
      && echo 'pref("security.sandbox.content.level", 1);' >> /opt/firefox/defaults/pref/sandbox-prefs.js \
      && rm -rf /opt/firefox/crashreporter /opt/firefox/crashhelper /opt/firefox/pingsender /opt/firefox/updater /opt/firefox/updater.ini /opt/firefox/update-settings.ini /opt/firefox/vaapitest /opt/firefox/glxtest \
      && apt-get purge -y --auto-remove wget xz-utils \
      && rm -rf /tmp/* /var/tmp/*

COPY policies.json /opt/firefox/distribution/policies.json

# Layer 3: user creation (rarely changes)
# KasmVNC needs no SETUID/SETGID and runs rootless — the image defaults to
# the unprivileged user. Persistent volumes inherit ownership from this dir.
RUN addgroup --gid 1000 browser \
    && adduser --disabled-password --gecos "" --uid 1000 --ingroup browser --shell /bin/bash browser \
    && mkdir -p /home/browser/.config/openbox /home/browser/.vnc \
    && chmod 755 /home/browser /home/browser/.config /home/browser/.config/openbox \
    && chown -R browser:browser /home/browser

# Layer 4: scripts + KasmVNC template (changes most often — only this layer rebuilds)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY browser-session.sh /usr/local/bin/browser-session.sh
COPY web-watchdog.sh /usr/local/bin/web-watchdog.sh
COPY kasmvnc.yaml /etc/kasmvnc/kasmvnc.yaml.template

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/browser-session.sh /usr/local/bin/web-watchdog.sh \
    && sed -i 's/\r$//' /usr/local/bin/browser-session.sh

EXPOSE 6901

USER browser

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ss -tln state listening sport :6901 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
