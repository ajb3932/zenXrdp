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

COPY docker/startwm.sh /etc/xrdp/startwm.sh
COPY docker/openbox-autostart /etc/xdg/openbox/autostart
RUN chmod +x /etc/xrdp/startwm.sh /etc/xdg/openbox/autostart
