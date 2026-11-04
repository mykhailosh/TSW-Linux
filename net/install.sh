#!/bin/sh
# TSW-1060 Ethernet MAC setup. Run as root from this folder: sh install.sh
# The next boot switches to a new random MAC unless /etc/default/tsw-mac already has one.
set -e
cd "$(dirname "$0")"
install -D -m 755 tsw-mac -t /usr/local/sbin/
install -m 644 tsw-mac.service /etc/systemd/system/
systemctl daemon-reload; systemctl enable tsw-mac.service
echo "installed. Address: /etc/default/tsw-mac (created on the next boot)"
