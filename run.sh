#!/bin/sh
cd "$(dirname "$0")"
if [ "$1" = install ]; then
    if [ ! -f target.qcow2 ]; then
        qemu-img create -f qcow2 target.qcow2 256M >/dev/null
    fi
    exec qemu-system-x86_64 -drive format=raw,file=centtrix.img \
        -drive format=qcow2,file=target.qcow2 \
        -m 512 -rtc base=localtime -nic user,model=e1000
fi
exec qemu-system-x86_64 -drive format=raw,file=centtrix.img -m 512 -rtc base=localtime -nic user,model=e1000
