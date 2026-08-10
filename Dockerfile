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
