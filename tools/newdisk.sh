#!/bin/sh
# factory-fresh filesystem (and no account): the kernel reformats at the next boot
cd "$(dirname "$0")/.."
dd if=/dev/zero of=centtrix.img bs=512 seek=896 count=1 conv=notrunc status=none
echo "centtrix.img: filesystem + account wiped, will be re-seeded at boot"
