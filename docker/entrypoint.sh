#!/bin/bash
set -euo pipefail

if [ -z "${RDP_PASSWORD:-}" ]; then
    RDP_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    echo "RDP_PASSWORD not set; generated random password for rdpuser: ${RDP_PASSWORD}"
fi
echo "rdpuser:${RDP_PASSWORD}" | chpasswd

mkdir -p /home/rdpuser/.zen /home/rdpuser/Downloads
chown -R rdpuser:rdpuser /home/rdpuser/.zen /home/rdpuser/Downloads

rm -rf /run/dbus /run/xrdp
mkdir -p /run/dbus /run/xrdp /run/xrdp/sockdir
chown root:xrdp /run/xrdp /run/xrdp/sockdir
chmod 2775 /run/xrdp
chmod 3777 /run/xrdp/sockdir

dbus-daemon --system --fork

/usr/sbin/xrdp-sesman --nodaemon &

exec /usr/sbin/xrdp --nodaemon
