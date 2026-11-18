; =============================================================================
;  bigfs.inc  -  BIGFS: big-file store (files above the 16 KB slot limit)
;
;  Lives on the disk at BIG_LBA, outside the CNTX slot filesystem:
;    sector 0        header   'BGF1', reserved
;    sectors 1..8    table    64 entries x 64 bytes
;    BIG_DATA..      file data, contiguous, bump-allocated (rm leaves holes;
;                    "bigfs format yes" resets the store)
;  The disk/image must be large enough: build.sh pads the image to 64 MB.
;  It is NEVER formatted automatically - you must run:  bigfs format yes
;  Terminal:  bigfs info | ls | cat NAME | rm NAME | format yes
;  Covered by test.sh (format, 20 KB write, read-back and compare).
; =============================================================================
BIG_LBA     equ 4096
BIG_DATA    equ BIG_LBA+16
BIG_MAXSEC  equ 32768                   ; 16 MB of data
BG_MAGIC    equ 0x31464742              ; 'BGF1'
BG_MAXE     equ 64
BE_USED     equ 52
BE_LBA      equ 40
BE_SECT     equ 44
BE_BYTES    equ 48
BE_SIZE     equ 64
%define bg_tab bg_buf+512
; buffers live in free RAM (gap between the system area, which ends at 0x5300000,
; and the Python area at 0x5400000) so they do not enlarge the kernel image
bg_buf      equ 0x5380000               ; header + table (4608 bytes)
bg_scr      equ 0x5390000               ; scratch for 'bigfs cat' (2048 bytes)

; ---- disk helpers: ATA when present, BIOS int 13h otherwise -------------------
; CF=1 means "nothing was read/written"; callers must not treat stale memory
; as a valid big-file table.  The BIOS path is only valid when the user has
; enabled BIOS services and stage2 preloaded the filesystem.
bg_rd:                                  ; eax=LBA ecx=sectors rdi=dest -> CF=1 on error
    push rax
    push rcx
    push rdx
    cmp byte [ata_ok], 0
    je .bios
.l: call ata_read1
    cmp byte [ata_ok], 0
    je .err
    inc eax
    dec ecx
    jnz .l
    clc
    jmp .o
.bios:
    cmp byte [SB_BIOS], 0
    je .err
    cmp dword [bi_fsok], 0
    je .err
    movzx edx, byte [bootdrv]
    call bios_rd
    jc .err
    clc
    jmp .o
.err:
    stc
.o: pop rdx
    pop rcx
    pop rax
    ret

bg_wr:                                  ; eax=LBA ecx=sectors rsi=src -> CF=1 on error
    push rax
    push rcx
    push rdx
    cmp byte [ata_ok], 0
    je .bios
.l: call ata_write1
    cmp byte [ata_ok], 0
    je .err
    inc eax
    dec ecx
    jnz .l
    clc
    jmp .o
.bios:
    cmp byte [SB_BIOS], 0
    je .err
    cmp dword [bi_fsok], 0
    je .err
    movzx edx, byte [bootdrv]
    call bios_wr
    jc .err
    clc
    jmp .o
.err:
    stc
.o: pop rdx
    pop rcx
    pop rax
    ret

bg_flush:                               ; write header + table -> CF
    push rax
    push rcx
    push rsi
    mov eax, BIG_LBA
    mov ecx, 9
    lea rsi, [bg_buf]
    call bg_wr
    pop rsi
    pop rcx
    pop rax
    ret

bg_load:                                ; -> eax=1 when a valid store is in memory
    cmp byte [bg_ok], 1
    jne .rd
    mov eax, 1
    ret
.rd:
    push rcx
    push rdi
    mov eax, BIG_LBA
    mov ecx, 9
    lea rdi, [bg_buf]
    call bg_rd
    jc .bad
    cmp dword [bg_buf], BG_MAGIC
    jne .bad
    mov byte [bg_ok], 1
    mov eax, 1
    jmp .o
.bad:
    xor eax, eax
.o: pop rdi
    pop rcx
    ret

bg_format:                              ; -> CF=1 on error
    push rax
    push rcx
    push rdi
    lea rdi, [bg_buf]
    xor eax, eax
    mov ecx, 4608/4
    rep stosd
    mov dword [bg_buf], BG_MAGIC
    call bg_flush
    jc .o
    mov byte [bg_ok], 1
    clc
.o: pop rdi
    pop rcx
    pop rax
    ret

bg_find:                                ; rsi=name -> rax = entry or 0
    push rcx
    push rdi
    lea rdi, [bg_tab]
    mov ecx, BG_MAXE
.l: cmp dword [rdi+BE_USED], 0
    je .n
    call strcmp
    je .f
.n: add rdi, BE_SIZE
    dec ecx
    jnz .l
    xor eax, eax
    jmp .o
.f: mov rax, rdi
.o: pop rdi
    pop rcx
    ret

; ---- bg_put: rsi=name rdx=data ecx=size -> eax: 0 ok, 1 not formatted,
;              2 no room, 3 disk error ------------------------------------------
bg_put:
    PUSHA
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    call bg_load
    test eax, eax
    jz .nofmt
    lea r15d, [r14+511]
    shr r15d, 9
    test r15d, r15d
    jnz .sz
    mov r15d, 1
.sz:
    mov rsi, r12
    call bg_find
    test rax, rax
    jz .scan
    mov dword [rax+BE_USED], 0          ; overwrite: drop the old entry
.scan:
    mov ebx, BIG_DATA
    xor r8d, r8d
    lea rdi, [bg_tab]
    mov ecx, BG_MAXE
.sc:
    cmp dword [rdi+BE_USED], 0
    jne .used
    test r8, r8
    jnz .nx
    mov r8, rdi
    jmp .nx
.used:
    mov eax, [rdi+BE_LBA]
    add eax, [rdi+BE_SECT]
    cmp eax, ebx
    jbe .nx
    mov ebx, eax
.nx:
    add rdi, BE_SIZE
    dec ecx
    jnz .sc
    test r8, r8
    jz .full
    lea eax, [rbx+r15]
    cmp eax, BIG_DATA+BIG_MAXSEC
    ja .full
    mov [r8+BE_LBA], ebx
    mov [r8+BE_SECT], r15d
    mov [r8+BE_BYTES], r14d
    mov dword [r8+BE_USED], 1
    mov rdi, r8
    mov rsi, r12
    mov ecx, 39
.cn:
    lodsb
    test al, al
    jz .cz
    stosb
    dec ecx
    jnz .cn
.cz:
    mov byte [rdi], 0
    mov eax, ebx
    mov ecx, r15d
    mov rsi, r13
    call bg_wr
    jc .io
    call bg_flush
    jc .io
    xor eax, eax
    jmp .r
.nofmt:
    mov eax, 1
    jmp .r
.full:
    mov eax, 2
    jmp .r
.io:
    ; never leave a half-written name in the table: drop the entry and try to
    ; persist the clean table.  The data sectors become a harmless hole.
    mov dword [r8+BE_USED], 0
    call bg_flush
    mov eax, 3
.r: mov [bg_res], eax
    POPA
    mov eax, [bg_res]
    ret

; ---- terminal command: bigfs ... ----------------------------------------------
term_bigfs:                             ; rsi = arguments
    PUSHA
    call skipsp
    cmp byte [rsi], 0
    je .usage
    mov rbx, rsi
.t: mov al, [rsi]
    cmp al, ' '
    jbe .te
    inc rsi
    jmp .t
.te:
    test al, al
    jz .have
    mov byte [rsi], 0
    inc rsi
    call skipsp
.have:
    mov r12, rsi                        ; argument (may be empty)
    mov rsi, rbx
    lea rdi, [bgc_format]
    call strcmp
    je .format
    lea rdi, [bgc_ls]
    call strcmp
    je .ls
    lea rdi, [bgc_cat]
    call strcmp
    je .cat
    lea rdi, [bgc_rm]
    call strcmp
    je .rm
    lea rdi, [bgc_info]
    call strcmp
    je .info
.usage:
    lea rsi, [s_bg_use]
    call tput_s
    jmp .o
.format:
    mov rsi, r12
    lea rdi, [bgc_yes]
    call strcmp
    jne .needyes
    call bg_format
    jc .ioerr
    lea rsi, [s_bg_fmtd]
    call tput_s
    jmp .o
.needyes:
    lea rsi, [s_bg_yes]
    call tput_s
    jmp .o
.ioerr:
    lea rsi, [s_bg_io]
    call tput_s
    jmp .o
.nofmt:
    lea rsi, [s_bg_nofmt]
    call tput_s
    jmp .o
.info:
    call bg_load
    test eax, eax
    jz .nofmt
    xor r15d, r15d
    lea r13, [bg_tab]
    mov r14d, BG_MAXE
.ic:
    cmp dword [r13+BE_USED], 0
    je .in
    inc r15d
.in:
    add r13, BE_SIZE
    dec r14d
    jnz .ic
    lea rsi, [s_bg_files]
    call tput_s
    mov eax, r15d
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
    call tput_s
    call tnl
    jmp .o
.ls:
    call bg_load
    test eax, eax
    jz .nofmt
    xor r15d, r15d
    lea r13, [bg_tab]
    mov r14d, BG_MAXE
.ll:
    cmp dword [r13+BE_USED], 0
    je .ln
    mov rsi, r13
    call tput_s
    mov eax, 42
    call tpad
    mov eax, [r13+BE_BYTES]
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
    call tput_s
    lea rsi, [s_bg_bytes]
    call tput_s
    call tnl
    inc r15d
.ln:
    add r13, BE_SIZE
    dec r14d
    jnz .ll
    test r15d, r15d
    jnz .o
    lea rsi, [s_bg_empty]
    call tput_s
    jmp .o
.rm:
    call bg_load
    test eax, eax
    jz .nofmt
    mov rsi, r12
    call bg_find
    test rax, rax
    jz .nf
    mov dword [rax+BE_USED], 0
    call bg_flush
    jc .ioerr
    lea rsi, [s_bg_rm]
    call tput_s
    jmp .o
.nf:
    lea rsi, [s_bg_nf]
    call tput_s
    jmp .o
.cat:
    call bg_load
    test eax, eax
    jz .nofmt
    mov rsi, r12
    call bg_find
    test rax, rax
    jz .nf
    mov r13, rax
    mov ecx, [r13+BE_SECT]
    cmp ecx, 4
    jbe .c1
    mov ecx, 4
.c1:
    mov eax, [r13+BE_LBA]
    lea rdi, [bg_scr]
    call bg_rd
    jc .ioerr
    mov r14d, [r13+BE_BYTES]
    cmp r14d, 2000
    jbe .c2
    mov r14d, 2000
.c2:
    lea rsi, [bg_scr]
.cl:
    test r14d, r14d
    jz .cd
    lodsb
    dec r14d
    cmp al, 10
    je .cnl
    cmp al, 13
    je .cl
    cmp al, 32
    jb .dot
    cmp al, 126
    ja .dot
    call tput_c
    jmp .cl
.dot:
    mov al, '.'
    call tput_c
    jmp .cl
.cnl:
    call tnl
    jmp .cl
.cd:
    call tnl
.o: POPA
    ret

bg_ok       db 0
bg_res      dd 0
bgc_format  db "format",0
bgc_ls      db "ls",0
bgc_cat     db "cat",0
bgc_rm      db "rm",0
bgc_info    db "info",0
bgc_yes     db "yes",0
s_bg_use    db "usage: bigfs info | ls | cat NAME | rm NAME | format yes",10,0
s_bg_nofmt  db "bigfs is not formatted. Run: bigfs format yes",10,0
s_bg_yes    db "format erases the big-file store. Run: bigfs format yes",10,0
s_bg_fmtd   db "bigfs formatted.",10,0
s_bg_io     db "bigfs: disk error.",10,0
s_bg_files  db "bigfs files: ",0
s_bg_bytes  db " bytes",0
s_bg_empty  db "(empty)",10,0
s_bg_rm     db "removed.",10,0
s_bg_nf     db "no such big file.",10,0
