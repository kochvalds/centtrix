#!/bin/sh
set -e
cd "$(dirname "$0")/.."
mkdir -p build
rm -f build/*.bin build/native_tab.inc
TAB=build/native_tab.inc
LIST=build/native_list.tmp
: > "$LIST"
ENT=build/native_ent.tmp
: > "$ENT"

cat > build/native_entry.asm <<'EOF'
[BITS 64]
extern _start
section .text.start
global _entry_stub
_entry_stub:
    jmp _start
EOF
nasm -f elf64 build/native_entry.asm -o build/native_entry.o

cat > build/native.ld <<'EOF'
SECTIONS
{
  . = 0x10000000;
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.data*) *(.bss*) *(COMMON) }
  /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) *(.gcc_except_table*) }
}
EOF

CFLAGS="-O2 -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -mno-red-zone -mcmodel=large"
RFLAGS="--target x86_64-unknown-linux-gnu --crate-type=lib --emit=obj -O -A warnings -C panic=abort -C relocation-model=static -C no-redzone=yes"
LDFLAGS="-T build/native.ld -e _entry_stub --oformat binary"

sane() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

add() {
    n="$1"
    printf '    dq n_p_%s, %s_blob, %s_len\n' "$n" "$n" "$n" >> "$ENT"
    printf 'n_p_%s db "/home/pkg/%s.bin",0\n' "$n" "$n" >> "$LIST"
}

for f in progs/*.c; do
    [ -e "$f" ] || continue
    n=$(sane "$(basename "$f" .c)")_c
    gcc $CFLAGS -c "$f" -o "build/$n.o"
    ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
    add "$n"
done

if command -v rustc >/dev/null 2>&1; then
    for f in progs/*.rs; do
        [ -e "$f" ] || continue
        n=$(sane "$(basename "$f" .rs)")_rs
        rustc $RFLAGS "$f" -o "build/$n.o"
        ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
        add "$n"
    done
else
    echo "rustc not found: Rust programs skipped" >&2
fi

{
    printf 'nat_btab:\n'
    cat "$ENT"
    printf '    dq 0\n'
    cat "$LIST"
    while read -r l; do
        [ -n "$l" ] || continue
        n=$(echo "$l" | sed 's/.*n_p_\([^ ]*\) .*/\1/')
        printf '%s_blob:\n    incbin "build/%s.bin"\n%s_len equ $-%s_blob\n' "$n" "$n" "$n" "$n"
    done < "$LIST"
} > "$TAB"

rm -f "$LIST" "$ENT"
ls -l build/*.bin
