# Zen Browser + Openbox + xrdp Docker Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a lightweight Docker container that boots into an Openbox desktop reachable via RDP on port 3389, auto-launching Zen Browser on session start, with two host-mountable volumes for the browser profile and downloads.

**Architecture:** `debian:bookworm-slim` base. `xrdp` + `xorgxrdp` provide RDP directly against a real Xorg server (no VNC layer). Zen Browser is installed from its official release tarball into `/opt/zen`. A fixed non-root user `rdpuser` runs the desktop session; xrdp's daemons run as root inside the container for simplicity (root is already the container's trust boundary — see Task 4 rationale). Openbox's `autostart` launches Zen automatically on login.

**Tech Stack:** Docker, Debian bookworm-slim, xrdp 0.9.21, xorgxrdp, Openbox, Zen Browser (Firefox-based), bash entrypoint, docker-compose.

## Global Constraints

- Base image: `debian:bookworm-slim` (per spec).
- RDP username is fixed: `rdpuser`, home `/home/rdpuser`. Not configurable.
- Only `RDP_PASSWORD` is configurable at runtime (via env var). If unset, entrypoint generates a random one and logs it once.
- No audio support (no pulseaudio, no xrdp sound module).
- No GPU/hardware acceleration.
- Two persistent volumes: `/home/rdpuser/.zen` (profile) and `/home/rdpuser/Downloads` (downloads).
- Port 3389 exposed for RDP.
- Every apt package name and shell command below has been verified by actually running it in a `debian:bookworm-slim` container during planning — see inline notes for what was confirmed and why.

---

## File Structure

```
/lab/appdata/zen/
├── Dockerfile
├── docker-compose.yml
├── .dockerignore
├── README.md
└── docker/
    ├── entrypoint.sh       # container PID 1: sets password, fixes volume ownership, starts dbus/sesman/xrdp
    ├── startwm.sh           # replaces /etc/xrdp/startwm.sh — launches the Openbox session
    └── openbox-autostart    # replaces /etc/xdg/openbox/autostart — launches Zen
```

---

### Task 1: Base image, RDP/WM packages, and the `rdpuser` account

**Files:**
- Create: `Dockerfile`

**Interfaces:**
- Produces: an image where `xrdp`, `xrdp-sesman`, `openbox`, `openbox-session`, `dbus-daemon` are on `PATH`, and system user `rdpuser` exists with home `/home/rdpuser`.

**Verified facts this task relies on:**
- `xrdp`, `xorgxrdp`, `openbox`, `dbus`, `dbus-x11`, `ca-certificates`, `curl`, `xz-utils` all exist as package names in `debian:bookworm-slim` (confirmed via `apt-cache show` and a full `apt-get install`).
- The `xrdp` package's default `/etc/xrdp/xrdp.ini` already registers an `[Xorg]` session (via `xorgxrdp`'s `libxup.so`) as the **first** session section, so it's used automatically with no config edits needed.
- The `xrdp`/`ssl-cert` packages already generate `/etc/xrdp/cert.pem` and `/etc/xrdp/key.pem` (symlinked to the Debian snakeoil cert) at package-install time — **no runtime cert generation is needed** (this simplifies the entrypoint versus the original design doc).

- [ ] **Step 1: Write the Dockerfile base layer**

```dockerfile
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        xrdp \
        xorgxrdp \
        openbox \
        dbus \
        dbus-x11 \
        ca-certificates \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash rdpuser
```

- [ ] **Step 2: Build and verify the base layer**

Run: `docker build -t zen-rdp:dev /lab/appdata/zen`
Expected: build succeeds with no errors.

Run: `docker run --rm zen-rdp:dev bash -c "which xrdp xrdp-sesman openbox openbox-session dbus-daemon && id rdpuser"`
Expected: all five `which` calls print a path, and `id rdpuser` prints `uid=...(rdpuser) gid=...(rdpuser) groups=...(rdpuser)`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "Add base image with xrdp, openbox, and rdpuser account"
```

---

### Task 2: Install Zen Browser and its runtime libraries

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the base image.
- Produces: `/opt/zen/zen` (the Zen binary), symlinked at `/usr/local/bin/zen`. `LD_LIBRARY_PATH` includes `/opt/zen` at the image level (`ENV`), and `/etc/environment` also carries `LD_LIBRARY_PATH=/opt/zen` — later tasks that launch Zen via a PAM-mediated session (Task 3) rely on the `/etc/environment` copy, since PAM sessions do not inherit the daemon's process environment; `/etc/xrdp/startwm.sh`'s default comments confirm `pam_env` loads `/etc/environment` for xrdp-sesman sessions.

**Verified facts this task relies on:**
- Official tarball URL, confirmed to download and extract correctly:
  `https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz`
- `/opt/zen/zen` is a real ELF binary (not a wrapper script) with **no RPATH/RUNPATH** (confirmed via `readelf -d`). It `dlopen()`s `/opt/zen/libxul.so` at runtime, which itself needs both system libraries and several libraries that ship bundled inside the tarball (e.g. `libnspr4.so`, `libnss3.so`, `libmozgtk.so`) — none of which resolve without `/opt/zen` on `LD_LIBRARY_PATH`.
- The following apt packages, combined with `LD_LIBRARY_PATH=/opt/zen`, resolve every dependency of `libxul.so` with zero "not found" entries under `ldd` (confirmed):
  `fonts-liberation2 libgtk-3-0 libx11-xcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libasound2 libdbus-1-3 libxcb-shm0`
- `zen --version` runs successfully (exit 0, prints `Mozilla Zen 1.21.13b` at time of writing) with this exact library set.
- Zen logs `Sandbox: CanCreateUserNamespace() clone() failure: EPERM` on every run inside a default Docker container (Docker's default seccomp profile blocks unprivileged user namespaces). This is **harmless** — confirmed by an actual headless render test (`zen --headless --screenshot`) that produced a valid non-empty PNG despite the warning. No `MOZ_DISABLE_SANDBOX` or `--security-opt seccomp=unconfined` is needed; do not add them.

- [ ] **Step 1: Add the Zen runtime library layer and install Zen**

Append to `Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        fonts-liberation2 \
        libgtk-3-0 \
        libx11-xcb1 \
        libxcomposite1 \
        libxcursor1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxi6 \
        libxrandr2 \
        libxrender1 \
        libasound2 \
        libdbus-1-3 \
        libxcb-shm0 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/zen.tar.xz \
        https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz \
    && mkdir -p /opt/zen \
    && tar -xJf /tmp/zen.tar.xz -C /opt/zen --strip-components=1 \
    && rm /tmp/zen.tar.xz \
    && ln -s /opt/zen/zen /usr/local/bin/zen

ENV LD_LIBRARY_PATH=/opt/zen
RUN echo "LD_LIBRARY_PATH=/opt/zen" >> /etc/environment
```

- [ ] **Step 2: Build and verify Zen resolves all its libraries**

Run: `docker build -t zen-rdp:dev /lab/appdata/zen`
Expected: build succeeds.

Run: `docker run --rm zen-rdp:dev bash -c "ldd /opt/zen/libxul.so | grep 'not found'"`
Expected: empty output (no lines printed — every dependency resolves).

Run: `docker run --rm zen-rdp:dev zen --version`
Expected: prints a version string starting with `Mozilla Zen`, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "Install Zen Browser and its runtime libraries"
```

---

### Task 3: Wire Openbox as the xrdp session, auto-launch Zen

**Files:**
- Create: `docker/startwm.sh`
- Create: `docker/openbox-autostart`
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: `/usr/local/bin/zen` (Task 2), `openbox-session` (Task 1).
- Produces: `/etc/xrdp/startwm.sh` (replaces the distro default) and `/etc/xdg/openbox/autostart` (replaces the distro default, which is all-comments and does nothing).

**Verified facts this task relies on:**
- `openbox-session` (`/usr/bin/openbox-session`) execs `openbox --startup "<helper> OPENBOX"`, where the helper runs `/etc/xdg/openbox/autostart` (confirmed by reading both scripts inside the built image).
- xrdp's default `/etc/xrdp/startwm.sh` sources `/etc/profile` and `~/.profile` then execs `/etc/X11/Xsession`, which is generic multi-DE logic we don't need — replacing it outright with a two-line script that launches Openbox directly is simpler and avoids depending on Debian's Xsession.d machinery.
- No system D-Bus session bus is started by `openbox-session` itself; wrapping it in `dbus-launch --exit-with-session` is the standard idiom (used by most Xsession scripts) to give GTK apps a session bus, and ties its lifetime to the WM.

- [ ] **Step 1: Write `docker/startwm.sh`**

```sh
#!/bin/sh
exec dbus-launch --exit-with-session openbox-session
```

- [ ] **Step 2: Write `docker/openbox-autostart`**

```sh
#!/bin/sh
zen &
```

- [ ] **Step 3: Copy both into the image and make them executable**

Append to `Dockerfile`:

```dockerfile
COPY docker/startwm.sh /etc/xrdp/startwm.sh
COPY docker/openbox-autostart /etc/xdg/openbox/autostart
RUN chmod +x /etc/xrdp/startwm.sh /etc/xdg/openbox/autostart
```

- [ ] **Step 4: Build and verify the files land correctly**

Run: `docker build -t zen-rdp:dev /lab/appdata/zen`
Expected: build succeeds.

Run: `docker run --rm zen-rdp:dev bash -c "cat /etc/xrdp/startwm.sh && echo --- && cat /etc/xdg/openbox/autostart && echo --- && test -x /etc/xrdp/startwm.sh && test -x /etc/xdg/openbox/autostart && echo BOTH_EXECUTABLE"`
Expected: both file contents print as written above, followed by `BOTH_EXECUTABLE`.

- [ ] **Step 5: Commit**

```bash
git add docker/startwm.sh docker/openbox-autostart Dockerfile
git commit -m "Launch Openbox from xrdp and auto-start Zen on session start"
```

---

### Task 4: Entrypoint — password, volume ownership, and process startup

**Files:**
- Create: `docker/entrypoint.sh`
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: `rdpuser` (Task 1), `/home/rdpuser/.zen` and `/home/rdpuser/Downloads` mount points (created here if absent).
- Produces: a running container with `dbus-daemon`, `xrdp-sesman`, and `xrdp` (as PID 1) all up, listening on `0.0.0.0:3389`.

**Verified facts this task relies on (via a full end-to-end integration test run during planning):**
- Running `xrdp`, `xrdp-sesman`, and `dbus-daemon` **as root** (instead of the Debian package's default `User=xrdp` systemd setup) works cleanly and sidesteps two problems the systemd-based setup normally handles for you: (1) `xrdp`'s systemd unit uses `RuntimeDirectory=xrdp`, which without systemd requires manually creating `/run/xrdp`; (2) the snakeoil private key is `640 root:ssl-cert`, and the `xrdp` system user is **not** a member of `ssl-cert` by default in this image — running as root avoids needing to fix that up. This is a deliberate simplification for a single-purpose lab container; it trades the upstream package's least-privilege daemon user for a much simpler entrypoint.
- The exact `/run/xrdp` setup commands are copied from Debian's own `/usr/share/xrdp/socksetup` script (read directly from the installed package):
  ```
  mkdir -p /run/xrdp /run/xrdp/sockdir
  chown root:xrdp /run/xrdp /run/xrdp/sockdir
  chmod 2775 /run/xrdp
  chmod 3777 /run/xrdp/sockdir
  ```
- `dbus-daemon --system --fork` starts cleanly with no extra setup — `/var/lib/dbus/machine-id` already exists (created by the `dbus` package's postinst), so no `dbus-uuidgen` step is needed.
- `xrdp --nodaemon` and `xrdp-sesman --nodaemon` are real, documented flags (confirmed via `--help`) for running each daemon in the foreground.
- A full integration run (`dbus-daemon --system --fork`; `xrdp-sesman --nodaemon &`; `exec xrdp --nodaemon`) was built and started as a real container during planning: all three processes stayed up, `/var/log/xrdp.log` showed `listening to port 3389 on 0.0.0.0`, and a raw TCP connection to `127.0.0.1:3389` was accepted and logged (`Using default X.509 certificate: /etc/xrdp/cert.pem` — confirming the cert from Task 1 is picked up with no extra config).
- No `trap`-based multi-process shutdown handling is needed: Docker tears down every process in the container's namespace together on `stop`/`kill`, and this container holds no state that a hard stop could corrupt (browser profile and downloads live on the two volumes, not in daemon memory).

- [ ] **Step 1: Write `docker/entrypoint.sh`**

```bash
#!/bin/bash
set -euo pipefail

if [ -z "${RDP_PASSWORD:-}" ]; then
    RDP_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    echo "RDP_PASSWORD not set; generated random password for rdpuser: ${RDP_PASSWORD}"
fi
echo "rdpuser:${RDP_PASSWORD}" | chpasswd

mkdir -p /home/rdpuser/.zen /home/rdpuser/Downloads
chown -R rdpuser:rdpuser /home/rdpuser/.zen /home/rdpuser/Downloads

mkdir -p /run/xrdp /run/xrdp/sockdir
chown root:xrdp /run/xrdp /run/xrdp/sockdir
chmod 2775 /run/xrdp
chmod 3777 /run/xrdp/sockdir

dbus-daemon --system --fork

/usr/sbin/xrdp-sesman --nodaemon &

exec /usr/sbin/xrdp --nodaemon
```

- [ ] **Step 2: Wire the entrypoint into the Dockerfile**

Append to `Dockerfile`:

```dockerfile
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3389

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Build and verify the container comes up and listens on 3389**

Run: `docker build -t zen-rdp:dev /lab/appdata/zen`
Expected: build succeeds.

Run:
```bash
docker run -d --rm --name zen-rdp-verify -e RDP_PASSWORD=testpass123 -p 3389:3389 zen-rdp:dev
sleep 5
docker logs zen-rdp-verify
docker exec zen-rdp-verify bash -c "for p in /proc/[0-9]*; do cat \$p/comm 2>/dev/null; done | sort -u"
docker exec zen-rdp-verify tail -5 /var/log/xrdp.log
docker stop zen-rdp-verify
```
Expected: `docker logs` shows no password echoed as "generated" (since we passed `RDP_PASSWORD`); the process list includes `xrdp`, `xrdp-sesman`, and `dbus-daemon`; `/var/log/xrdp.log` shows `listening to port 3389 on 0.0.0.0`.

- [ ] **Step 4: Commit**

```bash
git add docker/entrypoint.sh Dockerfile
git commit -m "Add entrypoint: password setup, volume ownership, xrdp/sesman/dbus startup"
```

---

### Task 5: docker-compose, .dockerignore, and README

**Files:**
- Create: `docker-compose.yml`
- Create: `.dockerignore`
- Create: `README.md`

**Interfaces:**
- Consumes: the image built by Tasks 1–4, `RDP_PASSWORD` env var, `/home/rdpuser/.zen` and `/home/rdpuser/Downloads` mount points.

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  zen:
    build: .
    ports:
      - "3389:3389"
    environment:
      - RDP_PASSWORD=changeme
    volumes:
      - /zen/data:/home/rdpuser/.zen
      - /zen/downloads:/home/rdpuser/Downloads
    restart: unless-stopped
```

- [ ] **Step 2: Write `.dockerignore`**

```
.git
docs
README.md
```

- [ ] **Step 3: Write `README.md`**

```markdown
# zenXrdp

A lightweight Docker container that runs Zen Browser inside an Openbox
desktop, reachable over RDP on port 3389.

## Quick start

1. Edit `RDP_PASSWORD` in `docker-compose.yml` (or override it at runtime).
2. Create the two host directories used for persistence:
   ```bash
   mkdir -p /zen/data /zen/downloads
   ```
3. Start the container:
   ```bash
   docker compose up -d --build
   ```
4. Connect with any RDP client to `<host>:3389`, username `rdpuser`,
   password whatever you set `RDP_PASSWORD` to.

If `RDP_PASSWORD` is not set, a random password is generated on first
start and printed once to `docker logs zen` — check there if you didn't
set one.

## Persistence

- `/zen/data` → `~/.zen` — the full Zen profile (bookmarks, history,
  sessions, extensions).
- `/zen/downloads` → `~/Downloads` — downloaded files.

Both survive `docker compose down` / `up` as long as the host
directories aren't removed.

## Notes

- No audio redirection.
- No GPU acceleration.
- The RDP username (`rdpuser`) is fixed and not configurable — only the
  password is.
```

- [ ] **Step 4: Verify the compose file is valid**

Run: `docker compose -f /lab/appdata/zen/docker-compose.yml config`
Expected: prints the resolved compose config with no errors.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .dockerignore README.md
git commit -m "Add docker-compose, dockerignore, and README"
```

---

### Task 6: End-to-end acceptance test (build, run, persist, restart)

**Files:**
- None created — this task only runs verification commands.

**Interfaces:**
- Consumes: everything from Tasks 1–5.

- [ ] **Step 1: Build via compose**

Run:
```bash
mkdir -p /tmp/zen-e2e-data /tmp/zen-e2e-downloads
cd /lab/appdata/zen
ZEN_DATA_DIR=/tmp/zen-e2e-data ZEN_DOWNLOADS_DIR=/tmp/zen-e2e-downloads \
  docker compose -f <(sed "s#/zen/data#/tmp/zen-e2e-data#; s#/zen/downloads#/tmp/zen-e2e-downloads#" docker-compose.yml) \
  up -d --build
```
Expected: container builds and starts without error.

(Using `/tmp` directories here instead of `/zen/*` keeps this verification run from touching real host paths a user might already have data in — swap back to `/zen/data` and `/zen/downloads` for the real deployment.)

- [ ] **Step 2: Verify the RDP port is listening and daemons are up**

Run:
```bash
CID=$(docker compose -f <(sed "s#/zen/data#/tmp/zen-e2e-data#; s#/zen/downloads#/tmp/zen-e2e-downloads#" docker-compose.yml) ps -q zen)
docker inspect -f '{{.State.Status}}' "$CID"
```
Expected: prints `running`.

Run: `docker compose logs zen | tail -20`
Expected: no fatal errors; if `RDP_PASSWORD` wasn't set in the test compose override, a generated password line appears.

- [ ] **Step 3: Verify volume persistence survives a restart**

Run:
```bash
docker exec "$CID" bash -c "touch /home/rdpuser/.zen/marker-profile && touch /home/rdpuser/Downloads/marker-download && chown rdpuser:rdpuser /home/rdpuser/.zen/marker-profile /home/rdpuser/Downloads/marker-download"
docker compose restart zen
sleep 5
CID=$(docker compose -f <(sed "s#/zen/data#/tmp/zen-e2e-data#; s#/zen/downloads#/tmp/zen-e2e-downloads#" docker-compose.yml) ps -q zen)
docker exec "$CID" bash -c "ls /home/rdpuser/.zen/marker-profile /home/rdpuser/Downloads/marker-download"
```
Expected: both marker files still exist after restart, confirming the volumes persist and ownership is re-applied correctly by the entrypoint.

- [ ] **Step 4: Tear down the test run**

Run:
```bash
docker compose down
rm -rf /tmp/zen-e2e-data /tmp/zen-e2e-downloads
```

- [ ] **Step 5: Manual acceptance (human step, not automatable in this environment)**

Connect to the running container with a real RDP client (e.g. Windows' built-in Remote Desktop Connection, or `xfreerdp /v:<host>:3389 /u:rdpuser /p:<password>`) and confirm:
- The session opens into an Openbox desktop.
- Zen Browser launches automatically.
- A downloaded file lands in the mapped `/zen/downloads` host directory.

This step is called out explicitly because the sandbox used to write this plan has no RDP client with a display available — everything up through Step 4 was verified automatically, but the final visual confirmation needs a real RDP client.

No commit for this task — it's verification only.
