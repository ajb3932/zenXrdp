# Zen Browser + Openbox + xrdp Docker Container — Design

Date: 2026-08-07

## Goal

A lightweight Docker container that boots into a remote Linux desktop
(Openbox window manager) reachable via RDP on port 3389, auto-launching
Zen Browser (zen-browser.app) on session start.

## Architecture

- **Base image**: `debian:bookworm-slim`
- **Window manager**: Openbox
- **RDP stack**: `xrdp` (session broker/listener on 3389) + `xorgxrdp`
  (X driver that speaks RDP directly). No VNC layer, no dummy video
  driver — `xorgxrdp` plugs into the X server as its video driver,
  which is lighter and lower-latency than a common Xvnc-behind-xrdp
  setup.
- **Browser**: Zen Browser, installed from the official release
  tarball (`https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz`,
  per https://docs.zen-browser.app/guides/install-linux), extracted to
  `/opt/zen`, symlinked to `/usr/local/bin/zen`. Auto-launched by
  Openbox's `autostart` script so an RDP login lands directly in the
  browser.
- **Audio**: none. No pulseaudio / xrdp sound module.
- **User**: fixed non-root system user `rdpuser`, home
  `/home/rdpuser`. xrdp's master process runs as root (required to
  bind port 3389 and perform PAM auth); the actual desktop session
  runs as `rdpuser` via sesman/PAM, same as any standard xrdp install.
  The username is not configurable — only the password is, via
  `RDP_PASSWORD`. Fixing the username removes an entire class of
  complexity (home dir path templating, UID drift between runs,
  compose path templating) for no real benefit, since a single-user
  lab container has no reason to vary its login name.

## Build (Dockerfile)

- `apt-get install`: `xrdp xorgxrdp openbox dbus-x11 fonts-liberation2
  ca-certificates curl xz-utils`
- Create system user `rdpuser` with home `/home/rdpuser`
- Download and extract the Zen tarball to `/opt/zen`, symlink the
  `zen` binary to `/usr/local/bin/zen`
- Copy in:
  - entrypoint script
  - Openbox `autostart` (execs `zen` on session start)
  - xrdp `startwm.sh` override (execs `openbox-session` instead of
    the distro's default WM fallback)
- `EXPOSE 3389`

## Runtime (entrypoint)

1. Set `rdpuser`'s password from `RDP_PASSWORD` via `chpasswd`. If
   `RDP_PASSWORD` is unset, generate a random password and print it to
   the container logs once (never silently blank).
2. `chown -R rdpuser:rdpuser` the two volume mount points (profile dir,
   Downloads dir) so ownership is correct regardless of how the volume
   was created on the host.
3. Generate the xrdp TLS certificate if it doesn't already exist
   (standard xrdp self-signed cert, regenerated per-container since
   certs aren't persisted in this design).
4. Start `dbus`, then `xrdp-sesman`, then `xrdp` in the foreground,
   with a `trap` on SIGTERM for clean shutdown. Three daemons is not
   enough to justify pulling in supervisord — a small bash trap
   keeps the image lighter and the failure modes easier to reason
   about.

## Persistence

Two bind-mountable volumes, both under the fixed home directory:

- `/home/rdpuser/.zen` — full browser profile (bookmarks, history,
  sessions, extensions)
- `/home/rdpuser/Downloads` — downloaded files

## docker-compose.yml

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
```

## Testing plan

- `docker build` succeeds
- Container starts; `docker logs` shows xrdp listening on 3389
- Connect with an RDP client (e.g. `xfreerdp`); confirm Openbox
  session comes up and Zen launches automatically
- Restart the container; confirm Downloads and profile persist via
  the two volumes
- Confirm login fails with the wrong password and succeeds with the
  one set via `RDP_PASSWORD`

## Explicitly out of scope

- Audio redirection
- GPU/hardware acceleration
- Configurable RDP username
- Multi-user support
- Persisting the xrdp TLS certificate across recreations
