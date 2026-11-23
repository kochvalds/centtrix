#!/bin/sh
set -e
cd "$(dirname "$0")/.."
mkdir -p build
rm -f build/*.bin build/native_tab.inc
TAB=build/native_tab.inc
ENT=build/native_ent.tmp
PKG=build/native_pkg.tmp
: > "$ENT"
: > "$PKG"

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

emit() {
    n="$1"
    target="$2"
    tab="$3"
    printf '    dq n_p_%s, %s_blob, %s_len\n' "$n" "$n" "$n" >> "$tab"
    printf 'n_p_%s db "%s",0\n' "$n" "$target" >> "$tab.names"
}

build_c() {
    src="$1"
    base=$(basename "$src" .c)
    n=$(sane "$base")_c
    target="$2"
    gcc $CFLAGS -c "$src" -o "build/$n.o"
    ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
    emit "$n" "$target" "$ENT"
}

build_rs() {
    src="$1"
    base=$(basename "$src" .rs)
    n=$(sane "$base")_rs
    target="$2"
    rustc $RFLAGS "$src" -o "build/$n.o"
    ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
    emit "$n" "$target" "$ENT"
}

build_pkg_c() {
    src="$1"
    base=$(basename "$src" .c)
    n=pkg_$(sane "$base")_c
    target="$2"
    gcc $CFLAGS -c "$src" -o "build/$n.o"
    ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
    emit "$n" "$target" "$PKG"
}

build_pkg_rs() {
    src="$1"
    base=$(basename "$src" .rs)
    n=pkg_$(sane "$base")_rs
    target="$2"
    rustc $RFLAGS "$src" -o "build/$n.o"
    ld $LDFLAGS -o "build/$n.bin" build/native_entry.o "build/$n.o"
    emit "$n" "$target" "$PKG"
}

for f in progs/*.c; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .c)
    build_c "$f" "/home/pkg/$b.c"
done

if command -v rustc >/dev/null 2>&1; then
    for f in progs/*.rs; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .rs)
        build_rs "$f" "/home/pkg/$b.rs"
    done
    for f in progs/pkg/*.c; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .c)
        build_pkg_c "$f" "/base/pkg/$b.c"
    done
    for f in progs/pkg/*.rs; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .rs)
        build_pkg_rs "$f" "/base/pkg/$b.rs"
    done
else
    echo "rustc not found: Rust programs skipped" >&2
fi

{
    printf 'nat_btab:\n'
    grep '^    dq' "$ENT" 2>/dev/null || true
    printf '    dq 0\n'
    cat "$ENT.names" 2>/dev/null || true
    printf 'nat_pkgtab:\n'
    grep '^    dq' "$PKG" 2>/dev/null || true
    printf '    dq 0\n'
    cat "$PKG.names" 2>/dev/null || true
    while read -r l; do
        [ -n "$l" ] || continue
        n=$(echo "$l" | sed 's/.*n_p_\([A-Za-z0-9_]*\).*/\1/')
        printf '%s_blob:\n    incbin "build/%s.bin"\n%s_len equ $-%s_blob\n' "$n" "$n" "$n" "$n"
    done < "$ENT"
    while read -r l; do
        [ -n "$l" ] || continue
        n=$(echo "$l" | sed 's/.*n_p_\([A-Za-z0-9_]*\).*/\1/')
        printf '%s_blob:\n    incbin "build/%s.bin"\n%s_len equ $-%s_blob\n' "$n" "$n" "$n" "$n"
    done < "$PKG"
} > "$TAB"

rm -f "$ENT" "$PKG" "$ENT.names" "$PKG.names"
ls -l build/*.bin
