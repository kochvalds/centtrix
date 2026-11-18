#!/bin/sh
cd "$(dirname "$0")"
if [ "$1" = install ]; then
    [ -f target.img ] || dd if=/dev/zero of=target.img bs=1M count=64 status=none
    exec qemu-system-x86_64 -drive format=raw,file=centtrix.img \
        -drive format=raw,file=target.img \
        -m 256 -rtc base=localtime -nic user,model=e1000
fi
exec qemu-system-x86_64 -drive format=raw,file=centtrix.img -m 256 -rtc base=localtime -nic user,model=e1000
