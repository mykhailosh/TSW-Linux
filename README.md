# TSW-linux

Builds a clean Linux microSD image for Crestron TSW-1060 panels (Amlogic S812): Debian 12 with the
Linux 6.12 LTS kernel. The panel's eMMC is not touched: Crestron U-Boot on eMMC loads the kernel and DTB
from the card, so going back only takes inserting the original card.

## What the image contains

| Part | How it works |
|---|---|
| System | Debian 12 armhf, systemd, OpenSSH, DHCP on `eth0` |
| Kernel | 6.12.114 + the board description and 2 patches from `kernel/` |
| Display | simpledrm on the U-Boot framebuffer, 1280×800, console on screen |
| Touch | FT5822, `edt-ft5x06` driver built into the kernel, multitouch |
| Side buttons | `tsw-buttons`: they are keys of the same controller; provides a virtual touchscreen and keyboard |
| Sound | AIU I2S → ZL38051 → 2× TFA9890 with the Jabil profile, system-wide PulseAudio |
| Microphone | `snd-tsw-audin` module (card `TSW1060Mic`); no PulseAudio source yet, the gain is not tuned |
| Backlight | `tsw-backlight`: auto brightness, dim and off when idle |
| Network | random MAC per card: created on the first boot, kept in `/etc/default/tsw-mac` |

The image has no graphical environment. Programs draw directly to `/dev/dri/card0`.

## Building

You need Debian 12 or Ubuntu 22.04+ on x86_64, root, internet and an **original Crestron card image**. The
first 80 MiB come from it: the U-Boot copy, its environment and the FAT partition. That image is not in this
repository.

```bash
sudo ./build_tsw_mainline.sh <Crestron card image> tsw-1060.img
```

Write the result to a separate microSD of 4 GB or more and keep the original card. The script installs its
own tools (cross compiler, debootstrap, qemu-user-static, mtools). The work folder is
`tsw-mainline-build/`; to build again, delete `rootfs` in it.

Options (environment variables):

| Option | Meaning |
|---|---|
| `DTB_DEFAULT=bypass` | default to the DTB without the amplifier DSP mode (`tfa989x` driver, no profile) |
| `KERNEL_ONLY=1` | only the kernel, DTBs and modules |
| `KERNEL_DIR=path` | a ready, clean 6.12.114 tree instead of downloading it |
| `DEBIAN_KEYRING=file` | Debian keys: Ubuntu 22.04 has no bookworm key, use the file from the Debian 12 `debian-archive-keyring` package |
| `PASSWORD=...` | password of `root` and `tsw` (default `tsw`, change it) |
| `SND_VOLUME=60%` | volume at start |
| `NEW_HOSTNAME=...` | hostname (default `tsw-1060`, the same on every panel) |

Log in as `tsw` or `root` over SSH (address from DHCP), on the screen or through UART `ttyAML0` at 115200.

## Layout

| Folder | Contents | Install on a running panel |
|---|---|---|
| `kernel/` | DTS, patches, kernel configuration | through a build only |
| `sound/` | `tsw-jtag-off`, `tsw-sound`, `tsw-tfa`, PulseAudio and ALSA settings | `sh install.sh` |
| `backlight/` | `tsw-backlight` | `sh install.sh` |
| `buttons/` | `tsw-buttons` | `sh install.sh` |
| `mic/` | `snd-tsw-audin` driver, `tsw-mic-check` | `make WORK=<build folder>`, then `sh install.sh` |
| `net/` | `tsw-mac` | `sh install.sh` |

## Hardware notes

- **Do not touch:** GPIODV_0 (the touch controller disappears), GPIODV_28 (the backlight stays off until a
  power cycle), PMIC DCDC3, the eMMC.
- **The I2S clock must not stop:** otherwise the TFA9890 DSP loses its profile, so PulseAudio always keeps the
  device open. Microphone capture also takes its clock from playback.
- **48 kHz only:** ZL38051 and TFA9890 run at this rate, everything is converted to it.
- **Sound card order:** playback is `card 0` (`hw:0,0` in PulseAudio), the microphone is always `card 1`.
- **Service messages** are in English only.

## Checks after boot

```bash
dmesg | grep tsw-
```

```bash
/usr/local/sbin/tsw-sound status
```

```bash
tsw-mic-check
```

Expect `tsw-tfa: 0x34: cold start in 0.33 s`. If there is no sound, look at `cat /proc/asound/cards`.
