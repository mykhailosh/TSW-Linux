#!/bin/sh
# TSW-1060 boot logo. Run as root from this folder:
#   sh install.sh          copy logo.bmp to the card's FAT partition, U-Boot shows it from the next boot
#   sh install.sh remove   back to the Crestron logo
# Only the microSD changes (FAT file + U-Boot environment); the eMMC logo partition stays as it is.
# Without logo.bmp on the card U-Boot shows the Crestron logo, so a bad file cannot stop the boot.
set -e
cd "$(dirname "$0")"

HEAD='video open; video clear; video dev bl_on;'
LOAD='mmcinfo;if fatload mmc 0 ${loadaddr_logo} logo.bmp; then bmp display ${loadaddr_logo}; else '
FAT=${FAT:-/boot/fat}

die() { echo "tsw-logo: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

# The original command is kept in prepare_crestron (once), the new one is built from it.
ORIG=$(fw_printenv -n prepare_crestron 2>/dev/null || true)
if [ -z "$ORIG" ]; then
    ORIG=$(fw_printenv -n prepare) || die "cannot read the U-Boot environment (/etc/fw_env.config)"
    case "$ORIG" in *logo.bmp*) die "prepare already loads logo.bmp but prepare_crestron is missing" ;; esac
    fw_setenv prepare_crestron "$ORIG"
fi
case "$ORIG" in "$HEAD"*) ;; *) die "unexpected prepare: $ORIG" ;; esac

mounted=
if ! mountpoint -q "$FAT"; then
    mkdir -p "$FAT"
    mount -t vfat /dev/mmcblk0p1 "$FAT"
    mounted=1
fi

if [ "${1:-}" = remove ]; then
    fw_setenv prepare "$ORIG"
    rm -f "$FAT/LOGO.BMP"
    echo "tsw-logo: Crestron logo restored"
else
    [ -f logo.bmp ] || die "no logo.bmp here (make-logo.py makes one)"
    cp logo.bmp "$FAT/LOGO.BMP"
    fw_setenv prepare "$HEAD$LOAD${ORIG#"$HEAD"} fi;"
    echo "tsw-logo: logo.bmp installed, shown from the next boot"
fi
sync
[ -z "$mounted" ] || umount "$FAT"
fw_printenv prepare
