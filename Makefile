ASM ?= nasm
QEMU ?= qemu-system-x86_64
IMAGE := centtrix.img

.PHONY: all build run fresh clean

all: build

build:
	./build.sh

run: build
	./run.sh

fresh: build
	./tools/newdisk.sh

clean:
	rm -f $(IMAGE) centtrix.new centtrix_plus.asm build.log selftest.img

