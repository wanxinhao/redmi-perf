obj-m := redmi_perf_wmi.o

ifneq ($(KERNELRELEASE),)

# Kbuild pass: obj-m above is all that is needed.

else

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

endif
