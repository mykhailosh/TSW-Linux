// SPDX-License-Identifier: GPL-2.0
/*
 * snd-tsw-audin - capture from the AUDIN I2S input of the Amlogic Meson8 (S812)
 * on the Crestron TSW-1060.
 *
 * The ZL38051 voice processor (2 digital mics, AEC, beamforming) sends its output
 * on TDMA ch1/ch2 to GPIOY_5 (i2s_in_ch01). AUDIN takes BCLK/LRCLK from the AIU,
 * so playback (the system PulseAudio on hw:0) must keep the I2S clock running.
 *
 * Mainline has no AUDIN driver; the registers follow the Amlogic 3.10 kernel
 * (sound/soc/aml/m8/aml_audio_hw.c). The module creates its own platform device
 * (no DT node). FIFO0 writes 32-bit words to DDR in 64-byte blocks of 8 left and
 * 8 right samples, 24 bits in the low bits; .copy turns them into S16_LE (word >> shift)
 * or S32_LE (the whole 24-bit word, MSB-aligned).
 * The FIFO interrupt is not used: an hrtimer polls the write pointer (as the
 * AIU playback patch does).
 */
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/dma-mapping.h>
#include <linux/hrtimer.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/uio.h>
#include <sound/core.h>
#include <sound/pcm.h>

#define CBUS_BASE		0xc1100000
#define CBUS_REG(r)		(CBUS_BASE + (r) * 4)

#define AUDIN_BASE		CBUS_REG(0x2800)
#define AUDIN_SIZE		0x400
#define AUDIN_REG(r)		(((r) - 0x2800) * 4)
#define AUDIN_I2SIN_CTRL	AUDIN_REG(0x2810)
#define AUDIN_FIFO0_START	AUDIN_REG(0x2820)
#define AUDIN_FIFO0_END		AUDIN_REG(0x2821)
#define AUDIN_FIFO0_PTR		AUDIN_REG(0x2822)
#define AUDIN_FIFO0_CTRL	AUDIN_REG(0x2825)
#define AUDIN_FIFO0_CTRL1	AUDIN_REG(0x2826)

#define I2SIN_DIR		BIT(0)		/* clocks: 1 = internal */
#define I2SIN_CLK_SEL		BIT(1)		/* BCLK from the AIU */
#define I2SIN_LRCLK_SEL		BIT(2)		/* LRCLK from the AIU */
#define I2SIN_POS_SYNC		BIT(3)
#define I2SIN_LRCLK_SKEW(x)	((x) << 4)
#define I2SIN_LRCLK_INVT	BIT(7)
#define I2SIN_SIZE_24		(3 << 8)
#define I2SIN_CHAN_EN(x)	((x) << 10)
#define I2SIN_EN		BIT(15)

#define FIFO0_EN		BIT(0)
#define FIFO0_RST		BIT(1)
#define FIFO0_LOAD		BIT(2)
#define FIFO0_DIN_I2S		(1 << 3)
#define FIFO0_ENDIAN(x)		((x) << 8)
#define FIFO0_CHAN(x)		((x) << 11)
#define FIFO0_UG		BIT(15)

/*
 * GPIOY_5 -> i2s_in_ch01 (PIN_MUX_1 bit 5), off pcm_in_b (PIN_MUX_4 bit 24) and
 * PIN_MUX_3 bit 15 (cleared by the Crestron DTB). Written directly: the mainline
 * meson8 pinctrl lists this group as "i2s_in_ch01_pins", so it can't be selected.
 */
#define PIN_MUX(n)		CBUS_REG(0x202c + (n))

/*
 * AUDIN clock gate: HHI_GCLK_MPEG1 bit 2 (GCLK_AUD_IN in Amlogic 3.10, "i2s_spdif" =
 * CLKID_I2S_SPDIF in the mainline meson8b clock driver); U-Boot leaves it off.
 * AUDIN reset: RESET_AUDIN = 65 -> level register 2 bit 1 (1 = released).
 */
#define CLKID_I2S_SPDIF		35
#define HHI_GCLK_MPEG1		CBUS_REG(0x1051)
#define GCLK_AUD_IN		BIT(2)
#define RESET_LEVEL2		0xc1104488
#define RESET_AUDIN_BIT		BIT(1)

#define TSW_CARD_INDEX		1		/* card 0 is the playback card */
#define HW_FRAME		8		/* 2 x 32-bit words per frame in DDR */
#define BLOCK_FRAMES		8		/* 8 L + 8 R words per 64-byte block */
#define MAX_FRAMES		16384
#define HW_BYTES		(MAX_FRAMES * HW_FRAME)

static int pos_sync;
module_param(pos_sync, int, 0444);
MODULE_PARM_DESC(pos_sync, "I2SIN_POS_SYNC bit (default 0, as Amlogic 3.10 on Meson8)");
static int skew = 1;
module_param(skew, int, 0444);
MODULE_PARM_DESC(skew, "LRCLK skew in BCLK cycles, 0..7 (default 1 = I2S)");
static int lr_invert = 1;
module_param(lr_invert, int, 0444);
MODULE_PARM_DESC(lr_invert, "invert LRCLK (default 1)");
static int shift = 8;
module_param(shift, int, 0644);
MODULE_PARM_DESC(shift, "right shift of the 24-bit word to get S16 (default 8; can be changed while recording)");
static int debug;
module_param(debug, int, 0644);
MODULE_PARM_DESC(debug, "log the raw FIFO0 pointer on the first N timer ticks of each start");

struct tsw_audin {
	struct device *dev;
	void __iomem *regs;
	struct clk *clk;
	int debug_left;
	u32 *hw_area;
	dma_addr_t hw_addr;
	struct snd_pcm_substream *ss;
	struct hrtimer timer;
	ktime_t tick;
	unsigned int hw_bytes;
	unsigned int last_period;
	bool running;
};

static const struct snd_pcm_hardware tsw_audin_hw = {
	.info = SNDRV_PCM_INFO_INTERLEAVED | SNDRV_PCM_INFO_BLOCK_TRANSFER,
	.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S32_LE,
	.rates = SNDRV_PCM_RATE_48000,
	.rate_min = 48000,
	.rate_max = 48000,
	.channels_min = 2,
	.channels_max = 2,
	/* limits in frames are set in open (the frame size depends on the format) */
	.buffer_bytes_max = MAX_FRAMES * 8,
	.period_bytes_min = 64 * 4,
	.period_bytes_max = MAX_FRAMES * 4,
	.periods_min = 2,
	.periods_max = 64,
};

static snd_pcm_uframes_t tsw_audin_hw_pos(struct tsw_audin *a)
{
	u32 p;

	writel(1, a->regs + AUDIN_FIFO0_PTR);	/* latch the write pointer */
	p = readl(a->regs + AUDIN_FIFO0_PTR);
	if (a->debug_left > 0) {
		u32 off = (p & ~0x3f) - a->hw_addr;
		const u32 *w;

		a->debug_left--;
		dev_info(a->dev, "FIFO0 ptr %#x (start %#x end %#x ctrl %#x i2sin %#x)\n", p,
			 readl(a->regs + AUDIN_FIFO0_START), readl(a->regs + AUDIN_FIFO0_END),
			 readl(a->regs + AUDIN_FIFO0_CTRL), readl(a->regs + AUDIN_I2SIN_CTRL));
		if (off >= 64 && off < a->hw_bytes) {
			/* the last complete block: 8 left words, then the first 4 right ones */
			w = a->hw_area + (off - 64) / 4;
			dev_info(a->dev, "raw L %08x %08x %08x %08x %08x %08x %08x %08x R %08x %08x %08x %08x\n",
				 w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]);
		}
	}
	p &= ~0x3f;
	if (p < a->hw_addr || p >= a->hw_addr + a->hw_bytes)
		return 0;
	return (p - a->hw_addr) / HW_FRAME;
}

static enum hrtimer_restart tsw_audin_timer(struct hrtimer *t)
{
	struct tsw_audin *a = container_of(t, struct tsw_audin, timer);
	struct snd_pcm_runtime *rt;
	unsigned int period;

	if (!READ_ONCE(a->running))
		return HRTIMER_NORESTART;
	rt = a->ss->runtime;
	period = tsw_audin_hw_pos(a) / rt->period_size;
	if (period != a->last_period) {
		a->last_period = period;
		snd_pcm_period_elapsed(a->ss);
	}
	hrtimer_forward_now(t, a->tick);
	return HRTIMER_RESTART;
}

static int tsw_audin_open(struct snd_pcm_substream *ss)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	int ret;

	rt->hw = tsw_audin_hw;
	ret = snd_pcm_hw_constraint_step(rt, 0, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, BLOCK_FRAMES);
	if (!ret)
		ret = snd_pcm_hw_constraint_step(rt, 0, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, BLOCK_FRAMES);
	if (!ret)
		ret = snd_pcm_hw_constraint_minmax(rt, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, 2 * 64, MAX_FRAMES);
	if (!ret)
		ret = snd_pcm_hw_constraint_minmax(rt, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 64, MAX_FRAMES / 2);
	if (!ret)
		ret = snd_pcm_hw_constraint_integer(rt, SNDRV_PCM_HW_PARAM_PERIODS);
	if (!ret)
		ret = snd_pcm_hw_constraint_msbits(rt, 0, 32, 24);
	if (ret < 0)
		return ret;
	a->ss = ss;
	return 0;
}

static int tsw_audin_close(struct snd_pcm_substream *ss)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);

	writel(0, a->regs + AUDIN_I2SIN_CTRL);
	writel(0, a->regs + AUDIN_FIFO0_CTRL);
	a->ss = NULL;
	return 0;
}

static int tsw_audin_prepare(struct snd_pcm_substream *ss)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	u32 start = a->hw_addr;

	a->hw_bytes = rt->buffer_size * HW_FRAME;
	a->tick = ns_to_ktime(max_t(u64, div_u64((u64)rt->period_size * NSEC_PER_SEC,
						 rt->rate * 4), NSEC_PER_MSEC));
	memset(a->hw_area, 0, a->hw_bytes);

	writel(0, a->regs + AUDIN_I2SIN_CTRL);
	writel(start, a->regs + AUDIN_FIFO0_START);
	writel(start, a->regs + AUDIN_FIFO0_PTR);
	writel(start + a->hw_bytes - 8, a->regs + AUDIN_FIFO0_END);
	writel(FIFO0_EN | FIFO0_LOAD | FIFO0_DIN_I2S | FIFO0_ENDIAN(4) | FIFO0_CHAN(2) | FIFO0_UG,
	       a->regs + AUDIN_FIFO0_CTRL);
	writel(2 << 2, a->regs + AUDIN_FIFO0_CTRL1);	/* din_byte_num = 2 (24 bit) */
	writel(I2SIN_SIZE_24 | I2SIN_CHAN_EN(1) | (pos_sync ? I2SIN_POS_SYNC : 0) |
	       I2SIN_LRCLK_SKEW(skew & 7) | (lr_invert ? I2SIN_LRCLK_INVT : 0) |
	       I2SIN_CLK_SEL | I2SIN_LRCLK_SEL | I2SIN_DIR, a->regs + AUDIN_I2SIN_CTRL);
	dev_dbg(a->dev, "prepare: buffer %u frames at %pad, period %lu\n",
		(unsigned int)rt->buffer_size, &a->hw_addr, rt->period_size);
	return 0;
}

static int tsw_audin_trigger(struct snd_pcm_substream *ss, int cmd)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);
	u32 v;
	int i;

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
		/* reset the write pointer to START, as the Amlogic 3.10 driver does */
		for (i = 0; i < 10; i++) {
			v = readl(a->regs + AUDIN_FIFO0_CTRL);
			writel(v | FIFO0_RST, a->regs + AUDIN_FIFO0_CTRL);
			writel(0, a->regs + AUDIN_FIFO0_PTR);
			if (readl(a->regs + AUDIN_FIFO0_PTR) == readl(a->regs + AUDIN_FIFO0_START))
				break;
		}
		if (i == 10)
			dev_warn(a->dev, "FIFO0 write pointer did not reset\n");
		v = readl(a->regs + AUDIN_I2SIN_CTRL);
		writel(v | I2SIN_EN, a->regs + AUDIN_I2SIN_CTRL);
		a->last_period = 0;
		a->debug_left = debug;
		WRITE_ONCE(a->running, true);
		hrtimer_start(&a->timer, a->tick, HRTIMER_MODE_REL_SOFT);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		WRITE_ONCE(a->running, false);
		v = readl(a->regs + AUDIN_I2SIN_CTRL);
		writel(v & ~I2SIN_EN, a->regs + AUDIN_I2SIN_CTRL);
		hrtimer_try_to_cancel(&a->timer);
		return 0;
	}
	return -EINVAL;
}

static int tsw_audin_sync_stop(struct snd_pcm_substream *ss)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);

	hrtimer_cancel(&a->timer);
	return 0;
}

static snd_pcm_uframes_t tsw_audin_pointer(struct snd_pcm_substream *ss)
{
	return tsw_audin_hw_pos(snd_pcm_substream_chip(ss));
}

static int tsw_audin_copy(struct snd_pcm_substream *ss, int channel, unsigned long pos,
			  struct iov_iter *iter, unsigned long bytes)
{
	struct tsw_audin *a = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	bool s32 = rt->format == SNDRV_PCM_FORMAT_S32_LE;
	unsigned long f = bytes_to_frames(rt, pos), n = bytes_to_frames(rt, bytes);
	u32 buf[2 * 64];
	s16 *buf16 = (s16 *)buf;

	while (n) {
		unsigned int k = min(n, 64UL), i;
		size_t len = frames_to_bytes(rt, k);

		for (i = 0; i < k; i++, f++) {
			const u32 *blk = a->hw_area + (f / BLOCK_FRAMES) * 2 * BLOCK_FRAMES;
			u32 l = blk[f % BLOCK_FRAMES], r = blk[BLOCK_FRAMES + f % BLOCK_FRAMES];

			if (s32) {
				/* the whole 24-bit word, MSB-aligned */
				buf[2 * i] = l << 8;
				buf[2 * i + 1] = r << 8;
			} else {
				buf16[2 * i] = l >> shift;
				buf16[2 * i + 1] = r >> shift;
			}
		}
		if (copy_to_iter(buf, len, iter) != len)
			return -EFAULT;
		n -= k;
	}
	return 0;
}

static const struct snd_pcm_ops tsw_audin_ops = {
	.open = tsw_audin_open,
	.close = tsw_audin_close,
	.prepare = tsw_audin_prepare,
	.trigger = tsw_audin_trigger,
	.sync_stop = tsw_audin_sync_stop,
	.pointer = tsw_audin_pointer,
	.copy = tsw_audin_copy,
};

static u32 tsw_audin_set_bits(phys_addr_t addr, u32 set, u32 clr)
{
	void __iomem *r = ioremap(addr, 4);
	u32 old = 0;

	if (r) {
		old = readl(r);
		writel((old & ~clr) | set, r);
		iounmap(r);
	}
	return old;
}

static void tsw_audin_clk_off(void *data)
{
	struct tsw_audin *a = data;

	clk_disable_unprepare(a->clk);
	clk_put(a->clk);
}

/* the AUDIN gate through the clock framework (it owns HHI_GCLK_MPEG1) */
static int tsw_audin_clk_on(struct tsw_audin *a)
{
	struct of_phandle_args args = { .args_count = 1, .args = { CLKID_I2S_SPDIF } };
	struct clk *clk;
	int ret;

	args.np = of_find_compatible_node(NULL, NULL, "amlogic,meson8m2-clkc");
	if (!args.np)
		return -ENODEV;
	clk = of_clk_get_from_provider(&args);
	of_node_put(args.np);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	ret = clk_prepare_enable(clk);
	if (ret) {
		clk_put(clk);
		return ret;
	}
	a->clk = clk;
	return devm_add_action_or_reset(a->dev, tsw_audin_clk_off, a);
}

static int tsw_audin_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct tsw_audin *a;
	struct snd_card *card;
	struct snd_pcm *pcm;
	int ret;

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return ret;
	a = devm_kzalloc(dev, sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;
	a->dev = dev;
	a->regs = devm_ioremap(dev, AUDIN_BASE, AUDIN_SIZE);
	if (!a->regs)
		return -ENOMEM;
	a->hw_area = dmam_alloc_coherent(dev, HW_BYTES, &a->hw_addr, GFP_KERNEL);
	if (!a->hw_area)
		return -ENOMEM;
	hrtimer_init(&a->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL_SOFT);
	a->timer.function = tsw_audin_timer;

	ret = tsw_audin_clk_on(a);
	if (ret) {
		dev_warn(dev, "no AUDIN clock from clkc (%d), setting the gate directly\n", ret);
		tsw_audin_set_bits(HHI_GCLK_MPEG1, GCLK_AUD_IN, 0);
	}
	if (!(tsw_audin_set_bits(RESET_LEVEL2, RESET_AUDIN_BIT, 0) & RESET_AUDIN_BIT))
		dev_info(dev, "AUDIN was held in reset, released\n");
	writel(0, a->regs + AUDIN_I2SIN_CTRL);
	writel(0, a->regs + AUDIN_FIFO0_CTRL);
	tsw_audin_set_bits(PIN_MUX(4), 0, BIT(24));
	tsw_audin_set_bits(PIN_MUX(3), 0, BIT(15));
	tsw_audin_set_bits(PIN_MUX(1), BIT(5), 0);

	/*
	 * Fixed index: this module is loaded early at boot, and with the first free
	 * index it would take card 0 before the ASoC playback card probes, while
	 * PulseAudio and tsw-sound use hw:0,0 for playback.
	 */
	ret = snd_devm_card_new(dev, TSW_CARD_INDEX, "TSW1060Mic", THIS_MODULE, 0, &card);
	if (ret)
		return ret;
	strscpy(card->driver, "tsw-audin", sizeof(card->driver));
	strscpy(card->shortname, "TSW-1060 Mic", sizeof(card->shortname));
	strscpy(card->longname, "TSW-1060 microphones (ZL38051 AEC) on AUDIN I2S in",
		sizeof(card->longname));
	ret = snd_pcm_new(card, "AUDIN", 0, 0, 1, &pcm);
	if (ret)
		return ret;
	pcm->private_data = a;
	strscpy(pcm->name, "TSW-1060 Mic", sizeof(pcm->name));
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &tsw_audin_ops);
	ret = snd_card_register(card);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, a);
	dev_info(dev, "AUDIN capture card registered (buffer at %pad)\n", &a->hw_addr);
	return 0;
}

static void tsw_audin_remove(struct platform_device *pdev)
{
	struct tsw_audin *a = platform_get_drvdata(pdev);

	writel(0, a->regs + AUDIN_I2SIN_CTRL);
	writel(0, a->regs + AUDIN_FIFO0_CTRL);
	hrtimer_cancel(&a->timer);
}

static struct platform_driver tsw_audin_driver = {
	.probe = tsw_audin_probe,
	.remove = tsw_audin_remove,
	.driver = { .name = "tsw-audin" },
};

static struct platform_device *tsw_audin_pdev;

static int __init tsw_audin_init(void)
{
	struct platform_device_info info = {
		.name = "tsw-audin",
		.id = PLATFORM_DEVID_NONE,
		.dma_mask = DMA_BIT_MASK(32),
	};
	int ret;

	if (!of_machine_is_compatible("amlogic,meson8m2"))
		return -ENODEV;
	ret = platform_driver_register(&tsw_audin_driver);
	if (ret)
		return ret;
	tsw_audin_pdev = platform_device_register_full(&info);
	if (IS_ERR(tsw_audin_pdev)) {
		platform_driver_unregister(&tsw_audin_driver);
		return PTR_ERR(tsw_audin_pdev);
	}
	return 0;
}

static void __exit tsw_audin_exit(void)
{
	platform_device_unregister(tsw_audin_pdev);
	platform_driver_unregister(&tsw_audin_driver);
}

module_init(tsw_audin_init);
module_exit(tsw_audin_exit);
MODULE_DESCRIPTION("TSW-1060 microphone capture (Amlogic Meson8 AUDIN I2S input)");
MODULE_LICENSE("GPL");
