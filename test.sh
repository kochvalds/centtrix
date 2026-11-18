#!/bin/sh
# Build a self-testing image (does NOT replace the normal build).
# It replaces the login screen with src/selftest.inc and prints to COM1.
set -e
cd "$(dirname "$0")"
python3 src/patch.py centtrix.asm /tmp/centtrix_selftest.asm
python3 - <<'PY'
p = "/tmp/centtrix_selftest.asm"
t = open(p, encoding="utf-8", errors="surrogateescape").read()
old_login = "    call desk_draw\n    call login_screen\n.idle:\n"
if t.count(old_login) != 1:
    raise SystemExit("kmain login block not found exactly once")
t = t.replace(old_login, "    call desk_draw\n    call selftest\n.idle:\n", 1)
old = '%include "download.inc"\n'
if t.count(old) != 1:
    raise SystemExit("download include not found exactly once")
t = t.replace(old, old + '%include "selftest.inc"\n', 1)
open(p, "w", encoding="utf-8", errors="surrogateescape").write(t)
PY
nasm -f bin -I src/ /tmp/centtrix_selftest.asm -o selftest.img
truncate -s 64M selftest.img
echo "OK: selftest.img"
