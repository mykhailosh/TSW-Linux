#!/bin/sh
# TSW-1060 sound setup (mainline 6.12, DTB TSW1060-TFADSP). Run as root from this folder: sh install.sh
set -e
cd "$(dirname "$0")"
apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils libasound2-plugins alsa-utils
install -m 755 tsw-tfa /usr/local/bin/
install -D -m 644 tsw-tfa-jabil.json /usr/local/share/tsw-tfa/tsw-tfa-jabil.json
install -D -m 755 tsw-jtag-off tsw-sound -t /usr/local/sbin/
rm -f /etc/init.d/tsw-jtag-off /etc/init.d/tsw-sound
[ -f /etc/default/tsw-sound ] || install -m 644 tsw-sound.default /etc/default/tsw-sound
[ -f /etc/pulse/system.pa.orig ] || cp /etc/pulse/system.pa /etc/pulse/system.pa.orig
install -m 644 system.pa /etc/pulse/system.pa
install -D -m 644 tsw.conf /etc/pulse/daemon.conf.d/tsw.conf
install -D -m 644 client.conf /etc/pulse/client.conf.d/tsw.conf
[ -f /etc/asound.conf ] && cp /etc/asound.conf /etc/asound.conf.bak
install -m 644 asound.conf /etc/asound.conf
for u in root tsw; do id $u >/dev/null 2>&1 && adduser $u pulse-access >/dev/null && adduser $u audio >/dev/null; done
install -m 644 tsw-jtag-off.service tsw-sound.service /etc/systemd/system/
systemctl daemon-reload
systemctl --global disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
systemctl enable tsw-jtag-off.service tsw-sound.service
echo "installed. Start: systemctl start tsw-sound"
