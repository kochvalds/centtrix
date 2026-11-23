#!/bin/sh
set -e
cd "$(dirname "$0")/.."
OUT=Centtrix-4.0.iso
B=build/iso
rm -rf "$B"
mkdir -p "$B/tree/boot/isolinux"

dd if=centtrix.img of="$B/tree/boot/centtrix.img" bs=512 count=2945 status=none
dd if=/dev/zero of="$B/tree/boot/centtrix.img" bs=512 seek=896 count=1 conv=notrunc status=none
printf '\001' | dd of="$B/tree/boot/centtrix.img" bs=1 seek=$((0x1B0)) conv=notrunc status=none

fetch() {
    mkdir -p build/deb
    case "$1" in
        isolinux.bin) u=isolinux_6.04~git20190206.bf6db5b4+dfsg1-2_all.deb ;;
        *) u=syslinux-common_6.04~git20190206.bf6db5b4+dfsg1-3ubuntu4_all.deb ;;
    esac
    if [ ! -f build/deb/$u ]; then
        curl -fsSL "https://archive.ubuntu.com/ubuntu/pool/main/s/syslinux/$u" -o build/deb/$u
    fi
    dpkg-deb -x build/deb/$u build/deb/x
}

need() {
    for d in /usr/lib/ISOLINUX /usr/lib/syslinux/modules/bios /usr/share/syslinux \
             /usr/lib/syslinux /usr/share/ISOLINUX; do
        if [ -f "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done
    p=$(find build/deb/x -name "$1" 2>/dev/null | head -1 || true)
    if [ -z "$p" ]; then
        fetch "$1"
        p=$(find build/deb/x -name "$1" | head -1)
    fi
    [ -n "$p" ] || { echo "missing $1" >&2; exit 1; }
    echo "$p"
}

cp "$(need isolinux.bin)" "$B/tree/boot/isolinux/isolinux.bin"
cp "$(need ldlinux.c32)" "$B/tree/boot/isolinux/ldlinux.c32"
cp "$(need memdisk)" "$B/tree/boot/isolinux/memdisk"
MBR=$(need isohdpfx.bin)

cat > "$B/tree/boot/isolinux/isolinux.cfg" <<'EOF'
DEFAULT centtrix
PROMPT 0
TIMEOUT 10
LABEL centtrix
  LINUX memdisk
  INITRD /boot/centtrix.img
  APPEND harddisk
EOF

xorriso -as mkisofs -quiet -o "$OUT" \
    -isohybrid-mbr "$MBR" \
    -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-gpt-basdat "$B/tree"
ls -l "$OUT"
