; =============================================================================
;  selftest.inc  -  boot-time hardware/feature test (TEST BUILD ONLY)
;  Replaces login_screen, writes progress to COM1 (0x3F8), then halts.
;  Not included in the normal build.
; =============================================================================
selftest:
    PUSHA
    cld
    call com_init
    lea rsi, [t_banner]
    call com_puts

    ; ---- no ATA and no BIOS: bg_rd must report an error, not stale bytes ----
    mov al, [ata_ok]
    mov [s_ata], al
    mov al, [SB_BIOS]
    mov [s_bios], al
    mov byte [ata_ok], 0
    mov byte [SB_BIOS], 0
    mov eax, BIG_LBA
    mov ecx, 1
    lea rdi, [bg_scr]
    call bg_rd
    jc .guard_ok
    mov al, [s_ata]
    mov [ata_ok], al
    mov al, [s_bios]
    mov [SB_BIOS], al
    jmp .fail_guard
.guard_ok:
    mov al, [s_ata]
    mov [ata_ok], al
    mov al, [s_bios]
    mov [SB_BIOS], al
    lea rsi, [t_guard]
    call com_puts

    ; ---- CNT3: the boot-time format must have stamped the superblock --------
    cmp dword [SB3_MAGIC], SIG3
    jne .fail_fs3
    lea rsi, [t_fs3fmt]
    call com_puts
    call fs3_count
    mov eax, [fs_nfiles]
    add eax, [fs_ndirs]
    lea rsi, [t_cnt]
    call com_puts
    call com_hex

    ; ---- download: HTTP GET from the host (10.0.2.2) ------------------------
    lea rsi, [t_url]
    lea rdi, [dl_url]
    call strcpy
    call dl_fetch
    push rax
    lea rsi, [t_http]
    call com_puts
    pop rax
    call com_hex
    lea rsi, [t_status]
    call com_puts
    mov eax, [http_status]
    call com_hex
    lea rsi, [t_len]
    call com_puts
    mov eax, [HTTPB+48]
    call com_hex

    lea rsi, [t_name2]
    lea rdi, [dl_name]
    call strcpy
    call dl_save
    push rax
    lea rsi, [t_save]
    call com_puts
    pop rax
    call com_hex
    test eax, eax
    jnz .fail_bigsave

    ; the download is 20000 bytes -> a CNT3 chain; read it back and compare
    lea rsi, [t_name2]
    call mkpath_cur
    call fs3_find
    test rax, rax
    jz .fail_bigfind
    mov r12, rax
    lea rsi, [t_dlsize]
    call com_puts
    mov eax, [r12+48]
    call com_hex
    cmp dword [r12+48], 20000
    jne .fail_bigsize
    mov ebx, [r12+52]
    lea rdi, [VBMP]
    mov ecx, 0x300000
    call fs3_read_chain
    lea rsi, [t_rbytes]
    call com_puts
    call com_hex
    cmp eax, 20000
    jne .fail_bigsize
    lea rsi, [VBMP]
    lea rdi, [HTTPB+64]
    mov ecx, 2500
    repe cmpsq
    jne .fail_bigcmp
    lea rsi, [t_bigok]
    call com_puts
    ; drop the test file again
    mov eax, [r12+56]
    call fs3_del_id

    ; ---- small file -> normal CNT3 slot + disk write ------------------------
    lea rsi, [t_url_small]
    lea rdi, [dl_url]
    call strcpy
    call dl_fetch
    push rax
    lea rsi, [t_http]
    call com_puts
    pop rax
    call com_hex
    lea rsi, [t_status]
    call com_puts
    mov eax, [http_status]
    call com_hex
    lea rsi, [t_len]
    call com_puts
    mov eax, [HTTPB+48]
    call com_hex

    lea rsi, [t_name_small]
    lea rdi, [dl_name]
    call strcpy
    call dl_save
    push rax
    lea rsi, [t_save]
    call com_puts
    pop rax
    call com_hex
    test eax, eax
    jnz .fail_small

    lea rsi, [dl_name]
    call mkpath_cur
    call fs_find
    test rax, rax
    jz .fail_small
    mov r12, rax
    lea rsi, [t_fsize]
    call com_puts
    mov eax, [r12+48]
    call com_hex
    lea rsi, [t_fsdata]
    call com_puts
    mov eax, [r12+64]
    call com_hex
    lea rsi, [t_httpdata]
    call com_puts
    mov eax, [HTTPB+64]
    call com_hex
    lea rsi, [r12+64]
    lea rdi, [HTTPB+64]
    mov ecx, 125
    repe cmpsq
    jne .fail_small

    ; read the file back from the disk: first cluster through the FAT
    mov ebx, [r12+52]
    lea rdi, [RAWB]
    mov ecx, 16384
    call fs3_read_chain
    lea rsi, [t_diskdata]
    call com_puts
    mov eax, [RAWB+64]
    call com_hex
    lea rsi, [t_fsdata2]
    call com_puts
    mov eax, [r12+64]
    call com_hex
    lea rsi, [RAWB+64]
    lea rdi, [r12+64]
    mov ecx, 125
    repe cmpsq
    jne .fail_small
    lea rsi, [t_smallok]
    call com_puts

    ; drop the test file again
    mov eax, [r12+56]
    call fs3_del_id

    ; ---- terminal command parser: bigfs format yes --------------------------
    lea rsi, [t_bigcmd]
    call term_bigfs
    cmp dword [bg_buf], BG_MAGIC
    jne .fail_bigcmd
    lea rsi, [t_bigcmdok]
    call com_puts

    lea rsi, [t_ok]
    call com_puts
    jmp .halt

.fail_fs3:
    lea rsi, [t_f1]
    jmp .fail
.fail_bigsave:
    lea rsi, [t_f2]
    jmp .fail
.fail_bigfind:
    lea rsi, [t_f3]
    jmp .fail
.fail_bigsize:
    lea rsi, [t_f4]
    jmp .fail
.fail_bigcmp:
    lea rsi, [t_f5]
    jmp .fail
.fail_small:
    lea rsi, [t_f7]
    jmp .fail
.fail_bigcmd:
    lea rsi, [t_f8]
    jmp .fail
.fail_guard:
    lea rsi, [t_f9]
.fail:
    call com_puts
    lea rsi, [t_fail]
    call com_puts
.halt:
    cli
    hlt
    jmp .halt

; ---- tiny COM1 driver --------------------------------------------------------
com_init:
    push rax
    push rdx
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 1
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 3
    out dx, al
    mov dx, 0x3FA
    mov al, 0xC7
    out dx, al
    mov dx, 0x3FC
    mov al, 0x0B
    out dx, al
    pop rdx
    pop rax
    ret

com_putc:                               ; al = character
    push rax
    push rdx
    mov ah, al
    mov dx, 0x3FD
.w: in al, dx
    test al, 0x20
    jz .w
    mov dx, 0x3F8
    mov al, ah
    out dx, al
    pop rdx
    pop rax
    ret

com_puts:                               ; rsi = zstring
    push rax
    push rsi
.l: lodsb
    test al, al
    jz .d
    call com_putc
    jmp .l
.d: pop rsi
    pop rax
    ret

com_hex:                                ; eax -> 8 hex digits + newline
    push rax
    push rcx
    push rdx
    mov ecx, 8
.l: rol eax, 4
    push rax
    and al, 15
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p: call com_putc
    pop rax
    dec ecx
    jnz .l
    mov al, 10
    call com_putc
    pop rdx
    pop rcx
    pop rax
    ret

t_banner   db "SELFTEST START",10,0
t_ata      db "ata_ok=",0
t_disk     db "disk0=",0
t_mem      db "mem0=",0
t_fs3fmt   db "cnt3 superblock OK",10,0
t_cnt      db "entries=",0
t_rbytes   db "chain bytes=",0
t_bigok    db "big-file chain write/read/compare OK",10,0
t_name2    db "http.bin",0
t_url      db "http://10.0.2.2:8000/test.bin",0
t_url_small db "http://10.0.2.2:8000/small.txt",0
t_name_small db "small.txt",0
t_http     db "http result=",0
t_status   db "status=",0
t_len      db "len=",0
t_save     db "save result=",0
t_dlsize   db "saved size=",0
t_fsize    db "fs size=",0
t_fsdata   db "fs[0]=",0
t_httpdata db "http[0]=",0
t_diskdata db "disk[0]=",0
t_fsdata2  db "fs2[0]=",0
t_smallok  db "small-file write/read/disk OK",10,0
t_guard    db "no-device guard OK",10,0
t_bigcmd   db "format yes",0
t_bigcmdok db "bigfs terminal command OK",10,0
t_ok       db "SELFTEST OK",10,0
t_fail     db "SELFTEST FAILED",10,0
t_f1       db "at cnt3 superblock",10,0
t_f2       db "at big dl_save",10,0
t_f3       db "at big file find",10,0
t_f4       db "at big file size",10,0
t_f5       db "at big file compare",10,0
t_f7       db "at small file",10,0
t_f8       db "at bigfs command",10,0
t_f9       db "at no-device guard",10,0
s_ata      db 0
s_bios     db 0
