; bigfs_stub.inc - used by "build.sh lite": no big-file store, keeps the kernel small
bg_put:                                 ; always "not formatted" -> downloads are cut at 16 KB
    mov eax, 1
    ret
term_bigfs:
    lea rsi, [s_bg_off]
    call tput_s
    ret
s_bg_off db "bigfs is not built into this image (lite build).",10,0
