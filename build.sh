#!/bin/sh
# Build Centtrix+ :  ./build.sh          (needs nasm and python3)
#                    ./build.sh lite     (without BIGFS, smaller kernel)
set -e
cd "$(dirname "$0")"
OPT=""; [ "$1" = lite ] && OPT="--lite"
try() {
    python3 src/patch.py $1 centtrix.asm centtrix_plus.asm
    nasm -f bin -w-label-redef -I src/ centtrix_plus.asm -o centtrix.new 2> build.log
}
if ! try "$OPT"; then
    cat build.log
    if grep -q 'TIMES value' build.log && [ -z "$OPT" ]; then
        echo; echo "== kernel too big, retrying without BIGFS (lite) =="
        if try --lite; then echo "LITE build OK (no bigfs)"; else
            cat build.log; echo
            echo "== even lite does not fit. Does the ORIGINAL assemble? =="
            nasm -f bin centtrix.asm -o /tmp/orig.img 2>&1 | tail -3 || true
            echo "Send me the lines above."; exit 1
        fi
    else exit 1; fi
fi
# Only the boot sector + kernel live below FS_LBA; sectors from FS_LBA on hold
# the filesystem.  Overwriting them would wipe the user's files and account
# on every build, so an existing disk keeps its data.
if [ -f centtrix.img ] && [ "$(wc -c < centtrix.img)" -ge 67108864 ]; then
    dd if=centtrix.new of=centtrix.img bs=512 count=896 conv=notrunc status=none
    rm -f centtrix.new
else
    mv centtrix.new centtrix.img
fi
truncate -s 64M centtrix.img
# NOTE: the disk keeps its filesystem and the user account between builds.
# For a factory-fresh disk run tools/newdisk.sh
echo "OK: centtrix.img ($(wc -c < centtrix.img) bytes)"
