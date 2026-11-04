#!/bin/bash
# =============================================================================
# build_tsw_mainline.sh - microSD image for the Crestron TSW-1060 (Amlogic S812):
# Debian 12 (armhf) with a current Linux 6.12 LTS kernel, no Android.
# The panel's eMMC is not touched: Crestron U-Boot on eMMC loads the kernel and DTB from the card's FAT partition.
#
# What it does (everything from scratch):
#   1. kernel: v6.12.114 sources + TSW-1060 board description + sound patch (hrtimer for the FIFO),
#      configuration kernel/config-tsw1060 -> uImage, DTBs (DSP and bypass), modules;
#   2. Debian 12 root filesystem (systemd, OpenSSH, DHCP on eth0, ntpdate);
#   3. sound: system-wide PulseAudio (the device never suspends, so the I2S clock never stops),
#      JTAG off on the I2S lines, TFA9890 amplifiers in DSP mode with the Jabil profile;
#      backlight (tsw-backlight), side buttons (tsw-buttons), microphone (snd-tsw-audin module);
#   4. image: the first 80 MiB (U-Boot copy, environment, FAT) from the original card image,
#      kernel/DTB in FAT, U-Boot environment (boots the new kernel via preboot).
#
# Usage (Debian 12 / Ubuntu 22.04+ x86_64, root, internet):
#   sudo ./build_tsw_mainline.sh <original Crestron SD image> [output image]
# Options (environment variables):
#   DTB_DEFAULT=bypass boot the DTB without the DSP mode by default (tfa989x driver)
#   KERNEL_DIR=path    a ready, clean 6.12.114 source tree instead of downloading it
#   KERNEL_ONLY=1      build only the kernel, DTBs and modules (no image)
#   SND_VOLUME=60%     volume at start (/etc/default/tsw-sound)
#   DEBIAN_KEYRING=file  Debian keys for debootstrap (Ubuntu 22.04 has no bookworm key: use
#                      debian-archive-keyring.gpg from the Debian 12 package)
#   PASSWORD=...       password of root and tsw (default tsw)
#
# Details handled here (all verified on a panel):
#   * Boot: Crestron U-Boot rewrites bootcmd itself -> ";run boot_mainline" at the end of preboot.
#   * Memory: the DTB has linux,usable-memory-range (the first 2 MiB are firmware).
#   * Display: simpledrm on the U-Boot buffer @0x07900000 (+ clk_ignore_unused pd_ignore_unused).
#   * Network: RMII; random MAC, one per card (tsw-mac, /etc/default/tsw-mac);
#     the interface name is fixed by net.ifnames=0 -> eth0.
#   * Sound: the bootloader leaves JTAG on GPIOAO_8..11 (the I2S lines) -> tsw-jtag-off service;
#     the AIU FIFO interrupt on Meson8 does not follow periods -> hrtimer patch in the kernel;
#     ZL38051/TFA9890 support only 48 kHz -> PulseAudio and ALSA convert everything to 48 kHz;
#     the TFA9890 DSP loses its profile when the I2S clock stops -> PulseAudio without suspend-on-idle;
#     tsw-tfa loads the Jabil profile (stereo.cnt, settings_yushan), full start < 1 s.
#   * Backlight: U-Boot leaves the MP3309C enable on -> patch 0002 in the kernel, node without enable-gpios.
#   * Buttons: tsw-buttons grabs the touch device (EVIOCGRAB) and provides virtual devices (uinput).
#   * Microphone: mainline has no AUDIN driver -> the mic/snd-tsw-audin.c module is built here too.
#   * All service messages in the image are in English.
# =============================================================================
set -euo pipefail

SRC_IMG="${1:-}"
OUT_IMG="${2:-tsw-1060-mainline.img}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIN="$HERE/kernel"                  # dts, patches, kernel configuration
SND="$HERE/sound"                   # sound
BKL="$HERE/backlight"               # backlight
BTN="$HERE/buttons"                 # side buttons
MIC="$HERE/mic"                     # microphone
NET="$HERE/net"                     # MAC address
WORK="${WORK:-$(pwd)/tsw-mainline-build}"
KVER="${KVER:-6.12.114}"
KERNEL_DIR="${KERNEL_DIR:-}"
KERNEL_URL="${KERNEL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz}"
KERNEL_ONLY="${KERNEL_ONLY:-0}"
JOBS="${JOBS:-$(nproc)}"
SUITE="${SUITE:-bookworm}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
NEW_HOSTNAME="${NEW_HOSTNAME:-tsw-1060}"
USER_NAME="${USER_NAME:-tsw}"
PASSWORD="${PASSWORD:-tsw}"
DTB_DEFAULT="${DTB_DEFAULT:-dsp}"
SND_VOLUME="${SND_VOLUME:-60%}"
CROSS=arm-linux-gnueabihf-

# Layout (512-byte sectors), as on the Crestron card
P3_START=2048;    P3_SIZE=2048      # U-Boot environment @ 1 MiB
P1_START=81920;   P1_SIZE=81920     # FAT16: kernel, DTB (+ golden boot.img if it fits)
P2_START=163840                     # root filesystem up to the end of the image
IMG_MIB="${IMG_MIB:-3600}"          # fits any "4 GB" card

KADDR=0x12000000; DADDR=0x11800000
INITARGS="root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4 console=tty0 console=ttyAML0,115200n8 earlycon clk_ignore_unused pd_ignore_unused fbcon=nodefer net.ifnames=0"
BOOT_MAINLINE="mmcinfo;fatload mmc 0 $KADDR UIMAGE.TSW;fatload mmc 0 $DADDR TSW1060.DTB;bootm $KADDR - $DADDR"

PACKAGES="systemd,systemd-sysv,dbus,ifupdown,isc-dhcp-client,\
openssh-server,sudo,iproute2,iputils-ping,procps,psmisc,nano,vim,less,kmod,netbase,ca-certificates,wget,\
libubootenv-tool,ntpsec-ntpdate,i2c-tools,gpiod,evtest,e2fsprogs,dosfstools,python3,alsa-utils,flac,usbutils"
CHROOT_PACKAGES="udev pulseaudio pulseaudio-utils libasound2-plugins"

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m  warning: $*\033[0m"; }
die()  { echo -e "\n\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "root is required (sudo)"
for f in "$KIN/meson8m2-crestron-tsw1060.dts" "$KIN/meson8m2-crestron-tsw1060-tfadsp.dts" "$KIN/config-tsw1060"; do
  [ -f "$f" ] || die "missing $f (the kernel folder next to this script)"
done
[ -f "$MIC/snd-tsw-audin.c" ] || die "missing $MIC/snd-tsw-audin.c (the mic folder next to this script)"
if [ "$KERNEL_ONLY" != 1 ]; then
  [ -n "$SRC_IMG" ] || die "Usage: sudo $0 <original Crestron SD image> [output image]"
  [ -f "$SRC_IMG" ] || die "original image not found: $SRC_IMG"
  [ "$(realpath "$SRC_IMG")" != "$(realpath -m "$OUT_IMG")" ] || die "the output file is the same as the input"
  [ ! -e "$OUT_IMG" ] || die "$OUT_IMG already exists: delete it or choose another name"
  for f in "$SND"/{tsw-tfa,tsw-tfa-jabil.json,tsw-jtag-off,tsw-sound,tsw-jtag-off.service,tsw-sound.service,tsw-sound.default,system.pa,tsw.conf,client.conf,asound.conf} \
           "$BKL"/{tsw-backlight,tsw-backlight.default,tsw-backlight.service} \
           "$BTN"/{tsw-buttons,tsw-buttons.default,tsw-buttons.service} "$MIC/tsw-mic-check" \
           "$NET"/{tsw-mac,tsw-mac.service}; do
    [ -f "$f" ] || die "missing $f (the kit folders next to this script)"
  done
  case "$DTB_DEFAULT" in dsp|bypass) ;; *) die "DTB_DEFAULT: dsp or bypass" ;; esac
fi

# --- 0. U-Boot environment: read/write directly in the image (CRC32 + name=value\0...) ----
uenv() {  # uenv <image> get <name> | set <name> <value> | check
python3 - "$@" <<'PY'
import struct, sys, zlib
OFF, SIZE = 0x100000, 0x10000
path, cmd, *a = sys.argv[1:]
with open(path, 'rb') as f:
    f.seek(OFF); blk = f.read(SIZE)
if struct.unpack_from('<I', blk)[0] != zlib.crc32(blk[4:]) & 0xffffffff:
    sys.exit('U-Boot environment CRC mismatch (wrong card or image?)')
data = blk[4:]
items = [kv.decode('latin1').partition('=')[::2] for kv in data[:data.find(b'\0\0')].split(b'\0') if kv]
items = [list(x) for x in items]
get = lambda k: next((v for n, v in items if n == k), None)
if cmd == 'check':
    sys.exit(0)
if cmd == 'get':
    v = get(a[0]); print('' if v is None else v); sys.exit(0)
if cmd == 'set':
    for it in items:
        if it[0] == a[0]:
            it[1] = a[1]; break
    else:
        items.append([a[0], a[1]])
    body = b''.join(f'{k}={v}'.encode('latin1') + b'\0' for k, v in items) + b'\0'
    if len(body) > SIZE - 4:
        sys.exit('the environment does not fit')
    body += b'\0' * (SIZE - 4 - len(body))
    with open(path, 'r+b') as f:
        f.seek(OFF); f.write(struct.pack('<I', zlib.crc32(body) & 0xffffffff) + body)
PY
}

if [ "$KERNEL_ONLY" != 1 ]; then
  log "Checking the original image"
  uenv "$SRC_IMG" check || die "the original image has no Crestron U-Boot environment"
  echo "  crestron_uboot_version = $(uenv "$SRC_IMG" get crestron_uboot_version)"
fi

# --- 1. Host tools -------------------------------------------------------------
log "Build tools"
NEED=""
need() { command -v "$1" >/dev/null || NEED="$NEED $2"; }
need make make;  need patch patch;  need gcc gcc;  need bc bc;  need bison bison;  need flex flex;  need perl perl
need ${CROSS}gcc gcc-arm-linux-gnueabihf;  need mkimage u-boot-tools;  need dtc device-tree-compiler
need xz xz-utils;  need wget wget;  need depmod kmod;  need python3 python3
dpkg -s libssl-dev >/dev/null 2>&1 || NEED="$NEED libssl-dev"
if [ "$KERNEL_ONLY" != 1 ]; then
  need debootstrap debootstrap;  need qemu-arm-static qemu-user-static;  need mke2fs e2fsprogs
  need mcopy mtools
  [ -f "$DEBIAN_KEYRING" ] || NEED="$NEED debian-archive-keyring"
  dpkg -s binfmt-support >/dev/null 2>&1 || NEED="$NEED binfmt-support"
fi
if [ -n "$NEED" ]; then apt-get update && apt-get install -y $NEED; fi
[ "$KERNEL_ONLY" = 1 ] || update-binfmts --enable qemu-arm >/dev/null 2>&1 || true
mkdir -p "$WORK"

# --- 2. Kernel -----------------------------------------------------------------
KOUT="$WORK/kernel-out"
ART="$WORK/artifacts"
mkdir -p "$KOUT" "$ART"
if [ -n "$KERNEL_DIR" ]; then
  KSRC="$(realpath "$KERNEL_DIR")"
else
  KSRC="$WORK/linux-$KVER"
  if [ ! -d "$KSRC" ]; then
    log "Downloading Linux $KVER sources"
    wget -c -O "$WORK/linux-$KVER.tar.xz" "$KERNEL_URL"
    tar -C "$WORK" -xf "$WORK/linux-$KVER.tar.xz"
  fi
fi
[ -f "$KSRC/Makefile" ] || die "no kernel sources in $KSRC"

log "TSW-1060 board and kernel patches"
DTSDIR="$KSRC/arch/arm/boot/dts/amlogic"
cp "$KIN/meson8m2-crestron-tsw1060.dts" "$KIN/meson8m2-crestron-tsw1060-tfadsp.dts" "$DTSDIR/"
grep -q 'meson8m2-crestron-tsw1060-tfadsp.dtb' "$DTSDIR/Makefile" || \
  echo 'dtb-$(CONFIG_MACH_MESON8) += meson8m2-crestron-tsw1060.dtb meson8m2-crestron-tsw1060-tfadsp.dtb' >> "$DTSDIR/Makefile"
for p in "$KIN"/*.patch; do
  [ -e "$p" ] || continue
  if patch -d "$KSRC" -p1 -N --dry-run -s < "$p" >/dev/null 2>&1; then
    patch -d "$KSRC" -p1 -N -s < "$p"; echo "  applied: $(basename "$p")"
  elif patch -d "$KSRC" -p1 -R --dry-run -s < "$p" >/dev/null 2>&1; then
    echo "  already applied: $(basename "$p")"
  else
    die "patch does not apply: $p"
  fi
done

log "Building the kernel ($JOBS jobs; about 25 min on 2 cores)"
cp "$KIN/config-tsw1060" "$KOUT/.config"
KM="make -C $KSRC O=$KOUT ARCH=arm CROSS_COMPILE=$CROSS"
$KM olddefconfig >/dev/null
$KM -j"$JOBS" zImage modules amlogic/meson8m2-crestron-tsw1060.dtb amlogic/meson8m2-crestron-tsw1060-tfadsp.dtb
KREL="$($KM -s --no-print-directory kernelrelease)"
echo "  kernel version: $KREL"

mkimage -A arm -O linux -T kernel -C none -a 0x00208000 -e 0x00208000 -n "tsw1060 $KREL" \
  -d "$KOUT/arch/arm/boot/zImage" "$ART/UIMAGE.TSW" >/dev/null
# spare room in the DTB: U-Boot adds /chosen and memory
dtc -q -I dtb -O dtb -p 8192 -o "$ART/TSW1060-DSP.DTB" "$KOUT/arch/arm/boot/dts/amlogic/meson8m2-crestron-tsw1060-tfadsp.dtb"
dtc -q -I dtb -O dtb -p 8192 -o "$ART/TSW1060-BYPASS.DTB" "$KOUT/arch/arm/boot/dts/amlogic/meson8m2-crestron-tsw1060.dtb"
rm -rf "$ART/modroot"; mkdir -p "$ART/modroot"
$KM INSTALL_MOD_PATH="$ART/modroot" INSTALL_MOD_STRIP=1 modules_install >/dev/null
# microphone module: out of tree, built in a copy (M= writes into the source folder)
rm -rf "$WORK/mic"; mkdir -p "$WORK/mic"
cp "$MIC/snd-tsw-audin.c" "$WORK/mic/"
echo 'obj-m := snd-tsw-audin.o' > "$WORK/mic/Kbuild"
$KM M="$WORK/mic" modules
$KM M="$WORK/mic" INSTALL_MOD_PATH="$ART/modroot" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra modules_install >/dev/null
rm -f "$ART/modroot/lib/modules/$KREL/build" "$ART/modroot/lib/modules/$KREL/source"
tar -C "$ART/modroot" -czf "$ART/modules-$KREL.tar.gz" lib/modules
cp "$KOUT/.config" "$ART/config-$KREL"
ls -l "$ART"

if [ "$KERNEL_ONLY" = 1 ]; then
  log "Done (kernel only): $ART"
  exit 0
fi

# --- 3. Debian root filesystem ----------------------------------------------------
ROOT="$WORK/rootfs"
[ ! -e "$ROOT" ] || die "$ROOT already exists: delete it or set WORK=another_folder"
cleanup() {
  for m in dev/pts dev proc sys; do mountpoint -q "$ROOT/$m" 2>/dev/null && umount -l "$ROOT/$m" || true; done
}
trap cleanup EXIT

log "debootstrap $SUITE armhf (first stage)"
debootstrap --arch=armhf --variant=minbase --foreign \
  --keyring="$DEBIAN_KEYRING" \
  --include="$PACKAGES" \
  "$SUITE" "$ROOT" "$MIRROR"
cp "$(command -v qemu-arm-static)" "$ROOT/usr/bin/"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"

log "debootstrap (second stage, through qemu)"
chroot "$ROOT" /debootstrap/debootstrap --second-stage
mount -t proc proc "$ROOT/proc"; mount -t sysfs sys "$ROOT/sys"
mount --bind /dev "$ROOT/dev"; mount --bind /dev/pts "$ROOT/dev/pts"

log "System setup"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF
echo 'APT::Install-Recommends "false";' > "$ROOT/etc/apt/apt.conf.d/99tsw-no-recommends"

echo "$NEW_HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $NEW_HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF

cat > "$ROOT/etc/fstab" <<'EOF'
/dev/mmcblk0p2  /          ext4   defaults,noatime,errors=remount-ro  0 1
/dev/mmcblk0p1  /boot/fat  vfat   defaults,noauto                     0 0
tmpfs           /tmp       tmpfs  defaults,nosuid,nodev               0 0
EOF
mkdir -p "$ROOT/boot/fat"

# Network: RMII + SMSC LAN8720, the MAC is set by the tsw-mac service (net/). net.ifnames=0 on the kernel command line ->
# the interface is always eth0 (otherwise udev calls it end0).
cat > "$ROOT/etc/network/interfaces" <<'EOF'
# TSW-1060: wired Ethernet (RMII, SMSC LAN8720), DHCP
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    # hwaddress ether xx:xx:xx:xx:xx:xx
EOF

# U-Boot environment on the microSD (mmcblk0 = card, mmcblk1 = eMMC)
echo '/dev/mmcblk0  0x100000  0x10000  0x10000' > "$ROOT/etc/fw_env.config"

# SSH host keys are created on the first boot (every card has its own)
cat > "$ROOT/etc/systemd/system/tsw-firstboot.service" <<'EOF'
[Unit]
Description=TSW-1060: generate SSH host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

# Boot finished: reset the U-Boot counters (otherwise U-Boot falls back to golden), then set the time by NTP.
# The counters go first: they must not depend on the network. ntpdate retries until the network is up.
cat > "$ROOT/usr/local/sbin/tsw-bootok" <<'EOF'
#!/bin/sh
# TSW-1060: boot finished: reset the U-Boot boot counters, then set the time.
for v in boot_retry golden_boot_retry; do
    cur=$(fw_printenv -n "$v" 2>/dev/null || echo "?")
    [ "$cur" = "0" ] || fw_setenv "$v" 0
done
echo "tsw-bootok: boot complete, boot_retry reset"
i=0
until ntpdate -b -t 3 pool.ntp.org >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -ge 30 ] && { echo "tsw-bootok: no time from NTP"; exit 0; }
    sleep 10
done
echo "tsw-bootok: time set"
EOF
chmod 755 "$ROOT/usr/local/sbin/tsw-bootok"
cat > "$ROOT/etc/systemd/system/tsw-bootok.service" <<'EOF'
[Unit]
Description=TSW-1060: reset boot_retry, set the time
After=multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tsw-bootok

[Install]
WantedBy=multi-user.target
EOF

# Sound: see sound/ (tsw-jtag-off, tsw-sound, tsw-tfa, PulseAudio/ALSA settings)
install -m 755 "$SND/tsw-tfa" "$ROOT/usr/local/bin/tsw-tfa"
install -D -m 644 "$SND/tsw-tfa-jabil.json" "$ROOT/usr/local/share/tsw-tfa/tsw-tfa-jabil.json"
install -m 755 "$SND/tsw-jtag-off" "$SND/tsw-sound" "$ROOT/usr/local/sbin/"
install -m 644 "$SND/tsw-jtag-off.service" "$SND/tsw-sound.service" "$ROOT/etc/systemd/system/"
sed "s/^TSW_VOLUME=.*/TSW_VOLUME=$SND_VOLUME/" "$SND/tsw-sound.default" > "$ROOT/etc/default/tsw-sound"

# Backlight: see backlight/ (the mp3309c module with patch 0002 is in the kernel)
install -m 755 "$BKL/tsw-backlight" "$ROOT/usr/local/bin/tsw-backlight"
install -m 644 "$BKL/tsw-backlight.default" "$ROOT/etc/default/tsw-backlight"
install -m 644 "$BKL/tsw-backlight.service" "$ROOT/etc/systemd/system/"

# Side buttons: see buttons/
install -m 755 "$BTN/tsw-buttons" "$ROOT/usr/local/bin/tsw-buttons"
install -m 644 "$BTN/tsw-buttons.default" "$ROOT/etc/default/tsw-buttons"
install -m 644 "$BTN/tsw-buttons.service" "$ROOT/etc/systemd/system/"
echo uinput > "$ROOT/etc/modules-load.d/tsw-buttons.conf"

# MAC: random, created on the first boot (not in the image: every card gets its own)
install -m 755 "$NET/tsw-mac" "$ROOT/usr/local/sbin/tsw-mac"
install -m 644 "$NET/tsw-mac.service" "$ROOT/etc/systemd/system/"

# Microphone: see mic/ (no PulseAudio source yet: the ZL38051 gain is not tuned)
echo snd-tsw-audin > "$ROOT/etc/modules-load.d/tsw-mic.conf"
install -m 755 "$MIC/tsw-mic-check" "$ROOT/usr/local/bin/tsw-mic-check"

cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

log "Packages and users (in chroot)"
cat > "$ROOT/tmp/setup.sh" <<EOF
set -e
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update
apt-get install -y --no-install-recommends $CHROOT_PACKAGES
getent group input >/dev/null || groupadd -r input
id -u $USER_NAME >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,video,input,audio,dialout,pulse-access $USER_NAME
usermod -aG audio,pulse-access root
echo "root:$PASSWORD" | chpasswd
echo "$USER_NAME:$PASSWORD" | chpasswd
systemctl set-default multi-user.target
systemctl --global disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
systemctl enable serial-getty@ttyAML0.service tsw-firstboot.service tsw-bootok.service tsw-mac.service
systemctl enable tsw-jtag-off.service tsw-sound.service tsw-backlight.service tsw-buttons.service
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
apt-get clean
EOF
chroot "$ROOT" /bin/sh /tmp/setup.sh
rm -f "$ROOT/tmp/setup.sh"

# Sound settings: after installing pulseaudio (the package ships its own versions)
[ -f "$ROOT/etc/pulse/system.pa.orig" ] || cp "$ROOT/etc/pulse/system.pa" "$ROOT/etc/pulse/system.pa.orig"
install -m 644 "$SND/system.pa" "$ROOT/etc/pulse/system.pa"
install -D -m 644 "$SND/tsw.conf" "$ROOT/etc/pulse/daemon.conf.d/tsw.conf"
install -D -m 644 "$SND/client.conf" "$ROOT/etc/pulse/client.conf.d/tsw.conf"
install -m 644 "$SND/asound.conf" "$ROOT/etc/asound.conf"

log "Kernel modules $KREL"
tar -C "$ROOT" --keep-directory-symlink -xzf "$ART/modules-$KREL.tar.gz"
chroot "$ROOT" depmod -a "$KREL"

cleanup
rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/usr/bin/qemu-arm-static"
rm -rf "$ROOT/var/lib/apt/lists/"* "$ROOT/var/cache/apt/"*.bin
# machine-id: every card gets its own, systemd creates it on the first boot
: > "$ROOT/etc/machine-id"; rm -f "$ROOT/var/lib/dbus/machine-id"

# Check: services and settings in the image must have no Cyrillic text
CYR=$(python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
bad = []
for d in ('etc/systemd/system', 'etc/default', 'usr/local', 'etc/pulse', 'etc/asound.conf', 'etc/network/interfaces'):
    p = os.path.join(root, d)
    files = [p] if os.path.isfile(p) else [os.path.join(a, f) for a, _, fs in os.walk(p) for f in fs]
    for f in files:
        try:
            t = open(f, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        if any('\u0400' <= c <= '\u04ff' for c in t):
            bad.append(f[len(root):])
print(' '.join(bad))
PY
)
[ -z "$CYR" ] || warn "Cyrillic text in image files: $CYR"

# --- 4. Card image -----------------------------------------------------------------
log "Building the image $OUT_IMG"
OUT_BYTES=$(( IMG_MIB * 1024 * 1024 ))
TOTAL_SECTORS=$(( OUT_BYTES / 512 ))
P2_SIZE=$(( TOTAL_SECTORS - P2_START ))
[ "$P2_SIZE" -gt 2097152 ] || die "IMG_MIB is too small"

# the first 80 MiB as in the original: sector 0 (U-Boot copy), environment @1 MiB, FAT p1
dd if="$SRC_IMG" of="$OUT_IMG" bs=1M count=80 status=none
truncate -s "$OUT_BYTES" "$OUT_IMG"
python3 - "$SRC_IMG" "$OUT_IMG" "$P2_START" "$P2_SIZE" <<'PY'
import struct, sys
src, path, p2s, p2n = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(src, 'rb') as f:
    mbr = f.read(512)
orig = [mbr[0x1BE + 16 * i:0x1BE + 16 * i + 16] for i in range(4)]
# p1 (FAT) and p3 (U-Boot environment) as on the original card (type and bounds); p2 is the new root filesystem;
# the original extended partition (p4: Android sdcard/data/cache/logs) is not needed. The code in sector 0 (U-Boot) is left alone.
p1s, p1n = struct.unpack('<II', orig[0][8:16]); p3s, p3n = struct.unpack('<II', orig[2][8:16])
assert (p1s, p3s) == (81920, 2048), 'unexpected layout of the original card: p1@%d p3@%d' % (p1s, p3s)
p2 = struct.pack('<B3sB3sII', 0x00, b'\xfe\xff\xff', 0x83, b'\xfe\xff\xff', p2s, p2n)
with open(path, 'r+b') as f:
    f.seek(0x1BE); f.write(orig[0] + p2 + orig[2] + b'\0' * 16); f.seek(0x1FE); f.write(b'\x55\xaa')
print('  p1 FAT %d+%d (type %#x), p2 rootfs %d+%d, p3 env %d+%d' % (p1s, p1n, orig[0][4], p2s, p2n, p3s, p3n))
PY

# kernel and DTB in FAT p1 (8.3 names; U-Boot reads FAT16)
export MTOOLS_SKIP_CHECK=1
FAT="$OUT_IMG@@$(( P1_START * 512 ))"
mdir -i "$FAT" ::/ >/dev/null || die "the original image has no FAT partition at 40 MiB"
if [ "$DTB_DEFAULT" = dsp ]; then DTB_MAIN="$ART/TSW1060-DSP.DTB"; DTB_ALT="$ART/TSW1060-BYPASS.DTB"; ALT=TSW1060.BYP
else DTB_MAIN="$ART/TSW1060-BYPASS.DTB"; DTB_ALT="$ART/TSW1060-DSP.DTB"; ALT=TSW1060.DSP; fi
fatput() {
  mcopy -o -i "$FAT" "$ART/UIMAGE.TSW" ::UIMAGE.TSW && mcopy -o -i "$FAT" "$DTB_MAIN" ::TSW1060.DTB &&
  mcopy -o -i "$FAT" "$DTB_ALT" ::$ALT
}
if ! fatput 2>/dev/null; then
  warn "not enough room in FAT: deleting the Crestron golden boot.img (rollback = the original card)"
  mdel -i "$FAT" ::BOOT.IMG 2>/dev/null || mdel -i "$FAT" ::boot.img 2>/dev/null || true
  fatput || die "could not write the kernel/DTB to FAT"
fi
mdir -i "$FAT" ::/ | sed 's/^/  /'

# root filesystem
P2_IMG="$WORK/rootfs.ext4"
rm -f "$P2_IMG"
mke2fs -q -t ext4 -L rootfs -E lazy_itable_init=0,lazy_journal_init=0 -d "$ROOT" "$P2_IMG" "$(( P2_SIZE / 2 ))k"
e2fsck -fn "$P2_IMG" >/dev/null
dd if="$P2_IMG" of="$OUT_IMG" bs=1M seek=$(( P2_START / 2048 )) conv=notrunc status=none
rm -f "$P2_IMG"

# --- 5. U-Boot environment ----------------------------------------------------------
log "U-Boot environment"
dd if="$OUT_IMG" of="${OUT_IMG%.img}_env_original.bin" bs=64K skip=16 count=1 status=none
[ -n "$(uenv "$OUT_IMG" get initargs_crestron)" ] || uenv "$OUT_IMG" set initargs_crestron "$(uenv "$OUT_IMG" get initargs)"
PRE="$(uenv "$OUT_IMG" get preboot)"
case "$PRE" in *";run boot_mainline"*) ;; *) uenv "$OUT_IMG" set preboot "$PRE;run boot_mainline" ;; esac
uenv "$OUT_IMG" set boot_mainline "$BOOT_MAINLINE"
uenv "$OUT_IMG" set initargs "$INITARGS"
for kv in fdt_high=0xffffffff boot_retry=0 golden_boot_retry=0 golden=0 bootdelay=3; do
  uenv "$OUT_IMG" set "${kv%%=*}" "${kv#*=}"
done
echo "  preboot = $(uenv "$OUT_IMG" get preboot | tail -c 60)"
echo "  initargs = $(uenv "$OUT_IMG" get initargs)"

log "Done"
cat <<EOF
  Image:          $OUT_IMG ($(du -h --apparent-size "$OUT_IMG" | cut -f1)), kernel $KREL
  Kernel/DTB/modules separately: $ART  (to update without rebuilding the image)
  Original U-Boot environment: ${OUT_IMG%.img}_env_original.bin
  Login: $USER_NAME / $PASSWORD  (root / $PASSWORD): SSH (eth0, DHCP), screen (tty1), UART ttyAML0 115200
  MAC: random, created on the first boot; to set your own: MAC=... in /etc/default/tsw-mac, then reboot

  Default DTB: $DTB_DEFAULT (TSW1060.DTB); the spare one is $ALT in FAT.
  Sound is ready about 15 s after start: dmesg | grep tsw-   ;   /usr/local/sbin/tsw-sound status
  Write to a SEPARATE microSD of 4 GB or more. Keep the original Crestron card: it is your rollback.
EOF
