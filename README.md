# ⚠️ AI-Generated Code
This code was written with AI assistance and has not been formally audited. Review and test before using in production.

# Firefox over Web (KasmVNC)

Lightweight Docker container that runs Firefox inside an Openbox window manager, accessible from any modern web browser via [KasmVNC](https://github.com/kasmtech/KasmVNC) — no RDP/VNC client needed.

Ported from [firefox-rdp](https://github.com/wzcl1/firefox-rdp) with the same lightweight principles: **Debian trixie-slim** + **Openbox** + latest **Firefox**, no XFCE, no full desktop images.

Supports both **amd64** and **arm64** architectures (auto-detected at build time).

Useful for:
- Running a browser remotely without a full desktop environment
- Isolated browsing sessions
- Kiosk-style browser deployments
- Accessing a remote browser from devices where no RDP client is available (just a web browser)

## Quick Start

> **⚠️ Before exposing this port:** Change `VNC_PASSWORD` in `docker-compose.yml` from the default `change-me` to a strong password. The default is for local testing only.

```sh
git clone <this-repo>
cd firefox-web
docker compose up --build -d
```

Open in your browser:

| Setting    | Value                  |
|------------|------------------------|
| URL        | `https://localhost:6901` |
| Username   | `kasm_user`            |
| Password   | `change-me`            |

> Your browser will warn about the self-signed certificate (generated on first start and persisted in the profile volume). Accept it to continue. Safari is not supported for direct KasmVNC connections (it can't pass Basic Auth over WebSockets); use Chrome, Edge, or Firefox.
> **iOS:** Chrome on iOS works. **Safari and Firefox on iOS do not work with direct connections** — both are WebKit under the hood, and WebKit doesn't send Basic Auth on WebSocket connections (Kasm upstream documents Safari as unsupported for direct connections for exactly this reason). This affects the default UI and `/vnc.html` alike, on any KasmVNC version — downgrading won't help. Use Chrome on iOS.

## Features

- **Latest Firefox** — downloads the latest stable release from Mozilla at build time
- **Multi-arch** — amd64 and arm64 auto-detected; correct Firefox binary downloaded per architecture
- **Browser-native access** — KasmVNC 1.5.0 serves the desktop over HTTPS/WebSocket on port 6901; works from any modern browser, including touch scrolling on tablets
- **uBlock Origin** — downloaded from GitHub releases at build time (latest version via API), bundled in the image. Firefox verifies Mozilla's signature at install time — no manual SHA256 needed. Other extensions can still be installed manually.
- **Performance tuned** — Firefox Enterprise Policies plus `user.js` disable background services, speculation, telemetry, and crypto overhead to minimise CPU use in the container.
- **Privacy first** — built-in tracking protection intentionally disabled (uBlock covers it) to avoid the dual-layer CPU cost; ETP, Pocket, telemetry, and account sync are all off.
- **Minimal footprint** — stripped of crash reporter, updater, pingsender, GNOME icons, docs, and other unnecessary files
- **Disconnect sleep** — when you close the browser tab, Firefox is frozen (SIGSTOP) to use zero CPU. On reconnect, it resumes instantly with full session state preserved.
- **Openbox window manager** — lightweight, just enough to give Firefox proper window decorations
- **Rootless runtime** — everything (Xvnc, Openbox, Firefox) runs as the unprivileged `browser` user; the container drops ALL Linux capabilities

## Configuration

Environment variables in `docker-compose.yml`:

| Variable            | Default         | Description                            |
|---------------------|-----------------|----------------------------------------|
| `BROWSER_USER`      | `browser`       | Linux username the session runs as (uid 1000) |
| `VNC_PASSWORD`      | `change-me`     | Web login password for `kasm_user` (container refuses to start if unset; docker-compose.yml includes a default for quick start) |
| `VNC_PORT`          | `6901`          | Port the KasmVNC web server listens on inside the container |
| `RESOLUTION`        | `1280x1024`     | Desktop geometry (`WIDTHxHEIGHT`) |
| `FIREFOX_START_URL` | `about:blank`   | URL opened when the session starts |
| `FIREFOX_ARGS`      | `""`            | Extra Firefox CLI arguments |
| `FREEZE_ON_DISCONNECT` | `true`       | Freeze Firefox (SIGSTOP) when no browser tab is connected, to use zero CPU. Set to `false` to keep Firefox running when disconnected. |
| `FIREFOX_PROCESSES` | auto-detect     | Override `dom.ipc.processCount` (default: scaled by RAM) |
| `FIREFOX_CACHE_MB`  | auto-detect     | Override `browser.cache.memory.capacity` in MB (default: scaled by RAM) |

> **Security note:** `VNC_PASSWORD` is passed as a Docker environment variable, which means it's visible via `docker inspect <container>` and in process listings on the host. Avoid running this alongside untrusted workloads. For production use, consider mounting the password as a file secret or using Docker secrets instead of a plain environment variable.

### Example with custom options

```yaml
services:
  firefox-web:
    build: .
    ports:
      # Default: only listen on localhost — remove 127.0.0.1 prefix to expose on all interfaces
      - "127.0.0.1:6901:6901"
    environment:
      VNC_PASSWORD: secure-password-here
      RESOLUTION: 1920x1080
      FIREFOX_START_URL: https://example.com
      FIREFOX_ARGS: --kiosk
    shm_size: "2gb"
    restart: unless-stopped
```

## Performance & Privacy Tuning

The container applies two layers of Firefox configuration. The primary goal is **minimising CPU usage** for a single-user session in a constrained container. Privacy and clean-state behaviour are secondary benefits.

### Firefox Enterprise Policies (`/opt/firefox/distribution/policies.json`)

Applied at startup, locked so the user cannot override them. Shipped as `policies.json` in this repo (copied verbatim from the RDP variant: uBlock force-install, DNS-over-HTTPS on, telemetry off).

| Group | Settings | Reason |
|-------|----------|--------|
| **Telemetry & accounts** | `DisableTelemetry`, `DisableFirefoxStudies`, `DisableFeedbackCommands`, `DisableFirefoxAccounts`, `DisableSystemAddonUpdate`, `DisableDeveloperTools` | Eliminates background reporting, A/B experiments, and dev-tools overhead. Accounts disabled because there's no use for sync in a single-session container. |
| **Auto-updates** | `AppAutoUpdate`, `BackgroundAppUpdate`, `ExtensionUpdate` = `false` | Updates happen at Docker image build time, never at runtime. Stops periodic update-check network calls. |
| **Tracking & content** | `EnableTrackingProtection: false` (locked), `FirefoxHome.*` (all off, locked), `Homepage` = `about:blank` (locked), `SearchSuggestEnabled`, `FirefoxSuggest.*`, `VisualSearchEnabled` = `false` | uBlock Origin is force-installed and covers ad/tracking filtering; running ETP on top duplicates that CPU work. Disabling Firefox Home and Suggest eliminates background feeds. |
| **New Tab & search** | `NoDefaultBookmarks`, `OverrideFirstRunPage` / `OverridePostUpdatePage` = `""` | Clean profile, no marketing/onboarding pages. |
| **Extensions** | `uBlock0@raymondhill.net` = `force_installed` from local `.xpi` | uBlock Origin is bundled in the image (downloaded from GitHub at build time) and locked. Firefox verifies Mozilla's addon signature at install time — no manual SHA256 needed. Other extensions can still be installed manually from AMO or as local `.xpi` files (including temporary installs via `about:debugging`). |
| **Network** | `DNSOverHTTPS` = `true` (locked), `PostQuantumKeyAgreementEnabled` = `false`, `DisableEncryptedClientHello` = `false` | DNS-over-HTTPS is enabled for encrypted, privacy-preserving resolution. Post-quantum key agreement is off to reduce per-connection CPU cost. Encrypted Client Hello is left at its default (not disabled). |
| **Disabled APIs** | `TranslateEnabled`, `XSLTEnabled`, `PictureInPicture` (locked), `PrintingEnabled` = `false` | Translation, XSLT transforms, and print preview rendering are heavy. PiP would spin up an extra video-decode pipeline. |
| **Browser cleanup** | `DisableFormHistory`, `PasswordManagerEnabled`, `OfferToSaveLogins` = `false` | No password manager; form history disabled. No `SanitizeOnShutdown`, so the Firefox profile persists across disconnect/reconnect and container restarts. |
| **Misc hardening** | `SkipTermsOfUse`, `DontCheckDefaultBrowser`, `DisableSetDesktopBackground`, `DisableBuiltinPDFViewer` = `false`, `GoToIntranetSiteForSingleWordEntryInAddressBar` = `false`, `IPProtectionAvailable` = `false` | Skips onboarding dialogs and silent connections. PDF viewer left enabled — its CPU cost is bounded to active viewing (idle tabs do nothing). |

### `user.js` Profile Preferences (written by `browser-session.sh`)

The `user.js` is regenerated on every session start so updates take effect. It complements the policy layer with about:config tweaks Firefox doesn't expose via policies.

| Category | Prefs | Reason |
|----------|-------|--------|
| **GPU & media** | `gfx.webrender.enabled`, `media.hardware-video-decoding.enabled`, `media.ffmpeg.vaapi.enabled`, `layers.acceleration.disabled`, `webgl.disabled`, `gfx.canvas.accelerated` = all off | No GPU in container. WebRender / hardware video decode / canvas acceleration would either fail or force a CPU fallback path. |
| **Animation** | `general.smoothScroll` = `false`, `layout.animation.prefers-reduced-motion` = `1`, `image.animation_mode` = `"none"`, `nglayout.initialpaint.delay` = 0, `content.notify.interval` = 100000 | Disables smooth scrolling, CSS animations, and animated GIFs; eliminates initial paint delay and speeds up reflow notifications. |
| **Image memory** | `image.mem.decode_bytes_at_a_time` = 65536, `image.mem.surfacecache.max_size_kb` = 32768, `image.mem.surfacecache.min_expiration_ms` = 500 | Uses fewer, larger decode chunks; caps decoded image cache; evicts surfaces faster under memory pressure. |
| **Process model** | `dom.ipc.processCount` scaled by available RAM | Auto-detects memory limit from cgroup v2/v1 or `/proc/meminfo`, using the minimum to avoid overestimation in containers. Sets process count: <1 GB→1, 1–2 GB→2, 2–4 GB→4, 4–8 GB→6, ≥8 GB→8. Override via `FIREFOX_PROCESSES` env var. |
| **Cache** | `browser.cache.disk.enable` = `false`, `browser.cache.memory.enable` = `true`, `browser.cache.memory.capacity` scaled by RAM | Memory cache scales with available RAM: <1 GB→32MB, 1–2 GB→64MB, 2–4 GB→128MB, 4–8 GB→256MB, ≥8 GB→512MB. Override via `FIREFOX_CACHE_MB` env var. Firefox profile and cache persist across restarts via a named Docker volume. |
| **Session restore** | `browser.sessionhistory.max_entries` = 10, `browser.sessionhistory.max_total_viewers` = 0, `browser.sessionstore.max_tabs_undo` = 0, `browser.sessionstore.privacy_level` = 2, `browser.sessionstore.interval` = 30s, `browser.sessionrestore.restore_on_demand` = `true` | Bounded back/forward list; no cached BFCache renders; no recently-closed-tabs undo; tabs restored on demand to save memory. |
| **Network prediction** | `network.predictor.enabled` = `false`, `network.prefetch-next` = `false`, `network.dns.disablePrefetch` = `true`, `network.dns.disablePrefetchFromHTTPS` = `true`, `network.http.speculative-parallel-limit` = 0, `browser.places.speculativeConnect.enabled` = `false`, `browser.urlbar.speculativeConnect.enabled` = `false` | Kills all background pre-connection / pre-resolution work. |
| **Connection limits** | `network.http.max-connections` = 48, `network.http.max-persistent-connections-per-server` = 6, `network.dnsCacheEntries` = 256, `network.dnsCacheExpiration` = 3600, `network.dnsCacheExpirationGracePeriod` = 240, `network.ssl_tokens_cache_capacity` = 1000 | Lower total connection count (Firefox default is 6 per server); DNS cached for 1 hour with 4-minute grace; reduced TLS session cache to bound resource usage. |
| **TLS** | `security.ssl.enable_ocsp_stapling` = `false` | Disables OCSP stapling to avoid extra round-trips and CPU cost per TLS handshake. |
| **Background services** | `network.captive-portal-service.enabled`, `network.connectivity-service.enabled`, `browser.casting.enabled`, `media.gmp-gmpopenh264.enabled`, `app.update.enabled` = `false`, `extensions.getAddons.cache.enabled`, `lightweightThemes.update.enabled` = `false`, `browser.topsites.contile.enabled` = `false`, `network.process.enabled` = `false`, `media.rdd-process.enabled` = `false`, `dom.ipc.processCount.webIsolated` = 1 | Stops periodic HTTP probes, mDNS cast discovery, OpenH264 download, add-on metadata fetches; disables separate network and remote data decoder processes; caps site-isolation to 1 process. |
| **Tab & memory pressure** | `browser.tabs.unloadOnLowMemory` = `true`, `browser.low_commit_space_threshold_mb` = 256, `browser.pagethumbnails.capturing_disabled` = `true`, `browser.newtabpage.activity-stream.enabled` = `false` | Drops tabs under memory pressure; disables off-screen thumbnail rendering and activity-stream feeds. |
| **Media & content** | `media.autoplay.default` = 5, `media.video_stats.enabled` = `false`, `gfx.font_rendering.opentype_svg.enabled` = `false`, `javascript.options.asmjs` = `true`, `camera.control.face_detection.enabled` = `false` | Blocks autoplay video decode; removes per-frame and per-glyph CPU overhead from features we don't use. |
| **UI noise** | `browser.startup.homepage_override.mstone` = `ignore`, `browser.startup.blankWindow` = `false`, `accessibility.force_disabled` = 1, `clipboard.autocopy` = `false` | Suppresses the blank-window flash during startup, the accessibility walker, and Linux selection autocopy. |
| **Telemetry** | `app.normandy.enabled`, `app.shield.optoutstudies.enabled`, `browser.newtabpage.activity-stream.feeds.telemetry`, `browser.newtabpage.activity-stream.telemetry`, `browser.ping-centre.telemetry`, `toolkit.telemetry.unified`, `datareporting.healthreport.uploadEnabled` = `false`; `toolkit.coverage.opt-out` = `true`; `browser.contentblocking.report.endpoint_url` = `""` | Disables all telemetry, Shield experiments, health reporting, and content-blocking reporting to eliminate background network calls and CPU overhead. |

## Disconnect Sleep

When you close the browser tab (or lose network), a watchdog process detects that no TCP connection to port 6901 remains and sends `SIGSTOP` to Firefox. This completely freezes the process — zero CPU usage, zero network activity, while keeping the full session state in memory.

When you reconnect (open `https://localhost:6901` and log in again), the watchdog detects the new connection and sends `SIGCONT` to resume Firefox exactly where you left it.

This behaviour is controlled by the `FREEZE_ON_DISCONNECT` environment variable (default: `true`). Set it to `false` in `docker-compose.yml` to keep Firefox running when disconnected — useful if you want background processes or downloads to continue during disconnection.

| Behaviour | Detail |
|-----------|--------|
| Detection | Polls `ss -tn state established | grep ':6901 '` every 2 seconds |
| Debounce | 1-second confirmation delay before acting on state change, preventing thrashing from connection flaps |
| Freeze | `SIGSTOP` — process suspended by kernel, zero CPU |
| Thaw | `SIGCONT` — process resumes instantly |
| Memory | Stays in RAM (not swapped to disk) |
| Log | Bounded to 1MB with automatic rotation |
| Profile | Persists across disconnect/reconnect and container restart via Docker volume |
| Config | `FREEZE_ON_DISCONNECT=true` (default) to freeze, `false` to keep running |

This is transparent to the user — connect, browse, disconnect, reconnect, and your tabs are exactly where you left them.

## Building from source

```sh
docker compose up --build -d
```

Docker BuildKit automatically provides `TARGETARCH` during the build. The `Dockerfile` uses it to select the correct Firefox download URL (`linux64` for amd64, `linux64-aarch64` for arm64) and the correct KasmVNC `.deb` (`trixie` build, falling back to `bookworm` if the trixie asset is unavailable).

## Architecture support

| Architecture | Firefox binary                        | KasmVNC package | Status |
|--------------|---------------------------------------|-----------------|--------|
| amd64        | `linux64` (official Mozilla build)    | `kasmvncserver_trixie_1.5.0_amd64.deb` | Tested |
| arm64        | `linux64-aarch64` (official Mozilla build) | `kasmvncserver_trixie_1.5.0_arm64.deb` | Build only |

No `image` tag is set in `docker-compose.yml` — the image is always built locally for your architecture.

## Security

- `VNC_PASSWORD` is required — the container will refuse to start if not set
- KasmVNC uses password-based login (`kasm_user` + `VNC_PASSWORD`) over HTTPS — put it behind a VPN, SSH tunnel, or trusted private network for real deployments
- The container runs with `--shm-size=2gb` to prevent browser crashes from Docker's small default shared memory
- **Firefox content sandbox runs at level 1** (seccomp-bpf only) — provides syscall filtering without requiring nested user namespaces, which are blocked in rootless Docker. No `--no-sandbox` flag is used.
- **machine-id** is generated at container startup (`dbus-uuidgen`) to enable D-Bus session bus
- The KasmVNC web server uses a **self-signed certificate** generated on first start (persisted in the `firefox-profile` volume). Expect a browser warning on first visit.

> **Supply chain risk:** The Dockerfile downloads Firefox, uBlock Origin, and KasmVNC without version pinning beyond release tags or SHA checksum verification. A compromised or MITM'd download could supply tampered binaries. For untrusted build environments, pin to specific versions and verify checksums before running.

### Privilege model

The container runs fully unprivileged — there is no root process at runtime (unlike the RDP variant, which needs root for xrdp/sesman):

| Process | User | Why |
|---------|------|-----|
| `Xvnc` / `vncserver` | `BROWSER_USER` | Binds unprivileged port 6901, manages its own session — needs no root |
| `web-watchdog` | `BROWSER_USER` | Monitors TCP state and signals Firefox (same-uid processes) |
| Firefox + Openbox | `BROWSER_USER` | Runs fully unprivileged in the VNC session |

Additional hardening in `docker-compose.yml`:

- **`cap_drop: [ALL]` with no `cap_add`** — all Linux capabilities are dropped and none are restored
- **Unprivileged user** — the image defaults to `USER browser` (uid 1000)
- **`tmpfs` mounts** — `/tmp`, `/var`, `/run` are in-memory filesystems with bounded sizes
- **Named volume** — `/home/browser` (Firefox profile, extensions, bookmarks, VNC config, TLS cert) is stored in the `firefox-profile` Docker volume, persisting across container restarts and only destroyed when the volume is explicitly removed

For defense-in-depth, the default compose file binds to `127.0.0.1:6901` (localhost only). Remove the `127.0.0.1` prefix to expose on all interfaces, or use an SSH tunnel / Tailscale sidecar for network-accessible deployments.

### Health check

The Dockerfile includes a `HEALTHCHECK` that verifies KasmVNC is listening on port 6901 every 30 seconds. This allows Docker and orchestrators to detect a broken container and restart it automatically.

| Parameter | Value |
|-----------|-------|
| Interval | 30 seconds |
| Timeout | 5 seconds |
| Start period | 10 seconds |
| Retries | 3 |

### Extension surface

uBlock Origin is force-installed and cannot be removed. The `.xpi` is downloaded from GitHub at build time (latest version via API) and bundled in the image. Firefox verifies Mozilla's addon signature at install time — no manual SHA256 verification needed. Other extensions can be installed from AMO or as local `.xpi` files (including temporary installs via `about:debugging`).

## How it works

1. The container starts `vncserver :1` (KasmVNC) as the unprivileged user, plus a background watchdog process
2. The entrypoint renders `~/.vnc/kasmvnc.yaml` from the `kasmvnc.yaml` template (port, resolution, TLS cert, password file), sets the `kasm_user` password non-interactively from `VNC_PASSWORD`, and generates a self-signed TLS cert on first start
3. `vncserver` runs `~/.vnc/xstartup`, which launches Openbox as the window manager and Firefox with a pre-configured profile
4. The watchdog monitors web connections to port 6901 every 2 seconds, with a 1-second debounce to prevent rapid state changes
5. When the last browser tab disconnects, the watchdog sends `SIGSTOP` to Firefox (zero CPU, stays in RAM). On reconnect, it sends `SIGCONT` to resume instantly
6. Firefox Enterprise Policies (`policies.json`) force-install uBlock Origin from the bundled `.xpi` (Mozilla's signature is verified at install time), lock the Firefox Home page to `about:blank`, disable telemetry/updates/PiP, and enable DNS-over-HTTPS
7. Firefox `user.js` (regenerated each session) applies container-optimised about:config preferences: WebRender and hardware video decode off, GPU acceleration disabled, content processes capped by available RAM, all background services and speculative connections disabled
8. Firefox content sandbox runs at level 1 (seccomp-bpf) — provides syscall filtering without requiring nested user namespaces, which are blocked in rootless Docker
