ASM ?= nasm
QEMU ?= qemu-system-x86_64
BUILD_DIR := build
IMAGE := $(BUILD_DIR)/centtrix.img
SOURCE := src/centtrix.asm

.PHONY: all build run clean

all: build

build: $(IMAGE)

$(IMAGE): $(SOURCE)
	mkdir -p $(BUILD_DIR)
	$(ASM) -f bin $(SOURCE) -o $(IMAGE)

run: $(IMAGE)
	$(QEMU) -drive format=raw,file=$(IMAGE) -m 256 -rtc base=localtime

clean:
	rm -rf $(BUILD_DIR)
