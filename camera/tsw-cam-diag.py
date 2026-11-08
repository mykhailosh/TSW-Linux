#!/usr/bin/env python3
"""Camera receive diagnostics for the TSW-1060 (ov5640 -> meson8-csi2).

Starts a capture, reads the clock, receiver and sensor registers while it runs,
then stops it. Run as root; paste the whole output back.

The CSI-2 host and D-PHY registers give an external abort without the MIPI PHY
clock, so they are read only while that clock is enabled (during the capture).
"""
import ctypes
import glob
import mmap
import os
import signal
import subprocess
import sys
import time

WIDTH, HEIGHT = 1280, 720
MEDIA = '/dev/media0'
VIDEO = '/dev/video0'
SENSOR = '"ov5640 3-003c"'
RECEIVER = '"meson8-csi2"'
I2C_BUS, I2C_ADDR = 3, 0x3c

HHI = 0xc1104000
HHI_REGS = {
    'GCLK_MPEG1': 0x144,
    'MIPI_PHY_CLK_CNTL': 0x1b8,
    'VPU_CLK_CNTL': 0x1bc,
    'GEN_CLK_CNTL': 0x228,
    'CSI_PHY_CNTL0': 0x34c,
    'CSI_PHY_CNTL1': 0x350,
    'CSI_PHY_CNTL2': 0x354,
}
HOST, HOST_WORDS = 0xd0140000, 0x40     # DesignWare CSI-2 host
PHY, PHY_WORDS = 0xd0142000, 0x20       # Amlogic D-PHY
ADAP, ADAP_WORDS = 0xd010a800, 0x16     # CSI-2 adapter (VPU bus)

SENSOR_REGS = [0x3008, 0x300e, 0x3034, 0x3035, 0x3036, 0x3037, 0x3108,
               0x4202, 0x4300, 0x4800, 0x4814, 0x4837, 0x503d]


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    out = (r.stdout + r.stderr).rstrip()
    print(f'$ {cmd}')
    if out:
        print(out)
    return out


class Mem:
    def __init__(self):
        self.fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
        self.maps = {}

    def words(self, addr, count):
        page = addr & ~0xfff
        off = addr - page
        size = (off + 4 * count + 0xfff) & ~0xfff
        key = (page, size)
        if key not in self.maps:
            self.maps[key] = mmap.mmap(self.fd, size, mmap.MAP_SHARED,
                                       mmap.PROT_READ | mmap.PROT_WRITE,
                                       offset=page)
        m = self.maps[key]
        return [ctypes.c_uint32.from_buffer(m, off + 4 * i).value
                for i in range(count)]


def dump(mem, name, base, count):
    vals = mem.words(base, count)
    print(f'--- {name} {base:#010x}')
    for i in range(0, count, 4):
        row = vals[i:i + 4]
        print(f'  +{4 * i:03x}: ' + ' '.join(f'{v:08x}' for v in row))


def dump_hhi(mem):
    print('--- HHI')
    for name, off in HHI_REGS.items():
        print(f'  {name:18} +{off:03x} = {mem.words(HHI + off, 1)[0]:08x}')


def clocks():
    print('--- clocks (rate, enable count)')
    pats = ['*gen_clk*', '*mipi*', '*csi*', 'fclk_div3', 'vpu*']
    seen = set()
    for pat in pats:
        for d in sorted(glob.glob(f'/sys/kernel/debug/clk/{pat}')):
            if d in seen or not os.path.isdir(d):
                continue
            seen.add(d)
            try:
                rate = open(f'{d}/clk_rate').read().strip()
                en = open(f'{d}/clk_enable_count').read().strip()
            except OSError as e:
                rate, en = '?', str(e)
            print(f'  {os.path.basename(d):24} {rate:>12} en={en}')


def phy_clock_on():
    for d in glob.glob('/sys/kernel/debug/clk/*mipi_phy'):
        try:
            if int(open(f'{d}/clk_enable_count').read()) > 0:
                return True
        except (OSError, ValueError):
            pass
    return False


def irq_line():
    for line in open('/proc/interrupts'):
        if 'csi' in line:
            return ' '.join(line.split())
    return '(no csi line in /proc/interrupts)'


def sensor_regs():
    print('--- ov5640 registers (i2ctransfer -f)')
    for reg in SENSOR_REGS:
        r = subprocess.run(['i2ctransfer', '-f', '-y', str(I2C_BUS),
                            f'w2@{I2C_ADDR:#x}', f'{reg >> 8:#x}',
                            f'{reg & 0xff:#x}', 'r1'],
                           capture_output=True, text=True)
        print(f'  {reg:#06x} = {(r.stdout + r.stderr).strip()}')


def main():
    if os.geteuid() != 0:
        sys.exit('run as root')
    if not os.path.isdir('/sys/kernel/debug/clk'):
        subprocess.run(['mount', '-t', 'debugfs', 'none', '/sys/kernel/debug'])

    sh('uname -r')
    sh("lsmod | grep -E 'ov5640|csi2'")
    clocks()
    mem = Mem()
    dump_hhi(mem)

    fmt = f'UYVY8_1X16/{WIDTH}x{HEIGHT}'
    sh(f"media-ctl -d {MEDIA} -V '{SENSOR}:0 [fmt:{fmt}]'")
    sh(f"media-ctl -d {MEDIA} -V '{RECEIVER}:0 [fmt:{fmt}]'")
    sh(f'v4l2-ctl -d {VIDEO} --set-fmt-video=width={WIDTH},height={HEIGHT},pixelformat=UYVY')
    sh(f"media-ctl -d {MEDIA} --get-v4l2 '{SENSOR}:0'")
    sh(f"media-ctl -d {MEDIA} --get-v4l2 '{RECEIVER}:0'")
    sh(f"media-ctl -d {MEDIA} --get-v4l2 '{RECEIVER}:1'")
    subdev = sh(f"media-ctl -d {MEDIA} -e {SENSOR}").strip()
    if subdev.startswith('/dev/'):
        sh(f'v4l2-ctl -d {subdev} -L | grep -E -A3 "link_freq|pixel_rate"')

    print(f'irq before: {irq_line()}')
    print('=== starting capture')
    cap = subprocess.Popen(['v4l2-ctl', '-d', VIDEO, '--stream-mmap=4',
                            '--stream-count=100000', '--stream-to=/dev/null'],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
    time.sleep(2)

    alive = cap.poll() is None
    print(f'capture running: {alive}')
    clocks()
    dump_hhi(mem)
    if alive and phy_clock_on():
        dump(mem, 'host', HOST, HOST_WORDS)
        dump(mem, 'phy', PHY, PHY_WORDS)
        dump(mem, 'adapter', ADAP, ADAP_WORDS)
        time.sleep(0.5)
        print('=== 0.5 s later')
        dump(mem, 'host', HOST, HOST_WORDS)
        dump(mem, 'adapter', ADAP, ADAP_WORDS)
    else:
        print('MIPI PHY clock is off: not reading host and phy')
        dump(mem, 'adapter', ADAP, ADAP_WORDS)
    sensor_regs()
    print(f'irq during: {irq_line()}')

    print('=== stopping capture')
    if cap.poll() is None:
        cap.send_signal(signal.SIGINT)
    try:
        out, _ = cap.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        cap.kill()
        out, _ = cap.communicate()
    print(f'v4l2-ctl exit {cap.returncode}, output: {out.strip()[-400:]!r}')
    print(f'irq after: {irq_line()}')
    sh("dmesg | grep -E 'ov5640|csi' | tail -15")


if __name__ == '__main__':
    main()
