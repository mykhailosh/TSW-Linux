#!/bin/sh
# TSW-1060 backlight service setup. Run as root from this folder: sh install.sh
# Needs a DTB with the backlight@17 node WITHOUT enable-gpios (TSW1060-TFADSP.DTB from 30.10.2026 02:40 or newer).
set -e
cd "$(dirname "$0")"
KREL=$(uname -r)
# mp3309c.ko here is patched: enable-gpios optional (the chip enable is left to U-Boot)
if [ -f mp3309c.ko ]; then
    install -D -m 644 mp3309c.ko /lib/modules/$KREL/kernel/drivers/video/backlight/mp3309c.ko
    depmod -a $KREL
fi
install -m 755 tsw-backlight /usr/local/bin/tsw-backlight
[ -f /etc/default/tsw-backlight ] || install -m 644 tsw-backlight.default /etc/default/tsw-backlight
rm -f /etc/init.d/tsw-backlight
install -m 644 tsw-backlight.service /etc/systemd/system/
systemctl daemon-reload; systemctl enable tsw-backlight.service
echo "installed. Settings: /etc/default/tsw-backlight"
