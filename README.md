# TSW-linux

Builds a clean Linux microSD image for Crestron TSW-1060 panels (Amlogic S812): Debian 12 with the
Linux 6.12 LTS kernel. The panel's eMMC is not touched: Crestron U-Boot on eMMC loads the kernel and DTB
from the card, so going back only takes inserting the original card.

## What the image contains

| Part | How it works |
|---|---|
| System | Debian 12 armhf, systemd, OpenSSH, DHCP on `eth0` |
| Kernel | 6.12.114 + the board description and 7 patches from `kernel/` |
| Display | simpledrm on the U-Boot framebuffer, 1280×800, console on screen |
| Touch | FT5822, `edt-ft5x06` driver built into the kernel, multitouch |
| Side buttons | `tsw-buttons`: they are keys of the same controller; provides a virtual touchscreen and keyboard |
| Sound | AIU I2S → ZL38051 → 2× TFA9890 with the Jabil profile, system-wide PulseAudio |
| Microphone | `snd-tsw-audin` module (card `TSW1060Mic`); no PulseAudio source yet, the gain is not tuned |
| Camera | OV5640 on MIPI CSI-2, `ov5640` and `meson8-csi2` modules, capture to memory in UYVY; **not yet tested on a panel** |
| Video decoder | hardware H.264 up to 1920×1080, `meson-vdec` module (V4L2 M2M, for `h264_v4l2m2m`), microcode `meson8_h264.bin`; works on the panel (tsw-panel decodes its live video with it) |
| Backlight | `tsw-backlight`: auto brightness, dim and off when idle |
| Network | random MAC per card: created on the first boot, kept in `/etc/default/tsw-mac` |
| USB | keyboards, mice and other USB devices work when connected (verified) |

The image has no graphical environment. Programs draw directly to `/dev/dri/card0`.

## Getting the original card image

The build needs an image of the microSD card that came with the panel. Power the panel off before taking
the card out, and take the image before anything else: the card is the only way back to the original
system. The image holds Crestron files and data of that panel, so keep it private.

The card is read in full below, which gives you a backup. The build itself only uses the first 80 MiB.

### Linux

Find the card by its size and model; below it is `/dev/sdX` (a built-in reader shows `/dev/mmcblk0`):

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
```

Unmount it and make it read-only, so nothing can change it by accident:

```bash
sudo umount /dev/sdX?*
```

```bash
sudo blockdev --setro /dev/sdX
```

Read the card and compare the copy with it:

```bash
sudo dd if=/dev/sdX of=crestron-card.img bs=4M conv=fsync status=progress
```

```bash
sudo cmp /dev/sdX crestron-card.img
```

`cmp` prints nothing when the copy is identical. To take only what the build needs, add `bs=1M count=80` to
`dd` instead of `bs=4M`, and skip `cmp`.

### Windows

Use [USBImager](https://gitlab.com/bztsrc/usbimager), the regular build: the write-only (`wo`) build has no
Read button.

All partitions on the card have the Linux type, so Windows gives them no drive letter and may offer to format
the card. **Refuse: formatting destroys the original system.** Without a drive letter the card is hidden from
USBImager's default list, so it must be started with `-a`, which lists every disk.

1. Find the card's disk number in PowerShell, by its size and bus type:

   ```powershell
   Get-Disk | Select-Object Number, FriendlyName, BusType, @{n='GB';e={[math]::Round($_.Size/1GB,1)}}
   ```

2. Start PowerShell as Administrator, go to the USBImager folder and run:

   ```powershell
   .\usbimager.exe -a
   ```

3. Select the card in the device list. The list includes the system disks, so check the size against step 1.
4. Press **Read**, never **Write**. The image is saved to the Desktop as `usbimager-<date>T<time>.dd`.

Pass this file to the build. From WSL, the Desktop is under `/mnt/c/Users/<user>/Desktop/`.

## Building

You need Debian 12 or Ubuntu 22.04+ on x86_64, root, internet and an **original Crestron card image** (see
above). The first 80 MiB come from it: the U-Boot copy, its environment and the FAT partition. That image is
not in this repository. If it is not a Crestron card image, the build stops at the environment check.

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
| `VDEC_FW_SRC=folder` | H.264 microcode headers (`m8/ucode/h264` of the vendor 3.10 kernel) instead of downloading them |
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
| `camera/` | `tsw-cam-diag.py`: clocks, receiver and sensor registers during a capture | copy, run as root |
| `vdec/` | `make-meson8-h264-fw.py` (decoder microcode), `tsw-vdec-check` | the build installs the microcode; copy the check, run as root |
| `logo/` | `logo.bmp` (U-Boot boot logo), `make-logo.py` to make one from a picture | `sh install.sh` (`sh install.sh remove` = Crestron logo) |

## Hardware notes

- **Do not touch:** GPIODV_0 (the touch controller disappears), GPIODV_28 (the backlight stays off until a
  power cycle), PMIC DCDC3, the eMMC.
- **The I2S clock must not stop:** otherwise the TFA9890 DSP loses its profile, so PulseAudio always keeps the
  device open. Microphone capture also takes its clock from playback.
- **48 kHz only:** ZL38051 and TFA9890 run at this rate, everything is converted to it.
- **Sound card order:** playback is `card 0` (`hw:0,0` in PulseAudio), the microphone is always `card 1`.
- **Camera:** the OV5640 is on I2C_D (`i2c-3`, address 0x3c) and has no privacy shutter. The receiver
  registers sit on the VPU bus, which stays on from U-Boot because of `clk_ignore_unused pd_ignore_unused`.
  The camera driver, clocks and sensor tuning come from
  [tsx-mainline/linux](https://github.com/tsx-mainline/linux), adapted to 6.12.
- **Video decoder:** mainline `meson-vdec` supports only GX SoCs; patch 0007 adds the Meson8m2 platform.
  The microcode comes from the GPL headers of the vendor 3.10 kernel
  ([hardkernel/linux](https://github.com/hardkernel/linux/tree/odroidc-3.10.y/drivers/amlogic/amports/m8/ucode/h264),
  branch `odroidc-3.10.y`); the build downloads them and writes `/lib/firmware/meson/vdec/meson8_h264.bin`,
  which also goes into the modules archive. The VDEC clock is fixed in DT at 637.5 MHz. The decoder is
  `/dev/video1` (the camera keeps `/dev/video0`). **Frames come out with the bytes of every 64-bit word
  reversed:** Meson8 canvases cannot swap them (checked on the panel), so the program that reads the frame
  swaps them back (the panel app does it while converting to RGB). The capture buffers are cached (copying a
  frame out of uncached memory cost ffmpeg 28 ms per 720p frame). The CMA pool is 192 MiB.
- **Boot logo:** U-Boot's `prepare` loads `LOGO.BMP` from the card's FAT partition (1280×800, 24-bit BMP);
  without the file it shows the Crestron logo from the eMMC `logo` partition, which is never written. The
  original command is kept in `prepare_crestron`. `make-logo.py picture.png` centres a picture on black
  (U-Boot clears the screen to black first). Verified on a panel.
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

Camera: find the capture device, then set the same format on the sensor, the receiver and the video device.
The commands assume `/dev/media0` and `/dev/video0`.

```bash
media-ctl -p
```

```bash
media-ctl -d /dev/media0 -V '"ov5640 3-003c":0 [fmt:UYVY8_1X16/1280x720]'
```

```bash
media-ctl -d /dev/media0 -V '"meson8-csi2":0 [fmt:UYVY8_1X16/1280x720]'
```

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1280,height=720,pixelformat=UYVY
```

```bash
v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=30 --stream-to=frames.uyvy
```

Expect `ISP tuning for crestron,tsw-1060` in `dmesg | grep ov5640`. Without it the picture has a magenta cast.

Video decoder: `info` shows the module, the clocks and the power registers; `run` encodes a test clip
(needs `ffmpeg`, not in the image: `apt install ffmpeg`), decodes it in software and with
`h264_v4l2m2m` and compares every frame. If nothing comes out, it prints the decoder registers (read only
while the decoder is powered: without the VDEC clock a read hangs the CPU), the V4L2 calls and the ffmpeg
log. `bench` compares the speed and CPU load of both decoders on a streaming-like clip.

```bash
tsw-vdec-check info
```

```bash
tsw-vdec-check run 1280x720
```

```bash
tsw-vdec-check bench 1280x720
```

Expect `swap64 : 88/90 frames identical`: the bytes of each 64-bit word are reversed, and the last two
frames come out swapped when the stream is drained at its end (their timestamps are right).
`... is already open` means another program (often a hung ffmpeg) holds the decoder: the driver allows
one session.
