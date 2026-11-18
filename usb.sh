#!/bin/sh
# Write the image to a USB stick:  sudo ./usb.sh /dev/sdX     (ERASES the stick)
set -e
cd "$(dirname "$0")"
[ -n "$1" ] || { echo "usage: sudo $0 /dev/sdX"; exit 1; }
case "$1" in /dev/sd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/mmcblk[0-9]) ;; *) echo "give a whole disk like /dev/sdb"; exit 1;; esac
lsblk "$1" || true
printf "ALL DATA ON %s WILL BE DESTROYED. Type YES: " "$1"
read a; [ "$a" = YES ] || exit 1
dd if=centtrix.img of="$1" bs=1M conv=fsync status=progress
sync
echo "Done. Boot the PC in Legacy/CSM (BIOS) mode, not UEFI-only."
