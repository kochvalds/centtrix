#!/bin/sh
cd "$(dirname "$0")"
case "$1" in
install)
    if [ ! -f Centtrix-4.0.iso ]; then
        ./build.sh iso
    fi
    if [ ! -f target.qcow2 ]; then
        qemu-img create -f qcow2 target.qcow2 256M >/dev/null
    fi
    exec qemu-system-x86_64 \
        -cdrom Centtrix-4.0.iso -boot d \
        -drive format=qcow2,file=target.qcow2 \
        -m 512 -rtc base=localtime -nic user,model=e1000
    ;;
usb)
    if [ ! -f Centtrix-4.0.iso ]; then
        ./build.sh iso
    fi
    if [ ! -f usb.img ] || [ "$(wc -c < usb.img)" -lt 67108864 ]; then
        truncate -s 128M usb.img
        dd if=Centtrix-4.0.iso of=usb.img conv=notrunc status=none
    fi
    exec qemu-system-x86_64 \
        -drive if=none,id=usb,format=raw,file=usb.img \
        -device qemu-xhci -device usb-storage,drive=usb,bootindex=1 \
        -m 512 -rtc base=localtime -nic user,model=e1000
    ;;
esac
exec qemu-system-x86_64 -drive format=raw,file=centtrix.img -m 512 -rtc base=localtime -nic user,model=e1000
