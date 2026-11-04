# TSW-1060 microphone capture module (AUDIN I2S input), built out of tree against the
# kernel tree of build_tsw_mainline.sh:
#   make WORK=/path/to/tsw-mainline-build
# -> snd-tsw-audin.ko; copy it to the panel and run install.sh there.
obj-m := snd-tsw-audin.o

WORK ?= $(CURDIR)/../tsw-mainline-build
KVER ?= 6.12.114
KSRC ?= $(WORK)/linux-$(KVER)
KOUT ?= $(WORK)/kernel-out
CROSS ?= arm-linux-gnueabihf-

all:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) ARCH=arm CROSS_COMPILE=$(CROSS) modules

clean:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) ARCH=arm CROSS_COMPILE=$(CROSS) clean
