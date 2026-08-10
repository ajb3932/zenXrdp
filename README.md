# zenXrdp

A lightweight Docker container that runs Zen Browser inside an Openbox
desktop, reachable over RDP.

## Quick start

1. Edit `RDP_PASSWORD` in `docker-compose.yml` (or override it at runtime).
2. Create the two host directories used for persistence:
   ```bash
   mkdir -p /zen/data /zen/downloads
   ```
3. Start the container (pulls `ajb3932/zenxrdp:latest` from Docker Hub):
   ```bash
   docker compose up -d
   ```
4. Connect with any RDP client to `<host>:3390`, username `rdpuser`,
   password whatever you set `RDP_PASSWORD` to.

If `RDP_PASSWORD` is not set, a random password is generated on first
start and printed once to `docker logs zen` — check there if you didn't
set one.

## Port

The container listens on 3389 internally, but is published on host port
**3390** by default (`docker-compose.yml`'s `ports: ["3390:3389"]`) —
adjust this if 3389 is free on your host and you'd rather use it
directly, but check first (`ss -tlnp | grep 3389` or equivalent), since
many hosts already run their own RDP service on that port.

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
