#!/bin/sh
# TSW-1060 microphone setup. Run as root from this folder (with snd-tsw-audin.ko built by make): sh install.sh
# Capture card "TSW1060Mic" (hw:TSW1060Mic), 48 kHz / S16_LE / 2 ch; needs playback running (tsw-sound).
set -e
cd "$(dirname "$0")"
KREL=$(uname -r)
install -D -m 644 snd-tsw-audin.ko /lib/modules/$KREL/extra/snd-tsw-audin.ko
depmod -a "$KREL"
echo snd-tsw-audin > /etc/modules-load.d/tsw-mic.conf
install -m 755 tsw-mic-check /usr/local/bin/tsw-mic-check
modprobe snd-tsw-audin
echo "installed. Test: arecord -D hw:TSW1060Mic -f S16_LE -r 48000 -c 2 -d 5 /tmp/mic.wav; tsw-mic-check level /tmp/mic.wav"
