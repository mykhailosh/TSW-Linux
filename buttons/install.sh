#!/bin/sh
# TSW-1060 side buttons service setup. Run as root from this folder: sh install.sh
# Also run ../backlight/install.sh (tsw-backlight must know the virtual touchscreen and the button signals).
set -e
cd "$(dirname "$0")"
echo uinput > /etc/modules-load.d/tsw-buttons.conf
modprobe uinput || true
install -m 755 tsw-buttons /usr/local/bin/tsw-buttons
[ -f /etc/default/tsw-buttons ] || install -m 644 tsw-buttons.default /etc/default/tsw-buttons
# tsw-backlight must watch the filtered touchscreen, not the (grabbed) ft5x06 device
if [ -f /etc/default/tsw-backlight ] && grep -q '^TOUCH_NAME=ft5x06' /etc/default/tsw-backlight; then
    sed -i 's/^TOUCH_NAME=ft5x06.*/TOUCH_NAME=TSW-1060 touchscreen,ft5x06    # touchscreen device name parts, preferred first/' \
        /etc/default/tsw-backlight
fi
rm -f /etc/init.d/tsw-buttons
install -m 644 tsw-buttons.service /etc/systemd/system/
systemctl daemon-reload; systemctl enable tsw-buttons.service
echo "installed. Settings: /etc/default/tsw-buttons"
