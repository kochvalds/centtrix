; =============================================================================
;  CENTTRIX OS 3.5  -  64-bit (x86_64 long mode), one NASM file
;
;  build :  nasm -f bin centtrix.asm -o centtrix.img
;  run   :  qemu-system-x86_64 -drive format=raw,file=centtrix.img -m 256 -rtc base=localtime
;           (the kernel uses RAM up to ~83 MB, so give QEMU at least -m 96)
;
;  boot sector -> stage2 (real mode: VBE 32bpp, resolution from the superblock, A20)
;              -> protected mode -> paging -> long mode -> kernel
;  disk  : sector 0 = boot, 1..KSECT = kernel, FS_LBA.. = CNTX filesystem
;  fs    : /base  /dump  /home   (32 slots of 16 KB)
;  lang  : XPL, scripts are *.xep (write them in the built-in editor)
; =============================================================================

KSECT       equ 640                 ; kernel sectors after the boot sector
FS_LBA      equ 704                 ; filesystem superblock
VBEI        equ 0x1000              ; VBE controller info (stage2 scratch)
SBS         equ 0x1400              ; superblock sector copy (stage2 scratch)
FSBUF       equ 0x200000            ; in-memory filesystem (32 slots * 4096)
EDBUF       equ 0x280000            ; editor / script buffer
TBUF        equ 0x290000            ; terminal screen buffer
MISC        equ 0x2A0000
CMDBUF      equ MISC                ; terminal command line
PATHB       equ MISC+0x100          ; path scratch
NAMEB       equ MISC+0x200          ; file-name prompt buffer
TMPB        equ MISC+0x300          ; text scratch (0x300 bytes)
CLKB        equ MISC+0x600          ; clock text
ITEMS       equ MISC+0x800          ; list of slot pointers
SBBUF       equ MISC+0x1000         ; superblock sector
PWA         equ MISC+0x900
PWB         equ MISC+0x940
PWC         equ MISC+0x980
MTCOL       equ MISC+0xA00
STARB       equ MISC+0xA80
PARB        equ MISC+0xC00
SCUT        equ MISC+0xD00
SURFS       equ 0x3A0000
TPL_WIN     equ 0x3B0000
WALL        equ 0x1000000
BASE        equ 0x1900000
BACK        equ 0x2200000
M_DOCK      equ 0x2B00000
M_TOP       equ 0x2B80000
M_CARD      equ 0x2C00000
M_WIN       equ 0x2D00000
MAXF        equ 32
SLOT        equ 16384
MAXSZ       equ 16320

SW          equ 1024
SH          equ 768
TOPH        equ 32
WX          equ 112
WY          equ 56
WW          equ 800
WH          equ 640
HDRH        equ 40
STH         equ 28
GX          equ WX+8
GY          equ WY+HDRH+8
COLS        equ 98
ROWS        equ 34

C_TOP       equ 0x0B0B0B
%define C_ACC [th_acc]
%macro ACCSET 1
    push rax
    mov eax, [th_acc]
    mov [%1], eax
    pop rax
%endmacro
%define C_WIN  [th_win]
%define C_HDR  [th_hdr]
%define C_BRD  [th_brd]
%define C_TXT  [th_txt]
%define C_STAT [th_stat]
%define C_DIM  [th_dim]
%define C_CARD [th_card]
%macro SETC 2
    push rax
    mov eax, %2
    mov [%1], eax
    pop rax
%endmacro
SB_THEME    equ SBBUF+8
SB_USER     equ SBBUF+16
SB_HASH     equ SBBUF+48
SYS_KB      equ 0x5300000/1024
CARDX       equ 332
CARDY       equ 230
CARDW       equ 360
CARDH       equ 260

K_UP        equ 0xE0
K_DN        equ 0xE1
K_LF        equ 0xE2
K_RT        equ 0xE3
K_DEL       equ 0xE4
K_HOME      equ 0xE5
K_END       equ 0xE6
K_PGUP      equ 0xE7
K_PGDN      equ 0xE8
SB_WALL     equ SBBUF+0x60
SB_LAY2     equ SBBUF+0x64
SB_RESW     equ SBBUF+0x68
SB_RESH     equ SBBUF+0x6C
SB_LOGO     equ SBBUF+0x70
SB_ICST     equ SBBUF+0x71
SB_ACC      equ SBBUF+0x72
SB_DSZ      equ SBBUF+0x73
SB_CLK12    equ SBBUF+0x74
SB_BARST    equ SBBUF+0x75

; =============================================================================
;  STAGE 1  -  boot sector (16-bit)
; =============================================================================
[bits 16]
[org 0x7C00]

boot:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [bootdrv], dl
    mov si, KSECT
    mov dword [dap_lba], 1
    mov word [dap_seg], 0x07E0
    mov word [dap_off], 0
.rd:
    mov ax, si
    cmp ax, 32
    jbe .go
    mov ax, 32
.go:
    cmp word [dap_seg], 0x07E0
    jne .nf
    mov ax, 1
.nf:
    mov [dap_cnt], ax
    push ax
    push si
    mov si, dap
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
    pop si
    pop ax
    jc .fail
    sub si, ax
    movzx eax, ax
    add [dap_lba], eax
    shl ax, 5
    add [dap_seg], ax
    test si, si
    jnz .rd
    jmp 0x0000:stage2
.fail:
    mov ax, 0x0E45
    xor bx, bx
    int 0x10
    jmp $

bootdrv db 0
align 4
dap:     db 0x10, 0
dap_cnt: dw 0
dap_off: dw 0
dap_seg: dw 0
dap_lba: dq 0

times 510-($-$$) db 0
dw 0xAA55

; =============================================================================
;  STAGE 2  -  real mode part (variables must stay below 0x10000)
; =============================================================================
bi_fb:    dd 0
bi_pitch: dd 0
bi_mem:   dd 0
bi_w:     dd 1024
bi_h:     dd 768
vbe_tab:  dw 0x144, 0x118, 0
want_w:   dd 1024
want_h:   dd 768
lst_seg:  dw 0
lst_off:  dw 0
curmode:  dw 0
bi_fsok:  dd 0
fp_lba:   dd 0
fp_dst:   dd 0
modeinfo: times 256 db 0

stage2:
    xor ax, ax
    mov ds, ax
    mov es, ax
    ; total RAM in KB (INT 15h E801)
    mov ax, 0xE801
    int 0x15
    jc .nomem
    movzx eax, ax
    movzx ebx, bx
    shl ebx, 6
    add eax, ebx
    add eax, 1024
    mov [bi_mem], eax
.nomem:
    xor ax, ax
    mov ds, ax
    mov es, ax
    ; copy the filesystem into RAM through the BIOS (works on AHCI, USB and IDE alike)
    call fs_preload
    xor ax, ax
    mov ds, ax
    mov es, ax
    ; requested resolution: read the superblock sector, fall back to 1024x768
    mov dword [dap_lba], FS_LBA
    mov word [dap_cnt], 1
    mov word [dap_off], SBS
    mov word [dap_seg], 0
    mov si, dap
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
    jc .nosb
    cmp dword [SBS], 'CNT2'
    jne .nosb
    mov eax, [SBS+0x68]
    mov edx, [SBS+0x6C]
    cmp eax, 640
    jb .nosb
    cmp eax, 4096
    ja .nosb
    cmp edx, 480
    jb .nosb
    cmp edx, 2400
    ja .nosb
    mov [want_w], eax
    mov [want_h], edx
.nosb:
    xor ax, ax
    mov es, ax
    mov dword [VBEI], 'VBE2'
    mov di, VBEI
    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F
    jne .nolist
    mov ax, [VBEI+0x10]
    mov [lst_seg], ax
    mov ax, [VBEI+0x0E]
    mov [lst_off], ax
    call scan
    jnc .found
    cmp dword [want_w], 1024
    jne .t1024
    cmp dword [want_h], 768
    je .nolist
.t1024:
    mov dword [want_w], 1024
    mov dword [want_h], 768
    call scan
    jnc .found
.nolist:
    mov dword [want_w], 1024
    mov dword [want_h], 768
    mov word [lst_seg], 0
    mov word [lst_off], vbe_tab
    call scan
    jnc .found
    jmp vbe_fail
.found:
    mov eax, [modeinfo+0x28]
    mov [bi_fb], eax
    movzx eax, word [modeinfo+0x10]
    mov [bi_pitch], eax
    movzx eax, word [modeinfo+0x12]
    mov [bi_w], eax
    movzx eax, word [modeinfo+0x14]
    mov [bi_h], eax
    mov bx, [curmode]
    or bx, 0x4000
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    jne vbe_fail
    ; A20, GDT, protected mode
    in al, 0x92
    or al, 2
    out 0x92, al
    cli
    lgdt [gdtr]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x08:pm32

; fs_preload: superblock -> 0x1FF000, slots -> FSBUF (0x200000), bi_fsok = 1 when everything was read
fs_preload:
    mov dword [bi_fsok], 0
    mov dword [dap_lba], FS_LBA
    mov word [dap_cnt], 1
    mov word [dap_off], 0
    mov word [dap_seg], 0x6000
    mov si, dap
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
    jc .fail
    mov dword [fp_dst], 0x1FF000
    mov cx, 256
    call ext_copy
    jc .fail
    mov dword [fp_lba], FS_LBA+1
    mov dword [fp_dst], 0x200000
    mov bp, 16
.l: mov eax, [fp_lba]
    mov [dap_lba], eax
    mov word [dap_cnt], 64
    mov word [dap_off], 0
    mov word [dap_seg], 0x6000
    mov si, dap
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
    jc .fail
    mov cx, 16384
    call ext_copy
    jc .fail
    add dword [fp_lba], 64
    add dword [fp_dst], 0x8000
    dec bp
    jnz .l
    mov dword [bi_fsok], 1
.fail:
    ret

; ext_copy: copy cx words from 0x60000 to [fp_dst] with INT 15h AH=87h
ext_copy:
    mov eax, [fp_dst]
    mov [x_dl], ax
    shr eax, 16
    mov [x_dm], al
    mov [x_dh], ah
    xor ax, ax
    mov es, ax
    mov si, x_tab
    mov ah, 0x87
    int 0x15
    ret

align 4
x_tab:   dq 0
         dq 0
         db 0xFF, 0xFF, 0x00, 0x00, 0x06, 0x93, 0x00, 0x00
         dw 0xFFFF
x_dl:    dw 0
x_dm:    db 0
         db 0x93, 0x00
x_dh:    db 0
         dq 0
         dq 0

; walk the VBE mode list at lst_seg:lst_off for a linear 32bpp want_w x want_h mode
scan:
    mov ax, [lst_seg]
    mov fs, ax
    mov si, [lst_off]
.l: mov cx, [fs:si]
    add si, 2
    cmp cx, 0xFFFF
    je .no
    test cx, cx
    jz .no
    push si
    push cx
    mov ax, 0x4F01
    mov di, modeinfo
    int 0x10
    pop cx
    pop si
    cmp ax, 0x004F
    jne .l
    mov ax, [modeinfo]
    and ax, 0x91
    cmp ax, 0x91
    jne .l
    cmp byte [modeinfo+0x19], 32
    jne .l
    movzx eax, word [modeinfo+0x12]
    cmp eax, [want_w]
    jne .l
    movzx eax, word [modeinfo+0x14]
    cmp eax, [want_h]
    jne .l
    mov [curmode], cx
    clc
    ret
.no:
    stc
    ret

vbe_fail:
    mov ax, 0x0E56
    xor bx, bx
    int 0x10
    jmp $

align 8
gdt:
    dq 0
    dq 0x00CF9A000000FFFF           ; 0x08 code32
    dq 0x00CF92000000FFFF           ; 0x10 data
    dq 0x00AF9A000000FFFF           ; 0x18 code64
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt

; =============================================================================
;  protected mode -> long mode
; =============================================================================
[bits 32]
pm32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000
    ; page tables at 0x100000 (6 pages): identity map 4 GB with 2 MB pages
    mov edi, 0x100000
    xor eax, eax
    mov ecx, 0x6000 / 4
    rep stosd
    mov dword [0x100000], 0x101003
    mov dword [0x101000], 0x102003
    mov dword [0x101008], 0x103003
    mov dword [0x101010], 0x104003
    mov dword [0x101018], 0x105003
    mov edi, 0x102000
    mov eax, 0x83
    mov ecx, 2048
.pd:
    mov [edi], eax
    mov dword [edi+4], 0
    add eax, 0x200000
    add edi, 8
    loop .pd
    ; the linear framebuffer must not sit in the CPU cache: write-combining through the PAT
    ; when the CPU has one (PAT entry 1 := WC, pages marked PWT only), else plain uncached
    mov esi, 0x18
    mov eax, 1
    cpuid
    test edx, 1 << 16
    jz .nopat
    mov ecx, 0x277
    rdmsr
    and eax, 0xFFFF00FF
    or eax, 0x00000100              ; PA1 = 01 (WC)
    wrmsr
    mov esi, 0x08
.nopat:
    mov eax, [bi_fb]
    mov ebx, eax
    shr eax, 21
    mov ecx, [bi_pitch]
    imul ecx, [bi_h]
    lea ebx, [ebx+ecx-1]
    shr ebx, 21
.uc:
    or dword [0x102000+eax*8], esi
    inc eax
    cmp eax, ebx
    jbe .uc
    mov eax, cr4
    or eax, 0x620               ; PAE + OSFXSR + OSXMMEXCPT (SSE)
    mov cr4, eax
    mov eax, 0x100000
    mov cr3, eax
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x100
    wrmsr
    mov eax, cr0
    and eax, 0xFFFFFFFB         ; EM = 0
    or eax, 0x80000002          ; PG + MP
    mov cr0, eax
    jmp 0x18:lm64

; =============================================================================
;  64-bit kernel
; =============================================================================
[bits 64]
default abs
lm64:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, 0x90000
    cld
    jmp kmain

; ---------------------------------------------------------------- strings ----
strlen:                             ; rsi -> eax
    xor eax, eax
.l: cmp byte [rsi+rax], 0
    je .d
    inc eax
    jmp .l
.d: ret

strcmp:                             ; rsi,rdi -> ZF=1 if equal
    push rsi
    push rdi
.l: mov al, [rsi]
    cmp al, [rdi]
    jne .x
    test al, al
    jz .x
    inc rsi
    inc rdi
    jmp .l
.x: pop rdi
    pop rsi
    ret

strcpy:                             ; rsi -> rdi (clobbers al)
    push rsi
    push rdi
.l: lodsb
    stosb
    test al, al
    jnz .l
    pop rdi
    pop rsi
    ret

sappend:                            ; append rsi to rdi, rdi -> final NUL
.l: lodsb
    test al, al
    jz .d
    stosb
    jmp .l
.d: mov [rdi], al
    ret

u2s:                                ; eax=number, rdi=dest -> rdi at NUL
    push rbx
    push rcx
    push rdx
    xor ecx, ecx
    mov ebx, 10
.l: xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .l
.o: pop rdx
    mov [rdi], dl
    inc rdi
    dec ecx
    jnz .o
    mov byte [rdi], 0
    pop rdx
    pop rcx
    pop rbx
    ret

skipsp:                             ; skip blanks at rsi
.l: mov al, [rsi]
    cmp al, ' '
    je .s
    cmp al, 9
    je .s
    cmp al, 13
    je .s
    ret
.s: inc rsi
    jmp .l

is_xep:                             ; rsi=name -> eax=1 if ends with .xep
    push rsi
    push rcx
    call strlen
    xor ecx, ecx
    cmp eax, 4
    jb .no
    cmp dword [rsi+rax-4], 0x7065782E
    jne .no
    mov ecx, 1
.no:
    mov eax, ecx
    pop rcx
    pop rsi
    ret

ensure_ext:                         ; rsi=path: add .txt when no dot
    push rsi
    push rax
.l: mov al, [rsi]
    test al, al
    jz .no
    cmp al, '.'
    je .has
    inc rsi
    jmp .l
.no:
    mov dword [rsi], 0x7478742E
    mov byte [rsi+4], 0
.has:
    pop rax
    pop rsi
    ret

; ------------------------------------------------------------------- ATA -----
ata_read1:                          ; eax=LBA rdi=dest (advances) ; keeps eax
    cmp byte [ata_ok], 0
    je .skip
    push rax
    push rbx
    push rcx
    push rdx
    mov ebx, eax
    mov dx, 0x1F6
    shr eax, 24
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al
    mov dx, 0x1F4
    mov al, bh
    out dx, al
    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
    mov ebx, 0x800000
.w: dec ebx
    jz .to
    in al, dx
    test al, 0x80
    jnz .w
    test al, 1
    jnz .d
    test al, 8
    jz .w
    mov dx, 0x1F0
    mov ecx, 256
    rep insw
    jmp .d
.to: mov byte [ata_ok], 0
.d: pop rdx
    pop rcx
    pop rbx
    pop rax
.skip:
    ret

ata_write1:                         ; eax=LBA rsi=src (advances) ; keeps eax
    cmp byte [ata_ok], 0
    je .skip
    push rax
    push rbx
    push rcx
    push rdx
    mov ebx, eax
    mov dx, 0x1F6
    shr eax, 24
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al
    mov dx, 0x1F4
    mov al, bh
    out dx, al
    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30
    out dx, al
    mov ebx, 0x800000
.w: dec ebx
    jz .to
    in al, dx
    test al, 0x80
    jnz .w
    test al, 1
    jnz .d
    test al, 8
    jz .w
    mov dx, 0x1F0
    mov ecx, 256
    rep outsw
    mov dx, 0x1F7
    mov al, 0xE7
    out dx, al
    mov ebx, 0x800000
.f: dec ebx
    jz .to
    in al, dx
    test al, 0x80
    jnz .f
    jmp .d
.to: mov byte [ata_ok], 0
.d: pop rdx
    pop rcx
    pop rbx
    pop rax
.skip:
    ret

; ata_probe: with a BIOS-preloaded filesystem, check that the ATA ports lead to the disk we booted from
ata_probe:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    cmp dword [bi_fsok], 0
    je .o                           ; old path: trust the ports
    mov dx, 0x1F6
    mov al, 0xE0
    out dx, al
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .no
    test al, al
    jz .no
    mov rdi, TMPB
    xor eax, eax
    call ata_read1
    cmp byte [ata_ok], 0
    je .o
    mov rsi, TMPB
    mov rdi, 0x7C00
    mov ecx, 16
    repe cmpsd
    je .o
.no:
    mov byte [ata_ok], 0
.o: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------- filesystem ----
; slot (4096 bytes): +0 path (47 chars + NUL) | +48 size dword | +64 data
path_ok:                            ; rsi=path -> ZF=1 if valid
    push rax
    push rbx
    push rcx
    push rdx
    xor ebx, ebx
.d: mov eax, ebx
    shl eax, 3
    lea rdx, [dirpfx+rax]
    xor ecx, ecx
.c: mov al, [rdx+rcx]
    cmp al, [rsi+rcx]
    jne .n
    inc ecx
    cmp ecx, 6
    jb .c
    call strlen
    cmp eax, 46
    ja .bad
    cmp eax, 7
    jb .bad
    xor eax, eax
    jmp .x
.n: inc ebx
    cmp ebx, 3
    jb .d
.bad:
    mov eax, 1
    test eax, eax
.x: pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

fs_find:                            ; rsi=path -> rax=slot or 0
    push rdi
    push rcx
    mov rdi, FSBUF
    mov ecx, MAXF
.l: cmp byte [rdi], 0
    je .n
    call strcmp
    je .f
.n: add rdi, SLOT
    dec ecx
    jnz .l
    xor eax, eax
    jmp .o
.f: mov rax, rdi
.o: pop rcx
    pop rdi
    ret

parent_ok:                          ; rsi=path -> ZF=1 if parent folder exists
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    xor edx, edx
    xor ecx, ecx
.l: mov al, [rsi+rcx]
    test al, al
    jz .e
    cmp al, '/'
    jne .n
    cmp byte [rsi+rcx+1], 0
    je .n
    mov edx, ecx
.n: inc ecx
    jmp .l
.e: cmp edx, 5
    jbe .ok
    lea ecx, [rdx+1]
    mov rdi, PARB
    rep movsb
    mov byte [rdi], 0
    mov rsi, PARB
    call fs_find
    test rax, rax
    jz .bad
.ok:
    xor eax, eax
    jmp .o
.bad:
    mov eax, 1
    test eax, eax
.o: pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

fs_create:                          ; rsi=path -> rax=slot (existing or new) or 0
    push rcx
    push rdi
    call path_ok
    jne .fail
    call parent_ok
    jne .fail
    call fs_find
    test rax, rax
    jnz .out
    mov rdi, FSBUF
    mov ecx, MAXF
.s: cmp byte [rdi], 0
    je .got
    add rdi, SLOT
    dec ecx
    jnz .s
.fail:
    xor eax, eax
    jmp .out
.got:
    call strcpy
    mov dword [rdi+48], 0
    mov rax, rdi
.out:
    pop rdi
    pop rcx
    ret

fs_save:                            ; rax=slot ; keeps rax
    push rax
    push rcx
    push rsi
    mov rsi, rax
    sub rax, FSBUF
    shr rax, 14
    shl rax, 5
    add rax, FS_LBA+1
    mov ecx, 32
.l: call ata_write1
    inc eax
    dec ecx
    jnz .l
    pop rsi
    pop rcx
    pop rax
    ret

fs_move:                            ; rax=slot rsi=new path
    push rbx
    push rdi
    push rsi
    push rcx
    mov rbx, rax
    call fs_find
    test rax, rax
    jz .nd
    cmp rax, rbx
    je .nd
    mov byte [rax], 0
    call fs_save
.nd:
    mov rdi, rbx
    call strcpy
    mov rax, rbx
    call fs_save
    pop rcx
    pop rsi
    pop rdi
    pop rbx
    ret

fs_mk:                              ; rsi=path rdx=content(zstr) -> rax=slot
    push rbx
    push rcx
    push rdi
    push rsi
    call fs_create
    test rax, rax
    jz .out
    mov rbx, rax
    lea rdi, [rbx+64]
    mov rsi, rdx
    xor ecx, ecx
.c: mov al, [rsi]
    test al, al
    jz .z
    mov [rdi], al
    inc rsi
    inc rdi
    inc ecx
    jmp .c
.z: mov [rbx+48], ecx
    mov rax, rbx
.out:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

mkpath:                             ; ecx=dir(0..2) rsi=name -> rsi=PATHB
    push rax
    push rdx
    push rdi
    mov eax, ecx
    shl eax, 3
    lea rdx, [dirpfx+rax]
    mov rdi, PATHB
.p: mov al, [rdx]
    test al, al
    jz .n
    mov [rdi], al
    inc rdx
    inc rdi
    jmp .p
.n: mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .n
    pop rdi
    pop rdx
    pop rax
    mov rsi, PATHB
    ret

collect:                            ; lists curdir -> f_cnt, ITEMS
    push rax
    push rbx
    push rcx
    push rsi    push rdi
    mov dword [f_cnt], 0
    cmp dword [cd_len], 1
    jne .d
    mov dword [f_cnt], 3
    jmp .out
.d: mov rbx, FSBUF
    mov ecx, MAXF
    mov rdi, ITEMS
.l: cmp byte [rbx], 0
    je .n
    xor eax, eax
.c: cmp eax, [cd_len]
    jae .pre
    mov dl, [curdir+rax]
    cmp dl, [rbx+rax]
    jne .n
    inc eax
    jmp .c
.pre:
    lea rsi, [rbx+rax]
    cmp byte [rsi], 0
    je .n
.s: mov al, [rsi]
    inc rsi
    test al, al
    jz .add
    cmp al, '/'
    jne .s
    cmp byte [rsi], 0
    jne .n
.add:
    mov [rdi], rbx
    add rdi, 8
    inc dword [f_cnt]
.n: add rbx, SLOT
    dec ecx
    jnz .l
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

set_curdir:                         ; rsi=zstr dir path (with trailing /)
    push rax
    push rdi
    lea rdi, [curdir]
    call strcpy
    mov rsi, rdi
    call strlen
    mov [cd_len], eax
    pop rdi
    pop rax
    ret

upd_fdir:                           ; derive f_dir from curdir
    push rax
    mov eax, 3
    cmp dword [cd_len], 1
    je .s
    xor eax, eax
    cmp dword [curdir], 0x7361622F
    je .s
    mov eax, 1
    cmp dword [curdir], 0x6D75642F
    je .s
    mov eax, 2
.s: mov [f_dir], eax
    pop rax
    ret

dir_up:                             ; curdir -> parent
    push rax
    mov eax, [cd_len]
    cmp eax, 1
    jbe .o
    dec eax
.l: dec eax
    cmp byte [curdir+rax], '/'
    jne .l
    mov byte [curdir+rax+1], 0
    inc eax
    mov [cd_len], eax
.o: pop rax
    ret

basename:                           ; rsi=path -> rsi=last component (trailing / stripped by caller)
    push rax
    push rcx
    mov rcx, rsi
.l: mov al, [rcx]
    test al, al
    jz .d
    inc rcx
    cmp al, '/'
    jne .l
    cmp byte [rcx], 0
    je .l
    mov rsi, rcx
    jmp .l
.d: pop rcx
    pop rax
    ret

mkpath_cur:                         ; rsi=name -> rsi=PATHB (curdir, or /home/ when in dump or root)
    push rax
    push rdi
    push rsi
    mov rdi, PATHB
    cmp dword [cd_len], 1
    je .h
    cmp dword [curdir], 0x6D75642F
    je .h
    lea rsi, [curdir]
    jmp .c
.h: lea rsi, [dirpfx+16]
.c: call sappend
    pop rsi
    call sappend
    pop rdi
    pop rax
    mov rsi, PATHB
    ret

folder_empty:                       ; rax=folder slot -> ZF=1 if no children
    push r8
    push r9
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov r9, rax
    mov rsi, rax
    call strlen
    mov edx, eax
    mov rbx, FSBUF
    mov ecx, MAXF
.l: cmp byte [rbx], 0
    je .n
    cmp rbx, r9
    je .n
    xor edi, edi
.c: cmp edi, edx
    jae .full
    mov r8b, [r9+rdi]
    cmp r8b, [rbx+rdi]
    jne .n
    inc edi
    jmp .c
.full:
    mov eax, 1
    test eax, eax
    jmp .o
.n: add rbx, SLOT
    dec ecx
    jnz .l
    xor eax, eax
.o: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r9
    pop r8
    ret

fs_init:
    call ata_probe
    cmp dword [bi_fsok], 0
    je .atapath
    mov rsi, 0x1FF000               ; the BIOS already copied the disk contents to RAM
    mov rdi, SBBUF
    mov ecx, 128
    rep movsd
    cmp dword [SBBUF], 0x32544E43
    jne .format
    ret
.atapath:
    mov rdi, SBBUF
    mov eax, FS_LBA
    call ata_read1
    cmp dword [SBBUF], 0x32544E43       ; 'CNT2'
    jne .format
    mov rdi, FSBUF
    mov eax, FS_LBA+1
    mov ecx, MAXF*32
.ld:
    call ata_read1
    inc eax
    dec ecx
    jnz .ld
    ret
.format:
    mov rdi, FSBUF
    xor eax, eax
    mov ecx, (MAXF*SLOT)/8
    rep stosq
    lea rsi, [p_readme]
    lea rdx, [d_readme]
    call fs_mk
    lea rsi, [p_sys]
    lea rdx, [d_sys]
    call fs_mk
    lea rsi, [p_rainbow]
    lea rdx, [d_rainbow]
    call fs_mk
    lea rsi, [p_hello]
    lea rdx, [d_hello]
    call fs_mk
    lea rsi, [p_notes]
    lea rdx, [d_notes]
    call fs_mk
    ; write all slots
    mov rax, FSBUF
    mov ecx, MAXF
.sv:
    call fs_save
    add rax, SLOT
    dec ecx
    jnz .sv
    ; superblock
    mov rdi, SBBUF
    xor eax, eax
    mov ecx, 64
    rep stosq
    mov dword [SBBUF], 0x32544E43
    mov rsi, SBBUF
    mov eax, FS_LBA
    call ata_write1
    ret

; ---------------------------------------------------------------- graphics ---
; ---- begin gfx_core.inc
; =============================================================================
;  GRAPHICS CORE: surfaces as drawing targets, alpha blending, AA text
;  Pixel format 0xTTRRGGBB, TT = transparency (0 = opaque, 255 = invisible)
; =============================================================================
SF_PTR   equ 0
SF_W     equ 8
SF_H     equ 12
SF_VX    equ 16
SF_VY    equ 20
SF_SX    equ 24
SF_SY    equ 28
SF_FLG   equ 32
SF_SX0   equ 36
SF_SY0   equ 40
SF_SX1   equ 44
SF_SY1   equ 48
SF_TASK  equ 52
SF_TITLE equ 56
SF_DX0   equ 64
SF_DY0   equ 68
SF_DX1   equ 72
SF_DY1   equ 76
SF_BX    equ 80                     ; window box (virtual) x,y,w,h for hit tests
SF_BY    equ 84
SF_BW    equ 88
SF_BH    equ 92
SF_FOC   equ 96                     ; focused flag (title bar look)
SURF_SZ  equ 128

SFF_VIS  equ 1
SFF_DIRTY equ 2
SFF_SAFE equ 4
SFF_OPQ  equ 8
SFF_WIN  equ 16


; ---- select drawing target: esi = surface index
gfx_target:
    push rax
    push rcx
    push rdx
    push r8
    mov [cur_surf], esi
    mov eax, esi
    shl eax, 7
    add rax, SURFS
    mov [cur_sptr], rax
    mov r8, rax
    mov edx, [r8+SF_W]
    shl edx, 2
    mov [cur_pitch], edx
    mov rax, [r8+SF_PTR]
    mov ecx, [r8+SF_VY]
    imul rcx, rdx
    sub rax, rcx
    mov ecx, [r8+SF_VX]
    shl rcx, 2
    sub rax, rcx
    mov [cur_fb], rax
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ---- ebx=x ecx=y esi=w edx=h : grow the dirty box of the current surface
mark_dirty:
    push rax
    push r8
    mov r8, [cur_sptr]
    mov eax, ebx
    cmp eax, [r8+SF_DX0]
    jge .a
    mov [r8+SF_DX0], eax
.a: mov eax, ecx
    cmp eax, [r8+SF_DY0]
    jge .b
    mov [r8+SF_DY0], eax
.b: lea eax, [rbx+rsi]
    cmp eax, [r8+SF_DX1]
    jle .c
    mov [r8+SF_DX1], eax
.c: lea eax, [rcx+rdx]
    cmp eax, [r8+SF_DY1]
    jle .d
    mov [r8+SF_DY1], eax
.d: or dword [r8+SF_FLG], SFF_DIRTY
    pop r8
    pop rax
    ret

rect:                               ; ebx=x ecx=y esi=w edx=h eax=color
    test esi, esi
    jle .z
    test edx, edx
    jle .z
    call mark_dirty
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    mov r8d, eax
    mov eax, [cur_pitch]
    mov ecx, ecx
    imul rcx, rax
    mov ebx, ebx
    lea rdi, [rcx+rbx*4]
    add rdi, [cur_fb]
    mov eax, r8d
    mov ebx, [cur_pitch]
.row:
    push rdi
    mov ecx, esi
    rep stosd
    pop rdi
    add rdi, rbx
    dec edx
    jnz .row
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.z: ret

; ---- blend r10d (fg) over r13d (bg) with a = edx (0..15)  -> eax
blend15:
    mov esi, 15
    sub esi, edx
    mov eax, r10d
    and eax, 0xFF00FF
    imul eax, edx
    mov ecx, r13d
    and ecx, 0xFF00FF
    imul ecx, esi
    add eax, ecx
    imul eax, 17
    shr eax, 8
    and eax, 0xFF00FF
    mov ecx, r13d
    shr ecx, 8
    and ecx, 0xFF
    imul ecx, esi
    mov esi, r10d
    shr esi, 8
    and esi, 0xFF
    imul esi, edx
    add ecx, esi
    imul ecx, 17
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or eax, ecx
    ret

; ---- blend r10d (src) over r13d (dst) with a = edx (0..255) -> eax
blend255:
    mov esi, 255
    sub esi, edx
    mov eax, r10d
    and eax, 0xFF00FF
    imul eax, edx
    mov ecx, r13d
    and ecx, 0xFF00FF
    imul ecx, esi
    add eax, ecx
    add eax, 0x800080
    mov ecx, eax
    shr ecx, 8
    and ecx, 0xFF00FF
    add eax, ecx
    shr eax, 8
    and eax, 0xFF00FF
    mov ecx, r13d
    shr ecx, 8
    and ecx, 0xFF
    imul ecx, esi
    mov esi, r10d
    shr esi, 8
    and esi, 0xFF
    imul esi, edx
    add ecx, esi
    add ecx, 128
    mov esi, ecx
    shr esi, 8
    add ecx, esi
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or eax, ecx
    ret

; ---- plot color r10d with alpha edx (1..255) at r15 over whatever is there
;      clobbers eax ecx esi r13d ; keeps edx
plot_a:
    mov r13d, [r15]
    test r13d, 0xFF000000
    jnz px_over
    cmp edx, 255
    jne .b
    mov eax, r10d
    and eax, 0xFFFFFF
    mov [r15], eax
    ret
.b: call blend255
    mov [r15], eax
    ret

; general "over" for destinations that are themselves translucent (r13d = dst)
px_over:
    push rbx
    push rdx
    push rdi
    push r12
    push r14
    mov eax, r13d
    shr eax, 24                      ; Td
    cmp eax, 255
    jne .part
    mov eax, r10d
    and eax, 0xFFFFFF
    mov ecx, 255
    sub ecx, edx
    shl ecx, 24
    or eax, ecx
    mov [r15], eax
    jmp .out
.part:
    mov ebx, 255
    sub ebx, eax                     ; ad
    mov esi, 255
    sub esi, edx                     ; 255-a
    imul ebx, esi
    add ebx, 128
    mov ecx, ebx
    shr ecx, 8
    add ebx, ecx
    shr ebx, 8                       ; w2 = dst weight
    lea r14d, [rdx+rbx]              ; a_out
    xor edi, edi                     ; result rgb
    xor r12d, r12d                   ; shift
.ch:
    mov eax, r10d
    mov ecx, r12d
    shr eax, cl
    and eax, 0xFF
    imul eax, edx
    mov esi, r13d
    shr esi, cl
    and esi, 0xFF
    imul esi, ebx
    add eax, esi
    push rdx
    xor edx, edx
    div r14d
    pop rdx
    cmp eax, 255
    jbe .ok
    mov eax, 255
.ok:
    mov ecx, r12d
    shl eax, cl
    or edi, eax
    add r12d, 8
    cmp r12d, 24
    jb .ch
    mov eax, 255
    sub eax, r14d
    cmp eax, 0
    jge .ta
    xor eax, eax
.ta:
    shl eax, 24
    or edi, eax
    mov [r15], edi
.out:
    pop r14
    pop r12
    pop rdi
    pop rdx
    pop rbx
    ret

; ---- mono AA glyph: al=char ebx=x ecx=y (g_fg, g_bg, g_tr)
glyph:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    movzx eax, al
    shl eax, 6
    lea r8, [font_mono+rax]
    push rsi
    push rdx
    mov esi, 8
    mov edx, 16
    call mark_dirty
    pop rdx
    pop rsi
    mov r9d, [cur_pitch]
    mov eax, ecx
    imul rax, r9
    mov ecx, ebx
    lea rdi, [rax+rcx*4]
    add rdi, [cur_fb]
    mov r10d, [g_fg]
    mov r11d, [g_bg]
    movzx r14d, byte [g_tr]
    mov r12d, 16
.row:
    mov r15, rdi
    mov ecx, 4
.by:
    movzx eax, byte [r8]
    inc r8
    push rax
    shr eax, 4
    mov edx, eax
    call gl_px
    add r15, 4
    pop rax
    and eax, 15
    mov edx, eax
    call gl_px
    add r15, 4
    dec ecx
    jnz .by
    add rdi, r9
    dec r12d
    jnz .row
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

gl_px:                              ; edx=a(0..15) r15=dest r10=fg r11=bg r14=tr ; keeps ecx? no: uses eax esi r13
    test edx, edx
    jnz .nz
    test r14d, r14d
    jnz .r
    mov [r15], r11d
.r: ret
.nz:
    cmp edx, 15
    jne .p
    mov [r15], r10d
    ret
.p: test r14d, r14d
    jnz .tr
    mov r13d, r11d
    push rcx
    call blend15
    pop rcx
    mov [r15], eax
    ret
.tr:
    imul edx, edx, 17
    push rcx
    call plot_a
    pop rcx
    ret

text:                               ; rsi=zstr ebx=x ecx=y (mono)
    push rax
    push rbx
    push rsi
.l: lodsb
    test al, al
    jz .d
    call glyph
    add ebx, 8
    jmp .l
.d: pop rsi
    pop rbx
    pop rax
    ret

text_center:                        ; rsi=zstr ecx=y (centered on screen width of 1024 virtual)
    push rax
    push rbx
    call strlen
    shl eax, 2
    mov ebx, 512
    sub ebx, eax
    call text
    pop rbx
    pop rax
    ret

; ---- proportional AA text (g_uf font, g_fg color, blends over destination)
ui_text:                            ; rsi=zstr ebx=x ecx=y(top)
    push rbp
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8, [g_uf]
    mov r10d, [g_fg]
    mov r9d, [r8]                    ; H
    mov r11d, ebx                    ; pen x
    mov r12d, ecx                    ; y
.ch:
    lodsb
    test al, al
    jz .done
    movzx eax, al
    mov edx, [r8+8+rax*4]
    mov r14d, edx
    shr r14d, 24                     ; width
    and edx, 0xFFFFFF
    test r14d, r14d
    jz .ch
    lea rdi, [r8+rdx]                ; bitmap
    push rsi
    mov ebx, r11d
    mov ecx, r12d
    mov esi, r14d
    mov edx, r9d
    call mark_dirty
    pop rsi
    mov eax, r12d
    imul rax, [cur_pitch]
    mov ecx, r11d
    lea rbp, [rax+rcx*4]
    add rbp, [cur_fb]                ; dest row ptr
    xor ebx, ebx                     ; row
.rw:
    xor ecx, ecx                     ; col
    mov rax, rbp
.cl:
    mov edx, ecx
    shr edx, 1
    movzx edx, byte [rdi+rdx]
    test ecx, 1
    jnz .lo
    shr edx, 4
    jmp .gt
.lo:
    and edx, 15
.gt:
    test edx, edx
    jz .nx
    push rax
    push rcx
    push rsi
    mov r15, rax
    imul edx, edx, 17
    call plot_a
    pop rsi
    pop rcx
    pop rax
.nx:
    add rax, 4
    inc ecx
    cmp ecx, r14d
    jb .cl
    mov eax, r14d
    inc eax
    shr eax, 1
    add rdi, rax
    mov eax, [cur_pitch]
    add rbp, rax
    inc ebx
    cmp ebx, r9d
    jb .rw
    add r11d, r14d
    ; r15 was advanced, recompute at next glyph (done at top)
    jmp .ch
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rbp
    ret

ui_width:                           ; rsi=zstr -> eax pixels
    push rbx
    push rcx
    push rsi
    mov rbx, [g_uf]
    xor ecx, ecx
.l: lodsb
    test al, al
    jz .d
    movzx eax, al
    mov eax, [rbx+8+rax*4]
    shr eax, 24
    add ecx, eax
    jmp .l
.d: mov eax, ecx
    pop rsi
    pop rcx
    pop rbx
    ret

ui_text_c:                          ; rsi=zstr ebx=center x ecx=y
    push rax
    push rbx
    call ui_width
    shr eax, 1
    sub ebx, eax
    call ui_text
    pop rbx
    pop rax
    ret

ui_text_r:                          ; rsi=zstr ebx=right x ecx=y
    push rax
    push rbx
    call ui_width
    sub ebx, eax
    call ui_text
    pop rbx
    pop rax
    ret

; ---- corner coverage: ecx=i edx=j r9d=R -> eax = 0..255 ; clobbers esi xmm0-3
ccov:
    mov eax, r9d
    sub eax, ecx
    add eax, eax
    dec eax
    imul eax, eax
    mov esi, r9d
    sub esi, edx
    add esi, esi
    dec esi
    imul esi, esi
    add eax, esi
    cvtsi2ss xmm0, eax
    sqrtss xmm0, xmm0
    lea eax, [r9*2+1]
    cvtsi2ss xmm1, eax
    subss xmm1, xmm0
    xorps xmm2, xmm2
    maxss xmm1, xmm2
    mov eax, 0x40000000
    movd xmm3, eax
    minss xmm1, xmm3
    mov eax, 0x42FF0000
    movd xmm3, eax
    mulss xmm1, xmm3
    cvtss2si eax, xmm1
    ret

; ---- rounded rectangle: ebx=x ecx=y esi=w edx=h eax=color r9d=radius
rrect:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r10d, eax                    ; color
    mov r12d, ebx                    ; x
    mov r14d, ecx                    ; y
    mov ebp, esi                     ; w
    mov edi, edx                     ; h
    ; body bands
    mov eax, r10d
    mov ebx, r12d
    lea ecx, [r14+r9]
    mov esi, ebp
    mov edx, edi
    sub edx, r9d
    sub edx, r9d
    call rect
    mov eax, r10d
    lea ebx, [r12+r9]
    mov ecx, r14d
    mov esi, ebp
    sub esi, r9d
    sub esi, r9d
    mov edx, r9d
    call rect
    mov eax, r10d
    lea ebx, [r12+r9]
    lea ecx, [r14+rdi]
    sub ecx, r9d
    mov esi, ebp
    sub esi, r9d
    sub esi, r9d
    mov edx, r9d
    call rect
    ; corners
    xor r11d, r11d                   ; j
.cj:
    xor r8d, r8d                     ; i
.ci:
    mov ecx, r8d
    mov edx, r11d
    call ccov
    test eax, eax
    jz .skip
    mov edx, eax
    lea ecx, [r14+r11]               ; TL
    lea ebx, [r12+r8]
    call .put
    lea ecx, [r14+r11]               ; TR
    lea ebx, [r12+rbp-1]
    sub ebx, r8d
    call .put
    lea ecx, [r14+rdi-1]             ; BL
    sub ecx, r11d
    lea ebx, [r12+r8]
    call .put
    lea ecx, [r14+rdi-1]             ; BR
    sub ecx, r11d
    lea ebx, [r12+rbp-1]
    sub ebx, r8d
    call .put
.skip:
    inc r8d
    cmp r8d, r9d
    jb .ci
    inc r11d
    cmp r11d, r9d
    jb .cj
    mov ebx, r12d
    mov ecx, r14d
    mov esi, ebp
    mov edx, edi
    call mark_dirty
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.put:
    push rdx
    call .put2
    pop rdx
    ret
.put2:                              ; ebx=x ecx=y edx=alpha ; color r10d (TT = its own transparency)
    cmp byte [rr_mode], 0
    jne .lerp
    mov eax, r10d
    shr eax, 24
    jz .full
    xor eax, 255
    imul edx, eax
    add edx, 128
    mov eax, edx
    shr eax, 8
    add edx, eax
    shr edx, 8
    jnz .full
    ret
.full:
    mov eax, ecx
    imul rax, [cur_pitch]
    mov ecx, ebx
    lea r15, [rax+rcx*4]
    add r15, [cur_fb]
    cmp edx, 255
    jb .pa
    mov eax, r10d
    and eax, 0xFFFFFF
    mov [r15], eax
    ret
.pa:
    call plot_a
    ret
.lerp:                              ; replace mode : pixel = lerp(old, colour, coverage), alpha included
    mov eax, ecx
    imul rax, [cur_pitch]
    mov ecx, ebx
    lea r15, [rax+rcx*4]
    add r15, [cur_fb]
    mov eax, [r15]
    mov ebx, r10d
    call lerp_px
    mov [r15], eax
    ret


; eax = old ARGB, ebx = new ARGB, edx = coverage 0..255 -> eax
lerp_px:
    push rcx
    push rsi
    push rdi
    push r8
    xor edi, edi
    xor ecx, ecx
.l: mov esi, eax
    shr esi, cl
    and esi, 255
    mov r8d, ebx
    shr r8d, cl
    and r8d, 255
    sub r8d, esi
    imul r8d, edx
    imul r8d, 257
    sar r8d, 16
    add esi, r8d
    jns .p
    xor esi, esi
.p: cmp esi, 255
    jbe .q
    mov esi, 255.q: shl esi, cl
    or edi, esi
    add ecx, 8
    cmp ecx, 32
    jb .l
    mov eax, edi
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

; ---- end gfx_core.inc
; ---- begin wm_core.inc
; =============================================================================
;  WINDOW SYSTEM CORE: surfaces, compositor, wallpapers, window chrome
; =============================================================================
SI_BASE  equ 1
SI_DOCK  equ 2
SI_TOP   equ 3
SI_CARD  equ 4
SI_WIN0  equ 5
NWIN     equ 8
SMX      equ 40
SMT      equ 24
SMB      equ 56
WINSW    equ WW+2*SMX
WINSH    equ WH+SMT+SMB
WRAD     equ 12


; ---- damage -----------------------------------------------------------------
damage:                             ; eax=x0 ebx=y0 ecx=x1 edx=y1 (screen)
    cmp byte [dm_pend], 0
    jne .u
    mov [dm_x0], eax
    mov [dm_y0], ebx
    mov [dm_x1], ecx
    mov [dm_y1], edx
    mov byte [dm_pend], 1
    ret
.u: cmp eax, [dm_x0]
    jge .a
    mov [dm_x0], eax
.a: cmp ebx, [dm_y0]
    jge .b
    mov [dm_y0], ebx
.b: cmp ecx, [dm_x1]
    jle .c
    mov [dm_x1], ecx
.c: cmp edx, [dm_y1]
    jle .d
    mov [dm_y1], edx
.d: ret

damage_all:
    push rax
    push rbx
    push rcx
    push rdx
    xor eax, eax
    xor ebx, ebx
    mov ecx, [scr_w]
    mov edx, [scr_h]
    call damage
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- gather dirty boxes of every surface into the damage rectangle ----------
gather_damage:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    xor esi, esi
.l: mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov eax, [r8+SF_FLG]
    test eax, SFF_DIRTY
    jz .n
    and eax, ~SFF_DIRTY
    mov [r8+SF_FLG], eax
    test eax, SFF_VIS
    jz .reset
    ; box in virtual coords -> screen
    mov eax, [r8+SF_DX0]
    mov ebx, [r8+SF_DY0]
    mov ecx, [r8+SF_DX1]
    mov edx, [r8+SF_DY1]
    cmp eax, ecx
    jge .reset
    ; clamp to surface bounds (virtual)
    push rsi
    mov esi, [r8+SF_VX]
    cmp eax, esi
    jge .c1
    mov eax, esi
.c1: add esi, [r8+SF_W]
    cmp ecx, esi
    jle .c2
    mov ecx, esi
.c2: mov esi, [r8+SF_VY]
    cmp ebx, esi
    jge .c3
    mov ebx, esi
.c3: add esi, [r8+SF_H]
    cmp edx, esi
    jle .c4
    mov edx, esi
.c4: pop rsi
    sub eax, [r8+SF_VX]
    add eax, [r8+SF_SX]
    sub ecx, [r8+SF_VX]
    add ecx, [r8+SF_SX]
    sub ebx, [r8+SF_VY]
    add ebx, [r8+SF_SY]
    sub edx, [r8+SF_VY]
    add edx, [r8+SF_SY]
    call damage
.reset:
    mov dword [r8+SF_DX0], 0x7FFFFFFF
    mov dword [r8+SF_DY0], 0x7FFFFFFF
    mov dword [r8+SF_DX1], 0x80000000
    mov dword [r8+SF_DY1], 0x80000000
.n: inc esi
    cmp esi, 16
    jb .l
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- blit surface esi into BACK for the region rg_* -------------------------
blit_surf:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov [bs_sf], r8
    test dword [r8+SF_FLG], SFF_VIS
    jz .out
    mov r9d, [r8+SF_SX]
    mov eax, [r8+SF_SY]
    mov [bs_sy], eax
    mov r10d, eax
    mov r11d, [r8+SF_W]
    mov r12d, [r8+SF_H]
    mov eax, [rg_x0]
    cmp eax, r9d
    jge .a
    mov eax, r9d
.a: mov [bs_ix0], eax
    mov eax, [rg_y0]
    cmp eax, r10d
    jge .b
    mov eax, r10d
.b: mov [bs_iy0], eax
    mov eax, [rg_x1]
    lea ecx, [r9+r11]
    cmp eax, ecx
    jle .c
    mov eax, ecx
.c: mov [bs_ix1], eax
    mov eax, [rg_y1]
    lea ecx, [r10+r12]
    cmp eax, ecx
    jle .d
    mov eax, ecx
.d: mov [bs_iy1], eax
    mov eax, [bs_ix0]
    cmp eax, [bs_ix1]
    jge .out
    mov eax, [bs_iy0]
    cmp eax, [bs_iy1]
    jge .out
    mov ebp, [bs_iy0]               ; y
.row:
    ; src row base
    mov eax, ebp
    sub eax, [bs_sy]                 ; py
    mov r13d, eax
    imul eax, r11d
    shl rax, 2
    add rax, [r8+SF_PTR]
    mov r14, rax                     ; src row start (x = sx)
    ; dst row base
    mov eax, ebp
    imul eax, [back_pitch]
    mov rdi, BACK
    add rdi, rax                     ; dst row start (x = 0)
    mov edx, [r8+SF_FLG]
    test edx, SFF_OPQ
    jnz .whole
    test edx, SFF_SAFE
    jz .allslow
    cmp r13d, [r8+SF_SY0]
    jl .allslow
    cmp r13d, [r8+SF_SY1]
    jge .allslow
    ; fast span [fx0,fx1)
    mov eax, [r8+SF_SX0]
    add eax, r9d
    cmp eax, [bs_ix0]
    jge .f0
    mov eax, [bs_ix0]
.f0: cmp eax, [bs_ix1]
    jle .f1
    mov eax, [bs_ix1]
.f1: mov [bs_fx0], eax
    mov eax, [r8+SF_SX1]
    add eax, r9d
    cmp eax, [bs_fx0]
    jge .g0
    mov eax, [bs_fx0]
.g0: cmp eax, [bs_ix1]
    jle .g1
    mov eax, [bs_ix1]
.g1: mov [bs_fx1], eax
    mov ebx, [bs_ix0]
    mov ecx, [bs_fx0]
    call .slow
    mov ebx, [bs_fx0]
    mov ecx, [bs_fx1]
    call .fast
    mov ebx, [bs_fx1]
    mov ecx, [bs_ix1]
    call .slow
    jmp .nextrow
.allslow:
    mov ebx, [bs_ix0]
    mov ecx, [bs_ix1]
    call .slow
    jmp .nextrow
.whole:
    mov ebx, [bs_ix0]
    mov ecx, [bs_ix1]
    call .fast
.nextrow:
    inc ebp
    cmp ebp, [bs_iy1]
    jb .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; fast copy: x range [ebx, ecx) ; uses r14 (src row start at x=sx), r9d=sx, rdi row dst
.fast:
.fast_x:
    cmp ecx, ebx
    jle .fr
    push rdi
    push rsi
    mov eax, ebx
    sub eax, r9d
    lea rsi, [r14+rax*4]
    lea rdi, [rdi+rbx*4]
    sub ecx, ebx
    rep movsd
    pop rsi
    pop rdi
.fr: ret
; slow blend: x range [ebx, ecx)   (top byte = transparency: 0 opaque, 255 skip)
; groups of 4 pixels that are all transparent are skipped, all opaque ones stored at once
.slow:
.slow_x:
    cmp ecx, ebx
    jle .sr
    push rdi
    mov eax, ebx
    sub eax, r9d
    lea r15, [r14+rax*4]
    lea rdi, [rdi+rbx*4]
    sub ecx, ebx
    mov r12d, ecx
    pxor xmm4, xmm4
    mov eax, 255
    movd xmm5, eax
    pshufd xmm5, xmm5, 0
.s4:
    mov ecx, r12d
    test ecx, ecx
    jz .s9
    cmp ecx, 4
    jb .s1
    movdqu xmm0, [r15]
    movdqa xmm1, xmm0
    psrld xmm1, 24
    movdqa xmm2, xmm1
    pcmpeqd xmm2, xmm5
    movmskps eax, xmm2
    cmp eax, 15
    je .s4n                          ; four transparent
    pcmpeqd xmm1, xmm4
    movmskps eax, xmm1
    cmp eax, 15
    jne .s1                          ; mixed: take one pixel the slow way
    movdqu [rdi], xmm0               ; four opaque
.s4n:
    add r15, 16
    add rdi, 16
    sub r12d, 4
    jmp .s4
.s1:
    ; one pixel (when fewer than 4 remain or the group is mixed)
    mov eax, [r15]
    mov edx, eax
    shr edx, 24
    jz .st
    cmp edx, 255
    je .sk
    mov r10d, eax
    and r10d, 0xFFFFFF
    mov r13d, [rdi]
    neg edx
    add edx, 255
    call blend255
.st:
    mov [rdi], eax
.sk:
    add r15, 4
    add rdi, 4
    dec r12d
    jmp .s4
.s9:
    pop rdi
.sr: ret

; ---- paint cursor sprite into BACK (region rg_*) ----------------------------
cursor_draw:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8d, [mx]
    mov r9d, [my]
    xor r12d, r12d                   ; row
.r: mov eax, r9d
    add eax, r12d
    cmp eax, [rg_y0]
    jl .nr
    cmp eax, [rg_y1]
    jge .nr
    cmp eax, [scr_h]
    jge .nr
    imul eax, [back_pitch]
    mov rdi, BACK
    add rdi, rax
    xor r14d, r14d                   ; col
.c: mov ebx, r8d
    add ebx, r14d
    cmp ebx, [rg_x0]
    jl .nc
    cmp ebx, [rg_x1]
    jge .nc
    cmp ebx, [scr_w]
    jge .nc
    lea r15, [rdi+rbx*4]
    mov eax, r12d
    shl eax, 3
    mov ecx, r14d
    shr ecx, 1
    add eax, ecx
    movzx edx, byte [cursor_outline+rax]
    test r14d, 1
    jnz .o1
    shr edx, 4
    jmp .o2
.o1: and edx, 15
.o2: test edx, edx
    jz .fl
    mov r10d, 0x101010
    mov r13d, [r15]
    imul edx, edx, 17
    push rax
    call blend255
    mov [r15], eax
    pop rax
.fl:
    movzx edx, byte [cursor_fill+rax]
    test r14d, 1
    jnz .f1
    shr edx, 4
    jmp .f2
.f1: and edx, 15
.f2: test edx, edx
    jz .nc
    mov r10d, 0xFFFFFF
    mov r13d, [r15]
    imul edx, edx, 17
    call blend255
    mov [r15], eax
.nc:
    inc r14d
    cmp r14d, 16
    jb .c
.nr:
    inc r12d
    cmp r12d, 24
    jb .r
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- compose region rg_* into BACK and copy it to the screen -----------------
comp_region:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; clip
    cmp dword [rg_x0], 0
    jge .a
    mov dword [rg_x0], 0
.a: cmp dword [rg_y0], 0
    jge .b
    mov dword [rg_y0], 0
.b: mov eax, [scr_w]
    cmp [rg_x1], eax
    jle .c
    mov [rg_x1], eax
.c: mov eax, [scr_h]
    cmp [rg_y1], eax
    jle .d
    mov [rg_y1], eax
.d: mov eax, [rg_x0]
    cmp eax, [rg_x1]
    jge .out
    mov eax, [rg_y0]
    cmp eax, [rg_y1]
    jge .out
    ; BASE -> BACK
    mov ebx, [rg_y0]
.cp:
    mov eax, ebx
    imul eax, [back_pitch]
    mov ecx, [rg_x0]
    lea rsi, [rax+rcx*4]
    lea rdi, [rsi+BACK]
    add rsi, BASE
    mov ecx, [rg_x1]
    sub ecx, [rg_x0]
    rep movsd
    inc ebx
    cmp ebx, [rg_y1]
    jb .cp
    ; windows bottom -> top
    xor r8d, r8d
.w: cmp r8d, [zn]
    jae .wd
    movzx esi, byte [zlist+r8]
    call blit_surf
    inc r8d
    jmp .w
.wd:
    mov esi, SI_DOCK
    call blit_surf
    mov esi, SI_TOP
    call blit_surf
    mov esi, SI_CARD
    call blit_surf
    call cursor_draw
    ; BACK -> screen
    mov ebx, [rg_y0]
.sc:
    mov eax, ebx
    imul eax, [back_pitch]
    mov ecx, [rg_x0]
    lea rsi, [rax+rcx*4]
    add rsi, BACK
    mov eax, ebx
    imul eax, [bi_pitch]
    mov edi, [bi_fb]
    add rdi, rax
    lea rdi, [rdi+rcx*4]
    mov ecx, [rg_x1]
    sub ecx, [rg_x0]
    rep movsd
    inc ebx
    cmp ebx, [rg_y1]
    jb .sc
    sfence                           ; flush the write-combining buffers
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- flush: collect damage and compose it -----------------------------------
wm_flush:
    call gather_damage
    cmp byte [dm_pend], 0
    je .o
    mov byte [dm_pend], 0
    push rax
    mov eax, [dm_x0]
    mov [rg_x0], eax
    mov eax, [dm_y0]
    mov [rg_y0], eax
    mov eax, [dm_x1]
    mov [rg_x1], eax
    mov eax, [dm_y1]
    mov [rg_y1], eax
    pop rax
    call comp_region
.o: ret

; ---- window shadow template (alpha per pixel for a WINSW x WINSH surface) ----
tpl_make:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor r9d, r9d                     ; y
    mov rdi, TPL_WIN
.y: xor r8d, r8d                     ; x
.x:
    ; q = |p - c| - (h - R) with center offset by +8 in y
    mov eax, r8d
    sub eax, SMX+WW/2
    cdq
    xor eax, edx
    sub eax, edx                     ; |dx|
    sub eax, WW/2-WRAD
    mov ebx, r9d
    sub ebx, SMT+WH/2+8
    mov edx, ebx
    sar edx, 31
    xor ebx, edx
    sub ebx, edx                     ; |dy|
    sub ebx, WH/2-WRAD
    ; outside part: max(q,0)
    mov ecx, eax
    test ecx, ecx
    jns .qx
    xor ecx, ecx
.qx:
    mov edx, ebx
    test edx, edx
    jns .qy
    xor edx, edx
.qy:
    imul ecx, ecx
    imul edx, edx
    add ecx, edx
    cvtsi2ss xmm0, ecx
    sqrtss xmm0, xmm0
    ; inside part: min(max(qx,qy),0)
    cmp eax, ebx
    jge .mx
    mov eax, ebx
.mx:
    test eax, eax
    js .neg
    xor eax, eax
.neg:
    cvtsi2ss xmm1, eax
    addss xmm0, xmm1
    mov eax, WRAD
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1                 ; d
    ; t = 1 - d/D  clamp [0,1]
    mov eax, 0x42100000              ; D = 36.0
    movd xmm1, eax
    divss xmm0, xmm1
    mov eax, 0x3F800000
    movd xmm1, eax
    subss xmm1, xmm0
    xorps xmm2, xmm2
    maxss xmm1, xmm2
    mov eax, 0x3F800000
    movd xmm3, eax
    minss xmm1, xmm3
    movaps xmm2, xmm1
    mulss xmm2, xmm1
    mulss xmm1, xmm2                 ; t^3
    mov eax, 0x42C80000              ; A = 100
    movd xmm3, eax
    mulss xmm1, xmm3
    cvtss2si eax, xmm1
    mov [rdi], al
    inc rdi
    inc r8d
    cmp r8d, WINSW
    jb .x
    inc r9d
    cmp r9d, WINSH
    jb .y
    mov byte [tpl_ok], 1
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- window surface creation: esi = window slot 0..7, eax=screen x ebx=screen y
win_create:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, esi
    cmp byte [tpl_ok], 0
    jne .t
    push rax
    push rbx
    call tpl_make
    pop rbx
    pop rax
.t: lea esi, [r9+SI_WIN0]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov ecx, r9d
    imul ecx, 0x280000
    add ecx, M_WIN
    mov [r8+SF_PTR], rcx
    mov dword [r8+SF_PTR+4], 0
    mov dword [r8+SF_W], WINSW
    mov dword [r8+SF_H], WINSH
    mov dword [r8+SF_VX], WX-SMX
    mov dword [r8+SF_VY], WY-SMT
    mov [r8+SF_SX], eax
    mov [r8+SF_SY], ebx
    mov dword [r8+SF_FLG], SFF_VIS|SFF_SAFE|SFF_WIN|SFF_DIRTY
    mov dword [r8+SF_SX0], SMX+WRAD
    mov dword [r8+SF_SY0], SMT+WRAD
    mov dword [r8+SF_SX1], SMX+WW-WRAD
    mov dword [r8+SF_SY1], SMT+WH-WRAD
    mov dword [r8+SF_BX], SMX
    mov dword [r8+SF_BY], SMT
    mov dword [r8+SF_BW], WW
    mov dword [r8+SF_BH], WH
    mov dword [r8+SF_FOC], 1
    mov dword [r8+SF_DX0], WX-SMX
    mov dword [r8+SF_DY0], WY-SMT
    mov dword [r8+SF_DX1], WX-SMX+WINSW
    mov dword [r8+SF_DY1], WY-SMT+WINSH
    ; fill with shadow
    mov rdi, rcx
    mov rsi, TPL_WIN
    mov ecx, WINSW*WINSH
.f: movzx eax, byte [rsi]
    inc rsi
    xor eax, 255
    shl eax, 24
    stosd
    dec ecx
    jnz .f
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- window chrome ------------------------------------------------------------
hdr_draw:                           ; rsi = title ; current target must be a window surface
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rsi
    mov byte [g_tr], 0
    mov r8, [cur_sptr]
    mov r9d, WRAD
    mov eax, C_HDR
    mov ebx, WX
    mov ecx, WY
    mov esi, WW
    mov edx, HDRH+WRAD
    call rrect
    mov eax, C_WIN
    mov ecx, WY+HDRH
    mov edx, WRAD
    call rect
    mov eax, C_BRD
    mov edx, 1
    call rect
    mov r9d, 6
    mov esi, 12
    mov edx, 12
    mov ebx, WX+14
    mov ecx, WY+14
    mov eax, 0xFF5F57
    cmp dword [r8+SF_FOC], 0
    jne .l1
    mov eax, C_BRD
.l1: call rrect
    mov ebx, WX+34
    mov eax, 0xFEBC2E
    cmp dword [r8+SF_FOC], 0
    jne .l2
    mov eax, C_BRD
.l2: call rrect
    mov ebx, WX+54
    mov eax, 0x28C840
    cmp dword [r8+SF_FOC], 0
    jne .l3
    mov eax, C_BRD
.l3: call rrect
    lea rax, [font_uib]
    mov [g_uf], rax
    SETC g_fg, C_TXT
    cmp dword [r8+SF_FOC], 0
    jne .tt
    SETC g_fg, C_DIM
.tt:
    ; clear the title area is already done by the header fill
    mov rsi, r10
    mov ebx, WX+WW/2
    mov ecx, WY+10
    call ui_text_c
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

draw_win:                           ; rsi=title (all regs kept)
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    mov r10, rsi
    mov rax, [cur_sptr]
    mov [rax+SF_TITLE], rsi
    mov byte [g_tr], 0
    mov eax, C_WIN
    mov ebx, WX
    mov ecx, WY
    mov esi, WW
    mov edx, WH
    mov r9d, WRAD
    call rrect
    mov eax, C_STAT
    mov ecx, WY+WH-STH-WRAD
    mov edx, STH+WRAD
    call rrect
    mov eax, C_WIN
    mov ecx, WY+WH-STH-WRAD
    mov edx, WRAD
    call rect
    mov eax, C_BRD
    mov ecx, WY+WH-STH
    mov edx, 1
    call rect
    mov rsi, r10
    call hdr_draw
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

clear_content:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, C_WIN
    mov ebx, WX+1
    mov ecx, WY+HDRH+1
    mov esi, WW-2
    mov edx, WH-STH-HDRH-1
    call rect
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

set_status:                         ; rsi=zstr
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r9
    push rsi
    mov eax, C_STAT
    mov ebx, WX+1
    mov ecx, WY+WH-STH+1
    mov esi, WW-2
    mov edx, STH-1-WRAD
    call rect
    mov eax, C_STAT
    mov ebx, WX+WRAD
    mov ecx, WY+WH-WRAD
    mov esi, WW-2*WRAD
    mov edx, WRAD
    call rect
    pop rsi
    lea rax, [font_uis]
    mov [g_uf], rax
    SETC g_fg, C_DIM
    mov ebx, WX+16
    mov ecx, WY+WH-STH+6
    call ui_text
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- wallpapers ---------------------------------------------------------------
; entry: top, bottom, nblobs, 4 x (cx permille, cy permille, r permille of width, color, strength)
WP_N equ 6
wp_tab:
    ; 0 Aurora
    dd 0x0B1020, 0x1B2352, 3
    dd 200, 250, 520, 0x7B4DFF, 210
    dd 800, 720, 560, 0x1FC8B4, 170
    dd 620, 120, 380, 0xFF4FA3, 130
    dd 0, 0, 1, 0, 0
    ; 1 Dusk
    dd 0x2B1B4B, 0xE8795A, 2
    dd 500, 1000, 760, 0xFFB36B, 230
    dd 150, 80, 420, 0x6C4BD9, 160
    dd 0, 0, 1, 0, 0
    dd 0, 0, 1, 0, 0
    ; 2 Ocean
    dd 0x062B4F, 0x0E6FA8, 2
    dd 700, 200, 480, 0x3BD6E8, 170
    dd 200, 850, 520, 0x1D5FD1, 150
    dd 0, 0, 1, 0, 0
    dd 0, 0, 1, 0, 0
    ; 3 Graphite
    dd 0x17181C, 0x2D2F36, 2
    dd 500, 380, 650, 0x555A66, 130
    dd 900, 900, 400, 0x3A3E49, 120
    dd 0, 0, 1, 0, 0
    dd 0, 0, 1, 0, 0
    ; 4 Meadow
    dd 0xD3F2DF, 0x82C9A8, 2
    dd 300, 200, 520, 0xFFF4B8, 170
    dd 820, 800, 520, 0x62B9D8, 130
    dd 0, 0, 1, 0, 0
    dd 0, 0, 1, 0, 0
    ; 5 Blush
    dd 0xFFE4EC, 0xD9B6F0, 2
    dd 720, 180, 520, 0xFFC7A8, 190
    dd 180, 820, 560, 0xB7C8FF, 150
    dd 0, 0, 1, 0, 0
    dd 0, 0, 1, 0, 0
WP_SZ equ 23*4


wp_gen:                             ; eax = wallpaper index -> fills WALL
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    imul eax, eax, WP_SZ
    lea rsi, [wp_tab+rax]
    mov eax, [rsi]
    mov [wg_top], eax
    mov eax, [rsi+4]
    mov [wg_bot], eax
    mov r15d, [rsi+8]                ; nblobs
    ; blob params in pixels
    xor ecx, ecx
.bp:
    cmp ecx, r15d
    jae .bd
    mov ebx, ecx
    imul ebx, 20
    lea rdi, [rsi+rbx+12]
    mov ebx, ecx
    imul ebx, 24
    lea rbp, [wg_b+rbx]
    mov r8d, 1000
    mov eax, [rdi]
    imul eax, [scr_w]
    xor edx, edx
    div r8d
    mov [rbp], eax
    mov eax, [rdi+4]
    imul eax, [scr_h]
    xor edx, edx
    div r8d
    mov [rbp+4], eax
    mov eax, [rdi+8]
    imul eax, [scr_w]
    xor edx, edx
    div r8d
    mov r9d, eax
    imul r9, r9    mov [rbp+8], r9d
    mov eax, 1
    shl rax, 24
    xor edx, edx
    div r9
    mov [rbp+12], eax
    mov eax, [rdi+12]
    mov [rbp+16], eax
    mov eax, [rdi+16]
    mov [rbp+20], eax
    inc ecx
    jmp .bp
.bd:
    ; exact reciprocals: floor(n/w) = (n*m)>>35 for n < 2^22, w < 2^13, m = ceil(2^35/w)
    mov rax, 1
    shl rax, 35
    mov ecx, [scr_w]
    lea rax, [rax+rcx-1]
    xor edx, edx
    div rcx
    mov [wg_mw], rax
    mov rax, 1
    shl rax, 35
    mov ecx, [scr_h]
    lea rax, [rax+rcx-1]
    xor edx, edx
    div rcx
    mov [wg_mh], rax
    mov rdi, WALL
    xor r12d, r12d                   ; y
.y:
    mov eax, r12d
    shl eax, 10
    imul rax, [wg_mh]
    shr rax, 35
    imul eax, 3
    mov [wg_ty3], eax
    xor r13d, r13d                   ; x
.x:
    ; t = (3*ty + tx)/4 , 0..1023
    mov eax, r13d
    shl eax, 10
    imul rax, [wg_mw]
    shr rax, 35
    add eax, [wg_ty3]
    shr eax, 2
    cmp eax, 1023
    jbe .t
    mov eax, 1023
.t: mov r14d, eax                    ; t
    mov r9d, 1024
    sub r9d, r14d                    ; 1024-t
    ; blob weights, once per pixel
    xor ebp, ebp
.bw:
    cmp ebp, r15d
    jae .bwd
    lea rdx, [wg_b]
    mov ebx, ebp
    imul ebx, 24
    mov eax, r13d
    sub eax, [rdx+rbx]
    imul eax, eax
    mov esi, r12d
    sub esi, [rdx+rbx+4]
    imul esi, esi
    add eax, esi                     ; d2
    mov esi, [rdx+rbx+8]             ; r2
    cmp eax, esi
    jae .bw0
    sub esi, eax
    mov eax, [rdx+rbx+12]
    imul rsi, rax
    shr rsi, 16                      ; 0..256
    imul esi, esi
    shr esi, 8
    imul esi, [rdx+rbx+20]
    shr esi, 8                       ; weight 0..256
    jmp .bws
.bw0:
    xor esi, esi
.bws:
    mov [wg_wt+rbp*4], esi
    inc ebp
    jmp .bw
.bwd:
    ; channels
    xor r10d, r10d                   ; shift
    xor r11d, r11d                   ; result
    push r12
    push r13
    mov [wg_x], r13d
    mov [wg_y], r12d
.chn:
    mov ecx, r10d
    mov eax, [wg_top]
    shr eax, cl
    and eax, 0xFF
    imul eax, r9d
    mov ebx, [wg_bot]
    shr ebx, cl
    and ebx, 0xFF
    imul ebx, r14d
    add eax, ebx
    shr eax, 10
    mov r8d, eax                     ; c (0..255)
    xor ebp, ebp
.bl:
    cmp ebp, r15d
    jae .bn
    mov esi, [wg_wt+rbp*4]
    test esi, esi
    jz .bx
    lea rdx, [wg_b]
    mov ebx, ebp
    imul ebx, 24
    mov eax, [rdx+rbx+16]
    shr eax, cl
    and eax, 0xFF
    sub eax, r8d
    imul eax, esi
    sar eax, 8
    add r8d, eax
.bx:
    inc ebp
    jmp .bl
.bn:
    ; dither
    mov eax, [wg_y]
    and eax, 3
    shl eax, 2
    mov ebx, [wg_x]
    and ebx, 3
    add eax, ebx
    movzx eax, byte [dith4+rax]
    sub eax, 8
    sar eax, 2
    add r8d, eax
    test r8d, r8d
    jns .p1
    xor r8d, r8d
.p1: cmp r8d, 255
    jle .p2
    mov r8d, 255
.p2: mov ecx, r10d
    shl r8d, cl
    or r11d, r8d
    add r10d, 8
    cmp r10d, 24
    jb .chn
    pop r13
    pop r12
    mov [rdi], r11d
    add rdi, 4
    inc r13d
    cmp r13d, [scr_w]
    jb .x
    inc r12d
    cmp r12d, [scr_h]
    jb .y
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- init all surfaces ----------------------------------------------------------
wm_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; clear table
    mov rdi, SURFS
    mov ecx, 16*SURF_SZ/8
    xor eax, eax
    rep stosq
    mov eax, [scr_w]
    shl eax, 2
    mov [back_pitch], eax
    ; BASE as drawing surface
    mov r8d, SI_BASE
    shl r8d, 7
    add r8, SURFS
    mov qword [r8+SF_PTR], BASE
    mov eax, [scr_w]
    mov [r8+SF_W], eax
    mov eax, [scr_h]
    mov [r8+SF_H], eax
    mov dword [r8+SF_FLG], SFF_VIS|SFF_OPQ
    ; dirty boxes empty
    xor esi, esi
.d: mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_DX0], 0x7FFFFFFF
    mov dword [r8+SF_DY0], 0x7FFFFFFF
    mov dword [r8+SF_DX1], 0x80000000
    mov dword [r8+SF_DY1], 0x80000000
    inc esi
    cmp esi, 16
    jb .d
    mov dword [zn], 0
    mov esi, SI_BASE
    call gfx_target
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; base = wallpaper copy (desktop icons are drawn over it later)
base_from_wall:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, WALL
    mov rdi, BASE
    mov eax, [scr_w]
    imul eax, [scr_h]
    mov ecx, eax
    rep movsd
    call damage_all
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ---- end wm_core.inc
; ---- begin icons.inc
; =============================================================================
;  ICON RENDERER  -  tiles in 4 styles, glyph masks (40x40, 4 bit) -> ARGB
;  style 0 flat squircle, 1 glass (skeuomorphic), 2 round, 3 outline
; =============================================================================
ICA     equ 0x4500000               ; main atlas, 16 icons, stride IC_STR
IC_STR  equ 0x8000
ICS     equ 0x4600000               ; small atlas (sidebar)
ICS_STR equ 0x2000
ICS_SZ  equ 28
GLU     equ 0x4590000               ; unpacked glyph (40*40 bytes)
IC_N    equ 17


; per glyph: top rgb, bottom rgb
icon_col:
    db 0x5A,0xB4,0xFF, 0x1D,0x6A,0xE6   ; files    blue
    db 0x56,0x5B,0x68, 0x1B,0x1D,0x23   ; terminal graphite
    db 0xFF,0xC4,0x62, 0xF0,0x7A,0x24   ; editor   orange
    db 0x5C,0xE2,0xCB, 0x13,0x8E,0xB0   ; browser  teal
    db 0xC9,0x8E,0xFF, 0x7A,0x3C,0xE0   ; images   violet
    db 0xFF,0x92,0xBC, 0xE0,0x3A,0x78   ; paint    pink
    db 0xBC,0xC1,0xCB, 0x67,0x6D,0x79   ; settings grey
    db 0xD2,0xD7,0xE0, 0x86,0x8D,0x9A   ; trash    light grey
    db 0x6C,0xB8,0xFF, 0x2A,0x6F,0xE0   ; about    blue
    db 0x86,0xE6,0x8E, 0x1E,0x9E,0x46   ; monitor  green
    db 0xA6,0xAE,0xBC, 0x5A,0x62,0x72   ; keyboard slate
    db 0x72,0xA6,0xFF, 0x3B,0x5C,0xE0   ; person   indigo
    db 0xFF,0x7E,0x70, 0xD6,0x2C,0x2C   ; power    red
    db 0xFF,0xD6,0x62, 0xE8,0x9A,0x10   ; lock     gold
    db 0x7A,0x8C,0xFF, 0x4B,0x3C,0xC8   ; appear   blue-violet
    db 0x6F,0xD4,0xFF, 0x22,0x86,0xE0   ; home     sky
    db 0x62,0xD8,0xE8, 0x1C,0x74,0xD8   ; display  cyan

; ---- bilinear glyph sample: xmm0 = u, xmm1 = v (0..1 of the glyph box) -> xmm0 coverage 0..1
gtex:                               ; eax=x edx=y -> ecx (0..255)
    cmp eax, 40
    jae .z
    cmp edx, 40
    jae .z
    imul ecx, edx, 40
    add ecx, eax
    movzx ecx, byte [GLU+rcx]
    ret
.z: xor ecx, ecx
    ret

glyph_cov:
    push rax
    push rdx
    push r8
    push r9
    push r10
    push r11
    mulss xmm0, [c_40]
    subss xmm0, [c_half]
    mulss xmm1, [c_40]
    subss xmm1, [c_half]
    addss xmm0, [c_64]
    addss xmm1, [c_64]
    cvttss2si eax, xmm0
    cvttss2si edx, xmm1
    cvtsi2ss xmm2, eax
    subss xmm0, xmm2                ; fx
    cvtsi2ss xmm3, edx
    subss xmm1, xmm3                ; fy
    sub eax, 64
    sub edx, 64
    mov r8d, eax
    mov r9d, edx
    call gtex
    cvtsi2ss xmm4, ecx             ; t00
    lea eax, [r8+1]
    mov edx, r9d
    call gtex
    cvtsi2ss xmm5, ecx             ; t10
    mov eax, r8d
    lea edx, [r9+1]
    call gtex
    cvtsi2ss xmm6, ecx             ; t01
    lea eax, [r8+1]
    lea edx, [r9+1]
    call gtex
    cvtsi2ss xmm7, ecx             ; t11
    subss xmm5, xmm4
    mulss xmm5, xmm0
    addss xmm4, xmm5               ; top
    subss xmm7, xmm6
    mulss xmm7, xmm0
    addss xmm6, xmm7               ; bottom
    subss xmm6, xmm4
    mulss xmm6, xmm1
    addss xmm4, xmm6
    mulss xmm4, [c_inv255]
    movaps xmm0, xmm4
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rax
    ret

; xmm4 (colour) += (xmm5 - xmm4) * xmm6.x
mixc:
    shufps xmm6, xmm6, 0
    subps xmm5, xmm4
    mulps xmm5, xmm6
    addps xmm4, xmm5
    ret

; ---- eax = glyph index, ecx = size, rdi = destination (size*size dwords)
icon_render:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov [ic_gl], eax
    mov [ic_sz], ecx
    mov [ic_dst], rdi
    movzx edx, byte [SB_ICST]
    and edx, 3
    mov [ic_style], edx
    ; unpack the glyph mask
    imul esi, eax, 800
    lea rsi, [icon_masks+rsi]
    mov rdi, GLU
    mov ecx, 800
.up:
    movzx eax, byte [rsi]
    inc rsi
    mov edx, eax
    shr edx, 4
    imul edx, 17
    mov [rdi], dl
    and eax, 15
    imul eax, 17
    mov [rdi+1], al
    add rdi, 2
    dec ecx
    jnz .up
    ; colours
    mov eax, [ic_gl]
    lea eax, [rax+rax*2]
    add eax, eax
    lea rsi, [icon_col+rax]
    movzx eax, byte [rsi+0]
    cvtsi2ss xmm0, eax
    movss [ic_top+8], xmm0
    movzx eax, byte [rsi+1]
    cvtsi2ss xmm0, eax
    movss [ic_top+4], xmm0
    movzx eax, byte [rsi+2]
    cvtsi2ss xmm0, eax
    movss [ic_top+0], xmm0
    movzx eax, byte [rsi+3]
    cvtsi2ss xmm0, eax
    movss [ic_bot+8], xmm0
    movzx eax, byte [rsi+4]
    cvtsi2ss xmm0, eax
    movss [ic_bot+4], xmm0
    movzx eax, byte [rsi+5]
    cvtsi2ss xmm0, eax
    movss [ic_bot+0], xmm0
    mov eax, [th_acc]
    movzx ecx, al
    cvtsi2ss xmm0, ecx
    movss [ic_acc+0], xmm0
    movzx ecx, ah
    cvtsi2ss xmm0, ecx
    movss [ic_acc+4], xmm0
    shr eax, 16
    movzx ecx, al
    cvtsi2ss xmm0, ecx
    movss [ic_acc+8], xmm0
    ; geometry
    cvtsi2ss xmm0, dword [ic_sz]
    movss [f_S], xmm0
    movss xmm1, [c_one]
    divss xmm1, xmm0
    movss [f_invS], xmm1
    mulss xmm0, [c_half]
    movss [f_half], xmm0
    cmp dword [ic_style], 2
    jne .sq
    movss xmm1, xmm0                ; round : R = half
    jmp .rr
.sq:
    movss xmm1, [f_S]
    mulss xmm1, [c_r225]
.rr:
    movss [f_R], xmm1
    subss xmm0, xmm1
    movss [f_hr], xmm0
    movss xmm0, [f_S]
    mulss xmm0, [c_gsz]
    cmp dword [ic_style], 1
    jne .gs
    mulss xmm0, [c_gl_sc]
.gs:
    movss [f_gs], xmm0
    movss xmm1, [f_S]
    subss xmm1, xmm0
    mulss xmm1, [c_half]
    movss [f_go], xmm1
    movss xmm0, [f_S]
    mulss xmm0, [c_sh]
    movss [f_sh], xmm0
    mov rdi, [ic_dst]
    xor r12d, r12d                  ; py
.ly:
    xor r13d, r13d                  ; px
.lx:
    ; ---- signed distance of the tile
    cvtsi2ss xmm0, r13d
    addss xmm0, [c_half]
    subss xmm0, [f_half]
    andps xmm0, [m_abs]
    subss xmm0, [f_hr]              ; qx
    cvtsi2ss xmm1, r12d
    addss xmm1, [c_half]
    subss xmm1, [f_half]
    andps xmm1, [m_abs]
    subss xmm1, [f_hr]              ; qy
    movaps xmm2, xmm0
    maxss xmm2, [c_zero]
    movaps xmm3, xmm1
    maxss xmm3, [c_zero]
    mulss xmm2, xmm2
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    maxss xmm0, xmm1
    minss xmm0, [c_zero]
    addss xmm2, xmm0
    subss xmm2, [f_R]
    movss [f_d], xmm2
    movss xmm0, [c_half]
    subss xmm0, xmm2
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    movss [f_cov], xmm0
    ucomiss xmm0, [c_zero]
    ja .vis
    mov dword [rdi], 0xFF000000
    jmp .next
.vis:
    ; t = (py + .5) / S
    cvtsi2ss xmm0, r12d
    addss xmm0, [c_half]
    mulss xmm0, [f_invS]
    movss [f_t], xmm0
    ; base gradient
    movups xmm4, [ic_bot]
    movups xmm1, [ic_top]
    subps xmm4, xmm1
    shufps xmm0, xmm0, 0
    mulps xmm4, xmm0
    addps xmm4, xmm1
    mov eax, [ic_style]
    cmp eax, 1
    je .glass
    cmp eax, 3
    je .outline
    movss xmm0, [c_one]
    movss [f_ta], xmm0
    jmp .glyph
.glass:
    ; richer gradient: lighten the top, deepen the bottom
    movups xmm5, [v_white]
    movss xmm6, [c_a10]
    call mixc
    movups xmm5, [v_black]
    movss xmm6, [f_t]
    mulss xmm6, [c_a18]
    call mixc
    ; gloss on the upper half
    movss xmm0, [f_t]
    movss xmm1, [c_half]
    ucomiss xmm1, xmm0
    jbe .nogloss
    mulss xmm0, [c_two]
    movss xmm6, [c_one]
    subss xmm6, xmm0
    mulss xmm6, [c_a36]
    addss xmm6, [c_a14]
    movups xmm5, [v_white]
    call mixc
.nogloss:
    ; rim: dark outer line, bright inner line
    movss xmm0, [f_d]
    movss xmm1, [c_m09]
    ucomiss xmm0, xmm1
    jbe .notdark
    movups xmm5, [v_black]
    movss xmm6, [c_a30]
    call mixc
    jmp .rimdone
.notdark:
    movss xmm1, [c_m20]
    ucomiss xmm0, xmm1
    jbe .rimdone
    movss xmm6, [c_one]
    subss xmm6, [f_t]
    mulss xmm6, [c_a40]
    movups xmm5, [v_white]
    call mixc
.rimdone:
    ; bottom glow
    movss xmm0, [f_t]
    movss xmm1, [c_t75]
    ucomiss xmm0, xmm1
    jbe .noglow
    subss xmm0, xmm1
    mulss xmm0, [c_a56]
    movss xmm6, xmm0
    movups xmm5, [v_white]
    call mixc
.noglow:
    movss xmm0, [c_one]
    movss [f_ta], xmm0
    jmp .glyph
.outline:
    ; translucent dark tile with an accent rim
    movups xmm4, [v_dark]
    movss xmm0, [c_a60]
    movss [f_ta], xmm0
    movss xmm0, [f_d]
    movss xmm1, [c_m16]
    ucomiss xmm0, xmm1
    jbe .glyph
    movups xmm4, [ic_acc]
    movss xmm0, [c_one]
    movss [f_ta], xmm0
.glyph:
    ; glyph coverage + soft shadow
    movss xmm0, [f_go]
    cvtsi2ss xmm2, r13d
    addss xmm2, [c_half]
    subss xmm2, xmm0
    divss xmm2, [f_gs]              ; u
    cvtsi2ss xmm3, r12d
    addss xmm3, [c_half]
    subss xmm3, xmm0
    cmp dword [ic_style], 1
    jne .gv
    subss xmm3, [c_gl_dy]
.gv:
    divss xmm3, [f_gs]              ; v
    movss [f_tmp], xmm3
    movups [ic_col], xmm4
    movaps xmm0, xmm2
    movaps xmm1, xmm3
    call glyph_cov
    movss [f_mg], xmm0
    ; shadow sample: v shifted up by sh
    movss xmm1, [f_sh]
    divss xmm1, [f_gs]
    movss xmm3, [f_tmp]
    subss xmm3, xmm1
    ; recompute u
    cvtsi2ss xmm2, r13d
    addss xmm2, [c_half]
    subss xmm2, [f_go]
    divss xmm2, [f_gs]
    movaps xmm0, xmm2
    movaps xmm1, xmm3
    call glyph_cov
    movss [f_ms], xmm0
    movups xmm4, [ic_col]
    ; shadow (not for outline)
    cmp dword [ic_style], 3
    je .noshadow
    movss xmm6, [f_ms]
    movss xmm0, [c_a30]
    cmp dword [ic_style], 1
    jne .shs
    movss xmm0, [c_a45]
.shs:
    mulss xmm6, xmm0
    movups xmm5, [v_black]
    call mixc
.noshadow:
    ; glyph colour
    movups xmm5, [v_white]
    cmp dword [ic_style], 1
    jne .gcol
    ; glass: white fading into a cool tint towards the bottom
    movups xmm5, [v_tint]
    movss xmm6, [f_t]
    movups xmm7, [v_white]
    ; xmm5 = white + (tint - white) * t
    subps xmm5, xmm7
    shufps xmm6, xmm6, 0
    mulps xmm5, xmm6
    addps xmm5, xmm7
    jmp .gmix
.gcol:
    cmp dword [ic_style], 3
    jne .gmix
    movups xmm5, [ic_acc]
.gmix:
    movss xmm6, [f_mg]
    call mixc
    ; ---- to bytes
    xorps xmm0, xmm0
    maxps xmm4, xmm0
    movups xmm0, [v_255x]
    minps xmm4, xmm0
    cvtps2dq xmm4, xmm4
    packssdw xmm4, xmm4
    packuswb xmm4, xmm4
    movd eax, xmm4
    and eax, 0xFFFFFF
    movss xmm0, [f_cov]
    mulss xmm0, [f_ta]
    mulss xmm0, [c_255]
    cvtss2si ecx, xmm0
    cmp ecx, 255
    jbe .am
    mov ecx, 255
.am:
    xor ecx, 255
    shl ecx, 24
    or eax, ecx
    mov [rdi], eax
.next:
    add rdi, 4
    inc r13d
    cmp r13d, [ic_sz]
    jb .lx
    inc r12d
    cmp r12d, [ic_sz]
    jb .ly
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; ---- render both atlases for the current icon style / dock size
icons_build:
    push rax
    push rcx
    push rdi
    push rdx
    xor edx, edx
.m: mov eax, edx
    mov ecx, [dk_isz]
    mov edi, edx
    shl edi, 15
    add rdi, ICA
    call icon_render
    inc edx
    cmp edx, IC_N
    jb .m
    xor edx, edx
.s: mov eax, edx
    mov ecx, ICS_SZ
    mov edi, edx
    imul edi, ICS_STR
    add rdi, ICS
    call icon_render
    inc edx
    cmp edx, IC_N
    jb .s
    pop rdx
    pop rdi
    pop rcx
    pop rax
    ret

; ---- ARGB blit (0xTTRRGGBB) : rsi=src ebx=x ecx=y eax=w edx=h  into the current target
argb_blit:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsi
    mov r11d, eax
    mov r12d, edx
    mov r8d, ebx
    mov r9d, ecx
    mov esi, eax
    call mark_dirty
    mov rax, [cur_pitch]
    imul rax, r9
    lea rdi, [rax+r8*4]
    add rdi, [cur_fb]
.row:
    mov r15, rdi
    mov r14d, r11d
.px:
    mov r10d, [rbp]
    add rbp, 4
    mov edx, r10d
    shr edx, 24
    xor edx, 255
    jz .sk
    and r10d, 0xFFFFFF
    call plot_a
.sk:
    add r15, 4
    dec r14d
    jnz .px
    add rdi, [cur_pitch]
    dec r12d
    jnz .row
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- end icons.inc

puts_cell:                          ; rsi=zstr eax=col edx=row (content grid)
    push rbx
    push rcx
    push rax
    push rdx
    shl eax, 3
    add eax, GX
    mov ebx, eax
    mov ecx, edx
    shl ecx, 4
    add ecx, GY
    call text
    pop rdx
    pop rax
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------- chrome -----
prompt:                             ; rsi=prompt rdi=buffer -> eax=len (0=cancel)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
.draw:
    mov rsi, r13
    call set_status
    mov rsi, r13
    call strlen
    lea ebx, [rax*8+WX+12]
    mov byte [r12+r14], '_'
    mov byte [r12+r14+1], 0
    mov rsi, r12
    cmp byte [pr_mask], 0
    je .pm
    lea rdi, [STARB]
    xor ecx, ecx
.pst:
    cmp ecx, r14d
    jae .pse
    mov byte [rdi+rcx], '*'
    inc ecx
    jmp .pst
.pse:
    mov byte [rdi+rcx], '_'
    mov byte [rdi+rcx+1], 0
    mov rsi, rdi
.pm:
    SETC g_fg, C_TXT
    SETC g_bg, C_STAT
    mov ecx, WY+WH-STH+6
    call text
.key:
    call getkey
    cmp al, 13
    je .ok
    cmp al, 27
    je .cancel
    cmp al, 8
    je .bs
    cmp al, 32
    jb .key
    cmp al, 0xDF
    ja .key
    cmp r14d, 30
    jae .key
    mov [r12+r14], al
    inc r14d
    jmp .draw
.bs:
    test r14d, r14d
    jz .key
    dec r14d
    jmp .draw
.ok:
    mov byte [r12+r14], 0
    mov eax, r14d
    jmp .out
.cancel:
    mov byte [r12], 0
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------ keyboard/RTC ---
bcd:                                ; al = BCD -> al = binary
    push rcx
    mov ah, al
    shr ah, 4
    and al, 0x0F
    mov cl, ah
    shl cl, 3
    shl ah, 1
    add ah, cl
    add al, ah
    pop rcx
    ret

put2:                               ; al=value rdi=dest -> two digits, rdi+=2
    push rbx
    movzx eax, al
    mov bl, 10
    div bl
    add al, '0'
    add ah, '0'
    mov [rdi], al
    mov [rdi+1], ah
    add rdi, 2
    pop rbx
    ret

rtc_sec:
    xor eax, eax
    out 0x70, al
    in al, 0x71
    ret

; ---- begin sys.inc
; =============================================================================
;  INPUT (keyboard layouts, PS/2 mouse), TASKS, WINDOW MANAGER ACTIONS
; =============================================================================
TASKS    equ 0x3A1000
TSAVE    equ 0x4400000
STK      equ 0x4200000
NTASK    equ 9
T_STATE  equ 0
T_RSP    equ 8
T_SURF   equ 16
T_ENTRY  equ 24
T_ARG    equ 32
T_FG     equ 40
T_BG     equ 44
T_TR     equ 48
T_SC     equ 52
T_CURFB  equ 56
T_CURPIT equ 64
T_CURSRF equ 72
T_CURSPT equ 80
T_UF     equ 88
T_KIND   equ 96
T_TITLE  equ 104
SCR_SAVE equ 0xD00                   ; bytes of MISC swapped per task


; ---- key queue ---------------------------------------------------------------
kq_push:                            ; al
    push rbx
    push rcx
    mov ecx, [kq_t]
    mov ebx, ecx
    inc ebx
    and ebx, 63
    cmp ebx, [kq_h]
    je .f
    mov [kq+rcx], al
    mov [kq_t], ebx
.f: pop rcx
    pop rbx
    ret

kq_pop:                             ; -> al (0 = empty)
    push rbx
    mov ebx, [kq_h]
    cmp ebx, [kq_t]
    jne .g
    xor eax, eax
    pop rbx
    ret
.g: movzx eax, byte [kq+rbx]
    inc ebx
    and ebx, 63
    mov [kq_h], ebx
    pop rbx
    ret

; ---- layout id of the active layout (0 en, 1 ru, 2 es) -> eax
lay_id:
    xor eax, eax    cmp byte [lay_cur], 0
    je .r
    movzx eax, byte [SB_LAY2]
    and eax, 1
    inc eax
.r: ret

; ---- keyboard scancode handling: al = raw byte --------------------------------
kbd_scan:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    cmp al, 0xE0
    jne .n1
    mov byte [k_e0], 1
    jmp .out
.n1:
    movzx ebx, al
    movzx ecx, byte [k_e0]
    mov byte [k_e0], 0
    test bl, 0x80
    jnz .rel
    test ecx, ecx
    jnz .ext
    cmp bl, 0x2A
    je .shon
    cmp bl, 0x36
    je .shon
    cmp bl, 0x1D
    je .con
    cmp bl, 0x38
    je .alton
    cmp bl, 0x3A
    je .cap
    cmp bl, 0x39
    ja .out
    mov byte [lay_pend], 0
    cmp byte [k_alt], 0
    jne .altkey
    ; layout tables
    xor edx, edx
    cmp byte [k_ctrl], 0
    jne .lid
    call lay_id
    mov edx, eax
.lid:
    imul edx, edx, 192
    lea rsi, [lay_tab+rdx]
    movzx eax, byte [k_shift]
    cmp byte [k_caps], 0
    je .nc
    cmp byte [rsi+128+rbx], 0
    je .nc
    xor eax, 1
.nc:
    test eax, eax
    jz .ch
    add rsi, 64
.ch:
    mov al, [rsi+rbx]
    test al, al
    jz .out
    cmp al, 0xF0
    jb .nd
    mov [k_dead], al
    jmp .out
.nd:
    cmp byte [k_dead], 0
    je .nodead
    call dead_map
    mov byte [k_dead], 0
.nodead:
    cmp byte [k_ctrl], 0
    je .push
    mov ah, al
    or ah, 0x20
    cmp ah, 'a'
    jb .push
    cmp ah, 'z'
    ja .push
    and al, 0x1F
.push:
    call kq_push
    jmp .out
.altkey:
    cmp bl, 0x0F
    je .a_tab
    cmp bl, 0x10
    je .a_q
    cmp bl, 0x32
    je .a_m
    cmp bl, 0x20
    je .a_d
    jmp .out
.a_tab:
    call wm_next_window
    jmp .out
.a_q:
    call wm_close_focused
    jmp .out
.a_m:
    call wm_min_focused
    jmp .out
.a_d:
    xor eax, eax
    call focus_set
    jmp .out
.shon:
    mov byte [k_shift], 1
    cmp byte [k_alt], 0
    je .out
    mov byte [lay_pend], 1
    jmp .out
.con:
    mov byte [k_ctrl], 1
    jmp .out
.alton:
    mov byte [k_alt], 1
    cmp byte [k_shift], 0
    je .out
    mov byte [lay_pend], 1
    jmp .out
.cap:
    xor byte [k_caps], 1
    jmp .out
.ext:
    cmp bl, 0x1D
    je .con
    cmp bl, 0x38
    je .alton
    mov byte [lay_pend], 0
    mov al, K_UP
    cmp bl, 0x48
    je .e1
    mov al, K_DN
    cmp bl, 0x50
    je .e1
    mov al, K_LF
    cmp bl, 0x4B
    je .e1
    mov al, K_RT
    cmp bl, 0x4D
    je .e1
    mov al, K_DEL
    cmp bl, 0x53
    je .e2
    mov al, K_HOME
    cmp bl, 0x47
    je .e2
    mov al, K_END
    cmp bl, 0x4F
    je .e2
    mov al, K_PGUP
    cmp bl, 0x49
    je .e2
    mov al, K_PGDN
    cmp bl, 0x51
    je .e2
    mov al, 13
    cmp bl, 0x1C
    je .e2
    jmp .out
.e1:
    cmp byte [k_alt], 0
    je .e2
    ; alt + arrow : move the focused window
    xor ecx, ecx
    xor edx, edx
    cmp al, K_UP
    jne .m1
    mov edx, -24
.m1: cmp al, K_DN
    jne .m2
    mov edx, 24
.m2: cmp al, K_LF
    jne .m3
    mov ecx, -24
.m3: cmp al, K_RT
    jne .m4
    mov ecx, 24
.m4: mov eax, ecx
    mov ebx, edx
    call wm_move_focused
    jmp .out
.e2:
    call kq_push
    jmp .out
.rel:
    and bl, 0x7F
    cmp bl, 0x2A
    je .shoff
    cmp bl, 0x36
    je .shoff
    cmp bl, 0x1D
    je .cooff
    cmp bl, 0x38
    je .altoff
    jmp .out
.shoff:
    mov byte [k_shift], 0
    jmp .tog
.altoff:
    mov byte [k_alt], 0
.tog:
    cmp byte [lay_pend], 0
    je .out
    mov byte [lay_pend], 0
    xor byte [lay_cur], 1
    jmp .out
.cooff:
    mov byte [k_ctrl], 0
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

dead_map:                           ; al = char, k_dead = F0 (acute) / F1 (diaeresis)
    push rsi
    push rdi
    push rcx
    lea rsi, [dead_acute]
    lea rdi, [dead_acute_r]
    cmp byte [k_dead], 0xF0
    je .go
    lea rsi, [dead_diaer]
    lea rdi, [dead_diaer_r]
.go:
    xor ecx, ecx
.l: mov ah, [rsi+rcx]
    test ah, ah
    jz .no
    cmp ah, al
    je .hit
    inc ecx
    jmp .l
.hit:
    mov al, [rdi+rcx]
    jmp .o
.no:
    cmp al, ' '
    jne .o
    mov al, 39
.o: pop rcx
    pop rdi
    pop rsi
    ret

; ---- PS/2 mouse ---------------------------------------------------------------
kbc_wait_w:                         ; wait until the controller accepts a byte
    push rcx
    mov ecx, 50000
.l: in al, 0x64
    test al, 2
    jz .o
    dec ecx
    jnz .l
.o: pop rcx
    ret

kbc_wait_r:                         ; wait for output byte (CF=1 on timeout)
    push rcx
    mov ecx, 50000
.l: in al, 0x64
    test al, 1
    jnz .o
    dec ecx
    jnz .l
    stc
    pop rcx
    ret
.o: clc
    pop rcx
    ret

mouse_cmd:                          ; al = byte for the mouse
    push rax
    call kbc_wait_w
    mov al, 0xD4
    out 0x64, al
    call kbc_wait_w
    pop rax
    out 0x60, al
    call kbc_wait_r
    jc .o
    in al, 0x60
.o: ret

mouse_init:
    push rax
    call kbc_wait_w
    mov al, 0xA8
    out 0x64, al
    call kbc_wait_w
    mov al, 0x20
    out 0x64, al
    call kbc_wait_r
    jc .skip
    in al, 0x60
    or al, 2
    and al, 0xDF
    mov ah, al
    call kbc_wait_w
    mov al, 0x60
    out 0x64, al
    call kbc_wait_w
    mov al, ah
    out 0x60, al
    mov al, 0xF6
    call mouse_cmd
    mov al, 0xF4
    call mouse_cmd
.skip:
    pop rax
    ret

ms_byte:                            ; al = mouse data byte
    push rax
    push rbx
    push rcx
    push rdx
    movzx ebx, byte [ms_i]
    test ebx, ebx
    jnz .n1
    test al, 8
    jz .out
    mov [ms_b0], al
    mov byte [ms_i], 1
    jmp .out
.n1:
    cmp ebx, 1
    jne .n2
    mov [ms_b1], al
    mov byte [ms_i], 2
    jmp .out
.n2:
    mov byte [ms_i], 0
    movzx ecx, byte [ms_b0]
    test cl, 0xC0
    jnz .out
    movsx edx, byte [ms_b1]
    movsx eax, al
    neg eax                          ; screen y grows downwards
    mov ebx, [mx]
    add ebx, edx
    jns .x1
    xor ebx, ebx
.x1: mov edx, [scr_w]
    dec edx
    cmp ebx, edx
    jle .x2
    mov ebx, edx
.x2: mov [mx], ebx
    mov ebx, [my]
    add ebx, eax
    jns .y1
    xor ebx, ebx
.y1: mov edx, [scr_h]
    dec edx
    cmp ebx, edx
    jle .y2
    mov ebx, edx
.y2: mov [my], ebx
    and cl, 7
    mov [m_btn], cl
    call mouse_apply
.out:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- react to a new mouse state ------------------------------------------------
mouse_apply:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    inc dword [m_ev]
    ; cursor damage (old and new position)
    mov eax, [mx_old]
    sub eax, 2
    mov ebx, [my_old]
    sub ebx, 2
    lea ecx, [rax+22]
    lea edx, [rbx+30]
    call damage
    mov eax, [mx]
    sub eax, 2
    mov ebx, [my]
    sub ebx, 2
    lea ecx, [rax+22]
    lea edx, [rbx+30]
    call damage
    mov eax, [mx]
    mov [mx_old], eax
    mov eax, [my]
    mov [my_old], eax
    ; dragging
    mov esi, [drag_s]
    cmp esi, 0
    jl .nodrag
    test byte [m_btn], 1
    jz .enddrag
    mov eax, [mx]
    sub eax, [drag_gx]
    mov ebx, [my]
    sub ebx, [drag_gy]
    call win_move_to
    jmp .btn
.enddrag:
    mov dword [drag_s], -1
.nodrag:
.btn:
    movzx eax, byte [m_btn]
    movzx ebx, byte [m_btn_old]
    mov [m_btn_old], al
    test al, 1
    jz .done
    test bl, 1
    jnz .done
    call mouse_press
.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- left button pressed at (mx,my) -----------------------------------------------
mouse_press:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov eax, [mx]
    mov ebx, [my]
    cmp byte [pm_open], 0
    jne .pmclick
    cmp ebx, TOPH
    jl .topclk
    ; dock
    cmp dword [dk_w], 0
    je .win
    cmp eax, [dk_x]
    jl .win
    mov ecx, [dk_x]
    add ecx, [dk_w]
    cmp eax, ecx
    jge .win
    cmp ebx, [dk_y]
    jl .win
    mov ecx, [dk_y]
    add ecx, [dk_h]
    cmp ebx, ecx
    jge .win
    ; icon index
    sub eax, [dk_x0]
    jl .out
    xor edx, edx
    div dword [dk_step]
    cmp eax, [dk_n]
    jae .out
    cmp edx, [dk_isz]
    jae .out
    inc eax
    mov [launch_req], eax
    jmp .out
.win:
    mov r8d, [zn]
.wl:
    test r8d, r8d
    jz .desk
    dec r8d
    movzx esi, byte [zlist+r8]
    mov r9d, esi
    shl r9d, 7
    add r9, SURFS
    test dword [r9+SF_FLG], SFF_VIS
    jz .wl
    mov eax, [mx]
    mov ebx, [my]
    mov ecx, [r9+SF_SX]
    add ecx, [r9+SF_BX]
    sub eax, ecx                     ; rel x
    mov ecx, [r9+SF_SY]
    add ecx, [r9+SF_BY]
    sub ebx, ecx                     ; rel y
    test eax, eax
    js .wl
    test ebx, ebx
    js .wl
    cmp eax, [r9+SF_BW]
    jge .wl
    cmp ebx, [r9+SF_BH]
    jge .wl
    ; hit this window
    mov edi, [r9+SF_TASK]
    push rax
    push rbx
    mov eax, edi
    call focus_set
    pop rbx
    pop rax
    cmp ebx, HDRH
    jge .out
    ; traffic lights
    cmp ebx, 13
    jl .drag
    cmp ebx, 27
    jg .drag
    cmp eax, 13
    jl .drag
    cmp eax, 27
    jle .close
    cmp eax, 33
    jl .drag
    cmp eax, 47
    jle .minim
    cmp eax, 53
    jl .drag
    cmp eax, 67
    jle .zoom
.drag:
    mov eax, [mx]
    sub eax, [r9+SF_SX]
    mov [drag_gx], eax
    mov eax, [my]
    sub eax, [r9+SF_SY]
    mov [drag_gy], eax
    mov [drag_s], esi
    jmp .out
.close:
    mov eax, edi
    call task_kill
    jmp .out
.minim:
    call wm_min_focused
    jmp .out
.zoom:
    mov eax, [scr_w]
    sub eax, WW
    shr eax, 1
    sub eax, SMX
    call win_home_y
    call win_move_to
    jmp .out
.desk:
    xor eax, eax
    call focus_set
    mov byte [desk_click], 1
    jmp .out
.topclk:
    inc eax
    mov [top_click], eax
    jmp .out
.pmclick:
    mov [pm_cx], eax
    mov [pm_cy], ebx
    mov byte [pm_ev], 1
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- window helpers --------------------------------------------------------------
win_move_to:                        ; esi=surface eax=new sx ebx=new sy (clamped)
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    ; clamp: box inside the screen with a visible part
    mov ecx, [r8+SF_BX]
    add ecx, eax                      ; box x
    cmp ecx, 80-WW
    jge .x1
    mov eax, 80-WW
    sub eax, [r8+SF_BX]
.x1: mov ecx, [scr_w]
    sub ecx, 80
    sub ecx, [r8+SF_BX]
    cmp eax, ecx
    jle .x2
    mov eax, ecx
.x2: mov ecx, [r8+SF_BY]
    add ecx, ebx
    cmp ecx, TOPH
    jge .y1
    mov ebx, TOPH
    sub ebx, [r8+SF_BY]
.y1: mov ecx, [scr_h]
    sub ecx, 100
    sub ecx, [r8+SF_BY]
    cmp ebx, ecx
    jle .y2
    mov ebx, ecx
.y2: cmp eax, [r8+SF_SX]
    jne .mv
    cmp ebx, [r8+SF_SY]
    je .o
.mv:
    push rax
    push rbx
    mov eax, [r8+SF_SX]
    mov ebx, [r8+SF_SY]
    mov ecx, eax
    add ecx, [r8+SF_W]
    mov edx, ebx
    add edx, [r8+SF_H]
    call damage
    pop rbx
    pop rax
    mov [r8+SF_SX], eax
    mov [r8+SF_SY], ebx
    mov ecx, eax
    add ecx, [r8+SF_W]
    mov edx, ebx
    add edx, [r8+SF_H]
    call damage
.o: pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

wm_move_focused:                    ; eax=dx ebx=dy
    push rcx
    push rdx
    push rsi
    push r8
    mov ecx, [focus]
    test ecx, ecx
    jz .o
    shl ecx, 7
    add rcx, TASKS
    mov esi, [rcx+T_SURF]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    add eax, [r8+SF_SX]
    add ebx, [r8+SF_SY]
    call win_move_to
.o: pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

z_remove:                           ; esi = surface
    push rax
    push rcx
    xor ecx, ecx
.f: cmp ecx, [zn]
    jae .o
    cmp [zlist+rcx], sil
    je .got
    inc ecx
    jmp .f
.got:
.s: lea eax, [rcx+1]
    cmp eax, [zn]
    jae .d
    mov al, [zlist+rcx+1]
    mov [zlist+rcx], al
    inc ecx
    jmp .s
.d: dec dword [zn]
.o: pop rcx
    pop rax
    ret

z_raise:                            ; esi = surface
    push rax
    call z_remove
    mov eax, [zn]
    mov [zlist+rax], sil
    inc dword [zn]
    pop rax
    ret

surf_damage:                        ; esi = surface -> whole surface on screen
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov eax, [r8+SF_SX]
    mov ebx, [r8+SF_SY]
    lea ecx, [rax]
    add ecx, [r8+SF_W]
    lea edx, [rbx]
    add edx, [r8+SF_H]
    call damage
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; redraw the header of a window surface (focus look)
win_hdr_refresh:                    ; esi = surface
    push rax
    push rsi
    push r12
    push r13
    mov r12d, [cur_surf]
    mov r13d, esi
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov rsi, [r8+SF_TITLE]
    test rsi, rsi
    jz .o
    mov esi, r13d
    call gfx_target
    mov r8d, r13d
    shl r8d, 7
    add r8, SURFS
    mov rsi, [r8+SF_TITLE]
    call hdr_draw
.o: mov esi, r12d
    call gfx_target
    pop r13
    pop r12
    pop rsi
    pop rax
    ret

; ---- focus: eax = task (0 = desktop) -------------------------------------------------
focus_set:
    push rax
    push rbx
    push rsi
    push r8
    mov ebx, [focus]
    mov [focus], eax
    cmp ebx, eax
    je .same
    test ebx, ebx
    jz .nold
    mov r8d, ebx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne .nold
    mov esi, [r8+T_SURF]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_FOC], 0
    call win_hdr_refresh
.nold:
.same:
    test eax, eax
    jz .o
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    mov esi, [r8+T_SURF]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_FOC], 1
    or dword [r8+SF_FLG], SFF_VIS
    call z_raise
    call win_hdr_refresh
    call surf_damage
.o: pop r8
    pop rsi
    pop rbx
    pop rax
    ret

; topmost visible window's task (0 if none) -> eax
top_task:
    push rcx
    push rsi
    push r8
    mov ecx, [zn]
.l: test ecx, ecx
    jz .none
    dec ecx
    movzx esi, byte [zlist+rcx]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jz .l
    mov eax, [r8+SF_TASK]
    jmp .o
.none:
    xor eax, eax
.o: pop r8
    pop rsi
    pop rcx
    ret

wm_next_window:                     ; Alt+Tab : the lowest visible window comes to the top
    push rax
    push rcx
    push rsi
    push r8
    mov ecx, 0
.l: cmp ecx, [zn]
    jae .o
    movzx esi, byte [zlist+rcx]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jnz .got
    inc ecx
    jmp .l
.got:
    mov eax, [r8+SF_TASK]
    call focus_set
.o: pop r8
    pop rsi
    pop rcx
    pop rax
    ret

wm_close_focused:
    push rax
    mov eax, [focus]
    test eax, eax
    jz .o
    call task_kill
.o: pop rax
    ret

wm_min_focused:
    push rax
    push rsi
    push r8
    mov eax, [focus]
    test eax, eax
    jz .o
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    mov esi, [r8+T_SURF]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    and dword [r8+SF_FLG], ~SFF_VIS
    call surf_damage
    call top_task
    call focus_set
.o: pop r8
    pop rsi
    pop rax
    ret

; ---- tasks --------------------------------------------------------------------------
yield:
    cmp dword [ntasks], 1
    ja .go
    ret
.go:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8d, [task_cur]
    mov r9d, r8d
    shl r9d, 7
    add r9, TASKS
    mov [r9+T_RSP], rsp
    mov eax, [g_fg]
    mov [r9+T_FG], eax
    mov eax, [g_bg]
    mov [r9+T_BG], eax
    movzx eax, byte [g_tr]
    mov [r9+T_TR], eax
    mov eax, [g_scale]
    mov [r9+T_SC], eax
    mov rax, [cur_fb]
    mov [r9+T_CURFB], rax
    mov rax, [cur_pitch]
    mov [r9+T_CURPIT], rax
    mov eax, [cur_surf]
    mov [r9+T_CURSRF], eax
    mov rax, [cur_sptr]
    mov [r9+T_CURSPT], rax
    mov rax, [g_uf]
    mov [r9+T_UF], rax
    mov rsi, MISC
    mov edi, r8d
    shl edi, 12
    add rdi, TSAVE
    mov ecx, SCR_SAVE/8
    rep movsq
    mov eax, r8d
.nx:
    inc eax
    cmp eax, NTASK
    jb .ok
    xor eax, eax
.ok:
    mov edx, eax
    shl edx, 7
    add rdx, TASKS
    cmp dword [rdx+T_STATE], 1
    jne .nx
    mov [task_cur], eax
    mov rdi, MISC
    mov esi, eax
    shl esi, 12
    add rsi, TSAVE
    mov ecx, SCR_SAVE/8
    rep movsq
    mov eax, [rdx+T_FG]
    mov [g_fg], eax
    mov eax, [rdx+T_BG]
    mov [g_bg], eax
    mov eax, [rdx+T_TR]
    mov [g_tr], al
    mov eax, [rdx+T_SC]
    mov [g_scale], eax
    mov rax, [rdx+T_CURFB]
    mov [cur_fb], rax
    mov rax, [rdx+T_CURPIT]
    mov [cur_pitch], rax
    mov eax, [rdx+T_CURSRF]
    mov [cur_surf], eax
    mov rax, [rdx+T_CURSPT]
    mov [cur_sptr], rax
    mov rax, [rdx+T_UF]
    mov [g_uf], rax
    mov rsp, [rdx+T_RSP]
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

task_boot:
    mov eax, [task_cur]
    shl eax, 7
    add rax, TASKS
    mov rdx, [rax+T_ENTRY]
    mov rax, [rax+T_ARG]
    call rdx
task_exit:
    mov eax, [task_cur]
    call task_free
    call yield    jmp $

task_free:                          ; eax = task index
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov ebx, eax
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne .o
    mov dword [r8+T_STATE], 0
    dec dword [ntasks]
    mov esi, [r8+T_SURF]
    cmp esi, 0
    jle .nosurf
    call surf_damage
    call z_remove
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_FLG], 0
.nosurf:
    cmp ebx, [focus]
    jne .o
    mov dword [focus], 0
    call top_task
    mov [focus], ebx
    call focus_set
.o: pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

task_kill:                          ; eax = task index
    push rax
    cmp eax, [task_cur]
    jne .k
    call task_free
    call yield
    jmp $
.k: call task_free
    pop rax
    ret

; rax = entry, rbx = arg, ecx = kind (0 = many), rsi = title -> eax = task (0 = failed)
spawn:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    mov r12, rax
    mov r11, rbx
    mov r10d, ecx
    mov r9, rsi
    test r10d, r10d
    jz .new
    mov ecx, 1
.f: cmp ecx, NTASK
    jae .new
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne .fn
    cmp [r8+T_KIND], r10d
    je .exists
.fn:
    inc ecx
    jmp .f
.exists:
    mov eax, ecx
    call focus_set
    mov eax, ecx
    jmp .out
.new:
    mov ecx, 1
.g: cmp ecx, NTASK
    jae .fail
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 0
    je .got
    inc ecx
    jmp .g
.fail:
    xor eax, eax
    jmp .out
.got:
    mov r13d, ecx                    ; task index
    ; position (cascade)
    mov eax, [ntasks]
    dec eax
    xor edx, edx
    mov ecx, 6
    div ecx
    imul edx, edx, 28
    mov eax, [scr_w]
    sub eax, WW
    shr eax, 1
    sub eax, SMX
    add eax, edx
    call win_home_y
    add ebx, edx
    lea esi, [r13-1]
    call win_create
    lea esi, [r13+SI_WIN0-1]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov [r8+SF_TASK], r13d
    mov [r8+SF_TITLE], r9
    mov eax, [zn]
    mov [zlist+rax], sil
    inc dword [zn]
    ; task record
    mov r8d, r13d
    shl r8d, 7
    add r8, TASKS
    mov dword [r8+T_STATE], 1
    mov [r8+T_ENTRY], r12
    mov [r8+T_ARG], r11
    mov [r8+T_KIND], r10d
    mov [r8+T_TITLE], r9
    mov [r8+T_SURF], esi
    mov dword [r8+T_FG], 0
    mov dword [r8+T_BG], 0xFFFFFF
    mov dword [r8+T_TR], 0
    mov dword [r8+T_SC], 1
    lea rax, [font_ui]
    mov [r8+T_UF], rax
    ; drawing target of the new task
    mov ebx, [cur_surf]
    push rbx
    call gfx_target
    mov rax, [cur_fb]
    mov [r8+T_CURFB], rax
    mov rax, [cur_pitch]
    mov [r8+T_CURPIT], rax
    mov eax, [cur_surf]
    mov [r8+T_CURSRF], eax
    mov rax, [cur_sptr]
    mov [r8+T_CURSPT], rax
    pop rsi
    call gfx_target
    ; stack
    mov eax, r13d
    shl eax, 17
    add eax, STK+0x20000
    mov rdi, rax
    mov qword [rdi-8], task_boot
    lea rdi, [rdi-128]
    mov rcx, rdi
    mov [r8+T_RSP], rdi
    xor eax, eax
    mov ecx, 15
    rep stosq
    ; clear the scratch save area
    mov edi, r13d
    shl edi, 12
    add rdi, TSAVE
    mov ecx, SCR_SAVE/8
    xor eax, eax
    rep stosq
    inc dword [ntasks]
    mov eax, r13d
    call focus_set
    mov eax, r13d
.out:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- the service routine run on every key poll ------------------------------------
wm_service:
    push rax
.rd:
    in al, 0x64
    test al, 1
    jz .done
    test al, 0x20
    jnz .aux
    in al, 0x60
    call kbd_scan
    jmp .rd
.aux:
    in al, 0x60
    call ms_byte
    jmp .rd
.done:
    call wm_flush
    pop rax
    ret

pollkey:                            ; -> al = key or 0
    call wm_service
    mov eax, [task_cur]
    cmp eax, [focus]
    jne .no
    call kq_pop
    test al, al
    jnz .r
.no:
    call yield
    xor eax, eax
.r: ret

getkey:
.l: call pollkey
    test al, al
    jnz .r
    pause
    jmp .l
.r: ret

; ---- end sys.inc
; ---- begin shell.inc
; =============================================================================
;  SHELL: menu bar, dock, pop-up menus, desktop, launcher
; =============================================================================
%macro PUSHA 0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
%endmacro
%macro POPA 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
%endmacro

PMSH    equ 18                       ; pop-up shadow margin
PM_IH   equ 26
PM_SH   equ 10
DKPY    equ 36                       ; pill top inside the dock surface
DKGAP   equ 14
DKPAD   equ 18
DK_ITEMS equ 8
NAPPS   equ 7


; ---- surface setup: esi=index ebx=sx ecx=sy eax=w edx=h rdi=ptr (cleared to transparent)
surf_setup:
    PUSHA
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov [r8+SF_PTR], rdi
    mov dword [r8+SF_PTR+4], 0
    mov [r8+SF_W], eax
    mov [r8+SF_H], edx
    mov [r8+SF_VX], ebx
    mov [r8+SF_VY], ecx
    mov [r8+SF_SX], ebx
    mov [r8+SF_SY], ecx
    mov dword [r8+SF_FLG], SFF_VIS|SFF_DIRTY
    mov [r8+SF_DX0], ebx
    mov [r8+SF_DY0], ecx
    add ebx, eax
    add ecx, edx
    mov [r8+SF_DX1], ebx
    mov [r8+SF_DY1], ecx
    imul ecx, eax, 1
    imul ecx, edx
    mov eax, 0xFF000000
    rep stosd
    POPA
    ret

; ---- hide a pop-up style surface: esi = index
surf_hide:
    PUSHA
    call surf_damage
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_FLG], 0
    POPA
    ret

; ---- theme helpers --------------------------------------------------------------
; fg colour of chrome text
chrome_fg:
    cmp byte [SB_THEME], 0
    jne .d
    mov eax, 0x1D1D1F
    ret
.d: mov eax, 0xF5F5F7
    ret

; ================================================================ TOP BAR ====
top_init:
    PUSHA
    mov esi, SI_TOP
    xor ebx, ebx
    xor ecx, ecx
    mov eax, [scr_w]
    mov edx, TOPH
    mov rdi, M_TOP
    call surf_setup
    call top_draw
    POPA
    ret

; the logo (20 px) for the current setting: rsi = table
logo_ptr20:
    movzx eax, byte [SB_LOGO]
    cmp eax, 1
    je .m
    cmp eax, 2
    je .g
    lea rsi, [logo_rainbow_20]
    ret
.g: lea rsi, [logo_green_20]
    ret
.m: lea rsi, [logo_mono_20]
    cmp byte [SB_THEME], 0
    je .o
    lea rsi, [logo_monol_20]
.o: ret

logo_ptr64:
    movzx eax, byte [SB_LOGO]
    cmp eax, 1
    je .m
    cmp eax, 2
    je .g
    lea rsi, [logo_rainbow_64]
    ret
.g: lea rsi, [logo_green_64]
    ret
.m: lea rsi, [logo_mono_64]
    cmp byte [SB_THEME], 0
    je .o
    lea rsi, [logo_monol_64]
.o: ret

; logo drawn on a dark card (login) : always the light mono
logo_ptr64_dark:
    movzx eax, byte [SB_LOGO]
    cmp eax, 1
    je .m
    cmp eax, 2
    je .g
    lea rsi, [logo_rainbow_64]
    ret
.g: lea rsi, [logo_green_64]
    ret
.m: lea rsi, [logo_monol_64]
    ret

; ---- clock text into CLKB: "Sun 4 Oct  15:42"
rtc_get:                            ; al = reg -> al (binary)
    push rcx
    push rdx
    mov cl, al
.w: mov al, 0x0A
    out 0x70, al
    in al, 0x71
    test al, 0x80
    jnz .w
    mov al, cl
    out 0x70, al
    in al, 0x71
    mov dl, al
    mov al, 0x0B
    out 0x70, al
    in al, 0x71
    test al, 4
    mov al, dl
    jnz .b
    call bcd
.b: pop rdx
    pop rcx
    ret

clock_text:
    PUSHA
    mov al, 9
    call rtc_get
    movzx r12d, al
    add r12d, 2000                   ; year
    mov al, 8
    call rtc_get
    movzx r13d, al                   ; month
    mov al, 7
    call rtc_get
    movzx r14d, al                   ; day
    ; weekday (Sakamoto): (y + y/4 - y/100 + y/400 + t[m-1] + d) mod 7, y-- for Jan/Feb
    mov esi, r12d
    cmp r13d, 3
    jae .y3
    dec esi
.y3:
    mov ebx, esi
    shr ebx, 2
    add ebx, esi
    mov eax, esi
    xor edx, edx
    mov ecx, 100
    div ecx
    sub ebx, eax
    mov eax, esi
    xor edx, edx
    mov ecx, 400
    div ecx
    add ebx, eax
    lea rdx, [dow_t]
    movzx eax, byte [rdx+r13-1]
    add ebx, eax
    add ebx, r14d
    mov eax, ebx
    xor edx, edx
    mov ecx, 7
    div ecx
    mov rdi, CLKB
    imul esi, edx, 4
    lea rsi, [s_days+rsi]
    call sappend
    mov byte [rdi], ' '
    inc rdi
    mov eax, r14d
    call u2s
    mov byte [rdi], ' '
    inc rdi
    lea eax, [r13-1]
    imul eax, eax, 4
    lea rsi, [s_months+rax]
    call sappend
    mov word [rdi], 0x2020
    add rdi, 2
    mov al, 4
    call rtc_get
    movzx ebx, al
    cmp byte [SB_CLK12], 0
    je .h24
    mov eax, ebx
    xor edx, edx
    mov ecx, 12
    div ecx
    test edx, edx
    jnz .h1
    mov edx, 12
.h1:
    mov eax, edx
    call u2s
    jmp .mn
.h24:
    mov eax, ebx
    mov rdx, rdi
    call put2
.mn:
    mov byte [rdi], ':'
    inc rdi
    mov al, 2
    call rtc_get
    call put2
    cmp byte [SB_CLK12], 0
    je .e
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [s_am]
    cmp ebx, 12
    jb .ap
    lea rsi, [s_pm]
.ap:
    call sappend
.e: mov byte [rdi], 0
    mov al, 2
    call rtc_get
    movzx eax, al
    mov [clk_min], eax
    POPA
    ret


; title of the focused window, or "Centtrix"
focus_title:                        ; -> rsi
    mov eax, [focus]
    test eax, eax
    jz .d
    shl eax, 7
    add rax, TASKS
    mov rsi, [rax+T_TITLE]
    test rsi, rsi
    jnz .r
.d: lea rsi, [s_centtrix]
.r: ret

top_draw:
    PUSHA
    mov esi, SI_TOP
    call gfx_target
    ; bar
    mov eax, 0x30F6F6F8
    cmp byte [SB_THEME], 0
    je .lt
    mov eax, 0x3A1C1C20
.lt:
    cmp byte [SB_BARST], 0
    je .gl
    and eax, 0x00FFFFFF
.gl:
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, TOPH
    call rect
    mov eax, 0x80000000
    cmp byte [SB_THEME], 0
    je .bl
    mov eax, 0x78FFFFFF
    jmp .bl2
.bl:
    mov eax, 0x60000000
.bl2:
    cmp byte [SB_BARST], 0
    jne .bs
    xor ebx, ebx
    mov ecx, TOPH-1
    mov esi, [scr_w]
    mov edx, 1
    mov eax, 0x68808080
    call rect
.bs:
    ; logo
    call logo_ptr20
    mov ebx, 14
    mov ecx, 6
    mov eax, 20
    mov edx, 20
    call argb_blit
    mov dword [tb_lx1], 46
    call chrome_fg
    mov [g_fg], eax
    lea rax, [font_uib]
    mov [g_uf], rax
    ; application name
    call focus_title
    mov ebx, 56
    mov [tb_ax0], ebx
    mov ecx, 6
    push rsi
    call ui_text
    pop rsi
    call ui_width
    add eax, 56
    mov [tb_ax1], eax
    add eax, 18
    mov [tb_wx0], eax
    ; Windows menu title
    lea rax, [font_ui]
    mov [g_uf], rax
    lea rsi, [s_windows]
    mov ebx, [tb_wx0]
    add ebx, 10
    mov ecx, 6
    call ui_text
    call ui_width
    add eax, [tb_wx0]
    add eax, 20
    mov [tb_wx1], eax
    ; right side : clock
    call clock_text
    mov rsi, CLKB
    call ui_width
    mov ebx, [scr_w]
    sub ebx, 16
    sub ebx, eax
    mov [tb_cx0], ebx
    mov eax, [scr_w]
    sub eax, 8
    mov [tb_cx1], eax
    mov ecx, 6
    mov rsi, CLKB
    call ui_text
    ; layout badge (EN / RU / ES) with an accent underline
    lea rax, [font_uib]
    mov [g_uf], rax
    call lay_id
    imul eax, eax, 4
    lea rsi, [s_lay_names+rax]
    call ui_width
    mov r12d, eax
    mov ebx, [tb_cx0]
    sub ebx, 18
    sub ebx, r12d                    ; text x
    lea eax, [rbx-6]
    mov [tb_kx0], eax
    lea eax, [rbx+r12+6]
    mov [tb_kx1], eax
    mov ecx, 6
    push rbx
    call ui_text
    pop rbx
    mov eax, [th_acc]
    mov ecx, 25
    mov esi, r12d
    mov edx, 2
    call rect
    POPA
    ret

; text colour for chrome text drawn on pop-ups
; ================================================================ POP-UP MENU ==
; table entry : dq label, dd action, dd flags      flags 1 sep, 2 disabled, 4 checked
; rsi = table, ecx = count, ebx = anchor x, eax = kind
pm_show:
    PUSHA
    mov [pm_kind], al
    mov [pm_n], ecx
    mov r12d, ebx
    ; copy
    lea rdi, [pm_ent]
    mov edx, ecx
    shl edx, 1
.cp:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec edx
    jnz .cp
    ; size
    lea rax, [font_ui]
    mov [g_uf], rax
    xor r13d, r13d                   ; max width
    xor r14d, r14d                   ; height
    xor ebx, ebx
.sz:
    cmp ebx, [pm_n]
    jae .szd
    mov eax, ebx
    shl eax, 4
    lea rdi, [pm_ent+rax]
    test dword [rdi+12], 1
    jz .it
    add r14d, PM_SH
    jmp .nx
.it:
    add r14d, PM_IH
    mov rsi, [rdi]
    call ui_width
    cmp eax, r13d
    jbe .nx
    mov r13d, eax
.nx:
    inc ebx
    jmp .sz
.szd:
    add r13d, 52
    cmp r13d, 200
    jae .wok
    mov r13d, 200
.wok:
    add r14d, 12
    mov eax, [scr_w]
    sub eax, r13d
    sub eax, 8
    cmp r12d, eax
    jle .xo
    mov r12d, eax
.xo:
    cmp r12d, PMSH+2
    jge .xlo
    mov r12d, PMSH+2
.xlo:
    mov [pm_x], r12d
    mov dword [pm_y], TOPH+2
    mov [pm_w], r13d
    mov [pm_h], r14d
    mov dword [pm_hov], -1
    ; make sure an old pop-up is gone
    cmp byte [pm_open], 0
    je .nw
    mov esi, SI_CARD
    call surf_damage
.nw:
    mov byte [pm_open], 1
    call pm_draw
    POPA
    ret

pm_close:
    cmp byte [pm_open], 0
    je .r
    PUSHA
    mov esi, SI_CARD
    call surf_hide
    mov byte [pm_open], 0
    mov dword [tb_min], -1
    POPA
.r: ret

pm_draw:
    PUSHA
    mov esi, SI_CARD
    mov ebx, [pm_x]
    sub ebx, PMSH
    mov ecx, [pm_y]
    sub ecx, PMSH
    mov eax, [pm_w]
    add eax, 2*PMSH
    mov edx, [pm_h]
    add edx, 2*PMSH
    mov rdi, M_CARD
    ; (the old pixels must be redrawn on screen)
    call surf_damage
    call surf_setup
    mov esi, SI_CARD
    call gfx_target
    call panel_bg
    ; items
    lea rax, [font_ui]
    mov [g_uf], rax
    mov r12d, [pm_y]
    add r12d, 6
    xor r13d, r13d
.li:
    cmp r13d, [pm_n]
    jae .done
    mov eax, r13d
    shl eax, 4
    lea r14, [pm_ent+rax]
    test dword [r14+12], 1
    jz .item
    ; separator
    mov eax, 0x90808088
    mov ebx, [pm_x]
    add ebx, 12
    lea ecx, [r12+5]
    mov esi, [pm_w]
    sub esi, 24
    mov edx, 1
    call rect
    add r12d, PM_SH
    jmp .nx2
.item:
    call chrome_fg
    mov [g_fg], eax
    test dword [r14+12], 2
    jz .en
    cmp byte [SB_THEME], 0
    je .dl
    mov dword [g_fg], 0x8E8E93
    jmp .hv
.dl:
    mov dword [g_fg], 0x8E8E93
    jmp .hv
.en:
    cmp r13d, [pm_hov]
    jne .hv
    mov eax, [th_acc]
    mov ebx, [pm_x]
    add ebx, 5
    mov ecx, r12d
    mov esi, [pm_w]
    sub esi, 10
    mov edx, PM_IH
    mov r9d, 6
    call rrect
    mov dword [g_fg], 0xFFFFFF
.hv:
    mov rsi, [r14]
    mov ebx, [pm_x]
    add ebx, 26
    lea ecx, [r12+3]
    call ui_text
    test dword [r14+12], 4
    jz .nochk
    lea rsi, [s_check]
    mov ebx, [pm_x]
    add ebx, 9
    lea ecx, [r12+3]
    call ui_text
.nochk:
    add r12d, PM_IH
.nx2:
    inc r13d
    jmp .li
.done:
    POPA
    ret


panel_bg:                           ; pm_x/y/w/h, pm_rad ; target already selected
    PUSHA
    ; soft shadow: stacked rings, largest first (each ring replaces the previous one)
    mov r15d, PMSH
.sh:
    mov eax, PMSH
    sub eax, r15d
    imul eax, eax, 3
    add eax, 4                        ; opacity 4..55
    xor eax, 255
    shl eax, 24                       ; TT = 255 - opacity
    mov ebx, [pm_x]
    sub ebx, r15d
    mov ecx, [pm_y]
    sub ecx, r15d
    add ecx, 4
    mov esi, [pm_w]
    lea esi, [rsi+r15*2]
    mov edx, [pm_h]
    lea edx, [rdx+r15*2]
    mov r9d, [pm_rad]
    add r9d, r15d
    mov byte [rr_mode], 1
    call rrect
    mov byte [rr_mode], 0
    dec r15d
    jnz .sh
    ; panel
    mov eax, 0x0CF6F6F8
    cmp byte [SB_THEME], 0
    je .pl
    mov eax, 0x0E2A2A2E
.pl:
    mov ebx, [pm_x]
    mov ecx, [pm_y]
    mov esi, [pm_w]
    mov edx, [pm_h]
    mov r9d, [pm_rad]
    mov byte [rr_mode], 1
    ; rim
    push rax
    mov eax, 0x70808088
    cmp byte [SB_THEME], 0
    je .rm
    mov eax, 0x60FFFFFF
.rm:
    call rrect
    pop rax
    inc ebx
    inc ecx
    sub esi, 2
    sub edx, 2
    mov r9d, [pm_rad]
    dec r9d
    call rrect
    mov byte [rr_mode], 0
    POPA
    ret

; item under the pointer or -1
pm_hit:                             ; -> eax
    PUSHA
    mov eax, [mx]
    mov ebx, [my]
    mov r15d, -1
    cmp eax, [pm_x]
    jl .o
    mov ecx, [pm_x]
    add ecx, [pm_w]
    cmp eax, ecx
    jge .o
    mov r12d, [pm_y]
    add r12d, 6
    cmp ebx, r12d
    jl .o
    xor r13d, r13d
.l: cmp r13d, [pm_n]
    jae .o
    mov eax, r13d
    shl eax, 4
    lea r14, [pm_ent+rax]
    mov ecx, PM_IH
    test dword [r14+12], 1
    jz .h
    mov ecx, PM_SH
.h: lea edx, [r12+rcx]
    cmp ebx, edx
    jl .in
    mov r12d, edx
    inc r13d
    jmp .l
.in:
    test dword [r14+12], 3
    jnz .o
    mov r15d, r13d
.o: mov [pm_tmp], r15d
    POPA
    mov eax, [pm_tmp]
    ret

; ---- menus -----------------------------------------------------------------------
mn_logo:
    dq s_m_about
    dd 1, 0
    dq 0
    dd 0, 1
    dq s_m_settings
    dd 2, 0
    dq s_m_monitor
    dd 3, 0
    dq 0
    dd 0, 1
    dq s_m_lock
    dd 4, 0
    dq s_m_logout
    dd 5, 0
    dq 0
    dd 0, 1
    dq s_m_restart
    dd 6, 0
    dq s_m_shutdown
    dd 7, 0
mn_app:
    dq s_m_min
    dd 8, 0
    dq s_m_center
    dd 9, 0
    dq 0
    dd 0, 1
    dq s_m_close
    dd 10, 0
mn_desk:
    dq s_m_settings
    dd 2, 0
    dq s_m_nextwp
    dd 11, 0
    dq s_m_changelogo
    dd 12, 0
mn_none:
    dq s_m_nowin
    dd 0, 2

open_logo_menu:
    lea rsi, [mn_logo]
    mov ecx, 10
    mov ebx, 8
    mov eax, 1
    call pm_show
    mov dword [tb_min], 0
    ret

open_app_menu:
    cmp dword [focus], 0
    jne .w
    lea rsi, [mn_desk]
    mov ecx, 3
    jmp .s
.w: lea rsi, [mn_app]
    mov ecx, 4
.s: mov ebx, [tb_ax0]
    sub ebx, 10
    mov eax, 2
    call pm_show
    ret

; windows list menu : one entry per running task
open_win_menu:    PUSHA
    lea rdi, [pm_dyn]
    xor r12d, r12d                   ; count
    mov ecx, 1
.l: cmp ecx, NTASK
    jae .d
    mov eax, ecx
    shl eax, 7
    add rax, TASKS
    cmp dword [rax+T_STATE], 1
    jne .n
    mov rdx, [rax+T_TITLE]
    mov [rdi], rdx
    lea edx, [rcx+20]
    mov [rdi+8], edx
    xor edx, edx
    cmp ecx, [focus]
    jne .nf
    mov edx, 4
.nf:
    mov [rdi+12], edx
    add rdi, 16
    inc r12d
.n: inc ecx
    jmp .l
.d: test r12d, r12d
    jnz .ok
    lea rsi, [mn_none]
    mov ecx, 1
    jmp .s
.ok:
    lea rsi, [pm_dyn]
    mov ecx, r12d
.s: mov ebx, [tb_wx0]
    mov eax, 3
    call pm_show
    POPA
    ret

open_clock_menu:
    PUSHA
    lea rdi, [pm_dyn]
    lea rax, [s_c24]
    mov [rdi], rax
    mov dword [rdi+8], 40
    xor eax, eax
    cmp byte [SB_CLK12], 0
    jne .a
    mov eax, 4
.a: mov [rdi+12], eax
    lea rax, [s_c12]
    mov [rdi+16], rax
    mov dword [rdi+24], 41
    xor eax, eax
    cmp byte [SB_CLK12], 0
    je .b
    mov eax, 4
.b: mov [rdi+28], eax
    lea rsi, [pm_dyn]
    mov ecx, 2
    mov ebx, [tb_cx0]
    sub ebx, 20
    mov eax, 4
    call pm_show
    POPA
    ret

; ---- menu actions --------------------------------------------------------------------
menu_do:                            ; eax = action
    PUSHA
    mov r12d, eax
    call pm_close
    cmp r12d, 1
    je .about
    cmp r12d, 2
    je .set
    cmp r12d, 3
    je .mon
    cmp r12d, 4
    je .lock
    cmp r12d, 5
    je .logout
    cmp r12d, 6
    je .rest
    cmp r12d, 7
    je .down
    cmp r12d, 8
    je .min
    cmp r12d, 9
    je .cen
    cmp r12d, 10
    je .cls
    cmp r12d, 11
    je .nwp
    cmp r12d, 12
    je .nlogo
    cmp r12d, 40
    je .c24
    cmp r12d, 41
    je .c12
    cmp r12d, 20
    jb .out
    ; focus a window task
    lea eax, [r12-20]
    mov esi, eax
    shl esi, 7
    add rsi, TASKS
    mov esi, [rsi+T_SURF]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jnz .fo
    or dword [r8+SF_FLG], SFF_VIS|SFF_DIRTY
    call surf_damage
.fo:
    lea eax, [r12-20]
    call focus_set
    jmp .out
.c24:
    mov byte [SB_CLK12], 0
    jmp .clkset
.c12:
    mov byte [SB_CLK12], 1
.clkset:
    mov dword [clk_min], -1
    call top_draw
    call cfg_apply_save
    jmp .out
.about:
    mov ebx, 7
    jmp .setspawn
.set:
    xor ebx, ebx
    jmp .setspawn
.mon:
    mov ebx, 5
.setspawn:
    lea rax, [app_settings]
    mov ecx, 7
    lea rsi, [s_set_t]
    call spawn_replace
    jmp .out
.lock:
    mov byte [want_lock], 1
    jmp .out
.logout:
    mov byte [want_lock], 2
    jmp .out
.rest:
    mov byte [want_power], 1
    jmp .out
.down:
    mov byte [want_power], 2
    jmp .out
.min:
    call wm_min_focused
    jmp .out
.cen:
    mov esi, [focus]
    test esi, esi
    jz .out
    shl esi, 7
    add rsi, TASKS
    mov esi, [rsi+T_SURF]
    mov eax, [scr_w]
    sub eax, WW
    shr eax, 1
    sub eax, SMX
    call win_home_y
    call win_move_to
    jmp .out
.cls:
    mov eax, [focus]
    test eax, eax
    jz .out
    call task_kill
    jmp .out
.nwp:
    movzx eax, byte [SB_WALL]
    inc eax
    cmp eax, WP_N
    jb .w1
    xor eax, eax
.w1:
    call set_wallpaper
    jmp .out
.nlogo:
    movzx eax, byte [SB_LOGO]
    inc eax
    cmp eax, 3
    jb .l1
    xor eax, eax
.l1:
    mov [SB_LOGO], al
    call cfg_apply_save
.out:
    POPA
    ret


; surface y of a window that sits between the menu bar and the dock -> ebx
win_home_y:
    push rax
    mov ebx, [scr_h]
    sub ebx, TOPH+130+WH
    jns .p
    xor ebx, ebx
.p: shr ebx, 1
    add ebx, TOPH+4-SMT
    pop rax
    ret

; spawn, but replace an existing instance of the same kind (so a new argument takes effect)
spawn_replace:                      ; as spawn
    push rcx
    push rdx
    push r8
    mov edx, ecx
    mov ecx, 1
.f: cmp ecx, NTASK
    jae .go
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne .n
    cmp [r8+T_KIND], edx
    jne .n
    push rax
    mov eax, ecx
    call task_kill
    pop rax
    jmp .go
.n: inc ecx
    jmp .f
.go:
    mov ecx, edx
    pop r8
    pop rdx
    add rsp, 8
    call spawn
    ret

; ---- end shell.inc
; ---- begin shell2.inc
; =============================================================================
;  SHELL part 2: dock, settings storage (superblock + readable config file),
;  launcher, the shell loop
; =============================================================================
CFGBUF  equ 0x3A8000


apply_accent:
    push rax
    movzx eax, byte [SB_ACC]
    and eax, 7
    mov eax, [acc_tab+rax*4]
    mov [th_acc], eax
    pop rax
    ret

cfg_clamp:                          ; keep every stored value in range
    push rax
    cmp byte [SB_THEME], 1
    jbe .a
    mov byte [SB_THEME], 0
.a: cmp byte [SB_LOGO], 2
    jbe .b
    mov byte [SB_LOGO], 0
.b: cmp byte [SB_ICST], 3
    jbe .c
    mov byte [SB_ICST], 0
.c: cmp byte [SB_ACC], 7
    jbe .d
    mov byte [SB_ACC], 0
.d: cmp byte [SB_DSZ], 2
    jbe .e
    mov byte [SB_DSZ], 0
.e: cmp byte [SB_CLK12], 1
    jbe .f
    mov byte [SB_CLK12], 0
.f: cmp byte [SB_BARST], 1
    jbe .g
    mov byte [SB_BARST], 0
.g: cmp byte [SB_WALL], WP_N-1
    jbe .h
    mov byte [SB_WALL], 0
.h: cmp byte [SB_LAY2], 1
    jbe .i
    mov byte [SB_LAY2], 0
.i: cmp dword [SB_RESW], 0
    jne .j
    mov dword [SB_RESW], 1024
    mov dword [SB_RESH], 768
.j: movzx eax, byte [SB_DSZ]
    mov eax, [dsz_tab+rax*4]
    mov [dk_isz], eax
    pop rax
    ret

; ---- config file /home/settings.cfg ---------------------------------------------
cfg_tab:                            ; key, field, names, count
    dq k_theme, SB_THEME, n_theme
    dd 2, 0
    dq k_accent, SB_ACC, n_accent
    dd 8, 0
    dq k_wall, SB_WALL, n_wall
    dd WP_N, 0
    dq k_logo, SB_LOGO, n_logo
    dd 3, 0
    dq k_icons, SB_ICST, n_icons
    dd 4, 0
    dq k_dock, SB_DSZ, n_dock
    dd 3, 0
    dq k_clock, SB_CLK12, n_clock
    dd 2, 0
    dq k_bar, SB_BARST, n_bar
    dd 2, 0
    dq k_lay2, SB_LAY2, n_lay2
    dd 2, 0
    dq 0

; write names[idx] of entry rdx -> appended at rdi
cfg_name:                           ; rsi = names, eax = index
    push rcx
.l: test eax, eax
    jz .g
.s: cmp byte [rsi], 0
    je .e
    inc rsi
    jmp .s
.e: inc rsi
    dec eax
    jmp .l
.g: pop rcx
    ret

cfg_write:
    PUSHA
    mov rdi, CFGBUF
    lea rsi, [s_cfg_head]
    call sappend
    lea r12, [cfg_tab]
.l: mov rsi, [r12]
    test rsi, rsi
    jz .d
    call sappend
    mov byte [rdi], '='
    inc rdi
    mov rax, [r12+8]
    movzx eax, byte [rax]
    mov rsi, [r12+16]
    call cfg_name
    call sappend
    mov byte [rdi], 10
    inc rdi
    mov byte [rdi], 0
    add r12, 32
    jmp .l
.d: lea rsi, [p_cfg]
    call fs_create
    test rax, rax
    jz .o
    mov rbx, rax
    mov rsi, CFGBUF
    call strlen
    mov ecx, eax
    mov [rbx+48], ecx
    lea rdi, [rbx+64]
    rep movsb
    mov byte [rdi], 0
    mov rax, rbx
    call fs_save
.o: POPA
    ret

; line parser : applies "key=value" lines found in the file
cfg_load:
    PUSHA
    lea rsi, [p_cfg]
    call fs_find
    test rax, rax
    jz .o
    mov ecx, [rax+48]
    lea rsi, [rax+64]
    mov rdi, CFGBUF
    cmp ecx, 3000
    jbe .c
    mov ecx, 3000
.c: rep movsb
    mov byte [rdi], 0
    mov rsi, CFGBUF
.line:
    cmp byte [rsi], 0
    je .o
    cmp byte [rsi], '#'
    je .skip
    ; key
    mov rbx, rsi
.k: mov al, [rsi]
    test al, al
    jz .o
    cmp al, '='
    je .eq
    cmp al, 10
    je .skip
    inc rsi
    jmp .k
.eq:
    mov byte [rsi], 0
    inc rsi
    mov r13, rsi                    ; value
.v: mov al, [rsi]
    test al, al
    jz .have
    cmp al, 10
    je .have
    cmp al, 13
    je .have
    inc rsi
    jmp .v
.have:
    mov r14b, [rsi]
    mov byte [rsi], 0
    push rsi
    ; find entry
    lea r12, [cfg_tab]
.f: mov rdi, [r12]
    test rdi, rdi
    jz .nf
    mov rsi, rbx
    push rdi
    mov rdi, rsi
    pop rsi
    ; strcmp(rsi=table key, rdi=file key)
    push rax
    push rcx
.cmp:
    mov al, [rsi]
    cmp al, [rdi]
    jne .ne
    test al, al
    jz .hit
    inc rsi
    inc rdi
    jmp .cmp
.hit:
    pop rcx
    pop rax
    jmp .got
.ne:
    pop rcx
    pop rax
    add r12, 32
    jmp .f
.got:
    ; value -> index
    mov rsi, [r12+16]
    xor edx, edx
.n: cmp byte [rsi], 0
    je .nonum
    mov rdi, r13
    push rsi
.c2:
    mov al, [rsi]
    cmp al, [rdi]
    jne .n2
    test al, al
    jz .m
    inc rsi
    inc rdi
    jmp .c2
.n2:
    pop rsi
.sk:
    cmp byte [rsi], 0
    je .e2
    inc rsi
    jmp .sk
.e2:
    inc rsi
    inc edx
    jmp .n
.m: pop rsi
    cmp edx, [r12+24]
    jae .nf
    mov rax, [r12+8]
    mov [rax], dl
    jmp .nf
.nonum:
.nf:
    pop rsi
    mov [rsi], r14b
.skip:
    cmp byte [rsi], 0
    je .o
    cmp byte [rsi], 10
    je .nl
    inc rsi
    jmp .skip
.nl:
    inc rsi
    jmp .line
.o: POPA
    ret

cfg_apply_save:                     ; settings changed: persist + redraw chrome
    PUSHA
    call cfg_clamp
    call sb_save
    call cfg_write
    POPA
    ret

; refresh everything that depends on theme / accent / icon style / dock size
chrome_refresh:
    PUSHA
    call cfg_clamp
    call apply_theme
    call icons_build
    call dock_build
    call top_draw
    POPA
    ret

set_wallpaper:                      ; eax = index
    PUSHA
    mov [SB_WALL], al
    movzx eax, al
    call wp_gen
    call desk_draw
    call cfg_apply_save
    POPA
    ret

; ================================================================ DOCK =========
dock_build:
    PUSHA
    mov esi, SI_DOCK
    cmp dword [dk_w], 0
    je .nw
    call surf_damage
.nw:
    mov r12d, [dk_isz]
    lea eax, [r12+DKGAP]
    mov [dk_step], eax
    imul eax, eax, DK_ITEMS
    sub eax, DKGAP
    add eax, 2*DKPAD
    mov [dk_sw], eax
    lea edx, [r12+DKPY+34]
    mov [dk_sh], edx
    mov ebx, [scr_w]
    sub ebx, eax
    shr ebx, 1
    mov [dk_sx], ebx
    mov ecx, [scr_h]
    sub ecx, edx
    sub ecx, 2
    mov [dk_sy], ecx
    mov rdi, M_DOCK
    mov esi, SI_DOCK
    call surf_setup
    mov eax, [dk_sx]
    mov [dk_x], eax
    add eax, DKPAD
    mov [dk_x0], eax
    mov eax, [dk_sy]
    add eax, DKPY
    mov [dk_y], eax
    lea eax, [r12+26]
    mov [dk_h], eax
    mov eax, [dk_sw]
    mov [dk_w], eax
    mov dword [dk_n], DK_ITEMS
    call dock_draw
    POPA
    ret

; kinds currently running -> bitmask
dock_sig_calc:
    push rcx
    push rdx
    push r8
    xor edx, edx
    mov ecx, 1
.l: cmp ecx, NTASK
    jae .d
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne .n
    mov eax, [r8+T_KIND]
    and eax, 15
    bts edx, eax
.n: inc ecx
    jmp .l
.d: mov eax, edx
    pop r8
    pop rdx
    pop rcx
    ret

dock_draw:
    PUSHA
    mov esi, SI_DOCK
    call gfx_target
    mov r12d, [dk_isz]
    ; clear
    mov eax, 0xFF000000
    mov ebx, [dk_sx]
    mov ecx, [dk_sy]
    mov esi, [dk_sw]
    mov edx, [dk_sh]
    call rect
    ; pill
    mov eax, 0x50FFFFFF
    mov r13d, 0x70FFFFFF
    cmp byte [SB_THEME], 0
    je .pc
    mov eax, 0x4A2B2B30
    mov r13d, 0x70808090
.pc:
    mov ebx, [dk_sx]
    mov ecx, [dk_sy]
    add ecx, DKPY
    mov esi, [dk_sw]
    lea edx, [r12+26]
    mov r9d, 24
    mov byte [rr_mode], 1
    push rax
    mov eax, r13d
    call rrect
    pop rax
    inc ebx
    inc ecx
    sub esi, 2
    sub edx, 2
    mov r9d, 23
    call rrect
    mov byte [rr_mode], 0
    ; icons
    call dock_sig_calc
    mov r14d, eax
    xor r13d, r13d
.ic:
    cmp r13d, DK_ITEMS
    jae .tip
    mov eax, [dk_step]
    imul eax, r13d
    add eax, [dk_x0]
    mov ebx, eax
    mov ecx, [dk_sy]
    add ecx, DKPY+9
    cmp r13d, [dk_hov]
    jne .nl
    sub ecx, 10
.nl:
    mov esi, r13d
    shl esi, 15
    add rsi, ICA
    mov eax, r12d
    mov edx, r12d
    push rbx
    call argb_blit
    pop rbx
    ; running dot
    cmp r13d, 7
    jae .nd
    mov eax, [dk_task_kind+r13*4]
    bt r14d, eax
    jnc .nd
    mov eax, r12d
    shr eax, 1
    lea ebx, [rbx+rax-2]
    mov ecx, [dk_sy]
    add ecx, DKPY+9
    add ecx, r12d
    add ecx, 8
    mov eax, 0x00F2F2F7
    cmp byte [SB_THEME], 0
    jne .dc
    mov eax, 0x00303034
.dc:
    mov esi, 5
    mov edx, 5
    push r9
    mov r9d, 2
    call rrect
    pop r9
.nd:
    inc r13d
    jmp .ic
.tip:
    ; divider before the trash can
    mov eax, [dk_step]
    imul eax, 7
    add eax, [dk_x0]
    sub eax, DKGAP/2
    mov ebx, eax
    mov ecx, [dk_sy]
    add ecx, DKPY+14
    mov esi, 1
    lea edx, [r12-12]
    mov eax, 0x80909098
    call rect
    ; tooltip
    mov eax, [dk_hov]
    test eax, eax
    js .o
    imul eax, eax, 12
    lea r13, [s_dk_names+rax]
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, r13
    call ui_width
    lea r14d, [rax+22]               ; bubble width
    mov eax, [dk_step]
    imul eax, [dk_hov]
    add eax, [dk_x0]
    mov ebx, r12d
    shr ebx, 1
    add ebx, eax
    mov eax, r14d
    shr eax, 1
    sub ebx, eax
    mov ecx, [dk_sy]
    add ecx, 2
    mov esi, r14d
    mov edx, 26
    mov eax, 0x30202024
    cmp byte [SB_THEME], 0
    jne .tb
    mov eax, 0x28202024
.tb:
    mov r9d, 8
    push rbx
    call rrect
    pop rbx
    mov dword [g_fg], 0xFFFFFF
    mov rsi, r13
    add ebx, 11
    mov ecx, [dk_sy]
    add ecx, 5
    call ui_text
.o: POPA
    ret


; hovered dock item or -1
dock_hit:
    mov eax, [dk_w]
    test eax, eax
    jz .no
    mov eax, [mx]
    cmp eax, [dk_x]
    jl .no
    mov ecx, [dk_x]
    add ecx, [dk_w]
    cmp eax, ecx
    jge .no
    mov ecx, [my]
    cmp ecx, [dk_y]
    jl .no
    mov edx, [dk_y]
    add edx, [dk_h]
    cmp ecx, edx
    jge .no
    sub eax, [dk_x0]
    jl .no
    xor edx, edx
    div dword [dk_step]
    cmp eax, DK_ITEMS
    jae .no
    cmp edx, [dk_isz]
    jae .no
    ret
.no: mov eax, -1
    ret

; ================================================================ LAUNCHER =======
; eax = dock index (0..7)
launch_app:
    PUSHA
    mov ebx, 0
    cmp eax, 7
    jne .n
    mov ebx, 1                       ; trash = Files at /dump
    xor eax, eax
.n: imul edx, eax, 24
    lea rdx, [app_tab+rdx]
    mov rax, [rdx]
    mov ecx, [rdx+8]
    mov rsi, [rdx+16]
    test ebx, ebx
    jz .go
    mov ecx, 8                       ; separate kind so Files and Trash can both be open
.go:
    call spawn
    POPA
    ret
app_tab:
    dq app_files
    dd 1, 0
    dq s_files_t
    dq app_term
    dd 2, 0
    dq s_term_t
    dq app_editor
    dd 3, 0
    dq s_ed_t
    dq app_browser
    dd 4, 0
    dq s_br_t
    dq app_images
    dd 5, 0
    dq s_im_t
    dq app_paint
    dd 6, 0
    dq s_paint_t
    dq app_settings
    dd 7, 0
    dq s_set_t

; ================================================================ SHELL LOOP ======
shell_init:
    PUSHA
    call cfg_clamp
    call apply_theme
    call icons_build
    call top_init
    call dock_build
    mov dword [clk_min], -1
    POPA
    ret

shell_step:                         ; one pass of the shell (called from the idle loop)
    PUSHA
    mov eax, [focus]
    cmp eax, [tb_focus]
    je .nofoc
    mov [tb_focus], eax
    call top_draw
.nofoc:
    ; ---- clock / badge refresh
    inc dword [sh_tick]
    test dword [sh_tick], 31
    jnz .nock
    mov al, 2
    call rtc_get
    movzx eax, al
    cmp eax, [clk_min]
    je .nock
    call top_draw
.nock:
    ; ---- dock launches
    mov eax, [launch_req]
    test eax, eax
    jz .nl
    mov dword [launch_req], 0
    dec eax
    call pm_close
    call launch_app
.nl:
    ; ---- running-dot changes
    call dock_sig_calc
    cmp eax, [dk_sig]
    je .nsig
    mov [dk_sig], eax
    call dock_draw
.nsig:
    ; ---- hover
    mov eax, [m_ev]
    cmp eax, [last_mev]
    je .nh
    mov [last_mev], eax
    call dock_hit
    cmp eax, [dk_hov]
    je .dh2
    mov [dk_hov], eax
    call dock_draw
.dh2:
    cmp byte [pm_open], 0
    je .nh
    call pm_hit
    cmp eax, [pm_hov]
    je .nh
    mov [pm_hov], eax
    call pm_draw
.nh:
    ; ---- top bar click
    mov eax, [top_click]
    test eax, eax
    jz .ntc
    dec eax
    mov dword [top_click], 0
    call top_hit
.ntc:
    ; ---- click while a pop-up is open
    cmp byte [pm_ev], 0
    je .npe
    mov byte [pm_ev], 0
    call pm_hit_xy
    cmp eax, 0
    jl .dis
    mov eax, [pm_hit_item]
    call pm_pick
    jmp .npe
.dis:
    cmp dword [pm_cy], TOPH
    jge .cl
    mov eax, [pm_cx]
    call top_hit                     ; clicking a menu title switches menus
    jmp .npe
.cl:
    call pm_close
.npe:
    ; ---- desktop click (empty area)
    cmp byte [desk_click], 0
    je .nd
    mov byte [desk_click], 0
    call desk_clicked
.nd:
    ; ---- lock / power requests
    cmp byte [want_power], 0
    je .np
    call do_power
.np:
    cmp byte [want_lock], 0
    je .o
    call do_lock
.o: POPA
    ret

; which top-bar title is at x (eax) : open its menu (or close if already open)
top_hit:
    PUSHA
    mov r12d, eax
    movzx r13d, byte [pm_kind]
    cmp r12d, [tb_lx1]
    jl .logo
    cmp r12d, [tb_ax0]
    jl .none
    cmp r12d, [tb_wx0]
    jl .app
    cmp r12d, [tb_wx1]
    jl .win
    cmp r12d, [tb_kx0]
    jl .none
    cmp r12d, [tb_kx1]
    jl .lay
    cmp r12d, [tb_cx0]
    jl .none
    mov r14d, 4
    jmp .go
.logo:
    mov r14d, 1
    jmp .go
.app:
    mov r14d, 2
    jmp .go
.win:
    mov r14d, 3
    jmp .go
.lay:
    call pm_close
    xor byte [lay_cur], 1
    call top_draw
    jmp .o
.none:
    call pm_close
    jmp .o
.go:
    cmp byte [pm_open], 0
    je .op
    cmp r13d, r14d
    jne .op
    call pm_close
    jmp .o
.op:
    cmp r14d, 1
    jne .a2
    call open_logo_menu
    jmp .o
.a2:
    cmp r14d, 2
    jne .a3
    call open_app_menu
    jmp .o
.a3:
    cmp r14d, 3
    jne .a4
    call open_win_menu
    jmp .o
.a4:
    call open_clock_menu
.o: POPA
    ret
pm_hit_xy:                          ; uses the pressed position (pm_cx, pm_cy) -> eax item or -1
    push rbx
    push rcx
    push rdx
    mov eax, [mx]
    mov ebx, [my]
    push rax
    push rbx
    mov eax, [pm_cx]
    mov [mx], eax
    mov eax, [pm_cy]
    mov [my], eax
    call pm_hit
    mov [pm_hit_item], eax
    pop rbx
    pop rax
    mov [mx], eax
    mov [my], ebx
    mov eax, [pm_hit_item]
    pop rdx
    pop rcx
    pop rbx
    ret

pm_pick:                            ; eax = item index
    PUSHA
    shl eax, 4
    mov eax, [pm_ent+rax+8]
    call menu_do
    POPA
    ret

desk_clicked:
    PUSHA
    call pm_close
    call desk_icon_click
    POPA
    ret

; ---- power ------------------------------------------------------------------------
do_power:
    PUSHA
    movzx r12d, byte [want_power]
    mov byte [want_power], 0
    cmp r12d, 1
    jne .down
    ; restart through the keyboard controller
.w: in al, 0x64
    test al, 2
    jnz .w
    mov al, 0xFE
    out 0x64, al
    jmp $
.down:
    mov ax, 0x2000
    mov dx, 0x604
    out dx, ax                       ; QEMU / Bochs ACPI power-off
    mov dx, 0xB004
    out dx, ax
    ; still running: no ACPI power-off available here -> tell the truth
    call safe_screen
    POPA
    ret

safe_screen:
    PUSHA
    mov esi, SI_BASE
    call gfx_target
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, [scr_h]
    call rect
    mov dword [g_fg], 0xE8E8E8
    lea rax, [font_ui]
    mov [g_uf], rax
    lea rsi, [s_safe]
    mov ecx, [scr_h]
    shr ecx, 1
    sub ecx, 10
    mov ebx, [scr_w]
    shr ebx, 1
    call ui_text_c
    mov byte [pm_open], 0
    call hide_all_surfaces
    call damage_all
    call wm_flush
    cli
    hlt
    jmp $
    POPA
    ret

hide_all_surfaces:
    push rax
    push rcx
    push r8
    mov ecx, 2
.l: mov r8d, ecx
    shl r8d, 7
    add r8, SURFS
    mov dword [r8+SF_FLG], 0
    inc ecx
    cmp ecx, 13
    jb .l
    pop r8
    pop rcx
    pop rax
    ret

; ---- lock / log out ---------------------------------------------------------------------
do_lock:
    PUSHA
    movzx r12d, byte [want_lock]
    mov byte [want_lock], 0
    cmp r12d, 2
    jne .lk
    ; log out : close every window
    mov ecx, 1
.k: cmp ecx, NTASK
    jae .lk
    mov eax, ecx
    shl eax, 7
    add rax, TASKS
    cmp dword [rax+T_STATE], 1
    jne .n
    mov eax, ecx
    call task_free
.n: inc ecx
    jmp .k
.lk:
    call login_screen
    POPA
    ret

; ---- end shell2.inc
; ---- begin shell3.inc
; =============================================================================
;  SHELL part 3: blend rectangle, desktop icons, lock/login, splash
; =============================================================================
; blended rectangle: ebx=x ecx=y esi=w edx=h eax=0xTTRRGGBB (TT = transparency)
rect_a:
    PUSHA
    test esi, esi
    jle .o
    test edx, edx
    jle .o
    mov r10d, eax
    mov r11d, eax
    shr r11d, 24
    xor r11d, 255                     ; alpha
    jz .o
    and r10d, 0xFFFFFF
    mov r12d, esi
    mov r13d, edx
    mov r8d, ebx
    mov r9d, ecx
    call mark_dirty
    mov rax, [cur_pitch]
    imul rax, r9
    lea rdi, [rax+r8*4]
    add rdi, [cur_fb]
.row:
    mov r15, rdi
    mov r14d, r12d
.px:
    mov edx, r11d
    call plot_a
    add r15, 4
    dec r14d
    jnz .px
    add rdi, [cur_pitch]
    dec r13d
    jnz .row
.o: POPA
    ret

; ================================================================ DESKTOP ICONS ===
DSX     equ 36
DSY     equ 56
DSH     equ 104
DSW     equ 100

desk_count:                         ; icons = Home + shortcuts
    call scut_load
    mov eax, [scut_n]
    inc eax
    mov [ds_cnt], eax
    ret

; position of icon eax -> ebx=x ecx=y
desk_pos:
    push rdx
    push rsi
    mov esi, eax
    mov eax, [scr_h]
    sub eax, DSY+20
    sub eax, [dk_sh]
    xor edx, edx
    mov ecx, DSH
    div ecx                           ; rows per column
    test eax, eax
    jnz .r
    mov eax, 1
.r: mov ecx, eax
    mov eax, esi
    xor edx, edx
    div ecx                           ; eax = column, edx = row
    imul ebx, eax, DSW
    add ebx, DSX
    imul ecx, edx, DSH
    add ecx, DSY
    pop rsi
    pop rdx
    ret

desk_draw:
    PUSHA
    call base_from_wall
    mov esi, SI_BASE
    call gfx_target
    call desk_count
    xor r12d, r12d
.l: cmp r12d, [ds_cnt]
    jae .o
    mov eax, r12d
    call desk_pos
    mov r13d, ebx
    mov r14d, ecx
    cmp r12d, [ds_sel]
    jne .ns
    mov eax, 0x78FFFFFF
    cmp byte [SB_THEME], 0
    je .hl
    mov eax, 0x70FFFFFF
.hl:
    lea ebx, [r13-14]
    lea ecx, [r14-6]
    mov esi, DSW-8
    mov edx, DSH-8
    mov r9d, 12
    ; tinted selection (translucent white)
    mov eax, 0x68FFFFFF
    call rect_a
.ns:
    mov eax, [dk_isz]
    test r12d, r12d
    jnz .sc
    ; Home : the home glyph tile from the atlas
    mov rsi, ICA+15*IC_STR
    mov ebx, r13d
    mov ecx, r14d
    mov eax, [dk_isz]
    mov edx, eax
    call argb_blit
    lea rsi, [s_home_l]
    jmp .lab
.sc:
    lea eax, [r12-1]
    call scut_name                    ; TMPB, edx colour
    mov [ds_col], edx
    ; tile
    mov eax, [ds_col]
    mov ebx, r13d
    mov ecx, r14d
    mov esi, [dk_isz]
    mov edx, esi
    mov r9d, 13
    call rrect
    ; letter
    lea rax, [font_uil]
    mov [g_uf], rax
    mov dword [g_fg], 0xFFFFFF
    movzx eax, byte [sc_letter]
    mov [ds_ltr], al
    mov byte [ds_ltr+1], 0
    lea rsi, [ds_ltr]
    mov ebx, [dk_isz]
    shr ebx, 1
    add ebx, r13d
    mov ecx, [dk_isz]
    shr ecx, 1
    add ecx, r14d
    sub ecx, 19
    call ui_text_c
    mov rsi, TMPB
.lab:
    ; label with a soft shadow
    push rsi
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, [dk_isz]
    shr eax, 1
    lea ebx, [r13+rax+1]
    mov ecx, [dk_isz]
    lea ecx, [r14+rcx+9]
    mov dword [g_fg], 0x30000000
    call ui_text_c
    mov dword [g_fg], 0x000000
    mov eax, [dk_isz]
    shr eax, 1
    lea ebx, [r13+rax+1]
    mov ecx, [dk_isz]
    lea ecx, [r14+rcx+10]
    call ui_text_c
    pop rsi
    mov dword [g_fg], 0xFFFFFF
    mov eax, [dk_isz]
    shr eax, 1
    lea ebx, [r13+rax]
    mov ecx, [dk_isz]
    lea ecx, [r14+rcx+8]
    call ui_text_c
    inc r12d
    jmp .l
.o: call damage_all
    POPA
    ret

desk_hit:                           ; -> eax = icon index under the pointer or -1
    PUSHA
    mov r15d, -1
    call desk_count
    xor r12d, r12d
.l: cmp r12d, [ds_cnt]
    jae .o
    mov eax, r12d
    call desk_pos
    mov eax, [mx]
    sub eax, ebx
    add eax, 12
    js .n
    cmp eax, DSW-14
    jge .n
    mov eax, [my]
    sub eax, ecx
    add eax, 4
    js .n
    cmp eax, DSH-8
    jge .n
    mov r15d, r12d
    jmp .o
.n: inc r12d
    jmp .l
.o: mov [pm_tmp], r15d
    POPA
    mov eax, [pm_tmp]
    ret

desk_icon_click:
    PUSHA
    call desk_hit
    mov r12d, eax
    cmp r12d, [ds_sel]
    jne .sel
    test r12d, r12d
    js .o
    ; second click on the selected icon within about a second = open
    xor eax, eax
    call rtc_get
    movzx ebx, al
    mov eax, [ds_lsec]
    sub ebx, eax
    jns .d
    add ebx, 60
.d: cmp ebx, 1
    ja .again
    mov dword [ds_sel], -1
    call desk_draw
    test r12d, r12d
    jnz .sc
    xor eax, eax
    call launch_app
    jmp .o
.sc:
    lea eax, [r12-1]
    call scut_run_task
    jmp .o
.again:
.sel:
    mov [ds_sel], r12d
    xor eax, eax
    call rtc_get
    movzx eax, al
    mov [ds_lsec], eax
    call desk_draw
.o: POPA
    ret

; shortcuts open through the generic file launcher
scut_run_task:                      ; eax = index
    PUSHA
    call scut_run
    POPA
    ret

; ================================================================ LOCK / LOGIN ===

lock_begin:
    PUSHA
    call pm_close
    mov eax, [focus]
    mov [lk_focus], eax
    mov eax, [dk_w]
    mov [lk_dkw], eax
    mov dword [dk_w], 0
    mov ecx, 2
.l: mov r8d, ecx
    shl r8d, 7
    add r8, SURFS
    mov eax, [r8+SF_FLG]
    mov [lk_flags+rcx*4], eax
    test eax, SFF_VIS
    jz .n
    mov esi, ecx
    call surf_damage
    mov dword [r8+SF_FLG], 0
.n: inc ecx
    cmp ecx, 13
    jb .l
    xor eax, eax
    call focus_set
    mov dword [top_click], 0
    mov dword [launch_req], 0
    POPA
    ret

lock_end:
    PUSHA
    mov esi, SI_CARD
    call surf_hide
    mov ecx, 2
.l: mov r8d, ecx
    shl r8d, 7
    add r8, SURFS
    mov eax, [lk_flags+rcx*4]
    test eax, SFF_VIS
    jz .n
    or eax, SFF_DIRTY
    mov [r8+SF_FLG], eax
    mov esi, ecx
    call surf_damage
.n: inc ecx
    cmp ecx, 13
    jb .l
    mov eax, [lk_dkw]
    mov [dk_w], eax
    mov eax, [lk_focus]
    call focus_set
    mov dword [top_click], 0
    mov dword [launch_req], 0
    mov byte [desk_click], 0
    mov byte [pm_ev], 0
    POPA
    ret

; the card : rsi = subtitle, ecx = height
LGW equ 380
lg_card:
    PUSHA
    mov [lg_sub], rsi
    mov [pm_h], ecx
    mov dword [pm_w], LGW
    mov dword [pm_rad], 18
    mov eax, [scr_w]
    sub eax, LGW
    shr eax, 1
    mov [pm_x], eax
    mov eax, [scr_h]
    sub eax, ecx
    shr eax, 1
    sub eax, 20
    mov [pm_y], eax
    mov esi, SI_CARD
    mov ebx, [pm_x]
    sub ebx, PMSH
    mov ecx, [pm_y]
    sub ecx, PMSH
    mov eax, LGW+2*PMSH
    mov edx, [pm_h]
    add edx, 2*PMSH
    mov rdi, M_CARD
    call surf_setup
    mov esi, SI_CARD
    call gfx_target
    call panel_bg
    ; logo
    call logo_ptr64
    mov ebx, [pm_x]
    add ebx, LGW/2-32
    mov ecx, [pm_y]
    add ecx, 26
    mov eax, 64
    mov edx, 64
    call argb_blit
    call chrome_fg
    mov [g_fg], eax
    lea rax, [font_uib]
    mov [g_uf], rax
    lea rsi, [s_centtrix]
    mov ebx, [pm_x]
    add ebx, LGW/2
    mov ecx, [pm_y]
    add ecx, 100
    call ui_text_c
    mov dword [g_fg], 0x8E8E93
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, [lg_sub]
    mov ebx, [pm_x]
    add ebx, LGW/2
    mov ecx, [pm_y]
    add ecx, 124
    call ui_text_c
    POPA
    ret

; input box : rsi=label rdi=buf edx=mask ecx=y offset in card -> eax=len
lg_field:
    PUSHA
    mov r12, rdi
    mov r13d, edx
    mov r14d, ecx
    add r14d, [pm_y]
    mov r15, rsi
    xor ebp, ebp                     ; length
.draw:
    ; label
    mov dword [g_fg], 0x8E8E93
    lea rax, [font_uis]
    mov [g_uf], rax
    mov rsi, r15
    mov ebx, [pm_x]
    add ebx, 30
    lea ecx, [r14-18]
    call ui_text
    ; box
    mov eax, 0xC9C9D2
    cmp byte [SB_THEME], 0
    je .bx0
    mov eax, 0x55555C
.bx0:
    mov ebx, [pm_x]
    add ebx, 30
    mov ecx, r14d
    mov esi, LGW-60
    mov edx, 34
    mov r9d, 9
    call rrect
    mov eax, 0xFFFFFF
    cmp byte [SB_THEME], 0
    je .bx
    mov eax, 0x2C2C30
.bx:
    inc ebx
    inc ecx
    sub esi, 2
    sub edx, 2
    mov r9d, 8
    call rrect
    mov ebx, [pm_x]
    add ebx, 30
    call chrome_fg
    mov [g_fg], eax
    lea rax, [font_ui]
    mov [g_uf], rax
    ; text (or bullets)
    mov rdi, TMPB
    xor ecx, ecx
.cp:
    cmp ecx, ebp
    jae .ed
    mov al, [r12+rcx]
    test r13d, r13d
    jz .ok
    mov al, 127
.ok:
    mov [rdi+rcx], al
    inc ecx
    jmp .cp
.ed:
    mov byte [rdi+rcx], 0
    mov rsi, TMPB
    mov ebx, [pm_x]
    add ebx, 42
    lea ecx, [r14+7]
    call ui_text
    mov rsi, TMPB
    call ui_width
    mov ebx, [pm_x]
    lea ebx, [rbx+rax+43]
    mov eax, [th_acc]
    lea ecx, [r14+8]
    mov esi, 2
    mov edx, 18
    call rect
.key:
    call getkey
    cmp al, 13
    je .ok2
    cmp al, 8
    je .bs
    cmp al, 32
    jb .key
    cmp al, 0xDF
    ja .key
    cmp ebp, 24
    jae .key
    mov [r12+rbp], al
    inc ebp
    jmp .draw
.bs:
    test ebp, ebp
    jz .key
    dec ebp
    jmp .draw
.ok2:
    test ebp, ebp
    jz .key
    mov byte [r12+rbp], 0
    mov [lg_len], ebp
    POPA
    mov eax, [lg_len]
    ret

login_screen:
    PUSHA
    call lock_begin
    mov byte [sudo_on], 0
    cmp dword [SBBUF+4], 0x31525355
    je .have
.s1:
    lea rsi, [s_welcome]
    mov ecx, 420
    call lg_card
    lea rsi, [s_l_user]
    mov rdi, PWA
    xor edx, edx
    mov ecx, 170
    call lg_field
    lea rsi, [s_l_pass]
    mov rdi, PWB
    mov edx, 1
    mov ecx, 232
    call lg_field
    lea rsi, [s_l_rep]
    mov rdi, PWC
    mov edx, 1
    mov ecx, 294
    call lg_field
    mov rsi, PWB
    mov rdi, PWC
    call strcmp
    jne .s1
    lea rdi, [SB_USER]
    mov rsi, PWA
    call strcpy
    mov rsi, PWB
    call hash_str
    mov [SB_HASH], eax
    mov dword [SBBUF+4], 0x31525355
    call sb_save
    jmp .out
.have:
    mov byte [lk_bad], 0
.h1:
    lea rsi, [SB_USER]
    mov ecx, 290
    call lg_card
    cmp byte [lk_bad], 0
    je .nm
    mov dword [g_fg], 0xE5483D
    lea rax, [font_ui]
    mov [g_uf], rax
    lea rsi, [s_wrong]
    mov ebx, [pm_x]
    add ebx, LGW/2
    mov ecx, [pm_y]
    add ecx, 252
    call ui_text_c
.nm:
    lea rsi, [s_l_pass]
    mov rdi, PWA
    mov edx, 1
    mov ecx, 190
    call lg_field
    mov rsi, PWA
    call hash_str
    cmp eax, [SB_HASH]
    je .out
    mov byte [lk_bad], 1
    jmp .h1
.out:
    call lock_end
    POPA
    ret

; ================================================================ SPLASH =========
splash_screen:
    PUSHA
    mov esi, SI_BASE
    call gfx_target
    mov eax, 0x0C0C10
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, [scr_h]
    call rect
    lea rsi, [logo_monol_64]
    cmp byte [SB_LOGO], 1
    je .lg
    call logo_ptr64
.lg:
    mov ebx, [scr_w]
    shr ebx, 1
    sub ebx, 32
    mov ecx, [scr_h]
    shr ecx, 1
    sub ecx, 90
    mov eax, 64
    mov edx, 64
    call argb_blit
    lea rax, [font_uil]
    mov [g_uf], rax
    mov dword [g_fg], 0xF2F2F7
    lea rsi, [s_centtrix]
    mov ebx, [scr_w]
    shr ebx, 1
    mov ecx, [scr_h]
    shr ecx, 1
    add ecx, 0
    call ui_text_c
    ; progress bar
    mov r12d, [scr_w]
    shr r12d, 1
    sub r12d, 80
    mov r13d, [scr_h]
    shr r13d, 1
    add r13d, 60
    mov eax, 0x2A2A30
    mov ebx, r12d
    mov ecx, r13d
    mov esi, 160
    mov edx, 5
    mov r9d, 2
    call rrect
    mov r14d, 1
.st:
    mov eax, 0xF2F2F7
    mov ebx, r12d
    mov ecx, r13d
    mov esi, r14d
    imul esi, esi, 8
    mov edx, 5
    mov r9d, 2
    call rrect
    call damage_all
    call wm_flush
    call wait_tick
    inc r14d
    cmp r14d, 20
    jbe .st
    POPA
    ret

; ---- end shell3.inc
; ---- begin sin512.inc
sin512:
    dw 0,13,25,38,50,63,75,88,100,113,125,138,150,163,175,187
    dw 200,212,224,237,249,261,273,285,297,309,321,333,345,357,369,380
    dw 392,403,415,426,438,449,460,472,483,494,505,516,526,537,548,558
    dw 569,579,590,600,610,620,630,640,650,659,669,678,688,697,706,715
    dw 724,733,742,750,759,767,775,784,792,799,807,815,822,830,837,844
    dw 851,858,865,872,878,885,891,897,903,909,915,920,926,931,936,941
    dw 946,951,955,960,964,968,972,976,980,983,987,990,993,996,999,1002
    dw 1004,1007,1009,1011,1013,1015,1016,1018,1019,1020,1021,1022,1023,1023,1024,1024
    dw 1024,1024,1024,1023,1023,1022,1021,1020,1019,1018,1016,1015,1013,1011,1009,1007
    dw 1004,1002,999,996,993,990,987,983,980,976,972,968,964,960,955,951
    dw 946,941,936,931,926,920,915,909,903,897,891,885,878,872,865,858
    dw 851,844,837,830,822,815,807,799,792,784,775,767,759,750,742,733
    dw 724,715,706,697,688,678,669,659,650,640,630,620,610,600,590,579
    dw 569,558,548,537,526,516,505,494,483,472,460,449,438,426,415,403
    dw 392,380,369,357,345,333,321,309,297,285,273,261,249,237,224,212
    dw 200,187,175,163,150,138,125,113,100,88,75,63,50,38,25,13
    dw 0,-13,-25,-38,-50,-63,-75,-88,-100,-113,-125,-138,-150,-163,-175,-187
    dw -200,-212,-224,-237,-249,-261,-273,-285,-297,-309,-321,-333,-345,-357,-369,-380
    dw -392,-403,-415,-426,-438,-449,-460,-472,-483,-494,-505,-516,-526,-537,-548,-558
    dw -569,-579,-590,-600,-610,-620,-630,-640,-650,-659,-669,-678,-688,-697,-706,-715
    dw -724,-733,-742,-750,-759,-767,-775,-784,-792,-799,-807,-815,-822,-830,-837,-844
    dw -851,-858,-865,-872,-878,-885,-891,-897,-903,-909,-915,-920,-926,-931,-936,-941
    dw -946,-951,-955,-960,-964,-968,-972,-976,-980,-983,-987,-990,-993,-996,-999,-1002
    dw -1004,-1007,-1009,-1011,-1013,-1015,-1016,-1018,-1019,-1020,-1021,-1022,-1023,-1023,-1024,-1024
    dw -1024,-1024,-1024,-1023,-1023,-1022,-1021,-1020,-1019,-1018,-1016,-1015,-1013,-1011,-1009,-1007
    dw -1004,-1002,-999,-996,-993,-990,-987,-983,-980,-976,-972,-968,-964,-960,-955,-951
    dw -946,-941,-936,-931,-926,-920,-915,-909,-903,-897,-891,-885,-878,-872,-865,-858
    dw -851,-844,-837,-830,-822,-815,-807,-799,-792,-784,-775,-767,-759,-750,-742,-733
    dw -724,-715,-706,-697,-688,-678,-669,-659,-650,-640,-630,-620,-610,-600,-590,-579
    dw -569,-558,-548,-537,-526,-516,-505,-494,-483,-472,-460,-449,-438,-426,-415,-403
    dw -392,-380,-369,-357,-345,-333,-321,-309,-297,-285,-273,-261,-249,-237,-224,-212
    dw -200,-187,-175,-163,-150,-138,-125,-113,-100,-88,-75,-63,-50,-38,-25,-13

; ---- end sin512.inc
; ---- begin paint.inc
; =============================================================================
;  PAINT : 192x128 canvas, 16 colours, saved as a real 4-bit BMP in /home
; =============================================================================
PCW     equ 192
PCH     equ 128
PZ      equ 3
PCX     equ WX+156
PCY     equ WY+HDRH+16
PB      equ 0x4700000
PSNAP   equ 0x4710000
PSTK    equ 0x4800000
PBX     equ WX+8
PBY     equ WY+HDRH+12


pt_bbox_reset:
    mov dword [pt_dx0], 0x7FFFFFFF
    mov dword [pt_dy0], 0x7FFFFFFF
    mov dword [pt_dx1], -1
    mov dword [pt_dy1], -1
    ret

pt_put:                             ; eax=x ebx=y (canvas)
    cmp eax, PCW
    jae .r
    cmp ebx, PCH
    jae .r
    push rcx
    push rdx
    mov ecx, ebx
    imul ecx, PCW
    add ecx, eax
    mov edx, [pt_dc]
    mov [PB+rcx], dl
    cmp eax, [pt_dx0]
    jge .a
    mov [pt_dx0], eax
.a: cmp ebx, [pt_dy0]
    jge .b
    mov [pt_dy0], ebx
.b: lea ecx, [rax+1]
    cmp ecx, [pt_dx1]
    jle .c
    mov [pt_dx1], ecx
.c: lea ecx, [rbx+1]
    cmp ecx, [pt_dy1]
    jle .d
    mov [pt_dy1], ecx
.d: pop rdx
    pop rcx
.r: ret

pt_stamp:                           ; eax=x ebx=y
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov eax, [pt_size]
    movzx r14d, byte [pt_sizes+rax]
    mov r15d, r14d
    neg r15d
.dy:
    mov ebp, r14d
    neg ebp
.dx:
    mov eax, ebp
    imul eax, eax
    mov ecx, r15d
    imul ecx, ecx
    add eax, ecx
    mov ecx, r14d
    imul ecx, ecx
    add ecx, r14d
    cmp eax, ecx
    jg .sk
    lea eax, [r12+rbp]
    lea ebx, [r13+r15]
    call pt_put
.sk:
    inc ebp
    cmp ebp, r14d
    jle .dx
    inc r15d
    cmp r15d, r14d
    jle .dy
    POPA
    ret

pt_line:                            ; eax=x0 ebx=y0 ecx=x1 edx=y1
    PUSHA
    mov r8d, eax
    mov r9d, ebx
    mov r10d, ecx
    mov r11d, edx
    mov r12d, ecx
    sub r12d, eax
    mov r13d, 1
    jns .px
    neg r12d
    mov r13d, -1
.px:
    mov r14d, edx
    sub r14d, ebx
    mov r15d, 1
    jns .py
    neg r14d
    mov r15d, -1
.py:
    neg r14d                         ; dy = -|dy|
    lea ebp, [r12+r14]
.l: mov eax, r8d
    mov ebx, r9d
    call pt_stamp
    cmp r8d, r10d
    jne .c
    cmp r9d, r11d
    je .d
.c: mov eax, ebp
    add eax, eax
    cmp eax, r14d
    jl .n1
    add ebp, r14d
    add r8d, r13d
.n1:
    cmp eax, r12d
    jg .l
    add ebp, r12d
    add r9d, r15d
    jmp .l
.d: POPA
    ret

pt_rect:                            ; eax=x0 ebx=y0 ecx=x1 edx=y1
    PUSHA
    mov r8d, eax
    mov r9d, ebx
    mov r10d, ecx
    mov r11d, edx
    mov eax, r8d
    mov ebx, r9d
    mov ecx, r10d
    mov edx, r9d
    call pt_line
    mov eax, r10d
    mov ebx, r9d
    mov ecx, r10d
    mov edx, r11d
    call pt_line
    mov eax, r10d
    mov ebx, r11d
    mov ecx, r8d
    mov edx, r11d
    call pt_line
    mov eax, r8d
    mov ebx, r11d
    mov ecx, r8d
    mov edx, r9d
    call pt_line
    POPA
    ret

pt_oval:                            ; eax=x0 ebx=y0 ecx=x1 edx=y1
    PUSHA
    lea r8d, [rax+rcx]
    sar r8d, 1                       ; cx
    lea r9d, [rbx+rdx]
    sar r9d, 1                       ; cy
    mov r10d, ecx
    sub r10d, eax
    jns .a
    neg r10d
.a: sar r10d, 1                      ; a
    mov r11d, edx
    sub r11d, ebx
    jns .b
    neg r11d
.b: sar r11d, 1                      ; b
    xor r12d, r12d
.l: lea eax, [r12+128]
    and eax, 511
    movsx eax, word [sin512+rax*2]
    imul eax, r10d
    sar eax, 10
    add eax, r8d
    mov r13d, eax
    mov eax, r12d
    movsx eax, word [sin512+rax*2]
    imul eax, r11d
    sar eax, 10
    add eax, r9d
    mov ebx, eax
    mov eax, r13d
    call pt_stamp
    inc r12d
    cmp r12d, 512
    jb .l    POPA
    ret

pt_fill:                            ; eax=x ebx=y  fill with pt_col
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov ecx, ebx
    imul ecx, PCW
    add ecx, eax
    movzx r14d, byte [PB+rcx]        ; target colour
    mov eax, [pt_col]
    cmp r14d, eax
    je .o
    mov r15d, eax
    mov rdi, PSTK
    mov eax, r13d
    shl eax, 16
    or eax, r12d
    mov [rdi], eax
    mov ebp, 1                       ; count
.l: test ebp, ebp
    jz .done
    dec ebp
    mov eax, [PSTK+rbp*4]
    movzx ebx, ax                    ; x
    shr eax, 16                      ; y
    cmp ebx, PCW
    jae .l
    cmp eax, PCH
    jae .l
    mov ecx, eax
    imul ecx, PCW
    add ecx, ebx
    movzx edx, byte [PB+rcx]
    cmp edx, r14d
    jne .l
    mov [PB+rcx], r15b
    cmp ebp, 200000
    jae .l
    mov edx, eax
    shl edx, 16
    ; x+1
    lea esi, [rbx+1]
    or esi, edx
    mov [PSTK+rbp*4], esi
    inc ebp
    ; x-1
    lea esi, [rbx-1]
    and esi, 0xFFFF
    or esi, edx
    mov [PSTK+rbp*4], esi
    inc ebp
    ; y+1
    lea esi, [rax+1]
    shl esi, 16
    or esi, ebx
    mov [PSTK+rbp*4], esi
    inc ebp
    ; y-1
    lea esi, [rax-1]
    shl esi, 16
    or esi, ebx
    mov [PSTK+rbp*4], esi
    inc ebp
    jmp .l
.done:
    mov dword [pt_dx0], 0
    mov dword [pt_dy0], 0
    mov dword [pt_dx1], PCW
    mov dword [pt_dy1], PCH
.o: POPA
    ret

; draw the dirty part of the canvas into the window
pt_flush:
    PUSHA
    mov r12d, [pt_dx0]
    mov r13d, [pt_dy0]
    mov r14d, [pt_dx1]
    mov r15d, [pt_dy1]
    cmp r12d, r14d
    jge .o
    cmp r13d, r15d
    jge .o
    mov ebp, r13d                    ; y
.ry:
    mov ebx, r12d                    ; x
.rx:
    mov eax, ebp
    imul eax, PCW
    add eax, ebx
    movzx eax, byte [PB+rax]
    mov r8d, [pt_pal+rax*4]
    ; destination
    mov eax, ebp
    imul eax, PZ
    add eax, PCY
    imul rax, [cur_pitch]
    mov ecx, ebx
    imul ecx, PZ
    add ecx, PCX
    lea rdi, [rax+rcx*4]
    add rdi, [cur_fb]
    mov rdx, [cur_pitch]
    mov [rdi], r8d
    mov [rdi+4], r8d
    mov [rdi+8], r8d
    add rdi, rdx
    mov [rdi], r8d
    mov [rdi+4], r8d
    mov [rdi+8], r8d
    add rdi, rdx
    mov [rdi], r8d
    mov [rdi+4], r8d
    mov [rdi+8], r8d
    inc ebx
    cmp ebx, r14d
    jb .rx
    inc ebp
    cmp ebp, r15d
    jb .ry
    mov ebx, r12d
    imul ebx, PZ
    add ebx, PCX
    mov ecx, r13d
    imul ecx, PZ
    add ecx, PCY
    mov esi, r14d
    sub esi, r12d
    imul esi, PZ
    mov edx, r15d
    sub edx, r13d
    imul edx, PZ
    call mark_dirty
.o: call pt_bbox_reset
    POPA
    ret

pt_full:
    mov dword [pt_dx0], 0
    mov dword [pt_dy0], 0
    mov dword [pt_dx1], PCW
    mov dword [pt_dy1], PCH
    jmp pt_flush

; button: eax=x ebx=y ecx=w edx=h rsi=label edi=selected
pt_btn:
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov r14d, ecx
    mov r15d, edx
    mov rbp, rsi
    mov eax, [th_hdr]
    mov dword [g_fg], 0
    mov r8d, [th_txt]
    mov [g_fg], r8d
    test edi, edi
    jz .n
    mov eax, [th_acc]
    mov dword [g_fg], 0xFFFFFF
.n: mov ebx, r12d
    mov ecx, r13d
    mov esi, r14d
    mov edx, r15d
    mov r9d, 8
    call rrect
    lea rax, [font_uis]
    mov [g_uf], rax
    mov rsi, rbp
    mov ebx, r14d
    shr ebx, 1
    add ebx, r12d
    mov ecx, r15d
    sub ecx, 16
    shr ecx, 1
    add ecx, r13d
    call ui_text_c
    POPA
    ret

pt_panel:
    PUSHA
    ; clear the panel column
    mov eax, [th_win]
    mov ebx, PBX-4
    mov ecx, PBY-6
    mov esi, 150
    mov edx, 520
    call rect
    ; tools 2 x 3
    xor r12d, r12d
.t: cmp r12d, 6
    jae .pal
    mov eax, r12d
    and eax, 1
    imul eax, eax, 68
    add eax, PBX
    mov ebx, r12d
    shr ebx, 1
    imul ebx, ebx, 40
    add ebx, PBY
    lea rsi, [pt_names]
    mov ecx, r12d
.f: test ecx, ecx
    jz .fd
.s: cmp byte [rsi], 0
    je .se
    inc rsi
    jmp .s
.se:
    inc rsi
    dec ecx
    jmp .f
.fd:
    xor edi, edi
    cmp r12d, [pt_tool]
    jne .nsel
    mov edi, 1
.nsel:
    mov ecx, 64
    mov edx, 34
    call pt_btn
    inc r12d
    jmp .t
.pal:
    ; palette 4 x 4
    xor r12d, r12d
.p: cmp r12d, 16
    jae .sz
    mov eax, r12d
    and eax, 3
    imul eax, eax, 34
    add eax, PBX
    mov r13d, eax
    mov eax, r12d
    shr eax, 2
    imul eax, eax, 34
    add eax, PBY+128
    mov r14d, eax
    cmp r12d, [pt_col]
    jne .nr
    mov eax, [th_acc]
    lea ebx, [r13-3]
    lea ecx, [r14-3]
    mov esi, 36
    mov edx, 36
    mov r9d, 10
    call rrect
    mov eax, [th_win]
    lea ebx, [r13-1]
    lea ecx, [r14-1]
    mov esi, 32
    mov edx, 32
    mov r9d, 9
    call rrect
.nr:
    mov eax, 0xB4B4BC
    lea ebx, [r13-1]
    lea ecx, [r14-1]
    mov esi, 32
    mov edx, 32
    mov r9d, 8
    call rrect
    mov eax, [pt_pal+r12*4]
    mov ebx, r13d
    mov ecx, r14d
    mov esi, 30
    mov edx, 30
    mov r9d, 7
    call rrect
    inc r12d
    jmp .p
.sz:
    ; sizes
    xor r12d, r12d
.z: cmp r12d, 4
    jae .act
    imul eax, r12d, 34
    add eax, PBX
    mov r13d, eax
    mov eax, [th_hdr]
    cmp r12d, [pt_size]
    jne .zn
    mov eax, [th_acc]
.zn:
    mov ebx, r13d
    mov ecx, PBY+276
    mov esi, 30
    mov edx, 30
    mov r9d, 8
    call rrect
    movzx r14d, byte [pt_sizes+r12]
    mov eax, [th_txt]
    cmp r12d, [pt_size]
    jne .zd
    mov eax, 0xFFFFFF
.zd:
    lea ebx, [r13+14]
    sub ebx, r14d
    mov ecx, PBY+276+14
    sub ecx, r14d
    lea esi, [r14*2+2]
    mov edx, esi
    mov r9d, r14d
    inc r9d
    call rrect
    inc r12d
    jmp .z
.act:
    mov eax, PBX
    mov ebx, PBY+318
    mov ecx, 64
    mov edx, 34
    lea rsi, [s_pt_undo]
    xor edi, edi
    call pt_btn
    mov eax, PBX+68
    mov ebx, PBY+318
    mov ecx, 64
    mov edx, 34
    lea rsi, [s_pt_clr]
    xor edi, edi
    call pt_btn
    mov eax, PBX
    mov ebx, PBY+362
    mov ecx, 132
    mov edx, 38
    lea rsi, [s_pt_save]
    mov edi, 1
    call pt_btn
    POPA
    ret

pt_snap:                            ; remember the canvas for Undo
    push rsi
    push rdi
    push rcx
    mov rsi, PB
    mov rdi, PSNAP
    mov ecx, PCW*PCH/8
    rep movsq
    mov byte [pt_undo], 1
    pop rcx
    pop rdi
    pop rsi
    ret

pt_restore:                         ; snapshot -> canvas (for shape previews)
    push rsi
    push rdi
    push rcx
    mov rsi, PSNAP
    mov rdi, PB
    mov ecx, PCW*PCH/8
    rep movsq
    pop rcx
    pop rdi
    pop rsi
    ret

pt_save:
    PUSHA
    ; first free /home/paintN.bmp
    mov r12d, 1
.n: mov rdi, PATHB
    lea rsi, [s_pt_pre]
    call strcpy
    mov rdi, PATHB
.e: cmp byte [rdi], 0
    je .ee
    inc rdi
    jmp .e
.ee:
    mov eax, r12d
    call u2s
    lea rsi, [s_pt_ext]
    call sappend
    mov rsi, PATHB
    call fs_find
    test rax, rax
    jz .free
    inc r12d
    cmp r12d, 100
    jb .n
    jmp .full
.free:
    mov rsi, PATHB
    call fs_create
    test rax, rax
    jz .full
    mov rbx, rax
    ; header
    lea rdi, [rbx+64]
    lea rsi, [pt_bmphdr]
    mov ecx, 118
    rep movsb
    ; pixel rows bottom-up, two pixels per byte
    mov r13d, PCH-1
.row:
    mov eax, r13d
    imul eax, PCW
    lea rsi, [PB+rax]
    mov ecx, PCW/2
.px:
    movzx eax, byte [rsi]
    shl eax, 4
    or al, [rsi+1]
    mov [rdi], al
    inc rdi
    add rsi, 2
    dec ecx
    jnz .px
    dec r13d
    jns .row
    mov dword [rbx+48], 12406
    mov rax, rbx
    call fs_save
    mov rdi, TMPB
    lea rsi, [s_pt_ok1]
    call strcpy
    mov rdi, TMPB
.k: cmp byte [rdi], 0
    je .kk
    inc rdi
    jmp .k
.kk:
    mov rsi, PATHB
    call sappend
    lea rsi, [s_pt_ok2]
    call sappend
    mov rsi, TMPB
    call set_status
    jmp .o
.full:
    lea rsi, [s_pt_full]
    call set_status
.o: POPA
    ret

pt_bmphdr:
    db 'B','M'
    dd 12406
    dd 0
    dd 118
    dd 40
    dd PCW
    dd PCH
    dw 1
    dw 4
    dd 0
    dd 12288
    dd 2835
    dd 2835
    dd 16
    dd 0
    ; palette B,G,R,0
    %assign pi 0
    dd 0xFFFFFF,0x000000,0x808080,0xC0C0C0,0xE53935,0xFB8C00,0xFDD835,0x43A047
    dd 0x00ACC1,0x1E88E5,0x3949AB,0x8E24AA,0xEC407A,0x6D4C41,0xC0CA33,0x81D4FA

; pointer in window coordinates -> eax, ebx
mouse_virt:
    push r8
    mov r8, [cur_sptr]
    mov eax, [mx]
    sub eax, [r8+SF_SX]
    add eax, [r8+SF_VX]
    mov ebx, [my]
    sub ebx, [r8+SF_SY]
    add ebx, [r8+SF_VY]
    pop r8
    ret

; canvas cell under (eax, ebx) window coords: -> eax, ebx (clamped) ; CF=1 if outside
pt_cell:
    sub eax, PCX
    sub ebx, PCY
    cmp eax, 0
    jl .out
    cmp ebx, 0
    jl .out
    cmp eax, PCW*PZ
    jge .out
    cmp ebx, PCH*PZ
    jge .out
    push rdx
    push rcx
    xor edx, edx
    mov ecx, PZ
    div ecx
    push rax
    mov eax, ebx
    xor edx, edx
    div ecx
    mov ebx, eax
    pop rax
    pop rcx
    pop rdx
    clc
    ret
.out:
    stc
    ret

pt_clamp_cell:                      ; eax,ebx window coords -> clamped canvas cell
    sub eax, PCX
    jns .a
    xor eax, eax
.a: sub ebx, PCY
    jns .b
    xor ebx, ebx
.b: push rdx
    push rcx
    xor edx, edx
    mov ecx, PZ
    div ecx
    cmp eax, PCW-1
    jbe .c
    mov eax, PCW-1
.c: push rax
    mov eax, ebx
    xor edx, edx
    div ecx
    cmp eax, PCH-1
    jbe .d
    mov eax, PCH-1
.d: mov ebx, eax
    pop rax
    pop rcx
    pop rdx
    ret

pt_press:                           ; eax,ebx = window coords of the press
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov byte [pt_prev], 2            ; 2 = a button press : no dragging
    ; ---- panel
    cmp r12d, PBX
    jl .canvas
    cmp r12d, PBX+140
    jge .canvas
    ; tools
    mov eax, r13d
    sub eax, PBY
    jl .o
    cmp eax, 120
    jge .pal
    xor edx, edx
    mov ecx, 40
    div ecx
    mov r8d, eax                     ; row
    mov eax, r12d
    sub eax, PBX
    xor edx, edx
    mov ecx, 68
    div ecx
    cmp edx, 64
    jae .o
    lea eax, [rax+r8*2]
    cmp eax, 6
    jae .o
    mov [pt_tool], eax
    call pt_panel
    jmp .o
.pal:
    mov eax, r13d
    sub eax, PBY+128
    jl .szr
    cmp eax, 136
    jge .szr
    xor edx, edx
    mov ecx, 34
    div ecx
    cmp edx, 30
    jae .o
    mov r8d, eax
    mov eax, r12d
    sub eax, PBX
    xor edx, edx
    div ecx
    cmp edx, 30
    jae .o
    cmp eax, 4
    jae .o
    lea eax, [rax+r8*4]
    mov [pt_col], eax
    call pt_panel
    jmp .o
.szr:
    mov eax, r13d
    sub eax, PBY+276
    jl .ar
    cmp eax, 30
    jge .ar
    mov eax, r12d
    sub eax, PBX
    xor edx, edx
    mov ecx, 34
    div ecx
    cmp edx, 30
    jae .o
    cmp eax, 4
    jae .o
    mov [pt_size], eax
    call pt_panel
    jmp .o
.ar:
    mov eax, r13d
    sub eax, PBY+318
    jl .sv
    cmp eax, 34
    jge .sv
    mov eax, r12d
    sub eax, PBX
    cmp eax, 64
    jl .undo
    cmp eax, 68
    jl .o
    cmp eax, 132
    jge .o
    ; clear
    call pt_snap
    mov rdi, PB
    mov ecx, PCW*PCH/8
    xor eax, eax
    rep stosq
    call pt_full
    jmp .o
.undo:
    cmp byte [pt_undo], 0
    je .o
    ; swap current and snapshot so that a second Undo redoes
    mov rsi, PB
    mov rdi, PSNAP
    mov ecx, PCW*PCH/8
.sw:
    mov rax, [rsi]
    mov rdx, [rdi]
    mov [rsi], rdx
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .sw
    call pt_full
    jmp .o
.sv:
    mov eax, r13d
    sub eax, PBY+362
    jl .o
    cmp eax, 38
    jge .o
    call pt_save
    jmp .o
    ; ---- canvas
.canvas:
    mov eax, r12d
    mov ebx, r13d
    call pt_cell
    jc .o
    mov [pt_x0], eax
    mov [pt_y0], ebx
    mov [pt_lx], eax
    mov [pt_ly], ebx
    mov byte [pt_prev], 1
    call pt_snap
    mov ecx, [pt_col]
    mov [pt_dc], ecx
    cmp dword [pt_tool], 1
    jne .nt
    mov dword [pt_dc], 0
.nt:
    cmp dword [pt_tool], 5
    je .fill
    cmp dword [pt_tool], 1
    ja .shape
    call pt_stamp
    call pt_flush
    jmp .o
.shape:
    jmp .o
.fill:
    call pt_fill
    call pt_flush
.o: POPA
    ret

pt_drag:                            ; eax,ebx = window coords
    PUSHA
    cmp byte [pt_prev], 1
    jne .o
    call pt_clamp_cell
    mov r12d, eax
    mov r13d, ebx
    mov ecx, [pt_tool]
    cmp ecx, 1
    ja .shape
    cmp eax, [pt_lx]
    jne .mv
    cmp ebx, [pt_ly]
    je .o
.mv:
    mov ecx, eax
    mov edx, ebx
    mov eax, [pt_lx]
    mov ebx, [pt_ly]
    call pt_line
    mov [pt_lx], r12d
    mov [pt_ly], r13d
    call pt_flush
    jmp .o
.shape:
    cmp ecx, 5
    je .o
    cmp r12d, [pt_lx]
    jne .go
    cmp r13d, [pt_ly]
    je .o
.go:
    mov [pt_lx], r12d
    mov [pt_ly], r13d
    call pt_restore
    mov eax, [pt_x0]
    mov ebx, [pt_y0]
    mov ecx, r12d
    mov edx, r13d
    mov esi, [pt_tool]
    cmp esi, 2
    je .l
    cmp esi, 3
    je .r
    call pt_oval
    jmp .f
.l: call pt_line
    jmp .f
.r: call pt_rect
.f: call pt_full
.o: POPA
    ret

app_paint:
    mov dword [pt_tool], 0
    mov dword [pt_col], 1
    mov dword [pt_size], 1
    mov byte [pt_prev], 0
    mov byte [pt_undo], 0
    mov rdi, PB
    mov ecx, PCW*PCH/8
    xor eax, eax
    rep stosq
    call pt_bbox_reset
.full:
    lea rsi, [s_paint_t]
    call draw_win
    call pt_panel
    ; frame around the canvas
    mov eax, 0x808088
    mov ebx, PCX-2
    mov ecx, PCY-2
    mov esi, PCW*PZ+4
    mov edx, PCH*PZ+4
    call rect
    call pt_full
    ; hint line
    mov eax, [th_dim]
    mov [g_fg], eax
    lea rax, [font_uis]
    mov [g_uf], rax
    lea rsi, [s_pt_info]
    mov ebx, PCX
    mov ecx, PCY+PCH*PZ+12
    call ui_text
    lea rsi, [s_pt_info]
    call set_status
.loop:
    call pollkey
    test al, al
    jz .mouse
    cmp al, 'u'
    jne .k1
    mov eax, PBX+10
    mov ebx, PBY+330
    call pt_press
    mov byte [pt_prev], 0
    jmp .loop
.k1:
    cmp al, 'c'
    jne .k2
    mov eax, PBX+100
    mov ebx, PBY+330
    call pt_press
    mov byte [pt_prev], 0
    jmp .loop
.k2:
    cmp al, 's'
    jne .mouse
    call pt_save
.mouse:
    mov eax, [task_cur]
    cmp eax, [focus]
    jne .rel
    test byte [m_btn], 1
    jz .rel
    call mouse_virt
    cmp byte [pt_prev], 0
    jne .drag
    cmp ebx, WY+HDRH
    jl .loop
    call pt_press
    jmp .loop
.drag:
    call pt_drag
    jmp .loop
.rel:
    mov byte [pt_prev], 0
    jmp .loop

; ---- end paint.inc
; ---- begin settings.inc
; =============================================================================
;  SETTINGS : General, Appearance, Wallpaper, Display, Keyboard, Monitor,
;             Account, About   (mouse driven, hot-spot based)
; =============================================================================
HS      equ 0x3A9000
PREVICO equ 0x4630000
PREVSZ  equ 36
THUMB   equ 0x4640000
STX     equ WX
STY     equ WY+HDRH
SPX     equ WX+228
SPW     equ 548

A_TAB   equ 1
A_THEME equ 2
A_ACC   equ 3
A_CLK   equ 4
A_BAR   equ 5
A_LOGO  equ 6
A_ICON  equ 7
A_DOCK  equ 8
A_WALL  equ 9
A_RES   equ 10
A_LAY2  equ 11
A_REST  equ 12
A_CFG   equ 13
A_RESET equ 14
A_LOCK  equ 15
A_LOGT  equ 16
A_PASS  equ 17


; ---- hot spots ---------------------------------------------------------------
hs_add:                             ; eax=x ebx=y ecx=w edx=h esi=act edi=val
    push r8
    mov r8d, [hs_n]
    cmp r8d, 60
    jae .o
    imul r8d, r8d, 24
    add r8, HS
    mov [r8], eax
    mov [r8+4], ebx
    mov [r8+8], ecx
    mov [r8+12], edx
    mov [r8+16], esi
    mov [r8+20], edi
    inc dword [hs_n]
.o: pop r8
    ret

hs_find:                            ; eax=x ebx=y -> esi=act edi=val ; esi=0 none
    push rcx
    push rdx
    push r8
    xor ecx, ecx
.l: cmp ecx, [hs_n]
    jae .no
    mov r8d, ecx
    imul r8d, r8d, 24
    add r8, HS
    mov edx, eax
    sub edx, [r8]
    jl .n
    cmp edx, [r8+8]
    jge .n
    mov edx, ebx
    sub edx, [r8+4]
    jl .n
    cmp edx, [r8+12]
    jge .n
    mov esi, [r8+16]
    mov edi, [r8+20]
    jmp .o
.n: inc ecx
    jmp .l
.no:
    xor esi, esi
    xor edi, edi
.o: pop r8
    pop rdx
    pop rcx
    ret

; ---- text helpers : rsi=text ebx=x ecx=y -------------------------------------------
st_h:
    push rax
    lea rax, [font_uib]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    call ui_text
    pop rax
    ret
st_p:
    push rax
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    call ui_text
    pop rax
    ret
st_d:
    push rax
    lea rax, [font_uis]
    mov [g_uf], rax
    mov eax, [th_dim]
    mov [g_fg], eax
    call ui_text
    pop rax
    ret

; option button : eax=x ebx=y ecx=w edx=h rsi=label edi=selected r8d=act r9d=val
st_opt:
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov r14d, ecx
    mov r15d, edx
    mov rbp, rsi
    mov r10d, r8d
    mov r11d, r9d
    mov eax, [th_hdr]
    mov ecx, [th_txt]
    test edi, edi
    jz .n
    mov eax, [th_acc]
    mov ecx, 0xFFFFFF
.n: mov [g_fg], ecx
    mov ebx, r12d
    mov ecx, r13d
    mov esi, r14d
    mov edx, r15d
    mov r9d, 9
    call rrect
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, rbp
    mov ebx, r14d
    shr ebx, 1
    add ebx, r12d
    mov ecx, r15d
    sub ecx, 19
    shr ecx, 1
    add ecx, r13d
    call ui_text_c
    mov eax, r12d
    mov ebx, r13d
    mov ecx, r14d
    mov edx, r15d
    mov esi, r10d
    mov edi, r11d
    call hs_add
    POPA
    ret

; card background : eax=x ebx=y ecx=w edx=h edi=selected
st_card:
    PUSHA
    mov r12d, eax
    mov r13d, ebx
    mov r14d, ecx
    mov r15d, edx
    test edi, edi
    jz .n
    mov eax, [th_acc]
    mov esi, ecx
    add esi, 6
    lea edx, [r15+6]
    lea ebx, [r12-3]
    lea ecx, [r13-3]
    mov r9d, 14
    call rrect
.n: mov eax, [th_hdr]
    mov ebx, r12d
    mov ecx, r13d
    mov esi, r14d
    mov edx, r15d    mov r9d, 12
    call rrect
    POPA
    ret

; ---- previews ------------------------------------------------------------------------
st_prev_build:
    PUSHA
    movzx r15d, byte [SB_ICST]
    xor r12d, r12d                  ; style
.s: mov [SB_ICST], r12b
    xor r13d, r13d
.k: lea rax, [st_samples]
    movzx eax, byte [rax+r13]
    mov ecx, PREVSZ
    lea edx, [r12+r12*2]
    add edx, r13d
    imul edx, edx, PREVSZ*PREVSZ*4
    lea rdi, [PREVICO+rdx]
    call icon_render
    inc r13d
    cmp r13d, 3
    jb .k
    inc r12d
    cmp r12d, 4
    jb .s
    mov [SB_ICST], r15b
    POPA
    ret

st_walls_build:
    PUSHA
    xor r12d, r12d
.w: mov eax, r12d
    call wp_gen
    xor r13d, r13d                  ; ty
.ty:
    xor r14d, r14d                  ; tx
.tx:
    mov eax, r13d
    shl eax, 3
    imul eax, [scr_w]
    mov ecx, r14d
    shl ecx, 3
    add eax, ecx
    mov eax, [WALL+rax*4]
    mov ecx, r12d
    imul ecx, 96*128
    mov edx, r13d
    shl edx, 7
    add ecx, edx
    add ecx, r14d
    and eax, 0xFFFFFF
    mov [THUMB+rcx*4], eax
    inc r14d
    cmp r14d, 128
    jb .tx
    inc r13d
    cmp r13d, 96
    jb .ty
    inc r12d
    cmp r12d, WP_N
    jb .w
    movzx eax, byte [SB_WALL]
    call wp_gen
    POPA
    ret

; ---- layout of the whole window --------------------------------------------------------
st_tab_names:
    db "General",0,"Appearance",0,"Wallpaper",0,"Display",0,"Keyboard",0,"Monitor",0,"Account",0,"About",0

st_draw:
    PUSHA
    mov dword [hs_n], 0
    lea rsi, [s_set_t]
    call draw_win
    ; sidebar
    mov eax, [th_stat]
    mov ebx, STX
    mov ecx, STY
    mov esi, 200
    mov edx, WH-HDRH-STH
    call rect
    mov eax, [th_brd]
    mov ebx, STX+200
    mov ecx, STY
    mov esi, 1
    mov edx, WH-HDRH-STH
    call rect
    xor r12d, r12d
    lea r13, [st_tab_names]
.tb:
    cmp r12d, 8
    jae .pane
    imul r14d, r12d, 46
    add r14d, STY+14
    cmp r12d, [st_tab]
    jne .nsel
    mov eax, [th_acc]
    mov ebx, STX+10
    mov ecx, r14d
    mov esi, 180
    mov edx, 40
    mov r9d, 9
    call rrect
    mov dword [g_fg], 0xFFFFFF
    jmp .ic
.nsel:
    mov eax, [th_txt]
    mov [g_fg], eax
.ic:
    ; small tile icon
    lea rax, [st_tab_icon]
    movzx eax, byte [rax+r12]
    imul esi, eax, ICS_STR
    add rsi, ICS
    mov ebx, STX+20
    lea ecx, [r14+6]
    mov eax, ICS_SZ
    mov edx, ICS_SZ
    call argb_blit
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, r13
    mov ebx, STX+58
    lea ecx, [r14+10]
    call ui_text
.nx:
    cmp byte [r13], 0
    je .ne
    inc r13
    jmp .nx
.ne:
    inc r13
    mov eax, STX+10
    mov ebx, r14d
    mov ecx, 180
    mov edx, 40
    mov esi, A_TAB
    mov edi, r12d
    call hs_add
    inc r12d
    jmp .tb
.pane:
    ; title
    lea rsi, [st_tab_names]
    mov ecx, [st_tab]
.f: test ecx, ecx
    jz .t
.s: cmp byte [rsi], 0
    je .se
    inc rsi
    jmp .s
.se:
    inc rsi
    dec ecx
    jmp .f
.t: lea rax, [font_uil]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    mov ebx, SPX
    mov ecx, STY+16
    call ui_text
    mov eax, [st_tab]
    cmp eax, 0
    je .p0
    cmp eax, 1
    je .p1
    cmp eax, 2
    je .p2
    cmp eax, 3
    je .p3
    cmp eax, 4
    je .p4
    cmp eax, 5
    je .p5
    cmp eax, 6
    je .p6
    call st_pane_about
    jmp .done
.p0: call st_pane_general
    jmp .done
.p1: call st_pane_appear
    jmp .done
.p2: call st_pane_wall
    jmp .done
.p3: call st_pane_display
    jmp .done
.p4: call st_pane_keys
    jmp .done
.p5: call st_pane_monitor
    jmp .done
.p6: call st_pane_account
.done:
    POPA
    ret

; ---- General -------------------------------------------------------------------------
PY0     equ STY+78

st_pane_general:
    PUSHA
    lea rsi, [s_g_theme]
    mov ebx, SPX
    mov ecx, PY0
    call st_h
    xor r12d, r12d
.th:
    imul eax, r12d, 140
    add eax, SPX
    mov ebx, PY0+26
    mov ecx, 130
    mov edx, 38
    lea rsi, [s_th_l]
    test r12d, r12d
    jz .tl
    lea rsi, [s_th_d]
.tl:
    xor edi, edi
    cmp r12b, [SB_THEME]
    jne .tn
    mov edi, 1
.tn:
    mov r8d, A_THEME
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, 2
    jb .th
    ; accent
    lea rsi, [s_g_acc]
    mov ebx, SPX
    mov ecx, PY0+84
    call st_h
    xor r12d, r12d
.ac:
    imul r13d, r12d, 48
    add r13d, SPX
    cmp r12b, [SB_ACC]
    jne .na
    mov eax, [th_txt]
    lea ebx, [r13-4]
    mov ecx, PY0+106
    mov esi, 42
    mov edx, 42
    mov r9d, 21
    call rrect
    mov eax, [th_win]
    lea ebx, [r13-2]
    mov ecx, PY0+108
    mov esi, 38
    mov edx, 38
    mov r9d, 19
    call rrect
.na:
    mov eax, [acc_tab+r12*4]
    mov ebx, r13d
    mov ecx, PY0+110
    mov esi, 34
    mov edx, 34
    mov r9d, 17
    call rrect
    mov eax, r13d
    mov ebx, PY0+110
    mov ecx, 34
    mov edx, 34
    mov esi, A_ACC
    mov edi, r12d
    call hs_add
    inc r12d
    cmp r12d, 8
    jb .ac
    ; clock
    lea rsi, [s_g_clk]
    mov ebx, SPX
    mov ecx, PY0+166
    call st_h
    xor r12d, r12d
.ck:
    imul eax, r12d, 140
    add eax, SPX
    mov ebx, PY0+192
    mov ecx, 130
    mov edx, 38
    lea rsi, [s_c24]
    test r12d, r12d
    jz .cl
    lea rsi, [s_c12]
.cl:
    xor edi, edi
    cmp r12b, [SB_CLK12]
    jne .cn
    mov edi, 1
.cn:
    mov r8d, A_CLK
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, 2
    jb .ck
    ; bar
    lea rsi, [s_g_bar]
    mov ebx, SPX
    mov ecx, PY0+250
    call st_h
    xor r12d, r12d
.bk:
    imul eax, r12d, 140
    add eax, SPX
    mov ebx, PY0+276
    mov ecx, 130
    mov edx, 38
    lea rsi, [s_bar_g]
    test r12d, r12d
    jz .bl
    lea rsi, [s_bar_s]
.bl:
    xor edi, edi
    cmp r12b, [SB_BARST]
    jne .bn
    mov edi, 1
.bn:
    mov r8d, A_BAR
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, 2
    jb .bk
    ; buttons
    mov eax, SPX
    mov ebx, PY0+346
    mov ecx, 210
    mov edx, 38
    lea rsi, [s_g_cfg]
    xor edi, edi
    mov r8d, A_CFG
    xor r9d, r9d
    call st_opt
    mov eax, SPX+226
    mov ebx, PY0+346
    mov ecx, 190
    mov edx, 38
    lea rsi, [s_g_rst]
    xor edi, edi
    mov r8d, A_RESET
    xor r9d, r9d
    call st_opt
    lea rsi, [s_g_note]
    mov ebx, SPX
    mov ecx, PY0+404
    call st_d
    POPA
    ret

; ---- Appearance --------------------------------------------------------------------------

st_pane_appear:
    PUSHA
    lea rsi, [s_a_logo]
    mov ebx, SPX
    mov ecx, PY0-14
    call st_h
    xor r12d, r12d
.lg:
    imul r13d, r12d, 180
    add r13d, SPX
    xor edi, edi
    cmp r12b, [SB_LOGO]
    jne .ln
    mov edi, 1
.ln:
    mov eax, r13d
    mov ebx, PY0+10
    mov ecx, 168
    mov edx, 126
    call st_card
    ; the logo itself
    lea rsi, [logo_rainbow_64]
    cmp r12d, 1
    jb .lp
    lea rsi, [logo_green_64]
    cmp r12d, 2
    je .lp
    lea rsi, [logo_mono_64]
    cmp byte [SB_THEME], 0
    je .lp
    lea rsi, [logo_monol_64]
.lp:
    lea ebx, [r13+52]
    mov ecx, PY0+22
    mov eax, 64
    mov edx, 64
    call argb_blit
    lea rsi, [s_lg0]
    cmp r12d, 1
    jb .ll
    lea rsi, [s_lg2]
    cmp r12d, 2
    je .ll
    lea rsi, [s_lg1]
.ll:
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    lea ebx, [r13+84]
    mov ecx, PY0+98
    call ui_text_c
    mov eax, r13d
    mov ebx, PY0+10
    mov ecx, 168
    mov edx, 126
    mov esi, A_LOGO
    mov edi, r12d
    call hs_add
    inc r12d
    cmp r12d, 3
    jb .lg
    ; icon styles
    lea rsi, [s_a_icons]
    mov ebx, SPX
    mov ecx, PY0+160
    call st_h
    xor r12d, r12d
.is:
    imul r13d, r12d, 138
    add r13d, SPX
    xor edi, edi
    cmp r12b, [SB_ICST]
    jne .in
    mov edi, 1
.in:
    mov eax, r13d
    mov ebx, PY0+184
    mov ecx, 128
    mov edx, 104
    call st_card
    xor r14d, r14d
.pi:
    lea eax, [r12+r12*2]
    add eax, r14d
    imul eax, eax, PREVSZ*PREVSZ*4
    lea rsi, [PREVICO+rax]
    imul ebx, r14d, PREVSZ+4
    lea ebx, [rbx+r13+6]
    mov ecx, PY0+196
    mov eax, PREVSZ
    mov edx, PREVSZ
    call argb_blit
    inc r14d
    cmp r14d, 3
    jb .pi
    lea rsi, [s_is0]
    cmp r12d, 0
    je .il
    lea rsi, [s_is1]
    cmp r12d, 1
    je .il
    lea rsi, [s_is2]
    cmp r12d, 2
    je .il
    lea rsi, [s_is3]
.il:
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    lea ebx, [r13+64]
    mov ecx, PY0+256
    call ui_text_c
    mov eax, r13d
    mov ebx, PY0+184
    mov ecx, 128
    mov edx, 104
    mov esi, A_ICON
    mov edi, r12d
    call hs_add
    inc r12d
    cmp r12d, 4
    jb .is
    ; dock
    lea rsi, [s_a_dock]
    mov ebx, SPX
    mov ecx, PY0+312
    call st_h
    xor r12d, r12d
.dk:
    imul eax, r12d, 124
    add eax, SPX
    mov ebx, PY0+338
    mov ecx, 114
    mov edx, 38
    lea rsi, [s_ds0]
    cmp r12d, 0
    je .dl
    lea rsi, [s_ds1]
    cmp r12d, 1
    je .dl
    lea rsi, [s_ds2]
.dl:
    xor edi, edi
    cmp r12b, [SB_DSZ]
    jne .dn
    mov edi, 1
.dn:
    mov r8d, A_DOCK
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, 3
    jb .dk
    POPA
    ret

; ---- Wallpaper --------------------------------------------------------------------------------
st_pane_wall:
    PUSHA
    xor r12d, r12d
.w: mov eax, r12d
    cmp eax, 3
    jb .r0
    sub eax, 3
.r0:
    imul r13d, eax, 180
    add r13d, SPX
    mov eax, r12d
    cmp eax, 3
    setae al
    movzx eax, al
    imul r14d, eax, 176
    add r14d, PY0-14
    xor edi, edi
    cmp r12b, [SB_WALL]
    jne .n
    mov edi, 1
.n: mov eax, r13d
    mov ebx, r14d
    mov ecx, 168
    mov edx, 158
    call st_card
    ; thumbnail 128 x 96
    mov eax, r12d
    imul eax, eax, 96*128*4
    lea rsi, [THUMB+rax]
    lea ebx, [r13+20]
    lea ecx, [r14+12]
    mov eax, 128
    mov edx, 96
    mov r15d, 96
    ; opaque copy (thumbnail pixels have TT = 0)
    call st_blit_opaque
    ; label
    lea rsi, [wp_names]
    mov ecx, r12d
.f: test ecx, ecx
    jz .fd
.s: cmp byte [rsi], 0
    je .se
    inc rsi
    jmp .s
.se:
    inc rsi
    dec ecx
    jmp .f
.fd:
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    lea ebx, [r13+84]
    lea ecx, [r14+120]
    call ui_text_c
    mov eax, r13d
    mov ebx, r14d
    mov ecx, 168
    mov edx, 158
    mov esi, A_WALL
    mov edi, r12d
    call hs_add
    inc r12d
    cmp r12d, WP_N
    jb .w
    POPA
    ret

; fast opaque blit : rsi=src ebx=x ecx=y eax=w edx=h
st_blit_opaque:
    PUSHA
    mov r12d, eax
    mov r13d, edx
    mov r14, rsi
    mov esi, eax
    call mark_dirty
    mov rax, [cur_pitch]
    imul rax, rcx
    lea rdi, [rax+rbx*4]
    add rdi, [cur_fb]
    mov rsi, r14
.row:
    mov ecx, r12d
    push rdi
    rep movsd
    pop rdi
    add rdi, [cur_pitch]
    dec r13d
    jnz .row
    POPA
    ret

; ---- Display -----------------------------------------------------------------------------------
RES_N   equ 7

st_pane_display:
    PUSHA
    lea rsi, [s_d_res]
    mov ebx, SPX
    mov ecx, PY0-14
    call st_h
    xor r12d, r12d
.r: imul eax, r12d, 40
    add eax, PY0+12
    mov r13d, eax
    mov rdi, TMPB
    mov eax, [res_tab+r12*8]
    call u2s
    lea rsi, [s_d_x]
    call sappend
    mov eax, [res_tab+r12*8+4]
    call u2s
    xor edi, edi
    mov eax, [res_tab+r12*8]
    cmp eax, [SB_RESW]
    jne .n
    mov eax, [res_tab+r12*8+4]
    cmp eax, [SB_RESH]
    jne .n
    mov edi, 1
.n: mov eax, SPX
    mov ebx, r13d
    mov ecx, 260
    mov edx, 34
    mov rsi, TMPB
    mov r8d, A_RES
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, RES_N
    jb .r
    ; running resolution
    mov rdi, TMPB
    lea rsi, [s_d_now]
    call strcpy
    mov rdi, TMPB
.e: cmp byte [rdi], 0
    je .ee
    inc rdi
    jmp .e
.ee:
    mov eax, [scr_w]
    call u2s
    lea rsi, [s_d_x]
    call sappend
    mov eax, [scr_h]
    call u2s
    mov rsi, TMPB
    mov ebx, SPX+290
    mov ecx, PY0+14
    call st_p
    lea rsi, [s_d_n1]
    mov ebx, SPX+290
    mov ecx, PY0+60
    call st_d
    lea rsi, [s_d_n1b]
    mov ebx, SPX+290
    mov ecx, PY0+80
    call st_d
    lea rsi, [s_d_n2]
    mov ebx, SPX+290
    mov ecx, PY0+110
    call st_d
    lea rsi, [s_d_n2b]
    mov ebx, SPX+290
    mov ecx, PY0+130
    call st_d
    mov eax, SPX+290
    mov ebx, PY0+170
    mov ecx, 140
    mov edx, 38
    lea rsi, [s_d_rest]
    xor edi, edi
    mov r8d, A_REST
    xor r9d, r9d
    call st_opt
    POPA
    ret

; ---- Keyboard ----------------------------------------------------------------------------------
st_pane_keys:
    PUSHA
    lea rsi, [s_k_l1]
    mov ebx, SPX
    mov ecx, PY0
    call st_p
    lea rsi, [s_k_l2]
    mov ebx, SPX
    mov ecx, PY0+40
    call st_p
    xor r12d, r12d
.o: imul eax, r12d, 150
    add eax, SPX+30
    mov ebx, PY0+70
    mov ecx, 140
    mov edx, 38
    lea rsi, [s_k_ru]
    test r12d, r12d
    jz .l
    lea rsi, [s_k_es]
.l: xor edi, edi
    cmp r12b, [SB_LAY2]
    jne .n
    mov edi, 1
.n: mov r8d, A_LAY2
    mov r9d, r12d
    call st_opt
    inc r12d
    cmp r12d, 2
    jb .o
    lea rsi, [s_k_n1]
    mov ebx, SPX
    mov ecx, PY0+140
    call st_d
    lea rsi, [s_k_n2]
    mov ebx, SPX
    mov ecx, PY0+162
    call st_d
    lea rsi, [s_k_n3]
    mov ebx, SPX
    mov ecx, PY0+184
    call st_d
    lea rsi, [s_k_n4]
    mov ebx, SPX
    mov ecx, PY0+206
    call st_d
    POPA
    ret

; ---- Monitor ----------------------------------------------------------------------------------

st_pane_monitor:
    PUSHA
    lea rsi, [s_m_mem]
    mov ebx, SPX
    mov ecx, PY0-14
    call st_h
    mov rdi, TMPB
    lea rsi, [s_m_tot]
    call strcpy
    mov rdi, TMPB
.e1: cmp byte [rdi], 0
    je .e2
    inc rdi
    jmp .e1
.e2:
    mov eax, [bi_mem]
    shr eax, 10
    call u2s
    lea rsi, [s_m_mb1]
    call sappend
    mov eax, SYS_KB
    shr eax, 10
    call u2s
    lea rsi, [s_m_mb2]
    call sappend
    mov eax, [bi_mem]
    sub eax, SYS_KB
    shr eax, 10
    call u2s
    lea rsi, [s_m_mb3]
    call sappend
    mov rsi, TMPB
    mov ebx, SPX
    mov ecx, PY0+10
    call st_p
    ; bar
    mov eax, [th_hdr]
    mov ebx, SPX
    mov ecx, PY0+42
    mov esi, 500
    mov edx, 14
    mov r9d, 7
    call rrect
    mov eax, [bi_mem]
    test eax, eax
    jz .nb
    mov eax, SYS_KB
    imul eax, 500
    xor edx, edx
    div dword [bi_mem]
    cmp eax, 14
    jae .b1
    mov eax, 14
.b1:
    mov esi, eax
    mov eax, [th_acc]
    mov ebx, SPX
    mov ecx, PY0+42
    mov edx, 14
    mov r9d, 7
    call rrect
.nb:
    ; storage
    xor ecx, ecx
    xor edx, edx
    mov rdi, FSBUF
    mov esi, MAXF
.dl: cmp byte [rdi], 0
    je .dn
    inc ecx
    add edx, [rdi+48]
.dn: add rdi, SLOT
    dec esi
    jnz .dl
    push rdx
    push rcx
    lea rsi, [s_m_disk]
    mov ebx, SPX
    mov ecx, PY0+78
    call st_h
    mov rdi, TMPB
    lea rsi, [s_m_f1]
    call strcpy
    mov rdi, TMPB
.e3: cmp byte [rdi], 0
    je .e4
    inc rdi
    jmp .e3
.e4:
    pop rax
    call u2s
    lea rsi, [s_m_f2]
    call sappend
    mov eax, MAXF
    call u2s
    lea rsi, [s_m_f3]
    call sappend
    pop rax
    shr eax, 10
    call u2s
    lea rsi, [s_m_f4]
    call sappend
    mov rsi, TMPB
    mov ebx, SPX
    mov ecx, PY0+102
    call st_p
    cmp byte [ata_ok], 0
    jne .saved
    lea rsi, [s_m_ram]
    mov ebx, SPX
    mov ecx, PY0+120
    call st_d
.saved:
    ; uptime
    lea rsi, [s_m_up]
    mov ebx, SPX
    mov ecx, PY0+142
    call st_h
    call tod_sec
    sub eax, [boot_tod]
    jns .u1
    add eax, 86400
.u1:
    mov rdi, TMPB
    xor edx, edx
    mov ecx, 60
    div ecx
    push rdx
    xor edx, edx
    div ecx
    push rdx
    call u2s
    mov byte [rdi], 'h'
    mov byte [rdi+1], ' '
    add rdi, 2
    pop rax
    call u2s
    mov byte [rdi], 'm'
    mov byte [rdi+1], ' '
    add rdi, 2
    pop rax
    call u2s
    mov byte [rdi], 's'
    mov byte [rdi+1], 0
    mov rsi, TMPB
    mov ebx, SPX
    mov ecx, PY0+166
    call st_p
    ; network (read only: shows the state, never starts anything)
    lea rsi, [s_m_net]
    mov ebx, SPX
    mov ecx, PY0+206
    call st_h
    mov rdi, TMPB
    cmp byte [net_ok], 0
    jne .n1
    lea rsi, [s_m_net0]
    cmp byte [net_tried], 0
    je .n0
    lea rsi, [s_m_net1]
.n0:
    call strcpy
    jmp .nshow
.n1:
    lea rsi, [s_m_neth]
    test byte [e_status], 2
    jnz .nl
    lea rsi, [s_m_nethd]
.nl:
    call strcpy
    mov rdi, TMPB
.n2: cmp byte [rdi], 0
    je .n3
    inc rdi
    jmp .n2
.n3:
    cmp dword [my_ip], 0
    jne .n4
    lea rsi, [s_m_net2]
    call sappend
    jmp .nshow
.n4:
    mov eax, [my_ip]
    call ip2s
    lea rsi, [s_m_netg]
    call sappend
    mov eax, [net_gw]
    call ip2s
    lea rsi, [s_m_netd]
    call sappend
    mov eax, [net_dns]
    call ip2s
.nshow:
    mov rsi, TMPB
    mov ebx, SPX
    mov ecx, PY0+232
    call st_p
    ; windows
    lea rsi, [s_m_win]
    mov ebx, SPX
    mov ecx, PY0+286
    call st_h
    mov r13d, PY0+312
    xor r12d, r12d
    mov ecx, 1
.t: cmp ecx, NTASK
    jae .td
    mov eax, ecx
    shl eax, 7
    add rax, TASKS
    cmp dword [rax+T_STATE], 1
    jne .tn
    mov rsi, [rax+T_TITLE]
    push rcx
    mov ebx, SPX
    mov ecx, r13d
    call st_p
    pop rcx
    add r13d, 24
    inc r12d
.tn:
    inc ecx
    jmp .t
.td:
    test r12d, r12d
    jnz .o
    lea rsi, [s_m_none]
    mov ebx, SPX
    mov ecx, r13d
    call st_d
.o: POPA
    ret


; ---- Account ------------------------------------------------------------------------------------
st_pane_account:
    PUSHA
    lea rsi, [s_u_name]
    mov ebx, SPX
    mov ecx, PY0
    call st_d
    lea rsi, [SB_USER]
    mov ebx, SPX
    mov ecx, PY0+22
    call st_h
    mov eax, SPX
    mov ebx, PY0+76
    mov ecx, 250
    mov edx, 38
    lea rsi, [s_u_pw]    xor edi, edi
    mov r8d, A_PASS
    xor r9d, r9d
    call st_opt
    mov eax, SPX
    mov ebx, PY0+126
    mov ecx, 250
    mov edx, 38
    lea rsi, [s_u_lock]
    xor edi, edi
    mov r8d, A_LOCK
    xor r9d, r9d
    call st_opt
    mov eax, SPX
    mov ebx, PY0+176
    mov ecx, 250
    mov edx, 38
    lea rsi, [s_u_out]
    xor edi, edi
    mov r8d, A_LOGT
    xor r9d, r9d
    call st_opt
    POPA
    ret

; ---- About ------------------------------------------------------------------------------------------
st_pane_about:
    PUSHA
    call logo_ptr64
    mov ebx, SPX
    mov ecx, PY0-10
    mov eax, 64
    mov edx, 64
    call argb_blit
    lea rax, [font_uil]
    mov [g_uf], rax
    mov eax, [th_txt]
    mov [g_fg], eax
    lea rsi, [s_centtrix]
    mov ebx, SPX+80
    mov ecx, PY0-10
    call ui_text
    lea rsi, [s_ab_ver]
    mov ebx, SPX+80
    mov ecx, PY0+36
    call st_d
    mov r12d, PY0+80
    lea r13, [s_ab_1]
    lea r14, [s_ab_2]
    lea rsi, [s_ab_1]
    mov ebx, SPX
    mov ecx, r12d
    call st_p
    lea rsi, [s_ab_2]
    mov ebx, SPX
    lea ecx, [r12+26]
    call st_p
    lea rsi, [s_ab_3]
    mov ebx, SPX
    lea ecx, [r12+52]
    call st_p
    lea rsi, [s_ab_4]
    mov ebx, SPX
    lea ecx, [r12+78]
    call st_p
    lea rsi, [s_ab_5]
    mov ebx, SPX
    lea ecx, [r12+104]
    call st_p
    lea rsi, [s_ab_6]
    mov ebx, SPX
    lea ecx, [r12+130]
    call st_p
    lea rsi, [s_ab_7]
    mov ebx, SPX
    lea ecx, [r12+156]
    call st_p
    POPA
    ret

; ================================================================ ACTIONS ====
st_retarget:                        ; the chrome helpers moved the drawing target: come home
    PUSHA
    mov eax, [task_cur]
    shl eax, 7
    add rax, TASKS
    mov esi, [rax+T_SURF]
    call gfx_target
    POPA
    ret

st_act:                             ; esi=act edi=val
    PUSHA
    mov r12d, esi
    mov r13d, edi
    cmp r12d, A_TAB
    je .tab
    cmp r12d, A_THEME
    je .theme
    cmp r12d, A_ACC
    je .acc
    cmp r12d, A_CLK
    je .clk
    cmp r12d, A_BAR
    je .bar
    cmp r12d, A_LOGO
    je .logo
    cmp r12d, A_ICON
    je .icon
    cmp r12d, A_DOCK
    je .dock
    cmp r12d, A_WALL
    je .wall
    cmp r12d, A_RES
    je .res
    cmp r12d, A_LAY2
    je .lay
    cmp r12d, A_REST
    je .rest
    cmp r12d, A_CFG
    je .cfg
    cmp r12d, A_RESET
    je .reset
    cmp r12d, A_LOCK
    je .lock
    cmp r12d, A_LOGT
    je .logt
    cmp r12d, A_PASS
    je .pass
    jmp .o
.tab:
    mov [st_tab], r13d
    jmp .redraw
.theme:
    mov [SB_THEME], r13b
    call st_changed_look
    jmp .redraw
.acc:
    mov [SB_ACC], r13b
    call st_changed_look
    call st_prev_build
    jmp .redraw
.clk:
    mov [SB_CLK12], r13b
    mov dword [clk_min], -1
    call top_draw
    call cfg_apply_save
    jmp .redraw
.bar:
    mov [SB_BARST], r13b
    call top_draw
    call cfg_apply_save
    jmp .redraw
.logo:
    mov [SB_LOGO], r13b
    call top_draw
    call cfg_apply_save
    jmp .redraw
.icon:
    mov [SB_ICST], r13b
    call st_changed_look
    jmp .redraw
.dock:
    mov [SB_DSZ], r13b
    call st_changed_look
    jmp .redraw
.wall:
    mov eax, r13d
    call set_wallpaper
    jmp .redraw
.res:
    mov eax, [res_tab+r13*8]
    mov [SB_RESW], eax
    mov eax, [res_tab+r13*8+4]
    mov [SB_RESH], eax
    call sb_save
    jmp .redraw
.lay:
    mov [SB_LAY2], r13b
    mov byte [lay_cur], 0
    call top_draw
    call cfg_apply_save
    jmp .redraw
.rest:
    mov byte [want_power], 1
    jmp .o
.cfg:
    lea rsi, [p_cfg]
    call fs_find
    test rax, rax
    jz .o
    mov rbx, rax
    lea rax, [app_edit_file]
    mov ecx, 3
    lea rsi, [s_ed_t]
    call spawn_replace
    jmp .o
.reset:
    mov byte [SB_THEME], 0
    mov byte [SB_ACC], 0
    mov byte [SB_LOGO], 0
    mov byte [SB_ICST], 0
    mov byte [SB_DSZ], 0
    mov byte [SB_CLK12], 0
    mov byte [SB_BARST], 0
    mov byte [SB_LAY2], 0
    mov byte [lay_cur], 0
    call st_changed_look
    xor eax, eax
    call set_wallpaper
    jmp .redraw
.lock:
    mov byte [want_lock], 1
    jmp .o
.logt:
    mov byte [want_lock], 2
    jmp .o
.pass:
    mov byte [pr_mask], 1
    lea rsi, [s_newpw]
    mov rdi, PWA
    call prompt
    mov byte [pr_mask], 0
    test eax, eax
    jz .redraw
    mov rsi, PWA
    call hash_str
    mov [SB_HASH], eax
    call sb_save
    jmp .redraw
.redraw:
    call st_retarget
    call st_draw
.o: POPA
    ret

st_changed_look:
    PUSHA
    call chrome_refresh
    call desk_draw
    call cfg_apply_save
    call st_retarget
    POPA
    ret

app_edit_file:                      ; rax = slot
    call editor_open
    ret

; ================================================================ THE APP ====
app_settings:
    mov [st_tab], eax
    cmp dword [st_tab], 8
    jb .ok
    mov dword [st_tab], 0
.ok:
    mov byte [st_prev], 0
    call st_retarget
    call st_prev_build
    call st_walls_build
    call st_retarget
    mov dword [st_mon], -1
    call st_draw
.loop:
    call pollkey
    cmp al, K_UP
    jne .k1
    mov eax, [st_tab]
    test eax, eax
    jz .loop
    dec eax
    mov [st_tab], eax
    call st_draw
    jmp .loop
.k1:
    cmp al, K_DN
    jne .k2
    mov eax, [st_tab]
    cmp eax, 7
    jae .loop
    inc eax
    mov [st_tab], eax
    call st_draw
    jmp .loop
.k2:
    ; live refresh of the monitor page
    cmp dword [st_tab], 5
    jne .mouse
    call tod_sec
    cmp eax, [st_mon]
    je .mouse
    mov [st_mon], eax
    call st_draw
.mouse:
    mov eax, [task_cur]
    cmp eax, [focus]
    jne .rel
    test byte [m_btn], 1
    jz .rel
    cmp byte [st_prev], 0
    jne .loop
    mov byte [st_prev], 1
    call mouse_virt
    cmp ebx, WY+HDRH
    jl .loop
    call hs_find
    test esi, esi
    jz .loop
    call st_act
    jmp .loop
.rel:
    mov byte [st_prev], 0
    jmp .loop

; ---- end settings.inc
; ---- begin net.inc
; =============================================================================
;  NETWORK: PCI scan, Intel e1000 driver, ARP, IPv4, ICMP, UDP, DHCP, DNS,
;  TCP client and an HTTP/HTTPS fetcher (TLS in tls_*.inc).  Frames: eth(14) ip(20) l4.
;  IPv4 addresses are kept as dwords in memory (network byte order bytes).
; =============================================================================
NET      equ 0x4A00000
N_RXD    equ NET                    ; 32 rx descriptors
N_TXD    equ NET+0x400              ; 8 tx descriptors
N_RXB    equ NET+0x10000            ; 32 * 2048 rx buffers
N_TXB    equ NET+0x20000            ; 8 * 2048 tx buffers
N_PKT    equ NET+0x24000            ; frame being built
N_DNS    equ NET+0x25000            ; last DNS reply (udp payload)
N_DHCP   equ NET+0x25800            ; last DHCP reply (udp payload)
N_REQ    equ NET+0x26000            ; http request text
HTTPB    equ 0x4B00000              ; fetched page in file-slot layout (+0 name, +48 size, +64 data)
HTTP_MAX equ 0xFF000                ; max body
RAWB     equ 0x4C00000              ; raw http response
RAW_MAX  equ 0xFF000
NRX      equ 32
NTX      equ 8

E_NONIC  equ 1
E_HTTPS  equ 2
E_DHCP   equ 3
E_DNS    equ 4
E_CONN   equ 5
E_RESP   equ 6
E_URL    equ 7
E_REDIR  equ 8
E_LINK   equ 10
E_TLS    equ 11

; ------------------------------------------------------------- timers -------
tm_set:                             ; rdi = timer(8 bytes), eax = seconds
    push rax
    push rcx
    mov ecx, eax
    call tod_sec
    mov [rdi], eax
    inc ecx
    mov [rdi+4], ecx
    pop rcx
    pop rax
    ret

tm_chk:                             ; rdi = timer -> CF=1 when expired
    push rax
    call tod_sec
    sub eax, [rdi]
    jns .p
    add eax, 86400
.p: cmp eax, [rdi+4]
    cmc
    pop rax
    ret

net_lock:
.l: cmp byte [net_busy], 0
    je .t
    call yield
    jmp .l
.t: mov byte [net_busy], 1
    ret

net_unlock:
    mov byte [net_busy], 0
    ret

; ------------------------------------------------------------- PCI ----------
pci_rd:                             ; eax = bus/dev/fn base, ecx = offset -> eax
    push rdx
    or eax, ecx
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    pop rdx
    ret

pci_wr:                             ; eax = base, ecx = offset, esi = value
    push rdx
    push rax
    or eax, ecx
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, esi
    out dx, eax
    pop rax
    pop rdx
    ret

; ------------------------------------------------------------- e1000 regs ---
e_rd:                               ; edi = register -> eax (clobbers edx)
    cmp word [e_io], 0
    je .mm
    mov dx, [e_io]
    mov eax, edi
    out dx, eax
    add dx, 4
    in eax, dx
    ret
.mm:
    mov rax, [e_mmio]
    mov eax, [rax+rdi]
    ret

e_wr:                               ; edi = register, esi = value (clobbers eax, edx)
    cmp word [e_io], 0
    je .mm
    mov dx, [e_io]
    mov eax, edi
    out dx, eax
    add dx, 4
    mov eax, esi
    out dx, eax
    ret
.mm:
    mov rax, [e_mmio]
    mov [rax+rdi], esi
    ret

e1k_ok:                             ; ax = device id -> ZF=1 when supported
    push rsi
    lea rsi, [e1k_ids]
.l: cmp word [rsi], 0
    je .no
    cmp ax, [rsi]
    je .yes
    add rsi, 2
    jmp .l
.no: or rsi, rsi                    ; ZF=0 (rsi != 0)
    pop rsi
    ret
.yes:
    xor esi, esi                    ; ZF=1
    pop rsi
    ret

; map a 2 MB page uncached (for MMIO BARs), eax = physical address
map_mmio:
    push rax
    push rcx
    shr eax, 21
    mov ecx, eax
    mov rax, 0x102000
    lea rax, [rax+rcx*8]
    or dword [rax], 0x18            ; PWT | PCD
    mov rax, cr3
    mov cr3, rax
    pop rcx
    pop rax
    ret

; net_init: find and start the NIC.  Sets net_ok = 1 on success.
net_init:
    PUSHA
    mov byte [net_ok], 0
    xor r12d, r12d                  ; bus
.bus:
    xor r13d, r13d                  ; device
.dev:
    xor r14d, r14d                  ; function
.fn:
    mov eax, r12d
    shl eax, 16
    mov ecx, r13d
    shl ecx, 11
    or eax, ecx
    mov ecx, r14d
    shl ecx, 8
    or eax, ecx
    mov r15d, eax
    xor ecx, ecx
    call pci_rd
    cmp eax, 0xFFFFFFFF
    je .absent
    cmp ax, 0x8086
    jne .notours
    shr eax, 16
    call e1k_ok
    je .found
.notours:
    test r14d, r14d
    jnz .nextfn
    mov eax, r15d
    mov ecx, 0x0C
    call pci_rd
    test eax, 0x800000              ; multifunction device?
    jz .nextdev
.nextfn:
    inc r14d
    cmp r14d, 8
    jb .fn
    jmp .nextdev
.absent:
    test r14d, r14d
    jnz .nextfn
.nextdev:
    inc r13d
    cmp r13d, 32
    jb .dev
    inc r12d
    cmp r12d, 256
    jb .bus
    jmp .done
.found:
    ; enable I/O, memory and bus mastering
    mov eax, r15d
    mov ecx, 4
    call pci_rd
    or eax, 7
    mov esi, eax
    mov eax, r15d
    mov ecx, 4
    call pci_wr
    ; BAR0 = registers, any I/O BAR = port access
    mov eax, r15d
    mov ecx, 0x10
    call pci_rd
    mov ebx, eax
    and ebx, 0xFFFFFFF0
    and eax, 6
    cmp eax, 4                      ; 64-bit BAR: only usable when it sits below 4 GB
    jne .bar32
    mov eax, r15d
    mov ecx, 0x14
    call pci_rd
    test eax, eax
    jnz .done
.bar32:
    mov [e_mmio], rbx
    mov word [e_io], 0
    test ebx, ebx
    jnz .mm                         ; memory-mapped registers are preferred (QEMU's I/O BAR is a stub)
    mov r8d, 0x14
.bar:
    mov eax, r15d
    mov ecx, r8d
    call pci_rd
    test al, 1
    jz .nb
    and eax, 0xFFFC
    mov [e_io], ax
    jmp .gotio
.nb:
    add r8d, 4
    cmp r8d, 0x28
    jb .bar
.gotio:
    cmp word [e_io], 0
    jne .setup
    jmp .done
.mm:
    mov eax, ebx
    call map_mmio
.setup:
    call e1000_setup
    mov byte [net_ok], 1
.done:
    POPA
    ret

e1000_setup:
    PUSHA
    ; reset
    mov edi, 0
    call e_rd
    or eax, 0x04000000
    mov esi, eax
    mov edi, 0
    call e_wr
    mov ecx, 3000
.dl: in al, 0x80
    dec ecx
    jnz .dl
    mov ecx, 100000
.rst:
    mov edi, 0
    call e_rd
    test eax, 0x04000000
    jz .rd
    dec ecx
    jnz .rst
.rd:
    mov edi, 0xD8                   ; IMC: no interrupts
    mov esi, -1
    call e_wr
    mov edi, 0xC0
    call e_rd
    mov edi, 0                      ; link up, auto speed
    call e_rd
    and eax, ~((1<<3)|(1<<7)|(1<<30)|(1<<31))
    or eax, 0x60
    mov esi, eax
    mov edi, 0
    call e_wr
    ; MAC address from receive-address register 0
    mov edi, 0x5400
    call e_rd
    mov [my_mac], eax
    mov edi, 0x5404
    call e_rd
    mov [my_mac+4], ax
    ; clear multicast table
    xor ebx, ebx
.mta:
    lea edi, [rbx*4+0x5200]
    xor esi, esi
    call e_wr
    inc ebx
    cmp ebx, 128
    jb .mta
    ; rx ring
    mov rdi, N_RXD
    xor ecx, ecx
.rl:
    mov rax, rcx
    shl rax, 11
    add rax, N_RXB
    mov [rdi], rax
    mov qword [rdi+8], 0
    add rdi, 16
    inc ecx
    cmp ecx, NRX
    jb .rl
    mov edi, 0x2800
    mov esi, N_RXD
    call e_wr
    mov edi, 0x2804
    xor esi, esi
    call e_wr
    mov edi, 0x2808
    mov esi, NRX*16
    call e_wr
    mov edi, 0x2810
    xor esi, esi
    call e_wr
    mov edi, 0x2818
    mov esi, NRX-1
    call e_wr
    mov dword [rx_idx], 0
    ; tx ring
    mov rdi, N_TXD
    xor eax, eax
    mov ecx, NTX*4
    rep stosd
    mov edi, 0x3800
    mov esi, N_TXD
    call e_wr
    mov edi, 0x3804
    xor esi, esi
    call e_wr
    mov edi, 0x3808
    mov esi, NTX*16
    call e_wr
    mov edi, 0x3810
    xor esi, esi
    call e_wr
    mov edi, 0x3818
    xor esi, esi
    call e_wr
    mov dword [tx_idx], 0
    mov edi, 0x410                  ; TIPG
    mov esi, 0x0060200A
    call e_wr
    mov edi, 0x400                  ; TCTL: enable, pad short packets
    mov esi, 0x0004010A
    call e_wr
    mov edi, 0x100                  ; RCTL: enable, broadcast accept, strip CRC, 2 KB buffers
    mov esi, 0x0400800A
    call e_wr
    POPA
    ret

; e_send: rsi = frame, ecx = length
e_send:
    PUSHA
    cmp ecx, 1514
    ja .out
    mov r12d, ecx
    mov eax, [tx_idx]
    mov ebx, eax
    shl ebx, 11
    add rbx, N_TXB
    mov rdi, rbx
    rep movsb
    cmp r12d, 60
    jae .len
    mov ecx, 60
    sub ecx, r12d
    xor eax, eax
    rep stosb
    mov r12d, 60
.len:
    mov eax, [tx_idx]
    shl eax, 4
    mov rdx, N_TXD
    add rdx, rax
    mov [rdx], rbx
    mov word [rdx+8], r12w
    mov byte [rdx+10], 0
    mov byte [rdx+11], 0x0B         ; EOP | IFCS | RS
    mov byte [rdx+12], 0
    mov byte [rdx+13], 0
    mov word [rdx+14], 0
    mov eax, [tx_idx]
    inc eax
    cmp eax, NTX
    jb .ni
    xor eax, eax
.ni:
    mov [tx_idx], eax
    mov esi, eax
    mov edi, 0x3818
    call e_wr
    mov ecx, 300000
.w: test byte [rdx+12], 1
    jnz .out
    dec ecx
    jnz .w
.out:
    POPA
    ret

; net_poll: drain the receive ring
net_poll:
    PUSHA
    cmp byte [net_ok], 0
    je .out
    mov edi, 8                      ; STATUS (also latches the link state)
    call e_rd
    mov [e_status], eax
.l: mov eax, [rx_idx]
    shl eax, 4
    mov rbx, N_RXD
    add rbx, rax
    test byte [rbx+12], 1
    jz .out
    movzx ecx, word [rbx+8]
    cmp byte [rbx+13], 0
    jne .skip
    mov eax, [rx_idx]
    shl eax, 11
    mov rsi, N_RXB
    add rsi, rax
    call net_rx_frame
.skip:
    mov byte [rbx+12], 0
    mov esi, [rx_idx]
    mov edi, 0x2818
    call e_wr
    mov eax, [rx_idx]
    inc eax
    cmp eax, NRX
    jb .ni
    xor eax, eax
.ni:
    mov [rx_idx], eax
    jmp .l
.out:
    POPA
    ret

net_rx_frame:                       ; rsi = frame, ecx = length
    cmp ecx, 34
    jb .o
    cmp word [rsi+12], 0x0608
    je arp_in
    cmp word [rsi+12], 0x0008
    je ip_in
.o: ret

; ------------------------------------------------------------- ARP ----------
arp_lookup:                         ; eax = ip -> rsi = mac or 0
    push rcx
    push rdi
    lea rdi, [arp_tab]
    mov ecx, 4
.l: cmp byte [rdi+10], 0
    je .n
    cmp [rdi], eax
    je .f
.n: add rdi, 12
    dec ecx
    jnz .l
    xor esi, esi
    jmp .o
.f: lea rsi, [rdi+4]
.o: pop rdi
    pop rcx
    ret

arp_learn:                          ; eax = ip, rsi = mac
    PUSHA
    lea rdi, [arp_tab]
    mov ecx, 4
.l: cmp byte [rdi+10], 0
    je .use
    cmp [rdi], eax
    je .use
    add rdi, 12
    dec ecx
    jnz .l
    movzx edx, byte [arp_rr]
    inc byte [arp_rr]
    and byte [arp_rr], 3
    imul edx, edx, 12
    lea rdi, [arp_tab+rdx]
.use:
    mov [rdi], eax
    mov eax, [rsi]
    mov [rdi+4], eax
    mov ax, [rsi+4]
    mov [rdi+8], ax
    mov byte [rdi+10], 1
    POPA
    ret

arp_request:                        ; eax = target ip
    PUSHA
    mov r8d, eax
    mov rdi, N_PKT
    mov eax, 0xFFFFFFFF
    stosd
    stosw
    lea rsi, [my_mac]
    movsd
    movsw
    mov ax, 0x0608
    stosw
    mov ax, 0x0100                  ; hardware type ethernet
    stosw
    mov ax, 0x0008                  ; protocol ipv4
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0100                  ; request
    stosw
    lea rsi, [my_mac]
    movsd
    movsw
    mov eax, [my_ip]
    stosd
    xor eax, eax
    stosd
    stosw
    mov eax, r8d
    stosd
    mov rsi, N_PKT
    mov ecx, 42
    call e_send
    POPA
    ret

arp_in:                             ; rsi = frame
    PUSHA
    mov eax, [rsi+28]               ; sender ip
    test eax, eax
    jz .o
    mov ebx, [my_ip]
    test ebx, ebx
    jz .o
    cmp word [rsi+20], 0x0200       ; reply
    je .learn
    cmp word [rsi+20], 0x0100       ; request
    jne .o
    cmp [rsi+38], ebx               ; for us?
    jne .o
    lea rdx, [rsi+22]
    push rax
    mov rsi, rdx
    call arp_learn
    pop rax
    ; reply to the sender
    mov rdi, N_PKT
    mov rsi, rdx
    movsd
    movsw
    lea rsi, [my_mac]
    movsd
    movsw
    mov ax, 0x0608
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0008
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0200
    stosw
    lea rsi, [my_mac]
    movsd
    movsw
    mov eax, [my_ip]
    stosd
    mov rsi, rdx
    movsd
    movsw
    mov eax, [rdx+6]                ; sender ip sits right behind its mac
    stosd
    mov rsi, N_PKT
    mov ecx, 42
    call e_send
    jmp .o
.learn:
    lea rsi, [rsi+22]
    call arp_learn
.o: POPA
    ret

arp_resolve:                        ; eax = destination ip; CF=1 when no mac could be found
    PUSHA
    mov ecx, eax
    xor ecx, [my_ip]
    and ecx, [net_mask]
    jz .ol
    mov eax, [net_gw]
.ol:
    mov r12d, eax
    xor r13d, r13d
.try:
    mov eax, r12d
    call arp_lookup
    test rsi, rsi
    jnz .ok
    mov eax, r12d
    call arp_request
    lea rdi, [tmA]
    mov eax, 1
    call tm_set
.w: call net_poll
    mov eax, r12d
    call arp_lookup
    test rsi, rsi
    jnz .ok
    call yield
    lea rdi, [tmA]
    call tm_chk
    jnc .w
    inc r13d
    cmp r13d, 3
    jb .try
    POPA
    stc
    ret
.ok:
    POPA
    clc
    ret

route_mac:                          ; eax = destination ip -> rsi = next hop mac or 0
    push rax
    push rcx
    mov ecx, eax
    xor ecx, [my_ip]
    and ecx, [net_mask]
    jz .l
    mov eax, [net_gw]
.l: call arp_lookup
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------- IPv4 ---------
csum_acc:                           ; rsi = data, ecx = bytes, edx = running sum
    push rax
    push rbx
    push rcx
    push rsi
    mov ebx, ecx
    shr ecx, 1
    jz .odd
.w: movzx eax, word [rsi]
    add edx, eax
    add rsi, 2
    dec ecx    jnz .w
.odd:
    test ebx, 1
    jz .d
    movzx eax, byte [rsi]
    add edx, eax
.d: pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

csum_fin:                           ; edx = running sum -> ax = checksum (clobbers edx)
    mov eax, edx
.l: mov edx, eax
    shr eax, 16
    and edx, 0xFFFF
    add eax, edx
    cmp eax, 0xFFFF
    ja .l
    not eax
    and eax, 0xFFFF
    ret

; ip_out_mac: eax = dst ip, dl = protocol, ecx = l4 length (already at N_PKT+34), rbx = dst mac
ip_out_mac:
    PUSHA
    mov r8d, eax
    movzx r9d, dl
    mov r10d, ecx
    mov rdi, N_PKT
    mov rsi, rbx
    movsd
    movsw
    lea rsi, [my_mac]
    movsd
    movsw
    mov word [rdi], 0x0008
    add rdi, 2
    mov byte [rdi], 0x45
    mov byte [rdi+1], 0
    mov eax, r10d
    add eax, 20
    xchg al, ah
    mov [rdi+2], ax
    inc word [ip_id]
    mov ax, [ip_id]
    xchg al, ah
    mov [rdi+4], ax
    mov word [rdi+6], 0x0040        ; don't fragment
    mov byte [rdi+8], 64
    mov [rdi+9], r9b
    mov word [rdi+10], 0
    mov eax, [my_ip]
    mov [rdi+12], eax
    mov [rdi+16], r8d
    mov rsi, rdi
    mov ecx, 20
    xor edx, edx
    call csum_acc
    call csum_fin
    mov [rdi+10], ax
    mov rsi, N_PKT
    mov ecx, r10d
    add ecx, 34
    call e_send
    POPA
    ret

ip_out:                             ; eax = dst ip, dl = protocol, ecx = l4 length; mac from the arp cache
    push rbx
    push rsi
    push rax
    call route_mac
    mov rbx, rsi
    pop rax
    pop rsi
    test rbx, rbx
    jz .no
    call ip_out_mac
.no:
    pop rbx
    ret

ip_in:                              ; rsi = frame, ecx = length
    PUSHA
    movzx eax, byte [rsi+14]
    mov ecx, eax
    shr ecx, 4
    cmp ecx, 4
    jne .o
    cmp al, 0x45
    jb .o
    mov r8d, eax
    and r8d, 15
    shl r8d, 2                      ; header length
    test byte [rsi+20], 0x3F        ; more fragments / offset -> drop
    jnz .o
    cmp byte [rsi+21], 0
    jne .o
    mov eax, [rsi+30]               ; destination
    cmp eax, 0xFFFFFFFF
    je .acc
    cmp eax, [my_ip]
    je .acc
    cmp dword [my_ip], 0
    jne .o
.acc:
    movzx r9d, word [rsi+16]
    rol r9w, 8                      ; total length (host order)
    sub r9d, r8d                    ; l4 length
    lea rbx, [rsi+14]
    add rbx, r8                     ; l4 header
    movzx eax, byte [rsi+23]
    cmp eax, 1
    je .icmp
    cmp eax, 17
    je .udp
    cmp eax, 6
    jne .o
    call tcp_in
    jmp .o
.icmp:
    cmp r9d, 8
    jb .o
    cmp byte [rbx], 8
    je .echo
    cmp byte [rbx], 0
    jne .o
    mov ax, [rbx+4]
    cmp ax, 0x3412
    jne .o
    mov ax, [rbx+6]
    cmp ax, [ping_wire]
    jne .o
    mov eax, [rsi+26]
    mov [ping_from], eax
    mov dword [ping_got], 1
    jmp .o
.echo:
    cmp r9d, 1400
    ja .o
    mov r12d, r9d
    mov r13d, [rsi+26]              ; peer ip
    lea r14, [rsi+6]                ; peer mac
    mov rdi, N_PKT+34
    mov rsi, rbx
    mov ecx, r12d
    rep movsb
    mov byte [N_PKT+34], 0
    mov word [N_PKT+36], 0
    mov rsi, N_PKT+34
    mov ecx, r12d
    xor edx, edx
    call csum_acc
    call csum_fin
    mov [N_PKT+36], ax
    mov eax, r13d
    mov dl, 1
    mov ecx, r12d
    mov rbx, r14
    call ip_out_mac
    jmp .o
.udp:
    cmp r9d, 8
    jb .o
    mov ax, [rbx+2]                 ; destination port, wire order
    cmp ax, 0x4400                  ; 68
    je .dhcp
    cmp ax, [dns_lpw]
    jne .o
    sub r9d, 8
    cmp r9d, 1024
    ja .o
    lea rsi, [rbx+8]
    mov rdi, N_DNS
    mov ecx, r9d
    rep movsb
    mov [dns_got], r9d
    jmp .o
.dhcp:
    sub r9d, 8
    cmp r9d, 600
    ja .o
    lea rsi, [rbx+8]
    mov rdi, N_DHCP
    mov ecx, r9d
    rep movsb
    mov [dhcp_got], r9d
.o: POPA
    ret

; ------------------------------------------------------------- DHCP ---------
dhcp_send:                          ; al = 1 discover / 3 request
    PUSHA
    movzx r12d, al
    mov rdi, N_PKT+34
    mov word [rdi], 0x4400          ; 68
    mov word [rdi+2], 0x4300        ; 67
    mov word [rdi+6], 0
    add rdi, 8
    push rdi
    xor eax, eax
    mov ecx, 300/4
    rep stosd
    pop rdi
    mov byte [rdi], 1
    mov byte [rdi+1], 1
    mov byte [rdi+2], 6
    mov eax, [dh_xid]
    mov [rdi+4], eax
    mov word [rdi+10], 0x0080       ; broadcast flag
    mov eax, [my_mac]
    mov [rdi+28], eax
    mov ax, [my_mac+4]
    mov [rdi+32], ax
    mov dword [rdi+236], 0x63538263
    lea rbx, [rdi+240]
    mov byte [rbx], 53
    mov byte [rbx+1], 1
    mov [rbx+2], r12b
    add rbx, 3
    cmp r12d, 3
    jne .pl
    mov byte [rbx], 50
    mov byte [rbx+1], 4
    mov eax, [dh_reqip]
    mov [rbx+2], eax
    mov byte [rbx+6], 54
    mov byte [rbx+7], 4
    mov eax, [dh_reqsrv]
    mov [rbx+8], eax
    add rbx, 12
.pl:
    mov byte [rbx], 55
    mov byte [rbx+1], 3
    mov byte [rbx+2], 1
    mov byte [rbx+3], 3
    mov byte [rbx+4], 6
    mov byte [rbx+5], 255
    mov word [N_PKT+34+4], 0x3401   ; udp length 308
    mov eax, 0xFFFFFFFF
    mov dl, 17
    mov ecx, 308
    lea rbx, [bcast_mac]
    call ip_out_mac
    POPA
    ret

dhcp_parse:                         ; N_DHCP -> eax = message type (0 = not for us)
    push rsi
    push rbx
    mov esi, [dhcp_got]
    cmp esi, 241
    jb .no
    mov rsi, N_DHCP
    cmp byte [rsi], 2
    jne .no
    mov eax, [rsi+4]
    cmp eax, [dh_xid]
    jne .no
    cmp dword [rsi+236], 0x63538263
    jne .no
    mov eax, [rsi+16]
    mov [dh_yi], eax
    mov dword [dh_srv], 0
    mov dword [dh_mask], 0
    mov dword [dh_rt], 0
    mov dword [dh_dns], 0
    xor ebx, ebx
    lea rsi, [rsi+240]
    mov rdx, N_DHCP
    add edx, [dhcp_got]
.o: cmp rsi, rdx
    jae .end
    movzx eax, byte [rsi]
    cmp al, 255
    je .end
    test al, al
    jz .pad
    movzx ecx, byte [rsi+1]
    cmp al, 53
    jne .o1
    movzx ebx, byte [rsi+2]
.o1:
    cmp al, 54
    jne .o2
    mov eax, [rsi+2]
    mov [dh_srv], eax
    jmp .nx
.o2:
    cmp al, 1
    jne .o3
    mov eax, [rsi+2]
    mov [dh_mask], eax
    jmp .nx
.o3:
    cmp al, 3
    jne .o4
    mov eax, [rsi+2]
    mov [dh_rt], eax
    jmp .nx
.o4:
    cmp al, 6
    jne .nx
    mov eax, [rsi+2]
    mov [dh_dns], eax
.nx:
    lea rsi, [rsi+rcx+2]
    jmp .o
.pad:
    inc rsi
    jmp .o
.end:
    mov eax, ebx
    pop rbx
    pop rsi
    ret
.no:
    xor eax, eax
    pop rbx
    pop rsi
    ret

dhcp_wait:                          ; -> eax = message type, 0 on timeout
    push rdi
    lea rdi, [tmB]
    mov eax, 3
    call tm_set
.w: call net_poll
    cmp dword [dhcp_got], 0
    je .nw
    call dhcp_parse
    test eax, eax
    jnz .r
    mov dword [dhcp_got], 0
.nw:
    call yield
    lea rdi, [tmB]
    call tm_chk
    jnc .w
    xor eax, eax
.r: pop rdi
    ret

dhcp_run:                           ; eax = 1 when an address was leased
    PUSHA
    mov dword [my_ip], 0
    mov dword [net_mask], 0
    mov dword [net_gw], 0
    mov dword [net_dns], 0
    lea rdi, [arp_tab]
    mov ecx, 12
    xor eax, eax
    rep stosd
    call rnd
    shl eax, 16
    mov r8d, eax
    call rnd
    or eax, r8d
    mov [dh_xid], eax
    xor r12d, r12d
.disc:
    mov dword [dhcp_got], 0
    mov al, 1
    call dhcp_send
    call dhcp_wait
    cmp eax, 2
    je .offer
    inc r12d
    cmp r12d, 3
    jb .disc
    jmp .fail
.offer:
    mov eax, [dh_yi]
    mov [dh_reqip], eax
    mov eax, [dh_srv]
    mov [dh_reqsrv], eax
    xor r12d, r12d
.req:
    mov dword [dhcp_got], 0
    mov al, 3
    call dhcp_send
    call dhcp_wait
    cmp eax, 5
    je .ack
    inc r12d
    cmp r12d, 3
    jb .req
    jmp .fail
.ack:
    mov eax, [dh_yi]
    mov [my_ip], eax
    mov eax, [dh_mask]
    test eax, eax
    jnz .m
    mov eax, 0x00FFFFFF
.m: mov [net_mask], eax
    mov eax, [dh_rt]
    mov [net_gw], eax
    mov eax, [dh_dns]
    test eax, eax
    jnz .d
    mov eax, [dh_rt]
.d: mov [net_dns], eax
    POPA
    mov eax, 1
    ret
.fail:
    POPA
    xor eax, eax
    ret

; ------------------------------------------------------------- DNS ----------
dns_send:                           ; rsi = name
    PUSHA
    mov r12, rsi
    mov rdi, N_PKT+34
    mov ax, [dns_lpw]
    mov [rdi], ax
    mov word [rdi+2], 0x3500        ; 53
    mov word [rdi+6], 0
    mov ax, [dns_idw]
    mov [rdi+8], ax
    mov word [rdi+10], 0x0001       ; recursion desired
    mov word [rdi+12], 0x0100       ; one question
    mov word [rdi+14], 0
    mov dword [rdi+16], 0
    lea rdi, [rdi+20]
    mov rbx, rdi
    inc rdi
    mov rsi, r12
.c: lodsb
    test al, al
    jz .end
    cmp al, '.'
    je .dot
    stosb
    jmp .c
.dot:
    mov rax, rdi
    sub rax, rbx
    dec eax
    mov [rbx], al
    mov rbx, rdi
    inc rdi
    jmp .c
.end:
    mov rax, rdi
    sub rax, rbx
    dec eax
    mov [rbx], al
    mov byte [rdi], 0
    inc rdi
    mov dword [rdi], 0x01000100     ; type A, class IN
    add rdi, 4
    mov rax, rdi
    sub rax, N_PKT+34               ; udp length
    mov r13d, eax
    xchg al, ah
    mov [N_PKT+34+4], ax
    mov eax, [net_dns]
    mov dl, 17
    mov ecx, r13d
    call ip_out
    POPA
    ret

dns_skip:                           ; rsi = name -> rsi behind it
    push rax
    push rcx
.l: movzx eax, byte [rsi]
    test eax, eax
    jz .z
    mov ecx, eax
    and ecx, 0xC0
    cmp ecx, 0xC0
    je .p
    lea rsi, [rsi+rax+1]
    jmp .l
.z: inc rsi
    jmp .o
.p: add rsi, 2
.o: pop rcx
    pop rax
    ret

dns_parse:                          ; N_DNS -> eax = ip, 0 = answered but no address, -1 = not our reply
    push rbx
    push rcx
    push rsi
    push rdx
    mov rsi, N_DNS
    mov ax, [rsi]
    cmp ax, [dns_idw]
    jne .ign
    test byte [rsi+2], 0x80
    jz .ign
    mov al, [rsi+3]
    and al, 15
    jnz .none
    movzx ebx, word [rsi+6]
    xchg bl, bh                     ; answers
    movzx ecx, word [rsi+4]
    xchg cl, ch                     ; questions
    lea rsi, [rsi+12]
.q: test ecx, ecx
    jz .a
    call dns_skip
    add rsi, 4
    dec ecx
    jmp .q
.a: test ebx, ebx
    jz .none
    mov rdx, N_DNS
    add edx, [dns_got]
    cmp rsi, rdx
    jae .none
    call dns_skip
    movzx eax, word [rsi]
    xchg al, ah
    movzx ecx, word [rsi+8]
    xchg cl, ch
    cmp eax, 1
    jne .nx
    cmp ecx, 4
    jne .nx
    mov eax, [rsi+10]
    jmp .r
.nx:
    lea rsi, [rsi+rcx+10]
    dec ebx
    jmp .a
.none:
    xor eax, eax
    jmp .r
.ign:
    mov eax, -1
.r: pop rdx
    pop rsi
    pop rcx
    pop rbx
    ret

dns_resolve:                        ; rsi = host name -> eax = ip (0 = failed)
    PUSHA
    mov r12, rsi
    mov eax, [net_dns]
    test eax, eax
    jz .fail
    call arp_resolve
    jc .fail
    xor r13d, r13d
.try:
    mov dword [dns_got], 0
    call rnd
    mov [dns_idw], ax
    mov rsi, r12
    call dns_send
    lea rdi, [tmB]
    mov eax, 2
    call tm_set
.w: call net_poll
    cmp dword [dns_got], 0
    je .nw
    call dns_parse
    cmp eax, -1
    jne .got
    mov dword [dns_got], 0
.nw:
    call yield
    lea rdi, [tmB]
    call tm_chk
    jnc .w
    inc r13d
    cmp r13d, 3
    jb .try
.fail:
    POPA
    xor eax, eax
    ret
.got:
    mov [dns_res], eax
    POPA
    mov eax, [dns_res]
    ret

; ------------------------------------------------------------- ICMP ---------
net_ping:                           ; eax = ip -> eax = 1 when a reply came
    PUSHA
    mov r12d, eax
    call arp_resolve
    jc .fail
    inc word [ping_seq]
    mov ax, [ping_seq]
    xchg al, ah
    mov [ping_wire], ax
    mov dword [ping_got], 0
    mov rdi, N_PKT+34
    mov byte [rdi], 8
    mov byte [rdi+1], 0
    mov word [rdi+2], 0
    mov word [rdi+4], 0x3412
    mov ax, [ping_wire]
    mov [rdi+6], ax
    xor ecx, ecx
.p: mov al, cl
    add al, 'a'
    and al, 0x7F
    mov [rdi+8+rcx], al
    inc ecx
    cmp ecx, 32
    jb .p
    mov rsi, rdi
    mov ecx, 40
    xor edx, edx
    call csum_acc
    call csum_fin
    mov [N_PKT+34+2], ax
    mov eax, r12d
    mov dl, 1
    mov ecx, 40
    call ip_out
    lea rdi, [tmB]
    mov eax, 3
    call tm_set
.w: call net_poll
    cmp dword [ping_got], 0
    jne .ok
    call yield
    lea rdi, [tmB]
    call tm_chk
    jnc .w
.fail:
    POPA
    xor eax, eax
    ret
.ok:
    POPA
    mov eax, 1
    ret

; ------------------------------------------------------------- TCP ----------
tcp_send:                           ; al = flags, rsi = payload, ecx = payload length
    PUSHA
    movzx r12d, al
    mov r13, rsi
    mov r14d, ecx
    mov rdi, N_PKT+34
    mov ax, [tc_lport]
    xchg al, ah
    mov [rdi], ax
    mov ax, [tc_rport]
    xchg al, ah
    mov [rdi+2], ax
    mov eax, [tc_snd_nxt]
    bswap eax
    mov [rdi+4], eax
    mov eax, [tc_rcv_nxt]
    bswap eax
    mov [rdi+8], eax
    mov r15d, 20
    mov byte [rdi+12], 0x50
    test r12b, 2
    jz .nsyn
    mov byte [rdi+12], 0x60
    mov dword [rdi+20], 0xB4050402  ; MSS 1460
    mov r15d, 24
.nsyn:
    mov [rdi+13], r12b
    mov word [rdi+14], 0x0040       ; window 16384
    mov word [rdi+16], 0
    mov word [rdi+18], 0
    lea rdi, [rdi+r15]
    mov rsi, r13
    mov ecx, r14d
    rep movsb
    lea rdi, [ps_hdr]
    mov eax, [my_ip]
    mov [rdi], eax
    mov eax, [tc_rip]
    mov [rdi+4], eax
    mov byte [rdi+8], 0
    mov byte [rdi+9], 6
    mov eax, r15d
    add eax, r14d
    xchg al, ah
    mov [rdi+10], ax
    xor edx, edx
    mov rsi, rdi
    mov ecx, 12
    call csum_acc
    mov rsi, N_PKT+34
    mov ecx, r15d
    add ecx, r14d
    call csum_acc
    call csum_fin
    mov [N_PKT+34+16], ax
    mov eax, [tc_snd_nxt]
    add eax, r14d
    test r12b, 3                    ; SYN or FIN use one sequence number
    jz .sn
    inc eax
.sn:
    mov [tc_snd_nxt], eax
    mov eax, [tc_rip]
    mov dl, 6
    mov ecx, r15d
    add ecx, r14d
    call ip_out
    POPA
    ret

tcp_ack:
    push rax
    push rcx
    push rsi
    mov al, 0x10
    xor ecx, ecx
    xor esi, esi
    call tcp_send
    pop rsi
    pop rcx
    pop rax
    ret

tcp_in:                             ; rsi = frame, r8d = ip header length, rbx = tcp header, r9d = tcp length
    PUSHA
    mov r10d, r9d
    mov r9, rbx
    cmp r10d, 20
    jb .out
    movzx eax, byte [r9+12]
    shr eax, 4
    shl eax, 2
    mov r11d, eax                   ; tcp header length
    mov r12d, r10d
    sub r12d, r11d                  ; payload length
    js .out
    cmp byte [tc_state], 0
    je .out
    mov eax, [rsi+26]
    cmp eax, [tc_rip]
    jne .out
    mov ax, [r9]
    xchg al, ah
    cmp ax, [tc_rport]
    jne .out
    mov ax, [r9+2]
    xchg al, ah
    cmp ax, [tc_lport]
    jne .out
    mov eax, [r9+4]
    bswap eax
    mov r13d, eax                   ; seq
    mov eax, [r9+8]
    bswap eax
    mov r14d, eax                   ; ack
    movzx r15d, byte [r9+13]        ; flags
    lea r10d, [r13+r12]             ; sequence number right behind the payload
    test r15d, 4
    jz .norst
    mov byte [tc_rst], 1
    mov byte [tc_state], 0
    jmp .out
.norst:
    cmp byte [tc_state], 1
    jne .est
    mov eax, r15d
    and eax, 0x12
    cmp eax, 0x12
    jne .out
    cmp r14d, [tc_snd_nxt]
    jne .out
    lea eax, [r13+1]
    mov [tc_rcv_nxt], eax
    mov [tc_snd_una], r14d
    mov byte [tc_state], 2
    call tcp_ack
    jmp .out
.est:
    test r15d, 0x10
    jz .nack
    mov eax, r14d
    sub eax, [tc_snd_una]
    jle .nack
    mov edx, [tc_snd_nxt]
    sub edx, r14d
    js .nack
    mov [tc_snd_una], r14d
    mov eax, [tc_snd_nxt]
    cmp r14d, eax
    jne .nack
    cmp byte [tc_state], 3
    jne .nack
    mov byte [tc_ackd], 1
.nack:
    lea r8, [r9+r11]                ; payload
    test r12d, r12d
    jz .fin
    mov eax, [tc_rcv_nxt]
    sub eax, r13d                   ; bytes of this segment we already have
    jl .need
    cmp eax, r12d
    jae .need
    add r8, rax
    sub r12d, eax
    mov eax, [tc_rlen]
    mov ecx, r12d
    add ecx, eax
    cmp ecx, [tc_rmax]
    ja .trunc
    mov rdi, [tc_rbuf]
    add rdi, rax
    mov rsi, r8
    mov ecx, r12d
    rep movsb
    mov eax, [tc_rlen]
    add eax, r12d
    mov [tc_rlen], eax
    jmp .adv
.trunc:
    mov byte [tc_trunc], 1
.adv:
    add [tc_rcv_nxt], r12d
.need:
    mov byte [tc_needack], 1
.fin:
    test r15d, 1
    jz .nofin
    cmp [tc_rcv_nxt], r10d
    jne .nofin
    inc dword [tc_rcv_nxt]
    mov byte [tc_fin], 1
    mov byte [tc_needack], 1
.nofin:
    cmp byte [tc_needack], 0
    je .out
    mov byte [tc_needack], 0
    call tcp_ack
.out:
    POPA
    ret

tcp_connect:                        ; eax = ip, ecx = port -> eax = 1 when connected
    PUSHA
    mov [tc_rip], eax
    mov [tc_rport], cx
    call arp_resolve
    jc .fail
    call rnd
    and eax, 0x3FFF
    add eax, 49152
    mov [tc_lport], ax
    call rnd
    shl eax, 15
    mov r8d, eax
    call rnd
    xor eax, r8d
    mov [tc_isn], eax
    mov dword [tc_rlen], 0
    mov byte [tc_fin], 0
    mov byte [tc_rst], 0
    mov byte [tc_trunc], 0
    mov byte [tc_ackd], 0
    mov byte [tc_needack], 0
    mov dword [tc_rcv_nxt], 0
    mov byte [tc_state], 1
    xor r12d, r12d
.syn:
    mov eax, [tc_isn]
    mov [tc_snd_nxt], eax
    mov [tc_snd_una], eax
    mov al, 0x02
    xor ecx, ecx
    xor esi, esi
    call tcp_send
    lea rdi, [tmB]
    mov eax, 2
    call tm_set
.w: call net_poll
    cmp byte [tc_state], 2
    je .ok
    cmp byte [tc_rst], 0
    jne .fail
    call yield
    lea rdi, [tmB]
    call tm_chk
    jnc .w
    inc r12d
    cmp r12d, 3
    jb .syn
.fail:
    mov byte [tc_state], 0
    POPA
    xor eax, eax
    ret
.ok:
    POPA
    mov eax, 1
    ret

tcp_close:                          ; orderly close of the single connection
    PUSHA
    cmp byte [tc_state], 2
    jne .rst
    mov al, 0x11
    xor ecx, ecx
    xor esi, esi
    call tcp_send
    mov byte [tc_state], 3
    lea rdi, [tmB]
    mov eax, 1
    call tm_set
.w: call net_poll
    cmp byte [tc_ackd], 0
    jne .done
    call yield
    lea rdi, [tmB]
    call tm_chk
    jnc .w
    jmp .done
.rst:
    cmp byte [tc_state], 3
    je .done
    cmp byte [tc_state], 1
    jne .done
    mov al, 0x14
    xor ecx, ecx
    xor esi, esi
    call tcp_send
.done:
    mov byte [tc_state], 0
    POPA
    ret

; ------------------------------------------------------------- URLs ---------
; url_parse: net_url -> net_host, net_port, net_path; eax = 0 ok, E_HTTPS, E_URL
url_parse:
    PUSHA
    mov byte [net_tls], 0
    lea rsi, [net_url]
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x70747468             ; "http"
    jne .ns
    mov al, [rsi+4]
    or al, 0x20
    cmp al, 's'
    jne .h1
    cmp byte [rsi+5], ':'
    jne .ns
    cmp word [rsi+6], '//'
    jne .bad
    mov byte [net_tls], 1
    add rsi, 8
    jmp .host
.h1:
    cmp byte [rsi+4], ':'
    jne .ns
    cmp word [rsi+5], '//'
    jne .bad
    add rsi, 7
    jmp .host
.ns:
    mov rdi, rsi                    ; a scheme we do not know (ftp:// ...)?
.sc:
    mov al, [rdi]
    test al, al
    jz .host
    cmp al, '/'
    je .host
    cmp al, ':'
    je .colon
    inc rdi
    jmp .sc
.colon:
    cmp word [rdi+1], '//'
    je .bad
    jmp .host
.host:
    lea rdi, [net_host]
    xor ecx, ecx
.hl:
    mov al, [rsi]
    test al, al
    jz .he
    cmp al, ':'
    je .he
    cmp al, '/'
    je .he
    cmp al, '?'
    je .he
    cmp al, '#'
    je .he
    cmp ecx, 120
    jae .bad
    or al, 0                        ; keep as typed
    mov [rdi+rcx], al
    inc ecx    inc rsi
    jmp .hl
.he:
    test ecx, ecx
    jz .bad
    mov byte [rdi+rcx], 0
    mov ax, 80
    cmp byte [net_tls], 0
    je .dp
    mov ax, 443
.dp:
    mov [net_port], ax
    cmp byte [rsi], ':'
    jne .path
    inc rsi
    xor eax, eax
.pl:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .pe
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .bad
    inc rsi
    jmp .pl
.pe:
    test eax, eax
    jz .bad
    mov [net_port], ax
.path:
    lea rdi, [net_path]
    cmp byte [rsi], '/'
    je .pc
    mov byte [rdi], '/'
    inc rdi
    cmp byte [rsi], '?'
    je .pc
    mov byte [rdi], 0
    jmp .okk
.pc:
    xor ecx, ecx
.pcl:
    mov al, [rsi]
    test al, al
    jz .pz
    cmp al, '#'
    je .pz
    cmp al, ' '
    je .esc
    cmp ecx, 500
    jae .pz
    mov [rdi+rcx], al
    inc ecx
    inc rsi
    jmp .pcl
.esc:
    cmp ecx, 498
    jae .pz
    mov byte [rdi+rcx], '%'
    mov byte [rdi+rcx+1], '2'
    mov byte [rdi+rcx+2], '0'
    add ecx, 3
    inc rsi
    jmp .pcl
.pz:
    mov byte [rdi+rcx], 0
.okk:
    POPA
    xor eax, eax
    ret
.bad:
    POPA
    mov eax, E_URL
    ret

ip_literal:                         ; net_host -> eax = ip, CF=1 when it is not a dotted quad
    push rbx
    push rcx
    push rdx
    push rsi
    lea rsi, [net_host]
    xor ebx, ebx
.oct:
    xor eax, eax
    xor ecx, ecx
.dg:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul eax, eax, 10
    add eax, edx
    cmp eax, 255
    ja .no
    inc ecx
    inc rsi
    jmp .dg
.end:
    test ecx, ecx
    jz .no
    mov [ip_tmp+rbx], al
    inc ebx
    cmp ebx, 4
    je .four
    cmp byte [rsi], '.'
    jne .no
    inc rsi
    jmp .oct
.four:
    cmp byte [rsi], 0
    jne .no
    mov eax, [ip_tmp]
    clc
    jmp .r
.no:
    stc
.r: pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- end net.inc
; ---- begin net2.inc
; =============================================================================
;  NETWORK part 2: bring-up, HTTP/1.0 fetch, URL resolving, helpers, data
; =============================================================================

; net_ensure -> eax = 0 when a link and an address exist, otherwise an E_ code
net_ensure:
    push rdi
    cmp byte [net_ok], 0
    jne .have
    cmp byte [net_tried], 0
    jne .nonic
    mov byte [net_tried], 1
    call net_init
    cmp byte [net_ok], 0
    jne .have
.nonic:
    pop rdi
    mov eax, E_NONIC
    ret
.have:
    lea rdi, [tmA]
    mov eax, 3
    call tm_set
.lk:
    call net_poll
    test byte [e_status], 2
    jnz .up
    call yield
    lea rdi, [tmA]
    call tm_chk
    jnc .lk
    pop rdi
    mov eax, E_LINK
    ret
.up:
    cmp dword [my_ip], 0
    jne .ok
    call dhcp_run
    test eax, eax
    jnz .ok
    pop rdi
    mov eax, E_DHCP
    ret
.ok:
    pop rdi
    xor eax, eax
    ret

; net_reset: forget the lease and rescan for a card on the next use
net_reset:
    mov byte [net_tried], 0
    mov byte [net_ok], 0
    mov dword [my_ip], 0
    mov dword [net_gw], 0
    mov dword [net_mask], 0
    mov dword [net_dns], 0
    ret

; ------------------------------------------------------------- HTTP ---------
http_build_req:                     ; -> ecx = length, text at N_REQ
    push rsi
    push rdi
    push rax
    mov rdi, N_REQ
    lea rsi, [s_hget]
    call sappend
    lea rsi, [net_path]
    call sappend
    lea rsi, [s_hhost]
    call sappend
    lea rsi, [net_host]
    call sappend
    mov ax, 80
    cmp byte [net_tls], 0
    je .dp
    mov ax, 443
.dp:
    cmp [net_port], ax
    je .np
    mov byte [rdi], ':'
    inc rdi
    movzx eax, word [net_port]
    call u2s
.np:
    lea rsi, [s_htail]
    call sappend
    mov rcx, rdi
    sub rcx, N_REQ
    pop rax
    pop rdi
    pop rsi
    ret

; hdr_is: rsi = header line, rdi = lower-case prefix (zstr) -> ZF=1 when the line starts with it (ignoring case)
hdr_is:
    push rsi
    push rdi
    push rax
.l: mov al, [rdi]
    test al, al
    jz .y
    mov ah, [rsi]
    or ah, 0x20
    cmp al, ah
    jne .n
    inc rsi
    inc rdi
    jmp .l
.y: xor eax, eax                    ; ZF=1
    jmp .r
.n: or eax, 1                       ; ZF=0
.r: pop rax
    pop rdi
    pop rsi
    ret

; line_has: rsi = line (ends at CR/LF/NUL), rdi = lower-case word -> ZF=1 when found
line_has:
    push rsi
    push rdi
    push rbx
    push rcx
.s: mov al, [rsi]
    cmp al, 13
    je .n
    cmp al, 10
    je .n
    test al, al
    jz .n
    mov rbx, rsi
    mov rcx, rdi
.c: mov dl, [rcx]
    test dl, dl
    jz .y
    mov dh, [rbx]
    or dh, 0x20
    cmp dl, dh
    jne .nx
    inc rbx
    inc rcx
    jmp .c
.nx:
    inc rsi
    jmp .s
.y: xor eax, eax
    jmp .r
.n: or eax, 1
.r: pop rcx
    pop rbx
    pop rdi
    pop rsi
    ret

; http_parse: RAWB (tc_rlen bytes) -> HTTPB; eax = 0 ok, E_RESP when it is not HTTP
http_parse:
    PUSHA
    mov dword [http_status], 0
    mov byte [http_loc], 0
    mov byte [http_chunked], 0
    mov byte [http_class], 1
    mov r12d, [tc_rlen]
    cmp r12d, 12
    jb .bad
    mov rsi, RAWB
    cmp dword [rsi], 'HTTP'
    jne .bad
    ; status code
    movzx eax, byte [rsi+9]
    sub eax, '0'
    imul eax, eax, 10
    movzx edx, byte [rsi+10]
    sub edx, '0'
    add eax, edx
    imul eax, eax, 10
    movzx edx, byte [rsi+11]
    sub edx, '0'
    add eax, edx
    mov [http_status], eax
    ; end of headers
    mov r13, RAWB
    lea r14, [r13+r12]              ; end of data
    mov rsi, r13
.he:
    lea rax, [rsi+4]
    cmp rax, r14
    ja .nohdr
    cmp dword [rsi], 0x0A0D0A0D
    je .hfound
    inc rsi
    jmp .he
.nohdr:
    mov r15, r14                    ; headers only
    jmp .hdrs
.hfound:
    lea r15, [rsi+4]                ; start of body
.hdrs:
    ; walk the header lines
    mov rsi, r13
.nl:
    cmp byte [rsi], 10
    je .got
    inc rsi
    cmp rsi, r15
    jb .nl
    jmp .body
.got:
    inc rsi
    cmp rsi, r15
    jae .body
    cmp byte [rsi], 13
    je .body
    lea rdi, [h_ct]
    call hdr_is
    jne .t1
    lea rdi, [w_html]
    call line_has
    je .ishtml
    lea rdi, [w_text]
    call line_has
    je .istext
    lea rdi, [w_json]
    call line_has
    je .istext
    lea rdi, [w_xml]
    call line_has
    je .istext
    mov byte [http_class], 3
    jmp .nl
.ishtml:
    mov byte [http_class], 1
    jmp .nl
.istext:
    mov byte [http_class], 2
    jmp .nl
.t1:
    lea rdi, [h_te]
    call hdr_is
    jne .t2
    lea rdi, [w_chunked]
    call line_has
    jne .nl
    mov byte [http_chunked], 1
    jmp .nl
.t2:
    lea rdi, [h_loc]
    call hdr_is
    jne .nl
    lea rdx, [rsi+9]
.sp:
    cmp byte [rdx], ' '
    jne .cp
    inc rdx
    jmp .sp
.cp:
    lea rdi, [http_loc]
    xor ecx, ecx
.cl:
    mov al, [rdx]
    cmp al, 13
    je .ce
    cmp al, 10
    je .ce
    test al, al
    jz .ce
    cmp ecx, 500
    jae .ce
    mov [rdi+rcx], al
    inc ecx
    inc rdx
    jmp .cl
.ce:
    mov byte [rdi+rcx], 0
    jmp .nl
.body:
    ; destination slot
    mov rdi, HTTPB
    xor eax, eax
    mov ecx, 16
    rep stosd
    mov rdi, HTTPB
    cmp byte [http_class], 1
    je .nm1
    lea rsi, [s_nettxt]
    jmp .nm2
.nm1:
    lea rsi, [s_nethtm]
.nm2:
    call strcpy
    mov rdi, HTTPB+64
    cmp byte [http_class], 3
    jne .copy
    lea rsi, [s_binary]
    call sappend
    jmp .fin
.copy:
    cmp byte [http_chunked], 0
    jne .chunk
    mov rsi, r15
    mov rcx, r14
    sub rcx, rsi
    cmp rcx, HTTP_MAX
    jbe .cc
    mov ecx, HTTP_MAX
.cc:
    rep movsb
    jmp .fin
.chunk:
    mov rsi, r15
.ch:
    cmp rsi, r14
    jae .fin
    xor eax, eax
.hx:
    movzx edx, byte [rsi]
    cmp dl, '0'
    jb .hxe
    cmp dl, '9'
    jbe .dg
    or dl, 0x20
    cmp dl, 'a'
    jb .hxe
    cmp dl, 'f'
    ja .hxe
    sub dl, 'a'-10
    jmp .ad
.dg:
    sub dl, '0'
.ad:
    shl eax, 4
    or eax, edx
    inc rsi
    jmp .hx
.hxe:
    cmp rsi, r14                    ; skip chunk extensions up to the line end
    jae .fin
    cmp byte [rsi], 10
    je .le
    inc rsi
    jmp .hxe
.le:
    inc rsi
    test eax, eax
    jz .fin
    mov rcx, r14
    sub rcx, rsi
    cmp rcx, rax
    jbe .ok2
    mov ecx, eax
.ok2:
    mov rdx, rdi
    sub rdx, HTTPB+64
    add rdx, rcx
    cmp rdx, HTTP_MAX
    ja .fin
    rep movsb
    cmp byte [rsi], 13
    jne .l2
    inc rsi
.l2:
    cmp byte [rsi], 10
    jne .ch
    inc rsi
    jmp .ch
.fin:
    mov rax, rdi
    sub rax, HTTPB+64
    mov [HTTPB+48], eax
    POPA
    xor eax, eax
    ret
.bad:
    POPA
    mov eax, E_RESP
    ret

; ------------------------------------------------------------- URL join -----
; url_origin_len: rsi = absolute url -> eax = length of "http://host[:port]"
url_origin_len:
    push rsi
    xor eax, eax
    cmp byte [rsi+4], ':'
    je .h4
    cmp byte [rsi+5], ':'
    jne .n
    add eax, 8                      ; https://
    add rsi, 8
    jmp .l
.h4:
    add eax, 7                      ; http://
    add rsi, 7
.l: mov dl, [rsi]
    test dl, dl
    jz .d
    cmp dl, '/'
    je .d
    cmp dl, '?'
    je .d
    cmp dl, '#'
    je .d
    inc eax
    inc rsi
    jmp .l
.n: mov eax, 0
.d: pop rsi
    ret

; url_resolve: rsi = link, rdi = absolute base url, rdx = output (>= 600 bytes); output empty when unsupported
url_resolve:
    PUSHA
    mov r12, rdx
    mov r13, rdi
    mov r14, rsi
.sk:
    cmp byte [r14], ' '
    jne .go
    inc r14
    jmp .sk
.go:
    mov byte [r12], 0
    mov rsi, r14
    cmp byte [rsi], 0
    je .done
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x70747468             ; http
    jne .nh
    mov al, [rsi+4]
    or al, 0x20
    cmp al, 's'
    je .full
    cmp byte [rsi+4], ':'
    je .full
.nh:
    cmp word [rsi], '//'
    jne .n2
    mov rdi, r12
    lea rsi, [s_http]
    mov al, [r13+4]
    or al, 0x20
    cmp al, 's'
    jne .pr
    lea rsi, [s_https]              ; "//host/x" keeps the scheme of the page it is on
.pr:
    call sappend
    lea rsi, [r14+2]
    call sappend
    jmp .norm
.n2:
    ; other schemes (mailto:, javascript:, ...) before any '/'
    mov rsi, r14
.sc:
    mov al, [rsi]
    test al, al
    jz .rel
    cmp al, '/'
    je .rel
    cmp al, '?'
    je .rel
    cmp al, '#'
    je .rel
    cmp al, ':'
    je .done
    inc rsi
    jmp .sc
.rel:
    mov rsi, r13
    call url_origin_len
    mov r15d, eax
    mov rdi, r12
    mov rsi, r13
    mov ecx, r15d
    rep movsb
    mov byte [rdi], 0
    mov al, [r14]
    cmp al, '/'
    je .abs
    cmp al, '#'
    je .frag
    cmp al, '?'
    je .query
    ; relative path: base directory
    mov rsi, r13
    add rsi, r15
    mov rcx, rsi                    ; last slash in the base path
    mov rbx, rsi
.ls:
    mov al, [rsi]
    test al, al
    jz .le
    cmp al, '?'
    je .le
    cmp al, '#'
    je .le
    cmp al, '/'
    jne .ln
    lea rbx, [rsi+1]
.ln:
    inc rsi
    jmp .ls
.le:
    mov rsi, r13
    add rsi, r15
    cmp rbx, rsi
    jne .hasdir
    mov byte [rdi], '/'
    inc rdi
    jmp .tail
.hasdir:
    mov rcx, rbx
    sub rcx, rsi
    rep movsb
.tail:
    mov rsi, r14
    call sappend
    jmp .norm
.abs:
    mov rsi, r14
    call sappend
    jmp .norm
.frag:
    mov rdi, r12                    ; the base without its own fragment, plus the new one
    mov rsi, r13
.fl:
    mov al, [rsi]
    test al, al
    jz .fa
    cmp al, '#'
    je .fa
    stosb
    inc rsi
    jmp .fl
.fa:
    mov rsi, r14
    call sappend
    jmp .done
.query:
    mov rdi, r12
    mov rsi, r13
.ql:
    mov al, [rsi]
    test al, al
    jz .qa
    cmp al, '?'
    je .qa
    cmp al, '#'
    je .qa
    stosb
    inc rsi
    jmp .ql
.qa:
    mov rsi, r14
    call sappend
    jmp .done
.full:
    mov rdi, r12
    mov rsi, r14
    call sappend
.norm:
    mov rdi, r12
    call url_norm
.done:
    POPA
    ret

; url_norm: rdi = absolute url; removes "./" and "x/../" from the path in place
url_norm:
    PUSHA
    mov rsi, rdi
    call url_origin_len
    test eax, eax
    jz .o
    lea rsi, [rdi+rax]              ; path start (read)
    mov rbx, rsi                    ; first path byte: never back up beyond it
    mov r8, rsi                     ; write pointer
    cmp byte [rsi], '/'
    jne .o
.seg:
    ; rsi at '/' or at the end of the path
    mov al, [rsi]
    cmp al, '/'
    jne .tailcopy
    ; look at the next segment
    cmp byte [rsi+1], '.'
    jne .plain
    mov al, [rsi+2]
    cmp al, '/'
    je .dot
    test al, al
    jz .dotend
    cmp al, '?'
    je .dotend
    cmp al, '#'
    je .dotend
    cmp al, '.'
    jne .plain
    mov al, [rsi+3]
    cmp al, '/'
    je .dd
    test al, al
    jz .dd
    cmp al, '?'
    je .dd
    cmp al, '#'
    je .dd
.plain:
    mov byte [r8], '/'
    inc r8
    inc rsi
.pl:
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, '/'
    je .seg
    cmp al, '?'
    je .tailcopy
    cmp al, '#'
    je .tailcopy
    mov [r8], al
    inc r8
    inc rsi
    jmp .pl
.dot:
    add rsi, 2                      ; "/./" -> "/"
    jmp .seg
.dotend:
    add rsi, 2                      ; trailing "/." -> "/"
    mov byte [r8], '/'
    inc r8
    jmp .tailcopy
.dd:
    ; "/../": drop the last written segment
    add rsi, 3
.up:
    cmp r8, rbx
    jbe .upd
    dec r8
    cmp byte [r8], '/'
    jne .up
.upd:
    cmp byte [rsi], '/'
    je .seg
    mov byte [r8], '/'
    inc r8
    jmp .tailcopy
.tailcopy:
    mov al, [rsi]
    mov [r8], al
    inc rsi
    inc r8
    test al, al
    jnz .tailcopy
    jmp .o
.end:
    mov byte [r8], 0
.o: POPA
    ret

; ------------------------------------------------------------- fetch --------
; http_fetch: rsi = url (http://host/path, or just host/path) -> eax = 0 or an E_ code.
; The page is left in HTTPB as a file slot; http_status holds the HTTP status.
http_fetch:
    PUSHA
    call net_lock
    mov rdi, net_url
    mov ecx, 500
.cp:
    lodsb
    stosb
    test al, al
    jz .cd
    dec ecx
    jnz .cp
    mov byte [rdi], 0
.cd:
    mov dword [http_redirs], 0
.again:
    mov dword [http_status], 0
    mov byte [tc_trunc], 0
    call url_parse
    test eax, eax
    jnz .err
    call net_ensure
    test eax, eax
    jnz .err
    call ip_literal
    jnc .haveip
    lea rsi, [net_host]
    call dns_resolve
    test eax, eax
    jnz .haveip
    mov eax, E_DNS
    jmp .err
.haveip:
    mov [http_ip], eax
    mov rax, RAWB
    mov [tc_rbuf], rax
    mov dword [tc_rmax], RAW_MAX
    mov eax, [http_ip]
    movzx ecx, word [net_port]
    call tcp_connect
    test eax, eax
    jnz .conn
    mov eax, E_CONN
    jmp .err
.conn:
    cmp byte [net_tls], 0
    je .req
    call tls_handshake
    test eax, eax
    jnz .req
    call tcp_close
    mov eax, E_TLS
    jmp .err
.req:
    call http_build_req
    mov [req_len], ecx
    mov rsi, N_REQ
    cmp byte [net_tls], 0
    je .plainsend
    call tls_send_app
    jmp .sent
.plainsend:
    mov al, 0x18
    call tcp_send
.sent:
    mov dword [http_retx], 0
    mov dword [last_rlen], 0
    lea rdi, [tmC]
    mov eax, 15
    call tm_set
    lea rdi, [tmD]
    mov eax, 2
    call tm_set
.rl:
    call net_poll
    cmp byte [net_tls], 0
    je .nt
    call tls_pump
    cmp qword [V_ERR], 0
    jne .got
    cmp qword [V_CLOSED], 0
    jne .got
.nt:
    cmp byte [tc_fin], 0
    jne .got
    cmp byte [tc_rst], 0
    jne .got
    cmp byte [tc_trunc], 0
    jne .got
    mov eax, [tc_rlen]
    cmp eax, [last_rlen]
    je .np
    mov [last_rlen], eax
    lea rdi, [tmC]
    mov eax, 15
    call tm_set
.np:
    mov eax, [tc_snd_una]
    cmp eax, [tc_snd_nxt]
    je .nore
    lea rdi, [tmD]
    call tm_chk
    jnc .nore
    cmp dword [http_retx], 3
    jae .nore
    inc dword [http_retx]
    cmp byte [net_tls], 0
    je .plainre
    call tls_resend                 ; the very same encrypted bytes again
    jmp .rearm
.plainre:
    mov eax, [tc_snd_una]
    mov [tc_snd_nxt], eax
    mov rsi, N_REQ
    mov ecx, [req_len]
    mov al, 0x18
    call tcp_send
.rearm:
    lea rdi, [tmD]
    mov eax, 2
    call tm_set
.nore:
    call yield
    lea rdi, [tmC]
    call tm_chk
    jnc .rl
.got:
    cmp byte [net_tls], 0
    je .tclose
    call tls_pump                   ; whatever is still unread
    cmp qword [V_ERR], 0
    jne .tlserr
    call tls_close_notify
    mov eax, [V_WPOS]               ; from here on RAWB holds the decrypted response
    mov [tc_rlen], eax
.tclose:
    call tcp_close
    call http_parse
    test eax, eax
    jnz .err
    mov eax, [http_status]
    cmp eax, 301
    je .redir
    cmp eax, 302
    je .redir
    cmp eax, 303
    je .redir
    cmp eax, 307
    je .redir
    cmp eax, 308
    jne .okk
.redir:
    cmp byte [http_loc], 0
    je .okk
    inc dword [http_redirs]
    cmp dword [http_redirs], 6
    jbe .rd
    mov eax, E_REDIR
    jmp .err
.rd:
    lea rsi, [http_loc]
    lea rdi, [net_url]
    lea rdx, [url_tmp]
    call url_resolve
    cmp byte [url_tmp], 0
    je .okk
    lea rsi, [url_tmp]
    lea rdi, [net_url]
    call strcpy
    jmp .again
.tlserr:
    call tcp_close
    mov eax, E_TLS
    jmp .err
.okk:
    xor eax, eax
.err:
    mov [http_err], eax
    call net_unlock
    POPA
    mov eax, [http_err]
    ret

; net_errmsg: eax = E_ code -> rsi = message text
net_errmsg:
    lea rsi, [em_unknown]
    cmp eax, E_NONIC
    jne .1
    lea rsi, [em_nonic]
    ret
.1:
.2: cmp eax, E_DHCP
    jne .3
    lea rsi, [em_dhcp]
    ret
.3: cmp eax, E_DNS
    jne .4
    lea rsi, [em_dns]
    ret
.4: cmp eax, E_CONN
    jne .5
    lea rsi, [em_conn]
    ret
.5: cmp eax, E_RESP
    jne .6
    lea rsi, [em_resp]
    ret
.6: cmp eax, E_URL
    jne .7
    lea rsi, [em_url]
    ret
.7: cmp eax, E_REDIR
    jne .8    lea rsi, [em_redir]
    ret
.8: cmp eax, E_LINK
    jne .9
    lea rsi, [em_link]
    ret
.9: cmp eax, E_TLS
    jne .10
    jmp tls_errtext
.10: ret

; ip2s: eax = ip (memory order), rdi = dest -> dotted text, rdi at the NUL
ip2s:
    push rax
    push rcx
    push rdx
    mov ecx, 4
    mov edx, eax
.l: movzx eax, dl
    call u2s
    shr edx, 8
    dec ecx
    jz .d
    mov byte [rdi], '.'
    inc rdi
    jmp .l
.d: pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------- terminal ----
tc_hex2:                            ; al = byte -> two hex digits at rdi
    push rax
    mov ah, al
    shr al, 4
    call .d
    mov al, ah
    and al, 15
    call .d
    pop rax
    ret
.d: and al, 15
    cmp al, 10
    jb .n
    add al, 'a'-10-'0'
.n: add al, '0'
    mov [rdi], al
    inc rdi
    ret

tc_say:                             ; TMPB text + newline
    push rsi
    mov rsi, TMPB
    call tput_s
    call tnl
    pop rsi
    ret

tc_err:                             ; eax = E_ code
    push rsi
    call net_errmsg
    call tput_s
    call tnl
    pop rsi
    ret

tc_ifconfig:
    PUSHA
    call net_lock
    call net_ensure
    mov r12d, eax
    call net_unlock
    cmp byte [net_ok], 0
    jne .have
    mov eax, E_NONIC
    call tc_err
    jmp .o
.have:
    mov rdi, TMPB
    lea rsi, [s_if_eth]
    call sappend
    xor ebx, ebx
.m: mov al, [my_mac+rbx]
    call tc_hex2
    inc ebx
    cmp ebx, 6
    jae .me
    mov byte [rdi], ':'
    inc rdi
    jmp .m
.me:
    lea rsi, [s_if_up]
    test byte [e_status], 2
    jnz .l
    lea rsi, [s_if_down]
.l: call sappend
    call tc_say
    cmp dword [my_ip], 0
    jne .addr
    mov eax, r12d
    call tc_err
    jmp .o
.addr:
    mov rdi, TMPB
    lea rsi, [s_if_ip]
    call sappend
    mov eax, [my_ip]
    call ip2s
    lea rsi, [s_if_mask]
    call sappend
    mov eax, [net_mask]
    call ip2s
    call tc_say
    mov rdi, TMPB
    lea rsi, [s_if_gw]
    call sappend
    mov eax, [net_gw]
    call ip2s
    lea rsi, [s_if_dns]
    call sappend
    mov eax, [net_dns]
    call ip2s
    call tc_say
.o: POPA
    ret

tc_host_arg:                        ; rsi = args -> net_host filled, CF=1 when empty
    push rax
    push rcx
    push rdi
.s: cmp byte [rsi], ' '
    jne .g
    inc rsi
    jmp .s
.g: cmp byte [rsi], 0
    je .e
    lea rdi, [net_host]
    xor ecx, ecx
.c: mov al, [rsi+rcx]
    cmp al, ' '
    jbe .z
    cmp ecx, 120
    jae .z
    mov [rdi+rcx], al
    inc ecx
    jmp .c
.z: mov byte [rdi+rcx], 0
    pop rdi
    pop rcx
    pop rax
    clc
    ret
.e: pop rdi
    pop rcx
    pop rax
    stc
    ret

tc_resolve:                         ; net_host -> eax = ip (0 = failed, message printed)
    call ip_literal
    jnc .ok
    lea rsi, [net_host]
    call dns_resolve
    test eax, eax
    jnz .ok
    push rax
    mov eax, E_DNS
    call tc_err
    pop rax
.ok: ret

tc_ping:
    PUSHA
    call tc_host_arg
    jnc .go
    lea rsi, [s_ping_use]
    call tput_s
    jmp .o
.go:
    call net_lock
    call net_ensure
    test eax, eax
    jz .up
    call tc_err
    jmp .un
.up:
    call tc_resolve
    test eax, eax
    jz .un
    mov r12d, eax
    xor r13d, r13d
.l: mov eax, r12d
    call net_ping
    mov r14d, eax
    mov rdi, TMPB
    test r14d, r14d
    jz .no
    lea rsi, [s_ping_ok]
    call sappend
    mov eax, r12d
    call ip2s
    jmp .pr
.no:
    lea rsi, [s_ping_no]
    call sappend
.pr:
    call tc_say
    inc r13d
    cmp r13d, 4
    jb .l
.un:
    call net_unlock
.o: POPA
    ret

tc_nslookup:
    PUSHA
    call tc_host_arg
    jnc .go
    lea rsi, [s_ns_use]
    call tput_s
    jmp .o
.go:
    call net_lock
    call net_ensure
    test eax, eax
    jz .up
    call tc_err
    jmp .un
.up:
    call tc_resolve
    test eax, eax
    jz .un
    mov r12d, eax
    mov rdi, TMPB
    lea rsi, [net_host]
    call sappend
    lea rsi, [s_arrow]
    call sappend
    mov eax, r12d
    call ip2s
    call tc_say
.un:
    call net_unlock
.o: POPA
    ret

tc_dhcp:
    PUSHA
    call net_lock
    call net_reset
    call net_unlock
    call tc_ifconfig
    POPA
    ret

; ------------------------------------------------------------- data ---------

; ---- end net2.inc
; ---- begin tls_tables.inc
; ---- tables for tls_crypto.inc (generated)
sha_k:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
aes_sbox:
    db 0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76
    db 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0
    db 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15
    db 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75
    db 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84
    db 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf
    db 0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8
    db 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2
    db 0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73
    db 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb
    db 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79
    db 0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08
    db 0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a
    db 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e
    db 0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf
    db 0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16

; ---- end tls_tables.inc
; ---- begin tls_c1.inc
; =============================================================================
;  TLS crypto, part 1: SHA-256, HMAC-SHA256, TLS 1.2 PRF
;  State lives at fixed addresses (TS_*), nothing here is re-entrant.
; =============================================================================
TS        equ NET+0x30000
TS_W      equ TS+0x000              ; 64 dwords message schedule
TS_C1     equ TS+0x100              ; sha context (112 bytes)
TS_PAD    equ TS+0x180              ; 64 bytes hmac pad
TS_IN     equ TS+0x1C0              ; 32 bytes inner digest
TS_A      equ TS+0x1E0              ; 32 bytes P_hash A(i)
TS_B      equ TS+0x200              ; 32 bytes P_hash block
TS_PRF    equ TS+0x220              ; 6 qwords: out len secret slen seed seedlen
TS_HM     equ TS+0x260              ; 7 qwords hmac arguments

; context: +0 state[8] dd, +32 total bytes dq, +40 buffered dd, +48 buffer[64]
sha_init:                           ; rdi = ctx
    mov dword [rdi], 0x6a09e667
    mov dword [rdi+4], 0xbb67ae85
    mov dword [rdi+8], 0x3c6ef372
    mov dword [rdi+12], 0xa54ff53a
    mov dword [rdi+16], 0x510e527f
    mov dword [rdi+20], 0x9b05688c
    mov dword [rdi+24], 0x1f83d9ab
    mov dword [rdi+28], 0x5be0cd19
    mov qword [rdi+32], 0
    mov dword [rdi+40], 0
    ret

sha_blk:                            ; rdi = ctx : compress the 64 buffered bytes
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    xor ecx, ecx
.ld:
    mov eax, [rdi+48+rcx*4]
    bswap eax
    mov [TS_W+rcx*4], eax
    inc ecx
    cmp ecx, 16
    jb .ld
.ex:
    mov eax, [TS_W+rcx*4-8]         ; w[i-2]
    mov ebx, eax
    ror eax, 17
    mov edx, ebx
    ror edx, 19
    xor eax, edx
    shr ebx, 10
    xor eax, ebx                    ; s1
    mov ebx, [TS_W+rcx*4-60]        ; w[i-15]
    mov edx, ebx
    ror ebx, 7
    mov esi, edx
    ror esi, 18
    xor ebx, esi
    shr edx, 3
    xor ebx, edx                    ; s0
    add eax, ebx
    add eax, [TS_W+rcx*4-64]
    add eax, [TS_W+rcx*4-28]
    mov [TS_W+rcx*4], eax
    inc ecx
    cmp ecx, 64
    jb .ex
    mov r8d, [rdi]
    mov r9d, [rdi+4]
    mov r10d, [rdi+8]
    mov r11d, [rdi+12]
    mov r12d, [rdi+16]
    mov r13d, [rdi+20]
    mov r14d, [rdi+24]
    mov r15d, [rdi+28]
    xor ebp, ebp
.r:
    mov eax, r12d
    ror eax, 6
    mov ebx, r12d
    ror ebx, 11
    xor eax, ebx
    mov ebx, r12d
    ror ebx, 25
    xor eax, ebx                    ; S1(e)
    mov ebx, r13d
    xor ebx, r14d
    and ebx, r12d
    xor ebx, r14d                   ; Ch
    add eax, ebx
    add eax, r15d
    add eax, [sha_k+rbp*4]
    add eax, [TS_W+rbp*4]           ; T1
    mov ebx, r8d
    ror ebx, 2
    mov ecx, r8d
    ror ecx, 13
    xor ebx, ecx
    mov ecx, r8d
    ror ecx, 22
    xor ebx, ecx                    ; S0(a)
    mov ecx, r8d
    or ecx, r9d
    and ecx, r10d
    mov edx, r8d
    and edx, r9d
    or ecx, edx                     ; Maj
    add ebx, ecx                    ; T2
    mov r15d, r14d
    mov r14d, r13d
    mov r13d, r12d
    lea r12d, [r11+rax]
    mov r11d, r10d
    mov r10d, r9d
    mov r9d, r8d
    lea r8d, [rax+rbx]
    inc ebp
    cmp ebp, 64
    jb .r
    add [rdi], r8d
    add [rdi+4], r9d
    add [rdi+8], r10d
    add [rdi+12], r11d
    add [rdi+16], r12d
    add [rdi+20], r13d
    add [rdi+24], r14d
    add [rdi+28], r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

sha_upd:                            ; rdi = ctx, rsi = data, ecx = length (all registers kept)
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    mov eax, ecx
    add [rdi+32], rax
.lp:
    test ecx, ecx
    jz .done
    mov edx, [rdi+40]
    mov eax, 64
    sub eax, edx
    cmp eax, ecx
    jbe .n
    mov eax, ecx
.n: push rdi
    lea rdi, [rdi+48+rdx]
    mov r8d, eax
    xchg ecx, r8d                   ; ecx = chunk, r8d = remaining
    sub r8d, ecx
    add edx, ecx
    rep movsb
    pop rdi
    mov [rdi+40], edx
    mov ecx, r8d
    cmp edx, 64
    jne .lp
    call sha_blk
    mov dword [rdi+40], 0
    jmp .lp
.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

sha_fin:                            ; rdi = ctx, rsi = 32-byte output (registers kept, ctx destroyed)
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov r9, rsi
    mov rax, [rdi+32]
    shl rax, 3
    mov r8, rax                     ; bit length
    mov edx, [rdi+40]
    mov byte [rdi+48+rdx], 0x80
    inc edx
    cmp edx, 56
    jbe .pz
    mov ecx, 64
    sub ecx, edx
    push rdi
    lea rdi, [rdi+48+rdx]
    xor eax, eax
    rep stosb
    pop rdi
    call sha_blk
    xor edx, edx
.pz:
    mov ecx, 56
    sub ecx, edx
    push rdi
    lea rdi, [rdi+48+rdx]
    xor eax, eax
    rep stosb
    pop rdi
    bswap r8
    mov [rdi+48+56], r8
    call sha_blk
    xor ecx, ecx
.o: mov eax, [rdi+rcx*4]
    bswap eax
    mov [r9+rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .o
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; hmac_sha256: rdi = out32, rsi = key, edx = key length (<= 64),
;              r8 = part 1, r9d = its length, r10 = part 2, r11d = its length
hmac_sha256:
    PUSHA
    mov [TS_HM], rdi
    mov [TS_HM+8], r8
    mov [TS_HM+16], r9
    mov [TS_HM+24], r10
    mov [TS_HM+32], r11
    mov [TS_HM+40], rsi
    mov [TS_HM+48], rdx
    ; pad = key padded with zeros, xor 0x36
    mov rdi, TS_PAD
    xor eax, eax
    mov ecx, 8
    rep stosq
    mov rdi, TS_PAD
    mov rsi, [TS_HM+40]
    mov rcx, [TS_HM+48]
    rep movsb
    xor ecx, ecx
.x1:
    xor byte [TS_PAD+rcx], 0x36
    inc ecx
    cmp ecx, 64
    jb .x1
    mov rdi, TS_C1
    call sha_init
    mov rsi, TS_PAD
    mov ecx, 64
    call sha_upd
    mov rsi, [TS_HM+8]
    mov ecx, [TS_HM+16]
    call sha_upd
    mov rsi, [TS_HM+24]
    mov ecx, [TS_HM+32]
    call sha_upd
    mov rsi, TS_IN
    call sha_fin
    xor ecx, ecx
.x2:
    xor byte [TS_PAD+rcx], 0x6A     ; 0x36 ^ 0x5C
    inc ecx
    cmp ecx, 64
    jb .x2
    mov rdi, TS_C1
    call sha_init
    mov rsi, TS_PAD
    mov ecx, 64
    call sha_upd
    mov rsi, TS_IN
    mov ecx, 32
    call sha_upd
    mov rsi, [TS_HM]
    call sha_fin
    POPA
    ret

; tls_prf: rdi = out, ecx = out length, rsi = secret, edx = secret length,
;          r8 = seed (label || seed), r9d = seed length
tls_prf:
    PUSHA
    mov [TS_PRF], rdi
    mov [TS_PRF+8], rcx
    mov [TS_PRF+16], rsi
    mov [TS_PRF+24], rdx
    mov [TS_PRF+32], r8
    mov [TS_PRF+40], r9
    ; A(1) = HMAC(secret, seed)
    mov rdi, TS_A
    mov rsi, [TS_PRF+16]
    mov rdx, [TS_PRF+24]
    mov r8, [TS_PRF+32]
    mov r9, [TS_PRF+40]
    xor r10d, r10d
    xor r11d, r11d
    call hmac_sha256
.blk:
    ; B = HMAC(secret, A || seed)
    mov rdi, TS_B
    mov rsi, [TS_PRF+16]
    mov rdx, [TS_PRF+24]
    mov r8, TS_A
    mov r9d, 32
    mov r10, [TS_PRF+32]
    mov r11, [TS_PRF+40]
    call hmac_sha256
    mov rcx, [TS_PRF+8]
    cmp rcx, 32
    jbe .last
    mov ecx, 32
.last:
    mov rdi, [TS_PRF]
    mov rsi, TS_B
    mov rax, rcx
    rep movsb
    mov [TS_PRF], rdi
    sub [TS_PRF+8], rax
    jz .done
    ; A(i+1) = HMAC(secret, A(i))
    mov rdi, TS_A
    mov rsi, [TS_PRF+16]
    mov rdx, [TS_PRF+24]
    mov r8, TS_A
    mov r9d, 32
    xor r10d, r10d
    xor r11d, r11d
    call hmac_sha256
    jmp .blk
.done:
    POPA
    ret

; ---- end tls_c1.inc
; ---- begin tls_c2.inc
; =============================================================================
;  TLS crypto, part 2: AES-128 (software) and AES-GCM
; =============================================================================
TS_AS     equ TS+0x2A0              ; 16 bytes aes state
TS_AT     equ TS+0x2B0              ; 16 bytes aes temp
TS_CB     equ TS+0x2C0              ; 16 bytes counter block
TS_KS     equ TS+0x2D0              ; 16 bytes key stream / E(J0)
TS_EJ     equ TS+0x2E0              ; 16 bytes E(J0)
TS_Y      equ TS+0x2F0              ; ghash state: hi, lo (numbers)
TS_GA     equ TS+0x300              ; 9 qwords: ctx iv aad aadlen in len out tag dec
TS_XB     equ TS+0x350              ; 16 bytes block scratch
; key context: +0 round keys (176), +176 H hi, +184 H lo, +192 salt (4 bytes)
KC_SIZE   equ 208


aes_ks:                             ; rsi = key (16 bytes), rdi = 176-byte round-key buffer
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push rsi
    push rdi
    mov ecx, 4
    rep movsd
    pop rdi
    push rdi
    mov ecx, 4
    mov ebx, 1
.l: mov eax, [rdi+rcx*4-4]
    test ecx, 3
    jnz .ns
    ror eax, 8
    mov edx, 4
.sw:
    movzx r8d, al
    movzx r8d, byte [aes_sbox+r8]
    mov al, r8b
    ror eax, 8
    dec edx
    jnz .sw
    xor eax, ebx
    mov edx, ebx
    shl ebx, 1
    and edx, 0x80
    jz .nr
    xor ebx, 0x1B
.nr:
    and ebx, 0xFF
.ns:
    xor eax, [rdi+rcx*4-16]
    mov [rdi+rcx*4], eax
    inc ecx
    cmp ecx, 44
    jb .l
    pop rdi
    pop rsi
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

aes_enc:                            ; rsi = 16 bytes in, rdi = 16 bytes out, rdx = round keys
    PUSHA
    xor ecx, ecx
.i: mov eax, [rsi+rcx*4]
    xor eax, [rdx+rcx*4]
    mov [TS_AS+rcx*4], eax
    inc ecx
    cmp ecx, 4
    jb .i
    mov ebp, 1
.rd:
    xor ecx, ecx
.sb:
    movzx eax, byte [aes_sr+rcx]
    movzx eax, byte [TS_AS+rax]
    movzx eax, byte [aes_sbox+rax]
    mov [TS_AT+rcx], al
    inc ecx
    cmp ecx, 16
    jb .sb
    cmp ebp, 10
    je .last
    xor r8d, r8d                    ; column
.mc:
    mov eax, [TS_AT+r8*4]
    mov ebx, eax
    and ebx, 0x7F7F7F7F
    add ebx, ebx
    mov ecx, eax
    shr ecx, 7
    and ecx, 0x01010101
    imul ecx, ecx, 0x1B
    xor ebx, ecx                    ; xtime of every byte
    mov ecx, ebx
    ror ecx, 8
    xor ebx, ecx
    mov ecx, eax
    ror ecx, 8
    xor ebx, ecx
    ror ecx, 8
    xor ebx, ecx
    ror ecx, 8
    xor ebx, ecx
    mov ecx, ebp
    shl ecx, 2
    add ecx, r8d
    xor ebx, [rdx+rcx*4]
    mov [TS_AS+r8*4], ebx
    inc r8d
    cmp r8d, 4
    jb .mc
    inc ebp
    jmp .rd
.last:
    xor ecx, ecx
.f: mov eax, [TS_AT+rcx*4]
    xor eax, [rdx+160+rcx*4]
    mov [rdi+rcx*4], eax
    inc ecx
    cmp ecx, 4
    jb .f
    POPA
    ret

; gcm_setkey: rsi = 16-byte key, rdi = key context (KC_SIZE bytes)
gcm_setkey:
    PUSHA
    mov r12, rdi
    call aes_ks
    mov rdx, r12
    lea rsi, [TS_XB]
    xor eax, eax
    mov [rsi], rax
    mov [rsi+8], rax
    lea rdi, [TS_XB]
    call aes_enc
    mov rax, [TS_XB]
    bswap rax
    mov [r12+176], rax
    mov rax, [TS_XB+8]
    bswap rax
    mov [r12+184], rax
    POPA
    ret

; ghash: Y = (Y ^ block) * H   ; rbx:rax = block (numbers), r12 = key ctx
ghash_blk:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    xor rax, [TS_Y]
    xor rbx, [TS_Y+8]
    mov r10, [r12+176]
    mov r11, [r12+184]
    xor r8d, r8d
    xor r9d, r9d
    mov ecx, 128
.l: mov rdx, rax
    sar rdx, 63
    shld rax, rbx, 1
    shl rbx, 1
    mov rsi, r10
    and rsi, rdx
    xor r8, rsi
    mov rsi, r11
    and rsi, rdx
    xor r9, rsi
    mov rdx, r11
    and edx, 1
    neg rdx
    shrd r11, r10, 1
    shr r10, 1
    mov rsi, 0xE100000000000000
    and rsi, rdx
    xor r10, rsi
    dec ecx
    jnz .l
    mov [TS_Y], r8
    mov [TS_Y+8], r9
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

ghash_data:                         ; rsi = data, ecx = length (zero padded to 16), r12 = key ctx
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
.lp:
    test ecx, ecx
    jz .d
    cmp ecx, 16
    jb .part
    mov rax, [rsi]
    mov rbx, [rsi+8]
    bswap rax
    bswap rbx
    call ghash_blk
    add rsi, 16
    sub ecx, 16
    jmp .lp
.part:
    push rcx
    lea rdi, [TS_XB]
    xor eax, eax
    mov [rdi], rax
    mov [rdi+8], rax
    rep movsb
    pop rcx
    mov rax, [TS_XB]
    mov rbx, [TS_XB+8]
    bswap rax
    bswap rbx
    call ghash_blk
.d: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gcm_run: arguments in TS_GA: +0 ctx, +8 iv (8 bytes), +16 aad, +24 aadlen, +32 in, +40 len,
;          +48 out, +56 tag (16 bytes out), +64 decrypt flag
gcm_run:
    PUSHA
    mov r12, [TS_GA]
    ; J0 = salt || iv || 1
    mov eax, [r12+192]
    mov [TS_CB], eax
    mov rsi, [TS_GA+8]
    mov rax, [rsi]
    mov [TS_CB+4], rax
    mov dword [TS_CB+12], 0x01000000
    mov rsi, TS_CB
    mov rdi, TS_EJ
    mov rdx, r12
    call aes_enc
    ; counter mode
    mov r13, [TS_GA+32]             ; in
    mov r14, [TS_GA+48]             ; out
    mov r15, [TS_GA+40]             ; length
    mov ebp, 2
.ct:
    test r15, r15
    jz .ctd
    mov eax, ebp
    bswap eax
    mov [TS_CB+12], eax
    mov rsi, TS_CB
    mov rdi, TS_KS
    mov rdx, r12
    call aes_enc
    mov rcx, r15
    cmp rcx, 16
    jbe .cn
    mov ecx, 16
.cn:
    xor edx, edx
.cx:
    mov al, [r13+rdx]
    xor al, [TS_KS+rdx]
    mov [r14+rdx], al
    inc edx
    cmp edx, ecx
    jb .cx
    add r13, rcx
    add r14, rcx
    sub r15, rcx
    inc ebp
    jmp .ct
.ctd:
    ; ghash over aad, ciphertext, lengths
    xor eax, eax
    mov [TS_Y], rax
    mov [TS_Y+8], rax
    mov rsi, [TS_GA+16]
    mov ecx, [TS_GA+24]
    call ghash_data
    mov rsi, [TS_GA+32]
    cmp qword [TS_GA+64], 0
    jne .gd
    mov rsi, [TS_GA+48]             ; encrypting: hash the output
.gd:
    mov ecx, [TS_GA+40]
    call ghash_data
    mov rax, [TS_GA+24]
    shl rax, 3
    mov rbx, [TS_GA+40]
    shl rbx, 3
    call ghash_blk
    mov rax, [TS_Y]
    mov rbx, [TS_Y+8]
    bswap rax
    bswap rbx
    xor rax, [TS_EJ]
    xor rbx, [TS_EJ+8]
    mov rdi, [TS_GA+56]
    mov [rdi], rax
    mov [rdi+8], rbx
    POPA
    ret

; ---- end tls_c2.inc
; ---- begin tls_c3.inc
; =============================================================================
;  TLS crypto, part 3: X25519 (field elements are 4 little-endian qwords, mod 2^255-19,
;  kept below 2^256 and fully reduced only on output)
; =============================================================================
TS_FE     equ TS+0x500              ; 16 field elements of 32 bytes
FE_X1     equ TS_FE+0*32
FE_X2     equ TS_FE+1*32
FE_Z2     equ TS_FE+2*32
FE_X3     equ TS_FE+3*32
FE_Z3     equ TS_FE+4*32
FE_A      equ TS_FE+5*32
FE_AA     equ TS_FE+6*32
FE_B      equ TS_FE+7*32
FE_BB     equ TS_FE+8*32
FE_E      equ TS_FE+9*32
FE_C      equ TS_FE+10*32
FE_D      equ TS_FE+11*32
FE_DA     equ TS_FE+12*32
FE_CB     equ TS_FE+13*32
FE_T      equ TS_FE+14*32
FE_INV    equ TS_FE+15*32
TS_XK     equ TS+0x700              ; 32 bytes clamped scalar
TS_XS     equ TS+0x720              ; ladder swap state (dq)

%macro FE 4                         ; op, dst, a, b
    mov edi, %2
    mov esi, %3
    mov edx, %4
    call %1
%endmacro

fe_add:                             ; rdi = a + b (rsi, rdx)    mov r8, [rsi]
    add r8, [rdx]
    mov r9, [rsi+8]
    adc r9, [rdx+8]
    mov r10, [rsi+16]
    adc r10, [rdx+16]
    mov r11, [rsi+24]
    adc r11, [rdx+24]
    sbb rax, rax
    and eax, 38
    add r8, rax
    adc r9, 0
    adc r10, 0
    adc r11, 0
    sbb rax, rax
    and eax, 38
    add r8, rax
    mov [rdi], r8
    mov [rdi+8], r9
    mov [rdi+16], r10
    mov [rdi+24], r11
    ret

fe_sub:                             ; rdi = a - b
    mov r8, [rsi]
    sub r8, [rdx]
    mov r9, [rsi+8]
    sbb r9, [rdx+8]
    mov r10, [rsi+16]
    sbb r10, [rdx+16]
    mov r11, [rsi+24]
    sbb r11, [rdx+24]
    sbb rax, rax
    and eax, 38
    sub r8, rax
    sbb r9, 0
    sbb r10, 0
    sbb r11, 0
    sbb rax, rax
    and eax, 38
    sub r8, rax
    mov [rdi], r8
    mov [rdi+8], r9
    mov [rdi+16], r10
    mov [rdi+24], r11
    ret

fe_mul:                             ; rdi = a * b (rsi, rdx), may alias
    push rbx
    push rcx
    push r12
    push r13
    push r14
    push r15
    mov rcx, rdx
    mov rax, [rsi]
    mul qword [rcx]
    mov r8, rax
    mov r9, rdx
    mov rax, [rsi]
    mul qword [rcx+8]
    add r9, rax
    adc rdx, 0
    mov r10, rdx
    mov rax, [rsi]
    mul qword [rcx+16]
    add r10, rax
    adc rdx, 0
    mov r11, rdx
    mov rax, [rsi]
    mul qword [rcx+24]
    add r11, rax
    adc rdx, 0
    mov r12, rdx
    ; row 1
    mov rax, [rsi+8]
    mul qword [rcx]
    add r9, rax
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+8]
    mul qword [rcx+8]
    add r10, rax
    adc rdx, 0
    add r10, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+8]
    mul qword [rcx+16]
    add r11, rax
    adc rdx, 0
    add r11, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+8]
    mul qword [rcx+24]
    add r12, rax
    adc rdx, 0
    add r12, rbx
    adc rdx, 0
    mov r13, rdx
    ; row 2
    mov rax, [rsi+16]
    mul qword [rcx]
    add r10, rax
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+16]
    mul qword [rcx+8]
    add r11, rax
    adc rdx, 0
    add r11, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+16]
    mul qword [rcx+16]
    add r12, rax
    adc rdx, 0
    add r12, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+16]
    mul qword [rcx+24]
    add r13, rax
    adc rdx, 0
    add r13, rbx
    adc rdx, 0
    mov r14, rdx
    ; row 3
    mov rax, [rsi+24]
    mul qword [rcx]
    add r11, rax
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+24]
    mul qword [rcx+8]
    add r12, rax
    adc rdx, 0
    add r12, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+24]
    mul qword [rcx+16]
    add r13, rax
    adc rdx, 0
    add r13, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, [rsi+24]
    mul qword [rcx+24]
    add r14, rax
    adc rdx, 0
    add r14, rbx
    adc rdx, 0
    mov r15, rdx
    ; reduce: low + 38 * high
    mov rax, 38
    mul r12
    add r8, rax
    adc rdx, 0
    mov rbx, rdx
    mov rax, 38
    mul r13
    add r9, rax
    adc rdx, 0
    add r9, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, 38
    mul r14
    add r10, rax
    adc rdx, 0
    add r10, rbx
    adc rdx, 0
    mov rbx, rdx
    mov rax, 38
    mul r15
    add r11, rax
    adc rdx, 0
    add r11, rbx
    adc rdx, 0
    imul rbx, rdx, 38
    add r8, rbx
    adc r9, 0
    adc r10, 0
    adc r11, 0
    sbb rax, rax
    and eax, 38
    add r8, rax
    mov [rdi], r8
    mov [rdi+8], r9
    mov [rdi+16], r10
    mov [rdi+24], r11
    pop r15
    pop r14
    pop r13
    pop r12
    pop rcx
    pop rbx
    ret

fe_cswap:                           ; rdi, rsi = elements, rdx = mask (0 or all ones)
    xor ecx, ecx
.l: mov rax, [rdi+rcx*8]
    mov r8, [rsi+rcx*8]
    mov r9, rax
    xor r9, r8
    and r9, rdx
    xor rax, r9
    xor r8, r9
    mov [rdi+rcx*8], rax
    mov [rsi+rcx*8], r8
    inc ecx
    cmp ecx, 4
    jb .l
    ret

fe_tobytes:                         ; rdi = 32 bytes out, rsi = element -> fully reduced
    mov r8, [rsi]
    mov r9, [rsi+8]
    mov r10, [rsi+16]
    mov r11, [rsi+24]
    mov ecx, 2
.f: mov rax, r11
    shr rax, 63
    imul rax, rax, 19
    btr r11, 63
    add r8, rax
    adc r9, 0
    adc r10, 0
    adc r11, 0
    dec ecx
    jnz .f
    mov rax, r8                     ; v + 19 reaches 2^255 -> v >= p
    mov rbx, r9
    mov rcx, r10
    mov rdx, r11
    add rax, 19
    adc rbx, 0
    adc rcx, 0
    adc rdx, 0
    bt rdx, 63
    jnc .done
    btr rdx, 63
    mov r8, rax
    mov r9, rbx
    mov r10, rcx
    mov r11, rdx
.done:
    mov [rdi], r8
    mov [rdi+8], r9
    mov [rdi+16], r10
    mov [rdi+24], r11
    ret

; x25519: rdi = out (32), rsi = scalar (32), rdx = u (32)
x25519:
    PUSHA
    mov r12, rdi
    mov r13, rdx
    ; clamp
    mov rdi, TS_XK
    mov ecx, 4
    rep movsq
    and byte [TS_XK], 248
    and byte [TS_XK+31], 127
    or byte [TS_XK+31], 64
    ; u -> X1 (top bit cleared)
    mov rax, [r13]
    mov [FE_X1], rax
    mov rax, [r13+8]
    mov [FE_X1+8], rax
    mov rax, [r13+16]
    mov [FE_X1+16], rax
    mov rax, [r13+24]
    btr rax, 63
    mov [FE_X1+24], rax
    ; X3 = X1, X2 = 1, Z2 = 0, Z3 = 1
    mov ecx, 4
    mov esi, FE_X1
    mov edi, FE_X3
    rep movsq
    mov ecx, 4
    mov esi, fe_one
    mov edi, FE_X2
    rep movsq
    mov ecx, 4
    mov esi, fe_one
    mov edi, FE_Z3
    rep movsq
    xor eax, eax
    mov edi, FE_Z2
    mov ecx, 4
    rep stosq
    mov qword [TS_XS], 0
    mov ebp, 254
.lad:
    mov eax, ebp
    shr eax, 3
    movzx eax, byte [TS_XK+rax]
    mov ecx, ebp
    and ecx, 7
    shr eax, cl
    and eax, 1                      ; k_t
    mov rbx, rax
    xor rax, [TS_XS]                ; swap ^ k_t
    mov [TS_XS], rbx                ; swap = k_t
    neg rax
    mov r14, rax                    ; mask
    mov rdx, r14
    mov edi, FE_X2
    mov esi, FE_X3
    call fe_cswap
    mov rdx, r14
    mov edi, FE_Z2
    mov esi, FE_Z3
    call fe_cswap
    FE fe_add, FE_A, FE_X2, FE_Z2
    FE fe_mul, FE_AA, FE_A, FE_A
    FE fe_sub, FE_B, FE_X2, FE_Z2
    FE fe_mul, FE_BB, FE_B, FE_B
    FE fe_sub, FE_E, FE_AA, FE_BB
    FE fe_add, FE_C, FE_X3, FE_Z3
    FE fe_sub, FE_D, FE_X3, FE_Z3
    FE fe_mul, FE_DA, FE_D, FE_A
    FE fe_mul, FE_CB, FE_C, FE_B
    FE fe_add, FE_T, FE_DA, FE_CB
    FE fe_mul, FE_X3, FE_T, FE_T
    FE fe_sub, FE_T, FE_DA, FE_CB
    FE fe_mul, FE_T, FE_T, FE_T
    FE fe_mul, FE_Z3, FE_X1, FE_T
    FE fe_mul, FE_X2, FE_AA, FE_BB
    FE fe_mul, FE_T, FE_E, fe_a24
    FE fe_add, FE_T, FE_AA, FE_T
    FE fe_mul, FE_Z2, FE_E, FE_T
    dec ebp
    jns .lad
    mov rdx, [TS_XS]
    neg rdx
    mov edi, FE_X2
    mov esi, FE_X3
    call fe_cswap
    mov rdx, [TS_XS]
    neg rdx
    mov edi, FE_Z2
    mov esi, FE_Z3
    call fe_cswap
    ; inverse of Z2 : Z2^(p-2)
    mov ecx, 4
    mov esi, fe_one
    mov edi, FE_INV
    rep movsq
    mov ebp, 254
.inv:
    FE fe_mul, FE_INV, FE_INV, FE_INV
    cmp ebp, 4
    je .nm
    cmp ebp, 2
    je .nm
    FE fe_mul, FE_INV, FE_INV, FE_Z2
.nm:
    dec ebp
    jns .inv
    FE fe_mul, FE_T, FE_X2, FE_INV
    mov rdi, r12
    mov esi, FE_T
    call fe_tobytes
    POPA
    ret

; ---- end tls_c3.inc
; ---- begin tls_proto.inc
; =============================================================================
;  TLS 1.2 client: ECDHE (X25519) + AES-128-GCM, cipher suites C02F / C02B.
;  The server certificate and its signature are NOT checked: the connection is
;  encrypted, but the server is not authenticated.
; =============================================================================
TS_KCC    equ TS+0x800              ; client write key context (KC_SIZE)
TS_KCS    equ TS+0x8E0              ; server write key context
TS_TH     equ TS+0x9C0              ; transcript hash context (112)
TS_TH2    equ TS+0xA40              ; copy of it
TS_CR     equ TS+0xAC0              ; client random
TS_SR     equ TS+0xAE0              ; server random
TS_SPUB   equ TS+0xB00              ; server public key
TS_PRIV   equ TS+0xB20              ; our private key
TS_CPUB   equ TS+0xB40              ; our public key
TS_PMS    equ TS+0xB60              ; premaster secret
TS_MS     equ TS+0xB80              ; master secret (48)
TS_KB     equ TS+0xBC0              ; key block (40)
TS_SEED   equ TS+0xC00              ; label + seed (128)
TS_FIN    equ TS+0xC80              ; digest / verify data (64)
TS_POOL   equ TS+0xCC0              ; random pool (32)
TS_AAD    equ TS+0xCE0              ; 13 bytes
TS_TAG    equ TS+0xCF0              ; 16 bytes
TS_RET    equ TS+0xD00              ; qword
TS_RIN    equ TS+0xD40              ; random generator input (64)
; state (qwords)
V_ERR     equ TS+0xE00              ; failure reason, 0 = none
V_RPOS    equ TS+0xE08
V_WPOS    equ TS+0xE10
V_HSLEN   equ TS+0xE18
V_HSPOS   equ TS+0xE20
V_RSEQ    equ TS+0xE28
V_WSEQ    equ TS+0xE30
V_RDENC   equ TS+0xE38
V_CIPH    equ TS+0xE40
V_CSENT   equ TS+0xE48
V_FINOK   equ TS+0xE50
V_CLOSED  equ TS+0xE58
V_SKE     equ TS+0xE60
V_SENDLEN equ TS+0xE68
V_RCTR    equ TS+0xE70
V_HASRD   equ TS+0xE78              ; 0 unknown, 1 yes, 2 no
V_ALERT   equ TS+0xE80
TS_HSB    equ TS+0x1000             ; handshake reassembly (24 KB)
HSB_MAX   equ 0x6000
TS_SEND   equ TS+0x7000             ; last flight sent (kept for retransmission)
TS_PT     equ TS+0x10000            ; decrypted record (16 KB + slack)

; failure reasons
TR_HELLO  equ 1                     ; ServerHello not understood
TR_SUITE  equ 2                     ; unsupported cipher suite or curve
TR_FIN    equ 3                     ; server Finished did not verify
TR_ALERT  equ 4                     ; alert from the server
TR_MAC    equ 5                     ; record failed authentication
TR_TIME   equ 6                     ; timeout / connection closed during the handshake
TR_KEY    equ 7                     ; bad key exchange
TR_REC    equ 8                     ; bad or oversized record
TR_ORDER  equ 9                     ; handshake message out of order


%macro W8 1
    mov byte [rdi], %1
    inc rdi
%endmacro
%macro W16 1
    mov word [rdi], ((%1 & 0xFF) << 8) | ((%1 >> 8) & 0xFF)
    add rdi, 2
%endmacro

tls_fail:                           ; eax = reason (first failure wins)
    cmp qword [V_ERR], 0
    jne .r
    mov [V_ERR], rax
.r: ret

; ---- randomness: pool = SHA256(pool || counter || tsc || rdrand || clock) --------------------
tls_rand:                           ; rdi = destination, ecx = bytes
    PUSHA
    mov r12, rdi
    mov r13d, ecx
    cmp qword [V_HASRD], 0
    jne .hr
    mov eax, 1
    cpuid
    mov rax, 2
    bt ecx, 30
    jnc .sethr
    mov rax, 1
.sethr:
    mov [V_HASRD], rax
.hr:
.blk:
    test r13d, r13d
    jz .done
    mov rsi, TS_POOL
    mov rdi, TS_RIN
    mov ecx, 4
    rep movsq
    inc qword [V_RCTR]
    mov rax, [V_RCTR]
    mov [TS_RIN+32], rax
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [TS_RIN+40], rax
    xor eax, eax
    cmp qword [V_HASRD], 1
    jne .nr
    mov ecx, 10
.rr:
    rdrand rax
    jc .nr
    dec ecx
    jnz .rr
    xor eax, eax
.nr:
    mov [TS_RIN+48], rax
    call tod_sec
    mov [TS_RIN+56], eax
    mov rdi, TS_C1
    call sha_init
    mov rsi, TS_RIN
    mov ecx, 60
    call sha_upd
    mov rsi, TS_POOL
    call sha_fin
    ; output = SHA256(pool || 0xFF) so the pool itself is never revealed
    mov rsi, TS_POOL
    mov rdi, TS_RIN
    mov ecx, 4
    rep movsq
    mov byte [TS_RIN+32], 0xFF
    mov rdi, TS_C1
    call sha_init
    mov rsi, TS_RIN
    mov ecx, 33
    call sha_upd
    mov rsi, TS_FIN
    call sha_fin
    mov ecx, r13d
    cmp ecx, 32
    jbe .cp
    mov ecx, 32
.cp:
    mov rsi, TS_FIN
    mov rdi, r12
    sub r13d, ecx
    add r12, rcx
    rep movsb
    jmp .blk
.done:
    POPA
    ret

; ---- record encryption (client -> server) -----------------------------------------------------
; al = type, rsi = plaintext, ecx = length, rdi = destination ; returns rdi behind the record
tls_enc_rec:
    PUSHA
    mov r14, rdi
    mov r15d, ecx
    mov r13, rsi
    mov [r14], al
    mov word [r14+1], 0x0303
    lea eax, [rcx+24]
    xchg al, ah
    mov [r14+3], ax
    mov rax, [V_WSEQ]
    bswap rax
    mov [r14+5], rax
    mov [TS_AAD], rax
    mov bl, [r14]
    mov [TS_AAD+8], bl
    mov word [TS_AAD+9], 0x0303
    mov eax, r15d
    xchg al, ah
    mov [TS_AAD+11], ax
    mov qword [TS_GA], TS_KCC
    lea rax, [r14+5]
    mov [TS_GA+8], rax
    mov qword [TS_GA+16], TS_AAD
    mov qword [TS_GA+24], 13
    mov [TS_GA+32], r13
    mov [TS_GA+40], r15
    lea rax, [r14+13]
    mov [TS_GA+48], rax
    lea rax, [r14+13+r15]
    mov [TS_GA+56], rax
    mov qword [TS_GA+64], 0
    call gcm_run
    inc qword [V_WSEQ]
    lea rax, [r14+13+r15+16]
    mov [TS_RET], rax
    POPA
    mov rdi, [TS_RET]
    ret

; send TS_SEND (V_SENDLEN bytes) as TCP segments
tls_flush:
    PUSHA
    mov rsi, TS_SEND
    mov r12d, [V_SENDLEN]
.l: test r12d, r12d
    jz .d
    mov ecx, r12d
    cmp ecx, 1400
    jbe .s
    mov ecx, 1400
.s: mov al, 0x18
    sub r12d, ecx
    call tcp_send
    add rsi, rcx
    jmp .l
.d: POPA
    ret

tls_resend:                         ; retransmit the last flight
    push rax
    mov eax, [tc_snd_una]
    mov [tc_snd_nxt], eax
    pop rax
    jmp tls_flush

; ---- ClientHello ----------------------------------------------------------------------------
tls_hello:
    PUSHA
    mov rdi, TS_CR
    mov ecx, 32
    call tls_rand
    mov rdi, TS_SEND
    W8 0x16
    W16 0x0301
    W16 0                           ; record length (patched)
    mov r12, rdi                    ; handshake start
    W8 0x01
    W8 0
    W16 0                           ; handshake length (patched)
    W16 0x0303
    mov rsi, TS_CR
    mov ecx, 32
    rep movsb
    W8 0                            ; session id
    W16 4
    W16 0xC02F
    W16 0xC02B
    W8 1
    W8 0
    mov r13, rdi                    ; extensions length (patched)
    W16 0
    ; server name (not for IP literals)
    call ip_literal
    jnc .nosni
    lea rsi, [net_host]
    call strlen
    mov r14d, eax
    W16 0x0000
    lea eax, [r14+5]
    xchg al, ah
    mov [rdi], ax
    add rdi, 2
    lea eax, [r14+3]
    xchg al, ah
    mov [rdi], ax
    add rdi, 2
    W8 0
    mov eax, r14d
    xchg al, ah
    mov [rdi], ax
    add rdi, 2
    lea rsi, [net_host]
    mov ecx, r14d
    rep movsb
.nosni:
    W16 0x000A                      ; supported groups: x25519 first; P-256 is listed only because some
    W16 6                           ; servers refuse an ECDSA P-256 certificate unless it is on the list
    W16 4
    W16 0x001D
    W16 0x0017
    W16 0x000B                      ; EC point formats: uncompressed
    W16 2
    W8 1
    W8 0
    W16 0x000D                      ; signature algorithms
    W16 14
    W16 12
    W16 0x0403
    W16 0x0503
    W16 0x0804
    W16 0x0805
    W16 0x0401
    W16 0x0501
    W16 0xFF01                      ; renegotiation_info (empty)
    W16 1
    W8 0
    ; patch lengths
    mov rax, rdi
    lea rcx, [r13+2]
    sub rax, rcx
    xchg al, ah
    mov [r13], ax                   ; extensions length
    mov rax, rdi
    lea rcx, [r12+4]
    sub rax, rcx                    ; handshake body length
    mov [r12+3], al
    shr eax, 8
    mov [r12+2], al
    mov byte [r12+1], 0
    mov rax, rdi
    lea rcx, [r12]
    sub rax, rcx                    ; handshake message length
    mov r14d, eax
    xchg al, ah
    mov [TS_SEND+3], ax
    mov rax, rdi
    sub rax, TS_SEND
    mov [V_SENDLEN], eax
    ; transcript
    mov rdi, TS_TH
    call sha_init
    mov rsi, r12
    mov ecx, r14d
    call sha_upd
    POPA
    ret

; ---- key exchange, keys, client flight --------------------------------------------------------
seed_build:                         ; rsi = label, ecx = label length, r8 = first 32 bytes, r9 = second 32 bytes
    push rdi
    mov rdi, TS_SEED
    rep movsb
    mov rsi, r8
    mov ecx, 4
    rep movsq
    mov rsi, r9
    mov ecx, 4
    rep movsq
    pop rdi
    ret

tls_client_flight:
    PUSHA
    mov rdi, TS_PRIV
    mov ecx, 32
    call tls_rand
    mov rdi, TS_CPUB
    mov rsi, TS_PRIV
    mov rdx, x_base
    call x25519
    mov rdi, TS_PMS
    mov rsi, TS_PRIV
    mov rdx, TS_SPUB
    call x25519
    xor eax, eax
    mov ecx, 4
    mov rsi, TS_PMS
.z: or rax, [rsi]
    add rsi, 8
    dec ecx
    jnz .z
    test rax, rax
    jnz .keyok
    mov eax, TR_KEY
    call tls_fail
    jmp .out
.keyok:
    ; master secret
    lea rsi, [lbl_ms]
    mov ecx, 13
    mov r8, TS_CR
    mov r9, TS_SR
    call seed_build
    mov rdi, TS_MS
    mov ecx, 48
    mov rsi, TS_PMS
    mov edx, 32
    mov r8, TS_SEED
    mov r9d, 77
    call tls_prf
    ; key block
    lea rsi, [lbl_ke]
    mov ecx, 13
    mov r8, TS_SR
    mov r9, TS_CR
    call seed_build
    mov rdi, TS_KB
    mov ecx, 40
    mov rsi, TS_MS
    mov edx, 48
    mov r8, TS_SEED
    mov r9d, 77
    call tls_prf
    mov rsi, TS_KB
    mov rdi, TS_KCC
    call gcm_setkey
    mov eax, [TS_KB+32]
    mov [TS_KCC+192], eax
    mov rsi, TS_KB+16
    mov rdi, TS_KCS
    call gcm_setkey
    mov eax, [TS_KB+36]
    mov [TS_KCS+192], eax
    ; ClientKeyExchange
    mov rdi, TS_SEND
    W8 0x16
    W16 0x0303
    W16 37
    mov r12, rdi
    W8 0x10
    W8 0
    W16 33
    W8 32
    mov rsi, TS_CPUB
    mov ecx, 32
    rep movsb
    mov rsi, r12
    mov ecx, 37
    push rdi
    mov rdi, TS_TH
    call sha_upd
    pop rdi
    ; ChangeCipherSpec
    W8 0x14
    W16 0x0303
    W16 1
    W8 1
    ; Finished
    mov esi, TS_TH
    push rdi
    mov edi, TS_TH2
    mov ecx, 112
    rep movsb
    mov rdi, TS_TH2
    mov rsi, TS_FIN
    call sha_fin
    lea rsi, [lbl_cf]
    mov ecx, 15
    mov rdi, TS_SEED
    rep movsb
    mov rsi, TS_FIN
    mov ecx, 4
    rep movsq
    mov rdi, TS_FIN+32
    mov ecx, 12
    mov rsi, TS_MS
    mov edx, 48
    mov r8, TS_SEED
    mov r9d, 47
    call tls_prf
    mov byte [TS_PT], 0x14
    mov byte [TS_PT+1], 0
    mov word [TS_PT+2], 0x0C00
    mov rsi, TS_FIN+32
    mov rdi, TS_PT+4
    mov ecx, 12
    rep movsb
    mov rdi, TS_TH
    mov rsi, TS_PT
    mov ecx, 16
    call sha_upd
    pop rdi
    mov al, 0x16
    mov rsi, TS_PT
    mov ecx, 16
    call tls_enc_rec
    mov rax, rdi
    sub rax, TS_SEND
    mov [V_SENDLEN], eax
    mov qword [V_CSENT], 1
    call tls_flush
.out:
    POPA
    ret

; ---- server handshake messages -----------------------------------------------------------------
; rsi = body, ecx = length, al = type
tls_hs_msg:
    PUSHA
    cmp al, 2
    je .sh
    cmp al, 12
    je .ske
    cmp al, 14
    je .done
    cmp al, 20
    je .fin
    jmp .out
.sh:
    cmp ecx, 38
    jb .badh
    cmp word [rsi], 0x0303
    jne .badh
    push rsi
    lea rsi, [rsi+2]
    mov rdi, TS_SR
    mov ecx, 4
    rep movsq
    pop rsi
    movzx eax, byte [rsi+34]
    lea rdx, [rsi+35+rax]
    movzx eax, word [rdx]
    xchg al, ah
    mov [V_CIPH], rax
    cmp eax, 0xC02F
    je .shok
    cmp eax, 0xC02B
    je .shok
    mov eax, TR_SUITE
    call tls_fail
    jmp .out
.shok:
    cmp byte [rdx+2], 0
    je .out
.badh:
    mov eax, TR_HELLO
    call tls_fail
    jmp .out
.ske:
    cmp ecx, 69
    jb .badk
    cmp byte [rsi], 3
    jne .badk
    cmp word [rsi+1], 0x1D00
    jne .badk
    cmp byte [rsi+3], 32
    jne .badk
    lea rsi, [rsi+4]
    mov rdi, TS_SPUB
    mov ecx, 4
    rep movsq
    mov qword [V_SKE], 1
    jmp .out
.badk:
    mov eax, TR_SUITE
    call tls_fail
    jmp .out
.done:
    cmp qword [V_SKE], 0
    jne .go
    mov eax, TR_ORDER
    call tls_fail
    jmp .out
.go:
    cmp qword [V_CSENT], 0
    jne .out
    call tls_client_flight
    jmp .out
.fin:
    cmp ecx, 12
    jne .badf
    cmp qword [V_CSENT], 0
    je .badf
    push rsi
    mov esi, TS_TH
    mov edi, TS_TH2
    mov ecx, 112
    rep movsb
    mov rdi, TS_TH2
    mov rsi, TS_FIN
    call sha_fin
    lea rsi, [lbl_sf]
    mov ecx, 15
    mov rdi, TS_SEED
    rep movsb
    mov rsi, TS_FIN
    mov ecx, 4
    rep movsq
    mov rdi, TS_FIN+32
    mov ecx, 12
    mov rsi, TS_MS
    mov edx, 48
    mov r8, TS_SEED
    mov r9d, 47
    call tls_prf
    pop rsi
    xor eax, eax
    xor ecx, ecx
.cmp:
    mov dl, [rsi+rcx]
    xor dl, [TS_FIN+32+rcx]
    or al, dl
    inc ecx
    cmp ecx, 12
    jb .cmp
    test al, al
    jnz .badf
    mov qword [V_FINOK], 1
    jmp .out
.badf:
    mov eax, TR_FIN
    call tls_fail
.out:
    POPA
    ret

; handshake bytes in (rsi, ecx): reassemble and dispatch
tls_hs_input:
    PUSHA
    mov eax, [V_HSLEN]
    lea edx, [rax+rcx]
    cmp edx, HSB_MAX
    ja .big
    mov rdi, TS_HSB
    add rdi, rax
    rep movsb
    mov [V_HSLEN], edx
.m: mov rax, [V_HSPOS]
    mov edx, [V_HSLEN]
    sub edx, eax
    cmp edx, 4
    jb .compact
    lea rbx, [TS_HSB+rax]
    movzx ecx, byte [rbx+1]
    shl ecx, 8
    mov cl, [rbx+2]
    shl ecx, 8
    mov cl, [rbx+3]                 ; message length
    lea esi, [rcx+4]
    cmp edx, esi
    jb .compact
    movzx r12d, byte [rbx]          ; type
    cmp r12d, 20
    je .nohash                      ; server Finished is not part of what it signs
    push rcx
    push rbx
    mov rdi, TS_TH
    mov rsi, rbx
    lea ecx, [rcx+4]
    call sha_upd
    pop rbx
    pop rcx.nohash:
    lea rsi, [rbx+4]
    mov eax, r12d
    push rcx
    call tls_hs_msg
    pop rcx
    lea eax, [rcx+4]
    add [V_HSPOS], rax
    cmp qword [V_ERR], 0
    je .m
    jmp .out
.compact:
    mov eax, [V_HSPOS]
    mov ecx, [V_HSLEN]
    sub ecx, eax
    lea rsi, [TS_HSB+rax]
    mov rdi, TS_HSB
    mov [V_HSLEN], ecx
    rep movsb
    mov qword [V_HSPOS], 0
    jmp .out
.big:
    mov eax, TR_REC
    call tls_fail
.out:
    POPA
    ret

; ---- record layer (server -> client): consumes complete records from the raw stream in RAWB ---
tls_pump:
    PUSHA
.next:
    cmp qword [V_ERR], 0
    jne .out
    mov rax, [V_RPOS]
    mov edx, [tc_rlen]
    sub edx, eax
    cmp edx, 5
    jb .out
    mov rbx, [tc_rbuf]
    add rbx, rax
    movzx ecx, word [rbx+3]
    xchg cl, ch
    cmp ecx, 18432
    ja .badrec
    lea esi, [rcx+5]
    cmp edx, esi
    jb .out
    mov r13d, ecx                   ; payload length
    lea r12, [rbx+5]                ; payload
    movzx r14d, byte [rbx]          ; type
    add [V_RPOS], rsi
    cmp qword [V_RDENC], 0
    je .plain
    cmp r14d, 20
    je .plain                       ; (a stray CCS)
    ; decrypt
    cmp r13d, 24
    jb .badrec
    lea r15d, [r13-24]              ; plaintext length
    mov rax, [V_RSEQ]
    bswap rax
    mov [TS_AAD], rax
    mov [TS_AAD+8], r14b
    mov word [TS_AAD+9], 0x0303
    mov eax, r15d
    xchg al, ah
    mov [TS_AAD+11], ax
    mov qword [TS_GA], TS_KCS
    mov [TS_GA+8], r12
    mov qword [TS_GA+16], TS_AAD
    mov qword [TS_GA+24], 13
    lea rax, [r12+8]
    mov [TS_GA+32], rax
    mov [TS_GA+40], r15
    mov qword [TS_GA+48], TS_PT
    mov qword [TS_GA+56], TS_TAG
    mov qword [TS_GA+64], 1
    call gcm_run
    lea rsi, [r12+8+r15]
    xor eax, eax
    xor ecx, ecx
.tg:
    mov dl, [rsi+rcx]
    xor dl, [TS_TAG+rcx]
    or al, dl
    inc ecx
    cmp ecx, 16
    jb .tg
    test al, al
    jz .macok
    mov eax, TR_MAC
    call tls_fail
    jmp .out
.macok:
    inc qword [V_RSEQ]
    mov r12, TS_PT
    mov r13d, r15d
.plain:
    cmp r14d, 22
    je .hs
    cmp r14d, 23
    je .app
    cmp r14d, 20
    je .ccs
    cmp r14d, 21
    je .alert
    jmp .next                       ; unknown record types are ignored
.hs:
    mov rsi, r12
    mov ecx, r13d
    call tls_hs_input
    jmp .next
.ccs:
    cmp qword [V_CSENT], 0
    je .order
    mov qword [V_RDENC], 1
    mov qword [V_RSEQ], 0
    jmp .next
.order:
    mov eax, TR_ORDER
    call tls_fail
    jmp .out
.app:
    cmp qword [V_FINOK], 0
    je .order
    mov rdi, [tc_rbuf]
    add rdi, [V_WPOS]
    mov rsi, r12
    mov ecx, r13d
    add [V_WPOS], rcx
    rep movsb
    jmp .next
.alert:
    cmp r13d, 2
    jb .badrec
    mov al, [r12+1]
    test al, al
    jnz .realert
    mov qword [V_CLOSED], 1         ; close_notify
    jmp .next
.realert:
    cmp byte [r12], 1
    jne .fatal
    jmp .next                       ; warnings (user_canceled ...) are ignored
.fatal:
    movzx eax, al
    mov [V_ALERT], rax
    mov eax, TR_ALERT
    call tls_fail
    jmp .out
.badrec:
    mov eax, TR_REC
    call tls_fail
.out:
    POPA
    ret

; ---- application data ------------------------------------------------------------------------
tls_send_app:                       ; rsi = plaintext, ecx = length (< 1300)
    PUSHA
    mov rdi, TS_SEND
    mov al, 0x17
    call tls_enc_rec
    mov rax, rdi
    sub rax, TS_SEND
    mov [V_SENDLEN], eax
    call tls_flush
    POPA
    ret

tls_close_notify:
    PUSHA
    cmp qword [V_FINOK], 0
    je .o
    mov byte [TS_PT], 1
    mov byte [TS_PT+1], 0
    mov rdi, TS_SEND
    mov al, 0x15
    mov rsi, TS_PT
    mov ecx, 2
    call tls_enc_rec
    mov rax, rdi
    sub rax, TS_SEND
    mov [V_SENDLEN], eax
    call tls_flush
.o: POPA
    ret

tls_reset:
    PUSHA
    mov rdi, V_ERR
    xor eax, eax
    mov ecx, 17
    rep stosq                       ; V_ERR .. V_ALERT
    POPA
    ret

; ---- glue: handshake driver and error texts ------------------------------------------------------
tls_handshake:                      ; connection is up -> eax = 1 when the secure channel is ready
    PUSHA
    call tls_reset
    call tls_hello
    call tls_flush
    mov dword [http_retx], 0
    lea rdi, [tmC]
    mov eax, 15
    call tm_set
    lea rdi, [tmD]
    mov eax, 2
    call tm_set
.l: call net_poll
    call tls_pump
    cmp qword [V_ERR], 0
    jne .fail
    cmp qword [V_FINOK], 0
    jne .ok
    cmp byte [tc_rst], 0
    jne .closed
    cmp byte [tc_fin], 0
    jne .closed
    mov eax, [tc_snd_una]
    cmp eax, [tc_snd_nxt]
    je .nr
    lea rdi, [tmD]
    call tm_chk
    jnc .nr
    cmp dword [http_retx], 3
    jae .nr
    inc dword [http_retx]
    call tls_resend
    lea rdi, [tmD]
    mov eax, 2
    call tm_set
.nr:
    call yield
    lea rdi, [tmC]
    call tm_chk
    jnc .l
.closed:
    mov eax, TR_TIME
    call tls_fail
.fail:
    mov qword [TS_RET], 0
    jmp .r
.ok:
    mov qword [TS_RET], 1
.r: POPA
    mov rax, [TS_RET]
    ret

tls_errtext:                        ; -> rsi = message for E_TLS
    push rax
    push rcx
    push rdi
    mov rdi, TS_MSG
    lea rsi, [em_tls]
    call sappend
    mov rax, [V_ERR]
    lea rsi, [tr_unknown]
    cmp eax, 1
    jb .go
    cmp eax, 9
    ja .go
    lea rsi, [tr_tab]
    mov rsi, [rsi+rax*8-8]
.go:
    call sappend
    cmp qword [V_ERR], TR_ALERT
    jne .nal
    lea rsi, [em_alert]
    call sappend
    mov rax, [V_ALERT]
    call u2s
    mov byte [rdi], ')'
    inc rdi
.nal:
    mov byte [rdi], '.'
    mov byte [rdi+1], 0
    mov rsi, TS_MSG
    pop rdi
    pop rcx
    pop rax
    ret
TS_MSG    equ TS+0x14800

; ---- end tls_proto.inc
; ---- begin browser.inc
; =============================================================================
;  BROWSER: address bar, local pages and plain-http pages, a text-cell renderer
;  for real HTML (script/style skipped, entities, UTF-8, links, tables as text)
; =============================================================================
BRC     equ 0x4900000               ; page character cells
BRA     equ 0x4960000               ; page attribute cells (0 text, 1 bold/heading, 3 dim, 8+n link n)
BRL     equ 0x49C0000               ; link targets: 240 * 128
BRH     equ 0x49C8000               ; history: 16 * 512
BR_MAXR equ 3000
BRVIS   equ 32
BR_HN   equ 16
BR_NLK  equ 240

%macro TG 2
    mov rdx, %1
    cmp rax, rdx
    je %2
%endmacro

app_browser:
    PUSHA
    lea rsi, [p_www_idx]
    lea rdi, [br_loc]
    call strcpy
    call br_run
    POPA
    ret

browser_open:                       ; rax = file slot of a page (called from Files)
    PUSHA
    mov rsi, rax
    lea rdi, [br_loc]
    call strcpy
    call br_run
    POPA
    ret

; ------------------------------------------------------------- cell helpers --
br_nl:
    mov dword [br_col], 0
    cmp dword [br_row], BR_MAXR-1
    jae .o
    inc dword [br_row]
.o: ret

br_nl_if:
    cmp dword [br_col], 0
    je .o
    call br_nl
.o: ret

br_put:                             ; al = char
    push rbx
    push rcx
    cmp dword [br_col], COLS-2
    jb .ok
    push rax
    call br_nl
    pop rax
.ok:
    mov ebx, [br_row]
    cmp ebx, BR_MAXR-1
    jae .out
    imul ebx, COLS
    add ebx, [br_col]
    mov [BRC+rbx], al
    mov cl, [br_att]
    mov [BRA+rbx], cl
    inc dword [br_col]
.out:
    pop rcx
    pop rbx
    ret

; br_emit: al = visible or blank character; collapses blanks, wraps words, fills pre and title
br_emit:
    push rbx
    push rcx
    push rdx
    push rsi
    cmp byte [br_ttl], 0
    jne .ttl
    cmp byte [br_pre], 0
    jne .pre
    cmp al, ' '
    ja .vis
    mov byte [br_pend], 1
    jmp .o
.vis:
    cmp byte [br_pend], 0
    je .emit
    mov byte [br_pend], 0
    cmp dword [br_col], 0
    je .emit
    push rax
    mov rdx, [br_rp]
    xor ecx, ecx
.wl:
    cmp rdx, [br_end]
    jae .we
    mov bl, [rdx]
    cmp bl, ' '
    jbe .we
    cmp bl, '<'
    je .we
    inc ecx
    inc rdx
    jmp .wl
.we:
    inc ecx
    add ecx, [br_col]
    cmp ecx, COLS-3
    pop rax
    jae .wrap
    push rax
    mov al, ' '
    call br_put
    pop rax
    jmp .emit
.wrap:
    push rax
    call br_nl
    pop rax
.emit:
    call br_put
    jmp .o
.pre:
    cmp al, 10
    jne .p1
    call br_nl
    jmp .o
.p1:
    cmp al, 13
    je .o
    cmp al, 9
    jne .p2
    mov al, ' '
.p2:
    call br_put
    jmp .o
.ttl:
    cmp al, ' '
    jb .o
    mov ecx, [br_tl]
    cmp ecx, 60
    jae .o
    mov [br_title+rcx], al
    mov byte [br_title+rcx+1], 0
    inc dword [br_tl]
.o: pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

br_emits:                           ; rsi = zstr
    push rsi
    push rax
.l: lodsb
    test al, al
    jz .d
    call br_emit
    jmp .l
.d: pop rax
    pop rsi
    ret

; br_cp: eax = unicode code point -> emits an ASCII approximation
br_cp:
    push rax
    push rbx
    push rsi
    cmp eax, 0x80
    jae .hi
    cmp eax, ' '
    jae .asc
    mov al, ' '
.asc:
    call br_emit
    jmp .o
.hi:
    cmp eax, 0xA0
    jne .n1
    mov al, ' '
    call br_emit
    jmp .o
.n1:
    cmp eax, 0xC0
    jb .misc
    cmp eax, 0x100
    jae .big
    lea rbx, [lat1_tab]
    mov al, [rbx+rax-0xC0]
    call br_emit
    jmp .o
.big:
    cmp eax, 0x401
    je .yoU
    cmp eax, 0x451
    je .yoL
    cmp eax, 0x410
    jb .misc
    cmp eax, 0x44F
    ja .misc
    sub eax, 0x410
    lea rbx, [cyr_tab]
    mov eax, [rbx+rax*4]
.cy:
    test al, al
    jz .o
    push rax
    call br_emit
    pop rax
    shr eax, 8
    jmp .cy
.yoU:
    mov eax, 'Yo'
    jmp .cy
.yoL:
    mov eax, 'yo'
    jmp .cy
.misc:
    lea rbx, [misc_tab]
.m: cmp word [rbx], 0
    je .q
    cmp ax, [rbx]
    je .mf
    add rbx, 4
    jmp .m
.mf:
    movzx esi, word [rbx+2]
    lea rsi, [misc_str+rsi]
    call br_emits
    jmp .o
.q: mov al, '?'
    call br_emit
.o: pop rsi
    pop rbx
    pop rax
    ret

; br_entity: rsi just behind '&'; emits the character and moves rsi, or emits '&' alone
br_entity:
    push rax
    push rbx
    push rcx
    push rdx
    cmp byte [rsi], '#'
    jne .named
    lea rdx, [rsi+1]
    xor eax, eax
    mov ecx, 10
    cmp byte [rdx], 'x'
    je .hexs
    cmp byte [rdx], 'X'
    jne .dec
.hexs:
    inc rdx
    mov ecx, 16
.dec:
    xor ebx, ebx
.dl:
    movzx eax, byte [rdx]
    cmp al, ';'
    je .num
    cmp al, '0'
    jb .lit
    cmp al, '9'
    jbe .dg
    cmp ecx, 16
    jne .lit
    or al, 0x20
    cmp al, 'a'
    jb .lit
    cmp al, 'f'
    ja .lit
    sub al, 'a'-10
    jmp .ac
.dg:
    sub al, '0'
.ac:
    imul ebx, ecx
    add ebx, eax
    cmp ebx, 0x10FFFF
    ja .lit
    inc rdx
    jmp .dl
.num:
    lea rsi, [rdx+1]
    mov eax, ebx
    call br_cp
    jmp .o
.named:
    lea rbx, [ent_tab]
.nl:
    cmp byte [rbx], 0
    je .lit
    mov rdx, rsi
    mov rcx, rbx
.cm:
    mov al, [rcx]
    test al, al
    jz .nend
    cmp al, [rdx]
    jne .skip
    inc rcx
    inc rdx
    jmp .cm
.nend:
    cmp byte [rdx], ';'
    jne .skip
    lea rsi, [rdx+1]
    lea rbx, [rcx+1]
    mov rdx, rsi
    mov rsi, rbx
    call br_emits
    mov rsi, rdx
    jmp .o
.skip:
    mov rcx, rbx
.sk:
    cmp byte [rcx], 0
    je .s2
    inc rcx
    jmp .sk
.s2:
    inc rcx
.s3:
    cmp byte [rcx], 0
    je .s4
    inc rcx
    jmp .s3
.s4:
    lea rbx, [rcx+1]
    jmp .nl
.lit:
    mov al, '&'
    call br_emit
.o: pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; br_find: rsi = start, rdi = lower-case needle -> rsi = match (or the end of the page)
br_find:
    push rax
    push rbx
    push rcx
.s: cmp rsi, [br_end]
    jae .d
    mov rbx, rsi
    mov rcx, rdi
.c: mov al, [rcx]
    test al, al
    jz .d
    mov ah, [rbx]
    or ah, 0x20
    cmp al, ah
    jne .n
    inc rbx
    inc rcx
    jmp .c
.n: inc rsi
    jmp .s
.d: pop rcx
    pop rbx
    pop rax
    ret

; br_attr: rsi = just behind the tag name, r8 = end of tag, rdi = lower-case attribute name
;          -> rdx = value, ecx = length, ZF=1 when found
br_attr:
    push rax
    push rbx
    push rsi
    push rdi
.sk:
    cmp rsi, r8
    jae .no
    mov al, [rsi]
    cmp al, ' '
    jbe .sk1
    cmp al, '/'
    jne .nm
.sk1:
    inc rsi
    jmp .sk
.nm:
    mov rbx, rdi                    ; compare the attribute name
    mov rdx, rsi
.cn:
    mov al, [rbx]
    test al, al
    jz .ce
    mov ah, [rdx]
    or ah, 0x20
    cmp al, ah
    jne .other
    inc rbx
    inc rdx
    jmp .cn
.ce:
    mov al, [rdx]
    cmp al, '='
    je .val
    jmp .other
.other:
    ; skip this attribute (name, optional =value)
.on:
    cmp rsi, r8
    jae .no
    mov al, [rsi]
    cmp al, '='
    je .ov
    cmp al, ' '
    jbe .sk
    inc rsi
    jmp .on
.ov:
    inc rsi
    cmp rsi, r8
    jae .no
    mov al, [rsi]
    cmp al, '"'
    je .oq
    cmp al, 39
    je .oq
.ou:
    cmp rsi, r8
    jae .no
    cmp byte [rsi], ' '
    jbe .sk
    inc rsi
    jmp .ou
.oq:
    inc rsi
.oqs:
    cmp rsi, r8
    jae .no
    cmp [rsi], al
    je .oqe
    inc rsi
    jmp .oqs
.oqe:
    inc rsi
    jmp .sk
.val:
    lea rsi, [rdx+1]
    cmp rsi, r8
    jae .no
    mov al, [rsi]
    cmp al, '"'
    je .vq
    cmp al, 39
    je .vq
    mov rdx, rsi
.vu:
    cmp rsi, r8
    jae .vz
    cmp byte [rsi], ' '
    jbe .vz
    inc rsi
    jmp .vu
.vq:
    inc rsi
    mov rdx, rsi
.vqs:
    cmp rsi, r8
    jae .vz
    cmp [rsi], al
    je .vz
    inc rsi
    jmp .vqs
.vz:
    mov rcx, rsi
    sub rcx, rdx
    xor eax, eax                    ; ZF=1
    jmp .r
.no:
    xor ecx, ecx
    or eax, 1
.r: pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------- render -------
br_clear:
    push rax
    push rcx
    push rdi
    mov rdi, BRC
    mov ecx, BR_MAXR*COLS
    mov al, ' '
    rep stosb
    mov rdi, BRA
    mov ecx, BR_MAXR*COLS
    xor eax, eax
    rep stosb
    mov dword [br_rows], 1
    mov dword [br_nlk], 0
    mov byte [br_title], 0
    pop rdi
    pop rcx
    pop rax
    ret

br_render:
    PUSHA
    call br_clear
    mov dword [br_row], 0
    mov dword [br_col], 0
    mov dword [br_nlk], 0
    mov dword [br_tl], 0
    mov dword [br_rows], 1
    mov byte [br_att], 0
    mov byte [br_pend], 0
    mov byte [br_pre], 0
    mov byte [br_ttl], 0
    mov byte [br_plain], 0
    mov byte [br_title], 0
    mov rsi, [br_slot]
    call ext4
    mov rsi, [br_slot]
    mov ecx, [rsi+48]
    lea rsi, [rsi+64]
    lea r9, [rsi+rcx]
    mov [br_end], r9
    cmp eax, 0x6D74682E             ; ".htm"
    je .lp
    cmp eax, 0x6C6D7468             ; "html"
    je .lp
    mov byte [br_pre], 1
    mov byte [br_plain], 1
.lp:
    mov r9, [br_end]
    cmp rsi, r9
    jae .done
    movzx eax, byte [rsi]
    inc rsi
    mov [br_rp], rsi
    cmp byte [br_plain], 0
    jne .chr
    cmp al, '<'
    je .tag
    cmp al, '&'
    je .ent
.chr:
    cmp al, 0x80
    jae .utf
    call br_emit
    jmp .lp
.ent:
    call br_entity
    jmp .lp
.utf:
    cmp al, 0xC0
    jb .lp                          ; stray continuation byte
    mov ebx, eax
    mov ecx, 1
    and eax, 0x1F
    cmp bl, 0xE0
    jb .ul
    mov ecx, 2
    and eax, 0x0F
    cmp bl, 0xF0
    jb .ul
    mov ecx, 3
    and eax, 0x07
.ul:
    cmp rsi, r9
    jae .ue
    movzx edx, byte [rsi]
    mov ebx, edx
    and ebx, 0xC0
    cmp ebx, 0x80
    jne .ue
    shl eax, 6
    and edx, 0x3F
    or eax, edx
    inc rsi
    dec ecx
    jnz .ul
.ue:
    mov [br_rp], rsi
    call br_cp
    jmp .lp
; ---- tags
.tag:
    cmp rsi, r9
    jae .done
    cmp byte [rsi], '!'
    jne .t1
    cmp word [rsi+1], '--'
    jne .skipgt
    lea rsi, [rsi+3]
    lea rdi, [n_cmt]
    call br_find
    add rsi, 3
    jmp .lp
.t1:
    cmp byte [rsi], '?'
    je .skipgt
    xor ebx, ebx                    ; closing flag
    cmp byte [rsi], '/'
    jne .t2
    inc rsi
    mov ebx, 1
.t2:
    mov qword [br_tg], 0
    xor ecx, ecx
.tn:
    cmp rsi, r9
    jae .te
    mov al, [rsi]
    cmp al, '>'
    je .te
    cmp al, ' '
    jbe .te
    cmp al, '/'
    je .te
    or al, 0x20
    cmp ecx, 7
    jae .tsk
    mov [br_tg+rcx], al
    inc ecx
.tsk:
    inc rsi
    jmp .tn
.te:
    mov r8, rsi                     ; find the real end of the tag (quotes may hide a '>')
    xor edx, edx
.fe:
    cmp r8, r9
    jae .fd
    mov al, [r8]
    test dl, dl
    jz .fq
    cmp al, dl
    jne .fn
    xor edx, edx
    jmp .fn
.fq:
    cmp al, '>'
    je .fd
    cmp al, '"'
    je .fq1
    cmp al, 39
    jne .fn
.fq1:
    mov dl, al
.fn:
    inc r8
    jmp .fe
.fd:
    mov rax, [br_tg]
    test ebx, ebx
    jnz .closing
    TG 'script', .sk_script
    TG 'style', .sk_style
    TG 'noscrip', .sk_noscript
    TG 'svg', .sk_svg
    TG 'templat', .sk_tpl
    TG 'h1', .hd
    TG 'h2', .hd
    TG 'h3', .hd
    TG 'h4', .hd
    TG 'h5', .hd
    TG 'h6', .hd
    TG 'b', .bold
    TG 'strong', .bold
    TG 'th', .th
    TG 'td', .td
    TG 'p', .pb
    TG 'div', .pb
    TG 'section', .pb
    TG 'article', .pb
    TG 'header', .pb
    TG 'footer', .pb
    TG 'nav', .pb
    TG 'main', .pb
    TG 'aside', .pb
    TG 'form', .pb
    TG 'ul', .pb
    TG 'ol', .pb
    TG 'dl', .pb
    TG 'table', .pb
    TG 'tr', .pb
    TG 'blockqu', .pb
    TG 'figure', .pb
    TG 'center', .pb
    TG 'br', .brk
    TG 'li', .li
    TG 'dt', .pb
    TG 'dd', .dd
    TG 'a', .an
    TG 'img', .img
    TG 'hr', .hr
    TG 'pre', .prs
    TG 'title', .tts
    jmp .tdone
.closing:
    TG 'h1', .hc
    TG 'h2', .hc
    TG 'h3', .hc
    TG 'h4', .hc
    TG 'h5', .hc
    TG 'h6', .hc
    TG 'b', .att0
    TG 'strong', .att0    TG 'th', .att0
    TG 'p', .pc
    TG 'ul', .pc
    TG 'ol', .pc
    TG 'dl', .pc
    TG 'table', .pc
    TG 'blockqu', .pc
    TG 'div', .nlif
    TG 'section', .nlif
    TG 'article', .nlif
    TG 'header', .nlif
    TG 'footer', .nlif
    TG 'nav', .nlif
    TG 'main', .nlif
    TG 'aside', .nlif
    TG 'form', .nlif
    TG 'tr', .nlif
    TG 'li', .nlif
    TG 'dd', .nlif
    TG 'figure', .nlif
    TG 'a', .ac
    TG 'pre', .prc
    TG 'title', .ttc
    jmp .tdone
.sk_script:
    lea rdi, [n_script]
    jmp .skblk
.sk_style:
    lea rdi, [n_style]
    jmp .skblk
.sk_noscript:
    lea rdi, [n_noscript]
    jmp .skblk
.sk_svg:
    lea rdi, [n_svg]
    jmp .skblk
.sk_tpl:
    lea rdi, [n_tpl]
.skblk:
    mov rsi, r8
    call br_find
    mov r8, rsi
    cmp r8, r9
    jae .done
    jmp .skipgt2
.skipgt:
    mov r8, rsi
.skipgt2:
    ; move rsi to just behind the next '>'
    mov rsi, r8
.sg:
    cmp rsi, r9
    jae .done
    cmp byte [rsi], '>'
    je .sg1
    inc rsi
    jmp .sg
.sg1:
    inc rsi
    jmp .lp
.hd:
    call br_nl_if
    mov byte [br_att], 1
    jmp .tdone
.bold:
    cmp byte [br_att], 8
    jae .tdone
    mov byte [br_att], 1
    jmp .tdone
.th:
    call br_cellsep
    mov byte [br_att], 1
    jmp .tdone
.td:
    call br_cellsep
    jmp .tdone
.pb:
    call br_nl_if
    jmp .tdone
.brk:
    call br_nl
    jmp .tdone
.li:
    call br_nl_if
    mov al, '*'
    call br_put
    mov byte [br_pend], 0
    mov al, ' '
    call br_put
    jmp .tdone
.dd:
    call br_nl_if
    mov al, ' '
    call br_put
    call br_put
    mov byte [br_pend], 0
    jmp .tdone
.hr:
    call br_nl_if
    mov byte [br_att], 3
    mov ecx, 60
.hl:
    mov al, '-'
    call br_put
    dec ecx
    jnz .hl
    mov byte [br_att], 0
    call br_nl
    jmp .tdone
.prs:
    call br_nl_if
    mov byte [br_pre], 1
    mov byte [br_att], 3
    jmp .tdone
.tts:
    mov byte [br_ttl], 1
    jmp .tdone
.hc:
    mov byte [br_att], 0
    call br_nl_if
    call br_nl
    jmp .tdone
.att0:
    cmp byte [br_att], 8
    jae .tdone
    mov byte [br_att], 0
    jmp .tdone
.pc:
    call br_nl_if
    call br_nl
    jmp .tdone
.ac:
    mov byte [br_att], 0
    jmp .tdone
.prc:
    mov byte [br_pre], 0
    mov byte [br_att], 0
    call br_nl_if
    jmp .tdone
.ttc:
    mov byte [br_ttl], 0
    jmp .tdone
.nlif:
    call br_nl_if
    jmp .tdone
.img:
    lea rdi, [n_alt]
    call br_attr
    jne .tdone
    test ecx, ecx
    jz .tdone
    cmp ecx, 40
    jbe .al
    mov ecx, 40
.al:
    mov al, '['
    call br_emit
    mov rsi, rdx
.ac2:
    lodsb
    call br_emit
    dec ecx
    jnz .ac2
    mov al, ']'
    call br_emit
    jmp .tdone
.an:
    mov ecx, [br_nlk]
    cmp ecx, BR_NLK
    jae .tdone
    lea rdi, [n_href]
    call br_attr
    jne .tdone
    test ecx, ecx
    jz .tdone
    mov eax, [br_nlk]
    shl eax, 7
    lea rdi, [BRL+rax]
    cmp ecx, 126
    jbe .hc2
    mov ecx, 126
.hc2:
    mov rsi, rdx
    rep movsb
    mov byte [rdi], 0
    mov eax, [br_nlk]
    add eax, 8
    mov [br_att], al
    inc dword [br_nlk]
.tdone:
    mov rsi, r8
    cmp rsi, r9
    jae .lp
    inc rsi
    jmp .lp
.done:
    mov eax, [br_row]
    inc eax
    mov [br_rows], eax
    POPA
    ret

br_cellsep:                         ; blanks between table cells
    cmp dword [br_col], 0
    je .o
    push rax
    mov al, ' '
    call br_put
    call br_put
    pop rax
.o: mov byte [br_pend], 0
    ret

; ------------------------------------------------------------- loading ------
br_page_msg:                        ; rsi = html text -> HTTPB page "net.htm"
    PUSHA
    mov r12, rsi
    mov rdi, HTTPB
    xor eax, eax
    mov ecx, 16
    rep stosd
    mov rdi, HTTPB
    lea rsi, [s_nethtm]
    call strcpy
    mov rdi, HTTPB+64
    mov rsi, r12
    call sappend
    mov rax, rdi
    sub rax, HTTPB+64
    mov [HTTPB+48], eax
    POPA
    ret

br_errpage:                         ; eax = E_ code, br_loc = address
    PUSHA
    call net_errmsg
    mov r12, rsi
    mov rdi, TMPB
    lea rsi, [s_ep1]
    call sappend
    mov rsi, r12
    call sappend
    lea rsi, [s_ep2]
    call sappend
    lea rsi, [br_loc]
    call sappend
    lea rsi, [s_ep3]
    call sappend
    mov rsi, TMPB
    call br_page_msg
    POPA
    ret

br_load:
    PUSHA
    mov dword [br_nlk], 0
    lea rsi, [br_loc]
    cmp byte [rsi], '/'
    je .local
    ; ---- network page
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x70747468             ; "http" present?
    je .hasscheme
    lea rdi, [url_tmp]              ; add "http://"
    lea rsi, [s_http_s]
    call sappend
    lea rsi, [br_loc]
    call sappend
    lea rsi, [url_tmp]
    lea rdi, [br_loc]
    call strcpy
.hasscheme:
    lea rdi, [br_msg]
    lea rsi, [s_br_loading]
    call sappend
    lea rsi, [br_loc]
    call sappend
    lea rax, [br_msg]
    mov [br_stat], rax
    mov dword [br_sel], -1
    call br_draw
    lea rsi, [br_loc]
    call http_fetch
    test eax, eax
    jz .ok
    call br_errpage
    lea rax, [s_br_hint]
    mov [br_stat], rax
    mov rax, HTTPB
    mov [br_slot], rax
    jmp .render
.ok:
    lea rsi, [net_url]
    lea rdi, [br_loc]
    call strcpy
    mov rax, HTTPB
    mov [br_slot], rax
    lea rdi, [br_msg]
    lea rsi, [s_br_http]
    call sappend
    mov eax, [http_status]
    call u2s
    cmp byte [tc_trunc], 0
    je .nt
    lea rsi, [s_br_trunc]
    call sappend
.nt:
    lea rax, [br_msg]
    mov [br_stat], rax
    jmp .render
.local:
    lea rsi, [br_loc]
    call fs_find
    test rax, rax
    jnz .got
    lea rsi, [br_loc]
    call strlen
    lea rdi, [br_loc+rax]
    lea rsi, [s_dothtm]
    call sappend
    lea rsi, [br_loc]
    call fs_find
    test rax, rax
    jnz .got
    lea rsi, [br_loc]
    mov rdi, TMPB
    mov byte [rdi], 0
    lea rsi, [s_nf1]
    call sappend
    lea rsi, [br_loc]
    call sappend
    lea rsi, [s_ep3]
    call sappend
    mov rsi, TMPB
    call br_page_msg
    mov rax, HTTPB
.got:
    mov [br_slot], rax
    lea rax, [s_br_hint]
    mov [br_stat], rax
.render:
    call br_render
    mov dword [br_top], 0
    mov dword [br_sel], -1
    cmp dword [br_nlk], 0
    je .o
    mov dword [br_sel], 0
.o: POPA
    ret

br_hist_push:
    PUSHA
    cmp byte [br_loc], 0
    je .o
    mov ecx, [br_hn]
    cmp ecx, BR_HN
    jb .st
    mov rdi, BRH
    mov rsi, BRH+512
    mov ecx, 512*(BR_HN-1)/4
    rep movsd
    mov ecx, BR_HN-1
    mov dword [br_hn], BR_HN-1
.st:
    shl ecx, 9
    lea rdi, [BRH+rcx]
    lea rsi, [br_loc]
    call strcpy
    inc dword [br_hn]
.o: POPA
    ret

; ------------------------------------------------------------- UI ------------
br_row0:                            ; rsi = text -> drawn on row 0 (cut to the window width)
    PUSHA
    mov rdi, TMPB+0x200
    mov ecx, COLS-4
.c: lodsb
    test al, al
    jz .z
    stosb
    dec ecx
    jnz .c
.z: mov byte [rdi], 0
    mov rsi, TMPB+0x200
    xor eax, eax
    xor edx, edx
    call puts_cell
    POPA
    ret

br_draw:
    PUSHA
    lea rsi, [s_brw_t]
    call draw_win
    mov byte [g_tr], 0
    SETC g_bg, C_WIN
    cmp byte [br_editing], 0
    jne .edit
    SETC g_fg, C_TXT
    lea rsi, [br_loc]
    call br_row0
    jmp .title
.edit:
    ACCSET g_fg
    mov rdi, TMPB
    lea rsi, [s_br_go]
    call sappend
    lea rsi, [br_edit]
    call sappend
    mov word [rdi], '_'
    mov rsi, TMPB
    call br_row0
.title:
    SETC g_fg, C_DIM
    lea rsi, [br_title]
    cmp byte [rsi], 0
    jne .t1
    lea rsi, [s_untitled]
.t1:
    mov eax, 0
    mov edx, 1
    call puts_cell
    xor r10d, r10d
.row:
    mov eax, [br_top]
    add eax, r10d
    cmp eax, [br_rows]
    jae .done
    imul eax, COLS
    lea r8, [rax+BRC]
    lea r11, [rax+BRA]
    mov ecx, r10d
    add ecx, 2
    shl ecx, 4
    add ecx, GY
    mov ebx, GX
    xor r12d, r12d
.c: movzx edx, byte [r11+r12]
    mov al, [r8+r12]
    mov esi, [br_sel]
    add esi, 8
    cmp edx, esi
    jne .nsel
    cmp dword [br_sel], 0
    jl .nsel
    ACCSET g_bg
    mov dword [g_fg], 0xFFFFFF
    call glyph
    SETC g_bg, C_WIN
    jmp .next
.nsel:
    cmp al, ' '
    je .next
    test edx, edx
    jz .norm
    cmp edx, 1
    je .head
    cmp edx, 3
    je .dim
    ACCSET g_fg
    call glyph
    push rax
    push rcx
    push rdx
    push rsi
    mov eax, C_ACC
    add ecx, 14
    mov esi, 8
    mov edx, 1
    call rect
    pop rsi
    pop rdx
    pop rcx
    pop rax
    jmp .next
.norm:
    SETC g_fg, C_TXT
    call glyph
    jmp .next
.head:
    ACCSET g_fg
    call glyph
    inc ebx
    mov byte [g_tr], 1
    call glyph
    mov byte [g_tr], 0
    dec ebx
    jmp .next
.dim:
    SETC g_fg, C_DIM
    call glyph
.next:
    add ebx, 8
    inc r12d
    cmp r12d, COLS-2
    jb .c
    inc r10d
    cmp r10d, BRVIS
    jb .row
.done:
    mov rsi, [br_stat]
    cmp dword [br_sel], 0
    jl .st
    cmp byte [br_editing], 0
    jne .st
    mov eax, [br_sel]
    shl eax, 7
    lea rsi, [BRL+rax]
    mov rdi, TMPB+0x400
    mov word [rdi], '->'
    mov byte [rdi+2], ' '
    add rdi, 3
    call sappend
    mov rsi, TMPB+0x400
.st:
    call set_status
    POPA
    ret

br_run:
    PUSHA
    mov dword [br_hn], 0
    mov byte [br_editing], 0
    mov dword [br_top], 0
    mov dword [br_sel], -1
    call br_clear
    lea rax, [s_br_hint]
    mov [br_stat], rax
    call br_load
.draw:
    call br_draw
.k: call getkey
    cmp byte [br_editing], 0
    jne .edkey
    cmp al, 27
    je .exit
    cmp al, K_DN
    je .dn
    cmp al, K_UP
    je .up
    cmp al, ' '
    je .pgdn
    cmp al, 'b'
    je .pgup
    cmp al, K_PGDN
    je .pgdn
    cmp al, K_PGUP
    je .pgup
    cmp al, K_HOME
    je .home
    cmp al, K_END
    je .end
    cmp al, 9
    je .nx
    cmp al, K_RT
    je .nx
    cmp al, K_LF
    je .pv
    cmp al, 13
    je .follow
    cmp al, 8
    je .back
    cmp al, 'g'
    je .edit
    cmp al, 'G'
    je .edit
    cmp al, 'r'
    je .reload
    jmp .k
.exit:
    POPA
    ret
.edit:
    mov byte [br_editing], 1
    mov dword [br_elen], 0
    mov byte [br_edit], 0
    jmp .draw
.edkey:
    cmp al, 27
    je .edcancel
    cmp al, 13
    je .edgo
    cmp al, 8
    je .edbs
    cmp al, ' '
    jb .k
    cmp al, 126
    ja .k
    mov ecx, [br_elen]
    cmp ecx, 500
    jae .k
    mov [br_edit+rcx], al
    mov byte [br_edit+rcx+1], 0
    inc dword [br_elen]
    jmp .draw
.edbs:
    mov ecx, [br_elen]
    test ecx, ecx
    jz .k
    dec ecx
    mov [br_elen], ecx
    mov byte [br_edit+rcx], 0
    jmp .draw
.edcancel:
    mov byte [br_editing], 0
    jmp .draw
.edgo:
    mov byte [br_editing], 0
    cmp dword [br_elen], 0
    je .draw
    call br_hist_push
    lea rsi, [br_edit]
    lea rdi, [br_loc]
    call strcpy
    jmp .loadit
.reload:
    jmp .loadit
.loadit:
    call br_load
    jmp .draw
.dn:
    mov eax, [br_top]
    inc eax
    jmp .st
.up:
    mov eax, [br_top]
    dec eax
    jmp .st
.pgdn:
    mov eax, [br_top]
    add eax, BRVIS-1
    jmp .st
.pgup:
    mov eax, [br_top]
    sub eax, BRVIS-1
    jmp .st
.home:
    xor eax, eax
    jmp .st
.end:
    mov eax, [br_rows]
.st:
    mov ecx, [br_rows]
    sub ecx, BRVIS
    jg .c1
    xor ecx, ecx
.c1:
    cmp eax, ecx
    jle .c2
    mov eax, ecx
.c2:
    test eax, eax
    jns .c3
    xor eax, eax
.c3:
    mov [br_top], eax
    jmp .draw
.nx:
    mov eax, [br_nlk]
    test eax, eax
    jz .k
    mov ecx, [br_sel]
    inc ecx
    cmp ecx, eax
    jb .ss
    xor ecx, ecx
    jmp .ss
.pv:
    mov eax, [br_nlk]
    test eax, eax
    jz .k
    mov ecx, [br_sel]
    dec ecx
    jns .ss
    lea ecx, [rax-1]
.ss:
    mov [br_sel], ecx
    lea eax, [rcx+8]
    mov rdi, BRA
    push rcx
    mov ecx, BR_MAXR*COLS
    repne scasb
    pop rcx
    jne .draw
    sub rdi, BRA+1
    mov eax, edi
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, [br_top]
    cmp eax, ecx
    jge .v1
    mov [br_top], eax
    jmp .draw
.v1:
    lea edx, [rcx+BRVIS]
    cmp eax, edx
    jl .draw
    sub eax, BRVIS-1
    mov [br_top], eax
    jmp .draw
.back:
    mov ecx, [br_hn]
    test ecx, ecx
    jz .k
    dec ecx
    mov [br_hn], ecx
    shl ecx, 9
    lea rsi, [BRH+rcx]
    lea rdi, [br_loc]
    call strcpy
    jmp .loadit
.follow:
    mov eax, [br_sel]
    test eax, eax
    js .k
    shl eax, 7
    lea rsi, [BRL+rax]
    lea rdi, [br_loc]
    lea rdx, [url_tmp]
    call url_resolve
    cmp byte [url_tmp], 0
    jne .fok
    lea rax, [s_br_unsup]
    mov [br_stat], rax
    jmp .draw
.fok:
    call br_hist_push
    lea rsi, [url_tmp]
    lea rdi, [br_loc]
    call strcpy
    jmp .loadit

; ------------------------------------------------------------- data ---------
misc_str:
ms_dash  db "-", 0
ms_dd    db "--", 0
ms_sq    db "'", 0
ms_dq    db 34, 0
ms_star  db "*", 0
ms_ell   db "...", 0
ms_c     db "(c)", 0
ms_r     db "(R)", 0
ms_la    db "<<", 0
ms_ra    db ">>", 0
ms_dot   db ".", 0
ms_rarr  db "->", 0
ms_larr  db "<-", 0
ms_eur   db "EUR", 0
ms_tm    db "(TM)", 0
ms_deg   db "deg", 0
ms_pm    db "+-", 0
ms_half  db "1/2", 0
ms_x     db "x", 0
ms_gbp   db "GBP", 0

; ---- end browser.inc

; ================================================================ SYSTEM ====
apply_theme:
    call apply_accent
    cmp byte [SB_THEME], 0
    jne .dk
    mov dword [th_win], 0xFFFFFF
    mov dword [th_hdr], 0xEBEBEB
    mov dword [th_brd], 0xCCCCCC
    mov dword [th_txt], 0x2E3436
    mov dword [th_stat], 0xF6F5F4
    mov dword [th_dim], 0x77767B
    mov dword [th_card], 0xFFFFFF
    ret
.dk:
    mov dword [th_win], 0x242424
    mov dword [th_hdr], 0x303030
    mov dword [th_brd], 0x1A1A1A
    mov dword [th_txt], 0xEEEEEC
    mov dword [th_stat], 0x2B2B2B
    mov dword [th_dim], 0x9A9996
    mov dword [th_card], 0x383838
    ret

hash_str:                           ; rsi -> eax (FNV-1a)
    push rsi
    push rcx
    mov eax, 0x811C9DC5
.l: movzx ecx, byte [rsi]
    test ecx, ecx
    jz .d
    xor eax, ecx
    imul eax, eax, 0x01000193
    inc rsi
    jmp .l
.d: pop rcx
    pop rsi
    ret

sb_save:
    push rax
    push rsi
    mov rsi, SBBUF
    mov eax, FS_LBA
    call ata_write1
    pop rsi
    pop rax
    ret

wait_tick:                          ; waits one PIT wrap (~55 ms)
    push rax
    push rbx
    mov al, 0
    out 0x43, al
    in al, 0x40
    mov bl, al
    in al, 0x40
    mov bh, al
.l: mov al, 0
    out 0x43, al
    in al, 0x40
    mov ah, al
    in al, 0x40
    xchg al, ah
    cmp ax, bx
    mov bx, ax
    ja .d
    jmp .l
.d: pop rbx
    pop rax
    ret

tod_sec:                            ; -> eax = seconds since midnight (RTC)
    push rbx
    mov al, 4
    out 0x70, al
    in al, 0x71
    call bcd
    movzx ebx, al
    imul ebx, ebx, 60
    mov al, 2
    out 0x70, al
    in al, 0x71
    call bcd
    movzx eax, al
    add ebx, eax
    imul ebx, ebx, 60
    xor eax, eax
    out 0x70, al
    in al, 0x71
    call bcd
    movzx eax, al
    add eax, ebx
    pop rbx
    ret

rtc_put:                            ; al=cmos reg, rdi=dest -> two digits
    out 0x70, al
    in al, 0x71
    call bcd
    call put2
    ret

wait_secs:                          ; ebx = seconds (Esc aborts)
    push rax
    push rbx
    push rcx
    test ebx, ebx
    jz .d
.w1:
    call rtc_sec
    mov cl, al
.w2:
    call pollkey
    cmp al, 27
    je .d
    call rtc_sec
    cmp al, cl
    je .w2
    dec ebx
    jnz .w1
.d: pop rcx
    pop rbx
    pop rax
    ret

rnd:
    mov eax, [rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [rng], eax
    shr eax, 16
    ret

rnd_ch:
    call rnd
    and eax, 63
    cmp eax, 61
    jbe .o
    sub eax, 20
.o: add eax, 33
    ret

fs_stat:
    push rax
    push rcx
    push rdi
    xor eax, eax
    mov [st_files], eax
    mov [st_bytes], eax
    mov rdi, FSBUF
    mov ecx, MAXF
.l: cmp byte [rdi], 0
    je .n
    inc dword [st_files]
    mov eax, [rdi+48]
    add [st_bytes], eax
.n: add rdi, SLOT
    dec ecx
    jnz .l
    pop rdi
    pop rcx
    pop rax
    ret

ask_sudo:                           ; ZF=1 -> sudo granted
    push rax
    push rsi
    push rdi
    cmp byte [sudo_on], 0
    jne .yes
    mov byte [pr_mask], 1
    lea rsi, [s_pass]
    mov rdi, PWA
    call prompt
    mov byte [pr_mask], 0
    test eax, eax
    jz .no
    mov rsi, PWA
    call hash_str
    cmp eax, [SB_HASH]
    jne .no
    mov byte [sudo_on], 1
.yes:
    xor eax, eax
    jmp .out
.no:
    mov eax, 1
    test eax, eax
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; ---- calculator -------------------------------------------------------------
ex_fac:
    call skipsp
    mov al, [rsi]
    cmp al, '-'
    je .neg
    cmp al, '('
    je .par
    xor eax, eax
    xor ecx, ecx
.d: movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .dn
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    jmp .d
.dn:
    test ecx, ecx
    jnz .r
    mov byte [calc_err], 1
.r: ret
.neg:
    inc rsi
    call ex_fac
    neg eax
    ret
.par:
    inc rsi
    call ex_expr
    push rax
    call skipsp
    cmp byte [rsi], ')'
    jne .bad
    inc rsi
    pop rax
    ret
.bad:
    mov byte [calc_err], 1
    pop rax
    ret

ex_term:
    push rbx    call ex_fac
    mov ebx, eax
.l: call skipsp
    mov al, [rsi]
    cmp al, '*'
    je .m
    cmp al, '/'
    je .dv
    mov eax, ebx
    pop rbx
    ret
.m: inc rsi
    call ex_fac
    imul ebx, eax
    jmp .l
.dv:
    inc rsi
    call ex_fac
    mov ecx, eax
    test ecx, ecx
    jnz .ok
    mov byte [calc_err], 1
    mov ecx, 1
.ok:
    mov eax, ebx
    cdq
    idiv ecx
    mov ebx, eax
    jmp .l

ex_expr:
    push rbx
    call ex_term
    mov ebx, eax
.l: call skipsp
    mov al, [rsi]
    cmp al, '+'
    je .a
    cmp al, '-'
    je .s
    mov eax, ebx
    pop rbx
    ret
.a: inc rsi
    call ex_term
    add ebx, eax
    jmp .l
.s: inc rsi
    call ex_term
    sub ebx, eax
    jmp .l

; ---- cmatrix ----------------------------------------------------------------
mt_draw:                            ; al=char r8d=col r10d=row
    push rbx
    push rcx
    mov ebx, r8d
    shl ebx, 3
    add ebx, [t_ox]
    mov ecx, r10d
    shl ecx, 4
    add ecx, [t_oy]
    call glyph
    pop rcx
    pop rbx
    ret

fs_black:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx
    mov esi, SW
    mov edx, SH
    call rect
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

cmatrix:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    call rtc_sec
    add [rng], eax
    xor eax, eax
    cmp byte [t_fs], 0
    jne .full
    mov ebx, WX+1
    mov ecx, WY+HDRH+1
    mov esi, WW-2
    mov edx, WH-STH-HDRH-1
    jmp .fill
.full:
    xor ebx, ebx
    xor ecx, ecx
    mov esi, SW
    mov edx, SH
.fill:
    call rect
    xor r8d, r8d
.init:
    call rnd
    and eax, 31
    mov [MTCOL+r8], al
    inc r8d
    cmp r8d, COLS
    jb .init
    mov byte [g_tr], 0
.frame:
    xor r8d, r8d
.col:
    call rnd
    test al, 3
    jz .skipc
    movzx r9d, byte [MTCOL+r8]
    cmp r9d, ROWS
    jae .nohead
    mov dword [g_fg], 0xC8FFC8
    mov dword [g_bg], 0
    call rnd_ch
    mov r10d, r9d
    call mt_draw
.nohead:
    test r9d, r9d
    jz .noneck
    lea r10d, [r9-1]
    cmp r10d, ROWS
    jae .noneck
    mov dword [g_fg], 0x26A269
    mov dword [g_bg], 0
    call rnd_ch
    call mt_draw
.noneck:
    cmp r9d, 12
    jb .notail
    lea r10d, [r9-12]
    cmp r10d, ROWS
    jae .notail
    mov dword [g_bg], 0
    mov al, ' '
    call mt_draw
.notail:
    inc r9d
    cmp r9d, ROWS+14
    jbe .sv
    xor r9d, r9d
.sv:
    mov [MTCOL+r8], r9b
.skipc:
    inc r8d
    cmp r8d, COLS
    jb .col
    call wait_tick
    call pollkey
    test al, al
    jz .frame
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- /base guard --------------------------------------------------------------
chk_base:                           ; rsi=arg -> CF=1 if it points into /base
    push rax
    push rsi
    push rdi
    cmp byte [rsi], 0
    je .no
    cmp byte [rsi], '/'
    je .abs
    push rsi
    mov rdi, PATHB
    lea rsi, [tpath]
    call sappend
    pop rsi
    call sappend
    mov rsi, PATHB
    jmp .chk
.abs:
    mov rdi, PATHB
    call strcpy
    mov rsi, PATHB
.chk:
    cmp dword [rsi], 0x7361622F
    jne .no
    cmp byte [rsi+4], 'e'
    jne .no
    mov al, [rsi+5]
    test al, al
    jz .yes
    cmp al, '/'
    je .yes
.no:
    clc
    jmp .o
.yes:
    stc
.o: pop rdi
    pop rsi
    pop rax
    ret

guard_args:                         ; r15,r12 = args -> CF=1 if denied
    cmp byte [sudo_on], 0
    jne .ok
    cmp dword [t_cwd], 0
    je .bad0
    push rsi
    mov rsi, r15
    call chk_base
    jc .bad
    mov rsi, r12
    call chk_base
    jc .bad
    pop rsi
.ok:
    clc
    ret
.bad:
    pop rsi
.bad0:
    stc
    ret

; ================================================================ HOME ======
; ---- desktop shortcuts: /home/desktop.cfg holds one path per line -------------
scut_load:                          ; builds scut_n, SCUT[i] = (ptr, len)
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov dword [scut_n], 0
    lea rsi, [p_desk]
    mov rdi, PATHB
    call strcpy
    mov rsi, PATHB
    call fs_find
    test rax, rax
    jz .out
    mov ecx, [rax+48]
    lea rsi, [rax+64]
    lea rdi, [SCUT]
.l: test ecx, ecx
    jz .out
    cmp dword [scut_n], 24
    jae .out
    cmp byte [rsi], 10
    jne .st
    inc rsi
    dec ecx
    jmp .l
.st:
    mov [rdi], rsi
    xor ebx, ebx
.ln:
    test ecx, ecx
    jz .ed
    cmp byte [rsi], 10
    je .ed
    inc rsi
    inc ebx
    dec ecx
    jmp .ln
.ed:
    mov [rdi+8], rbx
    add rdi, 16
    inc dword [scut_n]
    jmp .l
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

scut_add:                           ; rsi=path zstr -> appended to desktop.cfg (no duplicates)
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rsi
    call scut_load
    xor ebx, ebx
.d: cmp ebx, [scut_n]
    jae .add
    mov rdi, rbx
    shl rdi, 4
    lea rdi, [SCUT+rdi]
    mov rsi, [rdi]
    mov ecx, [rdi+8]
    xor edx, edx
.c: cmp edx, ecx
    jae .full
    mov al, [rsi+rdx]
    cmp al, [r12+rdx]
    jne .nx
    inc edx
    jmp .c
.full:
    cmp byte [r12+rdx], 0
    je .out
.nx:
    inc ebx
    jmp .d
.add:
    lea rsi, [p_desk]
    mov rdi, PATHB
    call strcpy
    mov rsi, PATHB
    call fs_create
    test rax, rax
    jz .out
    mov rbx, rax
    mov rsi, r12
    call strlen
    mov ecx, [rbx+48]
    lea edx, [rcx+rax+1]
    cmp edx, MAXSZ
    ja .out
    lea rdi, [rbx+64+rcx]
    mov rsi, r12
.cp:
    lodsb
    test al, al
    jz .nl
    stosb
    jmp .cp
.nl:
    mov byte [rdi], 10
    mov [rbx+48], edx
    mov rax, rbx
    call fs_save
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

scut_del:                           ; eax = index
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov ebx, eax
    call scut_load
    cmp ebx, [scut_n]
    jae .out
    lea rsi, [p_desk]
    mov rdi, PATHB
    call strcpy
    mov rsi, PATHB
    call fs_find
    test rax, rax
    jz .out
    mov rdx, rax
    mov rdi, rbx
    shl rdi, 4
    lea rdi, [SCUT+rdi]
    mov r8, [rdi]
    mov ecx, [rdi+8]
    lea r9, [r8+rcx]
    mov r10d, [rdx+48]
    lea r10, [rdx+64+r10]
    cmp r9, r10
    jae .nonl
    cmp byte [r9], 10
    jne .nonl
    inc r9
.nonl:
    mov rcx, r10
    sub rcx, r9
    mov rdi, r8
    mov rsi, r9
    test rcx, rcx
    jle .nomv
    rep movsb
.nomv:
    lea rax, [rdx+64]
    mov rcx, rdi
    sub rcx, rax
    mov [rdx+48], ecx
    mov rax, rdx
    call fs_save
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

scut_name:                          ; eax=index -> TMPB = name, edx = color, sc_letter
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov ebx, eax
    shl rbx, 4
    lea rbx, [SCUT+rbx]
    mov rsi, [rbx]
    mov ecx, [rbx+8]
    mov r8, rsi
    xor eax, eax
.f: cmp eax, ecx
    jae .g
    cmp byte [rsi+rax], '/'
    jne .fn
    lea r8, [rsi+rax+1]
.fn:
    inc eax
    jmp .f
.g: lea r9, [rsi+rcx]
    lea rdi, [TMPB]
    xor edx, edx
    mov r10d, 0x811C9DC5
.cp:
    cmp r8, r9
    jae .z
    movzx eax, byte [r8]
    cmp al, '.'
    je .z
    cmp edx, 20
    jae .z
    mov [rdi+rdx], al
    xor r10d, eax
    imul r10d, r10d, 0x01000193
    inc r8
    inc edx
    jmp .cp
.z: mov byte [rdi+rdx], 0
    mov al, [TMPB]
    cmp al, 'a'
    jb .u
    cmp al, 'z'
    ja .u
    sub al, 32
.u: mov [sc_letter], al
    shr r10d, 8
    and r10d, 7
    mov edx, [scpal+r10*4]
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

scut_run:                           ; eax = index -> launches the target
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov ebx, eax
    shl rbx, 4
    lea rbx, [SCUT+rbx]
    mov rsi, [rbx]
    mov ecx, [rbx+8]
    lea rdi, [PATHB]
    rep movsb
    mov byte [rdi], 0
    mov rsi, PATHB
    call fs_find
    test rax, rax
    jz .o
    call launch_slot
.o: pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

ext4:                               ; rsi=zstr -> eax = last 4 chars lowercased
    push rcx
    call strlen
    cmp eax, 4
    jb .no
    mov eax, [rsi+rax-4]
    or eax, 0x20202020
    jmp .o
.no:
    xor eax, eax
.o: pop rcx
    ret

launch_slot:                        ; rax = slot
    push rbx
    push rsi
    mov rbx, rax
    mov rsi, rax
    call ext4
    cmp eax, 0x7065782E
    je .xep
    cmp eax, 0x706D622E
    je .bmp
    cmp eax, 0x6D74682E
    je .htm
    cmp eax, 0x6C6D7468
    je .htm
    mov rax, rbx
    call editor_open
    jmp .o
.xep:
    mov rax, rbx
    call run_slot
    jmp .o
.bmp:
    mov rax, rbx
    call viewer_show
    jmp .o
.htm:
    mov rax, rbx
    call browser_open
.o: pop rsi
    pop rbx
    ret


; ================================================================ FILES =====
files_draw:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    call clear_content
    mov byte [g_tr], 0
    ACCSET g_fg
    SETC g_bg, C_WIN
    cmp dword [cd_len], 1
    jne .dh
    lea rsi, [s_f_root]
    jmp .dp
.dh:
    lea rsi, [curdir]
.dp:
    xor eax, eax
    xor edx, edx
    call puts_cell
    cmp dword [f_cnt], 0
    jne .items
    SETC g_fg, C_DIM
    lea rsi, [s_empty]
    mov eax, 2
    mov edx, 2
    call puts_cell
.items:
    xor r12d, r12d
.it:
    cmp r12d, [f_cnt]
    jae .end
    cmp r12d, 30
    jae .end
    lea edx, [r12+2]
    SETC g_fg, C_TXT
    SETC g_bg, C_WIN
    cmp r12d, [f_sel]
    jne .nsel
    mov eax, C_ACC
    mov ebx, WX+8
    mov ecx, edx
    shl ecx, 4
    add ecx, GY-1
    mov esi, WW-16
    push rdx
    mov edx, 18
    call rect
    pop rdx
    mov dword [g_fg], 0xFFFFFF
    ACCSET g_bg
.nsel:
    cmp dword [cd_len], 1
    jne .file
    mov eax, r12d
    shl eax, 3
    lea rsi, [dirnm+rax]
    mov eax, 2
    call puts_cell
    mov eax, r12d
    shl eax, 4
    lea rsi, [dirdesc+rax]
    mov eax, 14
    call puts_cell
    jmp .nx
.file:
    mov rbx, [ITEMS+r12*8]
    mov eax, [cd_len]
    lea rsi, [rbx+rax]
    mov eax, 2
    call puts_cell
    mov rsi, rbx
    call strlen
    cmp byte [rbx+rax-1], '/'
    je .nx
    mov eax, [rbx+48]
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
    mov eax, 40
    call puts_cell
    lea rsi, [s_bytes]
    mov eax, 47
    call puts_cell
.nx:
    inc r12d
    jmp .it
.end:
    lea rsi, [s_nil]
    call set_status
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

run_slot:                           ; rax=slot -> runs .xep script in a window
    push rsi
    push rdi
    push rcx
    lea rsi, [s_xpl_t]
    call draw_win
    mov ecx, [rax+48]
    lea rsi, [rax+64]
    mov rdi, EDBUF
    rep movsb
    mov byte [rdi], 0
    mov rsi, EDBUF
    call xpl_run
    pop rcx
    pop rdi
    pop rsi
    ret

app_files:
    push rax
    lea rsi, [s_files_t]
    call draw_win
    pop rax
    lea rsi, [s_rootp]
    test rax, rax
    jz .rootp
    lea rsi, [dirpfx+8]
.rootp:
    call set_curdir
    mov dword [f_sel], 0
.refresh:
    call upd_fdir
    call collect
    mov ecx, [f_sel]
    cmp ecx, [f_cnt]
    jb .okc
    mov ecx, [f_cnt]
    test ecx, ecx
    jz .sv
    dec ecx
.sv:
    mov [f_sel], ecx
.okc:
    call files_draw
.key:
    call getkey
    cmp al, 27
    je .ret
    cmp al, K_UP
    je .up
    cmp al, K_DN
    je .dn
    cmp al, 13
    je .enter
    cmp al, 8
    je .back
    cmp al, 'n'
    je .new
    cmp al, 'm'
    je .mkdir
    cmp al, K_DEL
    je .del
    cmp al, 'd'
    je .del
    cmp al, 'r'
    je .run
    cmp al, 'u'
    je .restore
    jmp .key
.up:
    mov eax, [f_sel]
    test eax, eax
    jz .key
    dec eax
    mov [f_sel], eax
    call files_draw
    jmp .key
.dn:
    mov eax, [f_sel]
    inc eax
    cmp eax, [f_cnt]
    jae .key
    mov [f_sel], eax
    call files_draw
    jmp .key
.enter:
    cmp dword [cd_len], 1
    jne .inside
    mov eax, [f_sel]
    test eax, eax
    jnz .godir
    call ask_sudo
    jnz .refresh
    xor eax, eax
.godir:
    shl eax, 3
    lea rsi, [dirpfx+rax]
    call set_curdir
    mov dword [f_sel], 0
    jmp .refresh
.inside:
    cmp dword [f_cnt], 0
    je .key
    mov eax, [f_sel]
    mov rbx, [ITEMS+rax*8]
    mov rsi, rbx
    call strlen
    cmp byte [rbx+rax-1], '/'
    jne .open
    mov rsi, rbx
    call set_curdir
    mov dword [f_sel], 0
    jmp .refresh
.open:
    mov rax, rbx
    call editor_open
    lea rsi, [s_files_t]
    call draw_win
    jmp .refresh
.back:
    cmp dword [cd_len], 1
    je .key
    call dir_up
    mov dword [f_sel], 0
    jmp .refresh
.new:
    cmp dword [cd_len], 1
    je .key
    lea rsi, [s_pname]
    mov rdi, NAMEB
    call prompt
    test eax, eax
    jz .refresh
    mov rsi, NAMEB
    call mkpath_cur
    call ensure_ext
    call fs_create
    test rax, rax
    jz .refresh
    call editor_open
    lea rsi, [s_files_t]
    call draw_win
    jmp .refresh
.mkdir:
    cmp dword [cd_len], 1
    je .key
    lea rsi, [s_pname]
    mov rdi, NAMEB
    call prompt
    test eax, eax
    jz .refresh
    mov rsi, NAMEB
    call mkpath_cur
    mov rdi, rsi
    call strlen
    mov byte [rdi+rax], '/'
    mov byte [rdi+rax+1], 0
    mov rsi, rdi
    call fs_create
    jmp .refresh
.del:
    cmp dword [cd_len], 1
    je .key
    cmp dword [f_cnt], 0
    je .key
    mov eax, [f_sel]
    mov rax, [ITEMS+rax*8]
    mov rsi, rax
    mov rbx, rax
    call strlen
    cmp byte [rbx+rax-1], '/'
    jne .delf
    mov rax, rbx
    call folder_empty
    jne .refresh
    mov byte [rbx], 0
    mov rax, rbx
    call fs_save
    jmp .refresh
.delf:
    cmp dword [f_dir], 1
    jne .mv
    mov byte [rbx], 0
    mov rax, rbx
    call fs_save
    jmp .refresh
.mv:
    mov rsi, rbx
    call basename
    mov ecx, 1
    call mkpath
    mov rax, rbx
    call fs_move
    jmp .refresh
.restore:
    cmp dword [f_dir], 1
    jne .key
    cmp dword [f_cnt], 0
    je .key
    mov eax, [f_sel]
    mov rbx, [ITEMS+rax*8]
    mov rsi, rbx
    call basename
    mov ecx, 2
    call mkpath
    mov rax, rbx
    call fs_move
    jmp .refresh
.run:
    cmp dword [cd_len], 1
    je .key
    cmp dword [f_cnt], 0
    je .key
    mov eax, [f_sel]
    mov rbx, [ITEMS+rax*8]
    mov rsi, rbx
    call is_xep
    test eax, eax
    jz .key
    mov rax, rbx
    call run_slot
    lea rsi, [s_files_t]
    call draw_win
    jmp .refresh
.ret:
    ret

; ================================================================ EDITOR ====
ed_ls:                              ; ebx=pos -> eax=line start
    mov eax, ebx
.l: test eax, eax
    jz .d
    cmp byte [EDBUF+rax-1], 10
    je .d
    dec eax
    jmp .l
.d: ret

ed_le:                              ; ebx=pos -> eax=line end
    mov eax, ebx
.l: cmp eax, [ed_len]
    jae .d
    cmp byte [EDBUF+rax], 10
    je .d
    inc eax
    jmp .l
.d: ret

ed_insert:                          ; al=char
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, [ed_len]
    cmp edx, MAXSZ-1
    jae .o
    mov ebx, [ed_pos]
    mov ecx, edx
    sub ecx, ebx
    lea rsi, [EDBUF+rdx-1]
    lea rdi, [EDBUF+rdx]
    std
    rep movsb
    cld
    mov [EDBUF+rbx], al
    inc dword [ed_len]
    inc dword [ed_pos]
    mov byte [ed_mod], 1
.o: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

ed_save:
    push rax
    push rcx
    push rsi
    push rdi
    mov rax, [ed_slot]
    mov ecx, [ed_len]
    mov [rax+48], ecx
    lea rdi, [rax+64]
    mov rsi, EDBUF
    rep movsb
    call fs_save
    mov byte [ed_mod], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

ed_scroll:
    push rax
    push rcx
    push rdx
    xor eax, eax
    xor ecx, ecx
    mov edx, [ed_pos]
.l: cmp ecx, edx
    jae .d
    cmp byte [EDBUF+rcx], 10
    jne .n
    inc eax
.n: inc ecx
    jmp .l
.d: mov [ed_cline], eax
    mov ecx, [ed_top]
    cmp eax, ecx
    jae .a
    mov [ed_top], eax
    jmp .r
.a: lea edx, [rcx+ROWS]
    cmp eax, edx
    jb .r
    sub eax, ROWS-1
    mov [ed_top], eax
.r: pop rdx
    pop rcx
    pop rax
    ret

ed_render:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    call ed_scroll
    call clear_content    mov byte [g_tr], 0
    SETC g_fg, C_TXT
    SETC g_bg, C_WIN
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, [ed_top]
.l: cmp r8d, [ed_len]
    jae .end
    cmp r8d, [ed_pos]
    jne .nc
    mov [ed_ccol], r10d
.nc:
    movzx eax, byte [EDBUF+r8]
    cmp al, 10
    je .nl
    cmp r9d, r11d
    jb .adv
    mov edx, r9d
    sub edx, r11d
    cmp edx, ROWS
    jae .adv
    cmp r10d, COLS
    jae .adv
    mov ebx, r10d
    shl ebx, 3
    add ebx, GX
    mov ecx, edx
    shl ecx, 4
    add ecx, GY
    call glyph
.adv:
    inc r10d
    jmp .nx
.nl:
    inc r9d
    xor r10d, r10d
.nx:
    inc r8d
    jmp .l
.end:
    cmp r8d, [ed_pos]
    jne .cur
    mov [ed_ccol], r10d
.cur:
    mov ecx, [ed_cline]
    sub ecx, r11d
    cmp ecx, ROWS
    jae .out
    mov ebx, [ed_ccol]
    cmp ebx, COLS
    jae .out
    shl ebx, 3
    add ebx, GX
    shl ecx, 4
    add ecx, GY
    mov eax, C_ACC
    mov esi, 2
    mov edx, 16
    cmp byte [ed_mode], 1
    je .curd
    mov esi, 8
    add ecx, 14
    mov edx, 2
.curd:
    call rect
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

ed_status:
    push rax
    push rsi
    push rdi
    mov rdi, TMPB
    cmp byte [ed_warn], 0
    je .n
    lea rsi, [s_e37]
    call sappend
    jmp .f
.n: lea rsi, [s_normal]
    cmp byte [ed_mode], 0
    je .m
    lea rsi, [s_insert]
.m: call sappend
    mov rsi, [ed_slot]
    call sappend
    cmp byte [ed_mod], 0
    je .nm
    lea rsi, [s_mod]
    call sappend
.nm:
    lea rsi, [s_sp4]
    call sappend
    mov eax, [ed_cline]
    inc eax
    call u2s
    mov byte [rdi], ','
    inc rdi
    mov eax, [ed_ccol]
    inc eax
    call u2s
.f: mov rsi, TMPB
    call set_status
    pop rdi
    pop rsi
    pop rax
    ret

editor_open:                        ; rax=slot   (vim-like: normal / insert)
    mov [ed_slot], rax
    mov ecx, [rax+48]
    cmp ecx, MAXSZ
    jbe .szok
    mov ecx, MAXSZ
.szok:
    mov [ed_len], ecx
    lea rsi, [rax+64]
    mov rdi, EDBUF
    rep movsb
    mov dword [ed_pos], 0
    mov dword [ed_top], 0
    mov byte [ed_mod], 0
    mov byte [ed_warn], 0
    mov byte [ed_mode], 0
    mov byte [ed_pend], 0
    mov rsi, [ed_slot]
    call draw_win
.loop:
    call ed_render
    call ed_status
    call getkey
    mov dl, [ed_pend]
    mov byte [ed_pend], 0
    mov byte [ed_warn], 0
    cmp al, 0x13
    je .save
    cmp al, 0x12
    je .run
    cmp byte [ed_mode], 1
    je .ins
    cmp al, 'h'
    je .left
    cmp al, K_LF
    je .left
    cmp al, 'l'
    je .right
    cmp al, K_RT
    je .right
    cmp al, 'k'
    je .up
    cmp al, K_UP
    je .up
    cmp al, 'j'
    je .down
    cmp al, K_DN
    je .down
    cmp al, '0'
    je .home
    cmp al, K_HOME
    je .home
    cmp al, '$'
    je .end
    cmp al, K_END
    je .end
    cmp al, 'x'
    je .del
    cmp al, K_DEL
    je .del
    cmp al, 'i'
    je .toins
    cmp al, 'a'
    je .app
    cmp al, 'o'
    je .oline
    cmp al, 'd'
    je .dkey
    cmp al, ':'
    je .cmd
    cmp al, 27
    je .esc
    jmp .loop
.esc:
    cmp byte [ed_mod], 0
    je .exit
    cmp dl, 27
    je .exit
    mov byte [ed_pend], 27
    mov byte [ed_warn], 1
    jmp .loop
.dkey:
    cmp dl, 'd'
    je .dline
    mov byte [ed_pend], 'd'
    jmp .loop
.ins:
    cmp al, 27
    je .tonormal
    cmp al, K_LF
    je .left
    cmp al, K_RT
    je .right
    cmp al, K_UP
    je .up
    cmp al, K_DN
    je .down
    cmp al, K_HOME
    je .home
    cmp al, K_END
    je .end
    cmp al, K_DEL
    je .del
    cmp al, 8
    je .bs
    cmp al, 13
    je .nl
    cmp al, 9
    je .tab
    cmp al, 32
    jb .loop
    cmp al, 0xDF
    ja .loop
    call ed_insert
    jmp .loop
.nl:
    mov al, 10
    call ed_insert
    jmp .loop
.tab:
    mov r8d, 4
.t: mov al, ' '
    call ed_insert
    dec r8d
    jnz .t
    jmp .loop
.left:
    mov eax, [ed_pos]
    test eax, eax
    jz .loop
    dec eax
    mov [ed_pos], eax
    jmp .loop
.right:
    mov eax, [ed_pos]
    cmp eax, [ed_len]
    jae .loop
    inc eax
    mov [ed_pos], eax
    jmp .loop
.home:
    mov ebx, [ed_pos]
    call ed_ls
    mov [ed_pos], eax
    jmp .loop
.end:
    mov ebx, [ed_pos]
    call ed_le
    mov [ed_pos], eax
    jmp .loop
.up:
    mov ebx, [ed_pos]
    call ed_ls
    test eax, eax
    jz .loop
    mov r8d, ebx
    sub r8d, eax
    mov ebx, eax
    dec ebx
    call ed_ls
    mov edx, ebx
    sub edx, eax
    cmp r8d, edx
    jbe .um
    mov r8d, edx
.um:
    add eax, r8d
    mov [ed_pos], eax
    jmp .loop
.down:
    mov ebx, [ed_pos]
    call ed_ls
    mov r8d, ebx
    sub r8d, eax
    call ed_le
    cmp eax, [ed_len]
    jae .loop
    inc eax
    mov r9d, eax
    mov ebx, eax
    call ed_le
    sub eax, r9d
    cmp r8d, eax
    jbe .dm
    mov r8d, eax
.dm:
    add r9d, r8d
    mov [ed_pos], r9d
    jmp .loop
.del:
    mov ebx, [ed_pos]
    mov edx, [ed_len]
    cmp ebx, edx
    jae .loop
    mov ecx, edx
    sub ecx, ebx
    dec ecx
    lea rsi, [EDBUF+rbx+1]
    lea rdi, [EDBUF+rbx]
    rep movsb
    dec dword [ed_len]
    mov byte [ed_mod], 1
    jmp .loop
.bs:
    mov ebx, [ed_pos]
    test ebx, ebx
    jz .loop
    mov edx, [ed_len]
    mov ecx, edx
    sub ecx, ebx
    lea rsi, [EDBUF+rbx]
    lea rdi, [EDBUF+rbx-1]
    rep movsb
    dec dword [ed_len]
    dec dword [ed_pos]
    mov byte [ed_mod], 1
    jmp .loop
.tonormal:
    mov byte [ed_mode], 0
    mov eax, [ed_pos]
    test eax, eax
    jz .loop
    cmp byte [EDBUF+rax-1], 10
    je .loop
    dec dword [ed_pos]
    jmp .loop
.app:
    mov eax, [ed_pos]
    cmp eax, [ed_len]
    jae .toins
    cmp byte [EDBUF+rax], 10
    je .toins
    inc dword [ed_pos]
.toins:
    mov byte [ed_mode], 1
    jmp .loop
.oline:
    mov ebx, [ed_pos]
    call ed_le
    mov [ed_pos], eax
    mov al, 10
    call ed_insert
    mov byte [ed_mode], 1
    jmp .loop
.dline:
    mov ebx, [ed_pos]
    call ed_ls
    mov r8d, eax
    call ed_le
    mov r9d, eax
    cmp r9d, [ed_len]
    jae .dl1
    inc r9d
    jmp .dl2
.dl1:
    test r8d, r8d
    jz .dl2
    dec r8d
.dl2:
    mov ecx, [ed_len]
    sub ecx, r9d
    mov edx, r9d
    sub edx, r8d
    lea rsi, [EDBUF+r9]
    lea rdi, [EDBUF+r8]
    rep movsb
    sub [ed_len], edx
    mov eax, r8d
    cmp eax, [ed_len]
    jbe .dl3
    mov eax, [ed_len]
.dl3:
    mov ebx, eax
    call ed_ls
    mov [ed_pos], eax
    mov byte [ed_mod], 1
    jmp .loop
.cmd:
    lea rsi, [s_colon]
    mov rdi, NAMEB
    call prompt
    test eax, eax
    jz .loop
    mov rsi, NAMEB
    lea rdi, [v_w]
    call strcmp
    je .save
    lea rdi, [v_q]
    call strcmp
    je .quit
    lea rdi, [v_wq]
    call strcmp
    je .savequit
    lea rdi, [v_x]
    call strcmp
    je .savequit
    lea rdi, [v_qb]
    call strcmp
    je .exit
    lea rdi, [v_r]
    call strcmp
    je .run
    jmp .loop
.quit:
    cmp byte [ed_mod], 0
    je .exit
    mov byte [ed_warn], 1
    jmp .loop
.savequit:
    call ed_save
    jmp .exit
.save:
    call ed_save
    jmp .loop
.run:
    mov rsi, [ed_slot]
    call is_xep
    test eax, eax
    jz .loop
    call ed_save
    mov ecx, [ed_len]
    mov byte [EDBUF+rcx], 0
    mov rsi, EDBUF
    call xpl_run
    mov rsi, [ed_slot]
    call draw_win
    jmp .loop
.exit:
    ret

app_editor:                         ; file picker: type a name or choose a file
    mov dword [f_sel], 0
    mov dword [lf_len], 0
    mov byte [NAMEB], 0
.draw:
    lea rsi, [s_ed_t]
    call draw_win
    lea rsi, [dirpfx+16]
    call set_curdir
    call collect
    mov byte [g_tr], 0
    SETC g_fg, C_ACC
    SETC g_bg, C_WIN
    lea rsi, [s_openf]
    mov eax, 2
    mov edx, 1
    call puts_cell
    mov eax, C_HDR
    mov ebx, GX+8
    mov ecx, GY+36
    mov esi, WW-32
    mov edx, 26
    call rect
    SETC g_fg, C_TXT
    SETC g_bg, C_HDR
    mov ecx, [lf_len]
    mov byte [NAMEB+rcx], '_'
    mov byte [NAMEB+rcx+1], 0
    lea rsi, [NAMEB]
    mov ebx, GX+16
    mov ecx, GY+41
    call text
    mov ecx, [lf_len]
    mov byte [NAMEB+rcx], 0
    SETC g_fg, C_DIM
    SETC g_bg, C_WIN
    lea rsi, [s_homef]
    mov eax, 2
    mov edx, 5
    call puts_cell
    xor r12d, r12d
.it:
    cmp r12d, [f_cnt]
    jae .keys
    cmp r12d, 24
    jae .keys
    SETC g_fg, C_TXT
    SETC g_bg, C_WIN
    cmp r12d, [f_sel]
    jne .ns
    mov eax, C_ACC
    mov ebx, GX
    lea ecx, [r12+7]
    shl ecx, 4
    add ecx, GY-1
    mov esi, WW-16
    mov edx, 18
    call rect
    mov dword [g_fg], 0xFFFFFF
    ACCSET g_bg
.ns:
    mov rbx, [ITEMS+r12*8]
    lea rsi, [rbx+6]
    mov eax, 2
    lea edx, [r12+7]
    call puts_cell
    inc r12d
    jmp .it
.keys:
    lea rsi, [s_nil]
    call set_status
.key:
    call getkey
    cmp al, 27
    je .ret
    cmp al, 13
    je .enter
    cmp al, 8
    je .bs
    cmp al, K_UP
    je .up
    cmp al, K_DN
    je .dn
    cmp al, 32
    jb .key
    cmp al, 0xDF
    ja .key
    mov ecx, [lf_len]
    cmp ecx, 30
    jae .key
    mov [NAMEB+rcx], al
    inc ecx
    mov [lf_len], ecx
    mov byte [NAMEB+rcx], 0
    jmp .draw
.bs:
    mov ecx, [lf_len]
    test ecx, ecx
    jz .key
    dec ecx
    mov [lf_len], ecx
    mov byte [NAMEB+rcx], 0
    jmp .draw
.up:
    mov eax, [f_sel]
    test eax, eax
    jz .key
    dec eax
    mov [f_sel], eax
    jmp .draw
.dn:
    mov eax, [f_sel]
    inc eax
    cmp eax, [f_cnt]
    jae .key
    mov [f_sel], eax
    jmp .draw
.enter:
    cmp dword [lf_len], 0
    jne .byname
    cmp dword [f_cnt], 0
    je .key
    mov eax, [f_sel]
    mov rax, [ITEMS+rax*8]
    jmp .open
.byname:
    mov rsi, NAMEB
    call mkpath_cur
    call ensure_ext
    call fs_create
    test rax, rax
    jz .key
.open:
    call editor_open
    jmp app_editor
.ret:
    ret

; ================================================================ XPL =======
; XPL 1.0   say "text" | print v | let v n | add v n | sub v n | mul v n
;           at x y | color n | clear | box x y w h | wait n
;           repeat n ... next | end | # comment      (v = a..z)
match:                              ; rsi=text rdi=keyword -> ZF=1 (rsi after keyword)
    push rsi
    push rdi
.l: mov al, [rdi]
    test al, al
    jz .end
    cmp al, [rsi]
    jne .no
    inc rsi
    inc rdi
    jmp .l
.end:
    mov al, [rsi]
    test al, al
    jz .yes
    cmp al, ' '
    je .yes
    cmp al, 10
    je .yes
    cmp al, 13
    je .yes
    cmp al, 9
    je .yes
.no:
    pop rdi
    pop rsi
    or al, 1
    ret
.yes:
    pop rdi
    add rsp, 8
    call skipsp
    xor eax, eax
    ret

parse_num:                          ; rsi -> eax (number or variable a..z)
    push rbx
    call skipsp
    movzx eax, byte [rsi]
    cmp al, 'a'
    jb .dig
    cmp al, 'z'
    ja .dig
    sub eax, 'a'
    mov eax, [xvars+rax*4]
    inc rsi
    jmp .out
.dig:
    xor eax, eax
.d: movzx ebx, byte [rsi]
    sub ebx, '0'
    cmp ebx, 9
    ja .out
    imul eax, eax, 10
    add eax, ebx
    inc rsi
    jmp .d
.out:
    call skipsp
    pop rbx
    ret

xp_nl:
    mov dword [xp_col], 0
    inc dword [xp_row]
    cmp dword [xp_row], ROWS
    jb .r
    call clear_content
    mov dword [xp_row], 0
.r: ret

xp_putc:                            ; al=char
    push rbx
    push rcx
    mov ebx, [xp_col]
    cmp ebx, COLS
    jb .ok
    call xp_nl
    xor ebx, ebx
.ok:
    mov ecx, [xp_row]
    shl ebx, 3
    add ebx, GX
    shl ecx, 4
    add ecx, GY
    call glyph
    inc dword [xp_col]
    pop rcx
    pop rbx
    ret

xpl_run:                            ; rsi = NUL-terminated script
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    mov r12, rsi
    xor eax, eax
    mov [lp_sp], eax
    mov [xp_col], eax
    mov [xp_row], eax
    lea rdi, [xvars]
    mov ecx, 26
    rep stosd
    mov byte [g_tr], 0
    mov eax, C_TXT
    mov [g_fg], eax
    SETC g_bg, C_WIN
    call clear_content
    lea rsi, [s_running]
    call set_status
.line:
    call pollkey
    cmp al, 27
    je .abort
    mov rdi, r12
.fe:
    mov al, [rdi]
    test al, al
    jz .last
    cmp al, 10
    je .nlp
    inc rdi
    jmp .fe
.nlp:
    inc rdi
    mov r13, rdi
    jmp .parse
.last:
    xor r13d, r13d
.parse:
    mov rsi, r12
    call skipsp
    mov al, [rsi]
    test al, al
    jz .cont
    cmp al, 10
    je .cont
    cmp al, '#'
    je .cont
    lea rdi, [k_say]
    call match
    je .say
    lea rdi, [k_print]
    call match
    je .print
    lea rdi, [k_let]
    call match
    je .let
    lea rdi, [k_add]
    call match
    je .add
    lea rdi, [k_sub]
    call match
    je .sub
    lea rdi, [k_mul]
    call match
    je .mul
    lea rdi, [k_at]
    call match
    je .at
    lea rdi, [k_color]
    call match
    je .color
    lea rdi, [k_clear]
    call match
    je .clear
    lea rdi, [k_box]
    call match
    je .box
    lea rdi, [k_wait]
    call match
    je .wait
    lea rdi, [k_repeat]
    call match
    je .repeat
    lea rdi, [k_next]
    call match
    je .nextkw
    lea rdi, [k_end]
    call match
    je .done
    jmp .err
.cont:
    test r13, r13
    jz .done
    mov r12, r13
    jmp .line
.say:
    cmp byte [rsi], '"'
    jne .sl
    inc rsi
.sl:
    mov al, [rsi]
    test al, al
    jz .se
    cmp al, 10
    je .se
    cmp al, 13
    je .se
    cmp al, '"'
    je .se
    call xp_putc
    inc rsi
    jmp .sl
.se:
    call xp_nl
    jmp .cont
.print:
    call parse_num
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
.pl:
    lodsb
    test al, al
    jz .pe
    call xp_putc
    jmp .pl
.pe:
    call xp_nl
    jmp .cont
.let:
    movzx ebx, byte [rsi]
    sub ebx, 'a'
    cmp ebx, 25
    ja .err
    inc rsi
    call parse_num
    mov [xvars+rbx*4], eax
    jmp .cont
.add:
    movzx ebx, byte [rsi]
    sub ebx, 'a'
    cmp ebx, 25
    ja .err
    inc rsi
    call parse_num
    add [xvars+rbx*4], eax
    jmp .cont
.sub:
    movzx ebx, byte [rsi]
    sub ebx, 'a'
    cmp ebx, 25
    ja .err
    inc rsi
    call parse_num
    sub [xvars+rbx*4], eax
    jmp .cont
.mul:
    movzx ebx, byte [rsi]
    sub ebx, 'a'
    cmp ebx, 25
    ja .err
    inc rsi
    call parse_num
    imul eax, [xvars+rbx*4]
    mov [xvars+rbx*4], eax
    jmp .cont
.at:
    call parse_num
    cmp eax, COLS-1
    jbe .a1
    mov eax, COLS-1
.a1:
    mov [xp_col], eax
    call parse_num
    cmp eax, ROWS-1
    jbe .a2
    mov eax, ROWS-1
.a2:
    mov [xp_row], eax
    jmp .cont
.color:
    call parse_num
    and eax, 15
    jnz .cpal
    mov eax, C_TXT
    jmp .cset
.cpal:
    mov eax, [palette+rax*4]
.cset:
    mov [g_fg], eax
    jmp .cont
.clear:
    call clear_content
    mov dword [xp_col], 0
    mov dword [xp_row], 0
    jmp .cont
.box:
    call parse_num
    mov r8d, eax
    call parse_num
    mov r9d, eax
    call parse_num
    mov r10d, eax
    call parse_num
    mov r11d, eax
    cmp r8d, COLS
    jae .cont
    cmp r9d, ROWS
    jae .cont
    mov eax, COLS
    sub eax, r8d
    cmp r10d, eax
    jbe .b1
    mov r10d, eax
.b1:
    mov eax, ROWS
    sub eax, r9d
    cmp r11d, eax
    jbe .b2
    mov r11d, eax
.b2:
    mov ebx, r8d
    shl ebx, 3
    add ebx, GX
    mov ecx, r9d
    shl ecx, 4
    add ecx, GY
    mov esi, r10d
    shl esi, 3
    mov edx, r11d
    shl edx, 4
    mov eax, [g_fg]
    call rect
    jmp .cont
.wait:
    call parse_num
    mov ebx, eax
    test ebx, ebx
    jz .cont
.w1:
    call rtc_sec
    mov r14b, al
.w2:
    call pollkey
    cmp al, 27
    je .abort
    call rtc_sec
    cmp al, r14b
    je .w2
    dec ebx
    jnz .w1
    jmp .cont
.repeat:
    call parse_num
    test r13, r13
    jz .cont
    test eax, eax
    jnz .r1
    mov eax, 1
.r1:
    mov ecx, [lp_sp]
    cmp ecx, 4
    jae .err
    mov [lp_cnt+rcx*4], eax
    mov [lp_ptr+rcx*8], r13
    inc dword [lp_sp]
    jmp .cont
.nextkw:
    mov ecx, [lp_sp]
    test ecx, ecx
    jz .cont
    dec ecx
    dec dword [lp_cnt+rcx*4]
    jz .pop
    mov r13, [lp_ptr+rcx*8]
    jmp .cont
.pop:
    mov [lp_sp], ecx
    jmp .cont
.err:
    mov dword [g_fg], 0xE01B24
    lea rsi, [s_xerr]
.el:
    lodsb
    test al, al
    jz .ee
    call xp_putc
    jmp .el
.ee:
    call xp_nl
    lea rsi, [s_xstop]
    jmp .fin
.abort:
    lea rsi, [s_xabort]
    jmp .fin
.done:
    lea rsi, [s_xdone]
.fin:
    call set_status
    SETC g_fg, C_TXT
.k: call getkey
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx    ret

; ================================================================ TERMINAL ==
tnl:
    push rax
    push rcx
    push rsi
    push rdi
    mov dword [t_col], 0
    mov eax, [t_row]
    inc eax
    cmp eax, ROWS
    jb .s
    lea rsi, [TBUF+COLS]
    mov rdi, TBUF
    mov ecx, (ROWS-1)*COLS
    rep movsb
    mov rdi, TBUF+(ROWS-1)*COLS
    mov ecx, COLS
    mov al, ' '
    rep stosb
    mov eax, ROWS-1
    mov byte [t_scr], 1
.s: mov [t_row], eax
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

tput_c:                             ; al=char (keeps all regs)
    push rax
    push rbx
    push rdx
    cmp al, 10
    je .nl
    cmp al, 13
    je .out
    mov dl, al
    mov ebx, [t_col]
    cmp ebx, COLS
    jb .ok
    call tnl
    xor ebx, ebx
.ok:
    mov eax, [t_row]
    imul eax, COLS
    add eax, ebx
    mov [TBUF+rax], dl
    inc ebx
    mov [t_col], ebx
    jmp .out
.nl:
    call tnl
.out:
    pop rdx
    pop rbx
    pop rax
    ret

tput_s:                             ; rsi=zstr
.l: lodsb
    test al, al
    jz .d
    call tput_c
    jmp .l
.d: ret

tpad:                               ; eax=target column
    push rax
    push rbx
    mov ebx, eax
.l: cmp [t_col], ebx
    jae .d
    mov al, ' '
    call tput_c
    jmp .l
.d: pop rbx
    pop rax
    ret

term_clear_buf:
    push rax
    push rcx
    push rdi
    mov rdi, TBUF
    mov al, ' '
    mov ecx, ROWS*COLS
    rep stosb
    mov dword [t_row], 0
    mov dword [t_col], 0
    pop rdi
    pop rcx
    pop rax
    ret

term_prompt:
    lea rsi, [s_ps1]
    call tput_s
    lea rsi, [tpath]
    call tput_s
    lea rsi, [s_ps2]
    call tput_s
    mov eax, [t_col]
    mov [t_pstart], eax
    mov dword [t_inlen], 0
    ret

term_setmode:
    cmp byte [t_fs], 0
    jne .fs
    mov dword [t_cx], WX+1
    mov dword [t_cw], WW-2
    mov dword [t_ox], GX
    mov dword [t_oy], GY
    mov eax, C_TXT
    mov [t_fgc], eax
    mov eax, C_WIN
    mov [t_bgc], eax
    ret
.fs:
    mov dword [t_cx], 0
    mov dword [t_cw], SW
    mov dword [t_ox], 16
    mov dword [t_oy], 16
    mov dword [t_fgc], 0xD3D7CF
    mov dword [t_bgc], 0
    ret

term_row:                           ; eax=row
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov r8d, eax
    mov ecx, eax
    shl ecx, 4
    add ecx, [t_oy]
    mov ebx, [t_cx]
    mov esi, [t_cw]
    mov edx, 16
    mov eax, [t_bgc]
    call rect
    mov eax, r8d
    imul eax, COLS
    lea rsi, [TBUF+rax]
    mov byte [g_tr], 0
    mov eax, [t_fgc]
    mov [g_fg], eax
    mov eax, [t_bgc]
    mov [g_bg], eax
    xor edx, edx
.c: movzx eax, byte [rsi+rdx]
    cmp al, ' '
    je .s
    test al, al
    jz .s
    mov ebx, edx
    shl ebx, 3
    add ebx, [t_ox]
    mov ecx, r8d
    shl ecx, 4
    add ecx, [t_oy]
    call glyph
.s: inc edx
    cmp edx, COLS
    jb .c
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

term_all:
    push rax
    xor eax, eax
.l: call term_row
    inc eax
    cmp eax, ROWS
    jb .l
    pop rax
    ret

term_caret:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov ebx, [t_col]
    cmp ebx, COLS
    jae .o
    shl ebx, 3
    add ebx, [t_ox]
    mov ecx, [t_row]
    shl ecx, 4
    add ecx, [t_oy]
    add ecx, 14
    mov esi, 8
    mov edx, 2
    mov eax, C_ACC
    call rect
.o: pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

term_redraw:
    call term_setmode
    cmp byte [t_fs], 0
    jne .fs
    lea rsi, [s_term_t]
    call draw_win
    lea rsi, [s_nil]
    call set_status
    jmp .d
.fs:
    call fs_black
.d: call term_all
    call term_caret
    ret

parse_dir:                          ; rsi=arg -> eax=0..2 dir, 3 root, -1 bad
    push rbx
    push rsi
    push rdi
    cmp byte [rsi], '/'
    jne .a
    inc rsi
.a: cmp byte [rsi], 0
    je .root
    cmp word [rsi], 0x2E2E
    je .root
    xor ebx, ebx
.l: mov eax, ebx
    shl eax, 3
    lea rdi, [dirnm+rax]
    call strcmp
    je .got
    inc ebx
    cmp ebx, 3
    jb .l
    mov eax, -1
    jmp .x
.got:
    mov eax, ebx
    jmp .x
.root:
    mov eax, 3
.x: pop rdi
    pop rsi
    pop rbx
    ret

resolve:                            ; rsi=arg -> rsi=absolute path (in PATHB)
    push rcx
    push rdi
    cmp byte [rsi], '/'
    jne .rel
    mov rdi, PATHB
    call strcpy
    mov rsi, PATHB
    jmp .o
.rel:
    push rsi
    mov rdi, PATHB
    lea rsi, [tpath]
    cmp byte [tpath+1], 0
    jne .go
    lea rsi, [dirpfx+16]
.go:
    call sappend
    pop rsi
    call sappend
    mov rsi, PATHB
.o: pop rdi
    pop rcx
    ret

abs_dir:                            ; rsi=arg -> PATHB = absolute dir with trailing /, CF=1 if invalid
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    mov rdi, PATHB
    cmp byte [rsi], 0
    je .cur
    cmp word [rsi], 0x2E2E
    jne .n1
    cmp byte [rsi+2], 0
    je .up
.n1:
    cmp byte [rsi], '/'
    je .abs
    push rsi
    lea rsi, [tpath]
    call sappend
    pop rsi
.abs:
    call sappend
    jmp .fin
.cur:
    lea rsi, [tpath]
    call sappend
    jmp .fin
.up:
    lea rsi, [tpath]
    call sappend
    mov rsi, PATHB
    call strlen
    cmp eax, 1
    jbe .fin
    dec eax
.ul:
    dec eax
    cmp byte [PATHB+rax], '/'
    jne .ul
    mov byte [PATHB+rax+1], 0
.fin:
    mov rsi, PATHB
    call strlen
    cmp byte [PATHB+rax-1], '/'
    je .v
    mov byte [PATHB+rax], '/'
    mov byte [PATHB+rax+1], 0
.v: mov rsi, PATHB
    cmp word [rsi], 0x002F
    je .ok
    xor edx, edx
.tl:
    mov eax, edx
    shl eax, 3
    lea rdi, [dirpfx+rax]
    call strcmp
    je .ok
    inc edx
    cmp edx, 3
    jb .tl
    call fs_find
    test rax, rax
    jnz .ok
    stc
    jmp .out
.ok:
    clc
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    mov rsi, PATHB
    ret

find_any:                           ; rsi=path in PATHB -> rax=slot (exact, folder/, or .txt) or 0
    push rdi
    call fs_find
    test rax, rax
    jnz .d
    push rsi
    call strlen
    mov byte [rsi+rax], '/'
    mov byte [rsi+rax+1], 0
    call fs_find
    test rax, rax
    jnz .p
    mov rsi, [rsp]
    call strlen
    mov byte [rsi+rax-1], 0
    call ensure_ext
    call fs_find
.p: pop rsi
.d: pop rdi
    ret

set_tcwd:
    push rax
    mov eax, 3
    cmp word [tpath], 0x002F
    je .s
    xor eax, eax
    cmp dword [tpath], 0x7361622F
    je .s
    mov eax, 1
    cmp dword [tpath], 0x6D75642F
    je .s
    mov eax, 2
.s: mov [t_cwd], eax
    pop rax
    ret

%macro CMD 2
    mov rsi, rbx
    lea rdi, [%1]
    call strcmp
    je %2
%endmacro

%macro GUARD 0
    call guard_args
    jc .denied
%endmacro

term_exec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rsi, CMDBUF
    call skipsp
    cmp byte [rsi], 0
    je .out
    mov rbx, rsi
.f: mov al, [rsi]
    test al, al
    jz .ce
    cmp al, ' '
    je .cs
    inc rsi
    jmp .f
.cs:
    mov byte [rsi], 0
    inc rsi
    call skipsp
.ce:
    mov r14, rsi
    mov rsi, rbx
    lea rdi, [c_echo]
    call strcmp
    jne .noecho
    mov rsi, r14
    call tput_s
    call tnl
    jmp .out
.noecho:
    mov rsi, rbx
    lea rdi, [c_calc]
    call strcmp
    je .calc
    mov rsi, rbx
    lea rdi, [c_cowsay]
    call strcmp
    je .cow
    mov r15, r14
    mov rsi, r14
.g: mov al, [rsi]
    test al, al
    jz .gd
    cmp al, ' '
    je .gs
    inc rsi
    jmp .g
.gs:
    mov byte [rsi], 0
    inc rsi
    call skipsp
.gd:
    mov r12, rsi
    CMD c_help, .help
    CMD c_ls, .ls
    CMD c_cd, .cd
    CMD c_cat, .cat
    CMD c_edit, .edit
    CMD c_run, .run
    CMD c_new, .new
    CMD c_rm, .rm
    CMD c_cp, .cp
    CMD c_mkdir, .mkdir
    CMD c_mv, .mv
    CMD c_empty, .empty
    CMD c_clear, .clear
    CMD c_ver, .ver
    CMD c_reboot, .reboot
    CMD c_exit, .exit
    CMD c_cls, .clear
    CMD c_date, .date
    CMD c_uptime, .uptime
    CMD c_mem, .mem
    CMD c_sleep, .sleep
    CMD c_shutdown, .shutdown
    CMD c_cmatrix, .cmatrix
    CMD c_desktop, .exit
    CMD c_ps, .ps
    CMD c_whoami, .whoami
    CMD c_sudo, .sudo
    CMD c_kill, .kill
    CMD c_ifconfig, .ifc
    CMD c_ping, .ping
    CMD c_nslookup, .nsl
    CMD c_dhcp, .dhcp
    lea rsi, [s_unk]
    call tput_s
    jmp .out
.help:
    lea rsi, [s_help]
    call tput_s
    jmp .out
.ver:
    lea rsi, [s_ver]
    call tput_s
    jmp .out
.clear:
    call term_clear_buf
    jmp .out
.exit:
    mov byte [t_quit], 1
    jmp .out
.reboot:
    mov al, 0xFE
    out 0x64, al
    hlt
    jmp $

.cd:
    GUARD
    cmp byte [r15], 0
    jne .cd1
    lea r15, [s_homep]
.cd1:
    mov rsi, r15
    call abs_dir
    jc .badpath
    lea rdi, [tpath]
    mov rsi, PATHB
    call strcpy
    call set_tcwd
    jmp .out
.ls:
    cmp byte [r15], '0'
    jne .lsn
    cmp byte [r15+1], 0
    je .ls0

.lsn:
    GUARD
    mov rsi, r15
    call abs_dir
    jc .badpath
    cmp word [PATHB], 0x002F
    jne .lsd
    lea rsi, [s_rootls]
    call tput_s
    jmp .out
.lsd:
    mov rsi, PATHB
    call set_curdir
    call collect
    cmp dword [f_cnt], 0
    jne .lsl0
    lea rsi, [s_empty]
    call tput_s
    call tnl
    jmp .out
.lsl0:
    xor r14d, r14d
.lsl:
    cmp r14d, [f_cnt]
    jae .out
    mov r13, [ITEMS+r14*8]
    mov eax, [cd_len]
    lea rsi, [r13+rax]
    call tput_s
    mov eax, 30
    call tpad
    mov rsi, r13
    call strlen
    cmp byte [r13+rax-1], '/'
    jne .lsz
    call tnl
    inc r14d
    jmp .lsl
.lsz:
    mov eax, [r13+48]
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
    call tput_s
    lea rsi, [s_bytes]
    call tput_s
    call tnl
    inc r14d
    jmp .lsl
.cat:
    GUARD
    mov rsi, r15
    call resolve
    call find_any
    test rax, rax
    jz .nofile
    mov ecx, [rax+48]
    lea rsi, [rax+64]
.cl:
    test ecx, ecx
    jz .cd2
    lodsb
    call tput_c
    dec ecx
    jmp .cl
.cd2:
    cmp dword [t_col], 0
    je .out
    call tnl
    jmp .out
.edit:
    GUARD
    mov rsi, r15
    call resolve
    call ensure_ext
    call fs_create
    test rax, rax
    jz .badpath
    call editor_open
    call term_redraw
    jmp .out
.run:
    GUARD
    mov rsi, r15
    call resolve
    call fs_find
    test rax, rax
    jz .nofile
    mov r13, rax
    mov rsi, rax
    call is_xep
    test eax, eax
    jz .notxep
    mov rax, r13
    call run_slot
    call term_redraw
    jmp .out
.new:
    GUARD
    mov rsi, r15
    call resolve
    call ensure_ext
    call fs_create
    test rax, rax
    jz .badpath
    jmp .ok

.rm:
    GUARD
    mov rsi, r15
    call resolve
    call find_any
    test rax, rax
    jz .nofile
    mov r13, rax
    mov rsi, rax
    call strlen
    cmp byte [r13+rax-1], '/'
    jne .rmf
    mov rax, r13
    call folder_empty
    jne .notempty
    mov byte [r13], 0
    mov rax, r13
    call fs_save
    jmp .ok
.rmf:
    cmp dword [r13], 0x6D75642F
    jne .rm1
    cmp word [r13+4], 0x2F70
    jne .rm1
    mov byte [r13], 0
    mov rax, r13
    call fs_save
    jmp .ok
.rm1:
    mov rsi, r13
    call basename
    mov ecx, 1
    call mkpath
    mov rax, r13
    call fs_move
    jmp .ok
.mkdir:
    GUARD
    mov rsi, r15
    call resolve
    mov rdi, rsi
    call strlen
    cmp byte [rdi+rax-1], '/'
    je .mk1
    mov byte [rdi+rax], '/'
    mov byte [rdi+rax+1], 0
.mk1:
    mov rsi, rdi
    call fs_create
    test rax, rax
    jz .badpath
    jmp .ok
.notempty:
    lea rsi, [s_notempty]
    call tput_s
    jmp .out
.cp:
    GUARD
    mov rsi, r15
    call resolve
    call fs_find
    test rax, rax
    jz .nofile
    mov r13, rax
    mov rsi, r12
    call resolve
    call ensure_ext
    call fs_create
    test rax, rax
    jz .badpath
    cmp rax, r13
    je .badpath
    mov rdi, rax
    mov ecx, [r13+48]
    mov [rdi+48], ecx
    add rdi, 64
    lea rsi, [r13+64]
    rep movsb
    call fs_save
    jmp .ok
.mv:
    GUARD
    mov rsi, r15
    call resolve
    call fs_find
    test rax, rax
    jz .nofile
    mov r13, rax
    mov rsi, r12
    call resolve
    call ensure_ext
    call path_ok
    jne .badpath
    mov rax, r13
    call fs_move
    jmp .ok
.empty:
    mov r13, FSBUF
    mov r14d, MAXF
.el:
    cmp byte [r13], 0
    je .en
    cmp dword [r13], 0x6D75642F
    jne .en
    cmp word [r13+4], 0x2F70
    jne .en
    mov byte [r13], 0
    mov rax, r13
    call fs_save
.en:
    add r13, SLOT
    dec r14d
    jnz .el
    jmp .ok
.ls0:
    cmp byte [sudo_on], 0
    je .denied
    mov r13, FSBUF
    mov r14d, MAXF
.l0:
    cmp byte [r13], 0
    je .l0n
    mov al, '0'
    call tput_c
    mov rsi, r13
    call tput_s
    call tnl
.l0n:
    add r13, SLOT
    dec r14d
    jnz .l0
    jmp .out
.date:
    mov rdi, TMPB
    mov byte [rdi], '2'
    mov byte [rdi+1], '0'
    add rdi, 2
    mov al, 9
    call rtc_put
    mov byte [rdi], '-'
    inc rdi
    mov al, 8
    call rtc_put
    mov byte [rdi], '-'
    inc rdi
    mov al, 7
    call rtc_put
    mov byte [rdi], ' '
    inc rdi
    mov al, 4
    call rtc_put
    mov byte [rdi], ':'
    inc rdi
    mov al, 2
    call rtc_put
    mov byte [rdi], ':'
    inc rdi
    xor eax, eax
    call rtc_put
    mov byte [rdi], 10
    mov byte [rdi+1], 0
    mov rsi, TMPB
    call tput_s
    jmp .out
.uptime:
    call tod_sec
    sub eax, [boot_tod]
    jns .up1
    add eax, 86400
.up1:
    xor edx, edx
    mov ecx, 3600
    div ecx
    mov r13d, edx
    mov rdi, TMPB
    lea rsi, [s_up]
    call sappend
    call u2s
    lea rsi, [s_h]
    call sappend
    mov eax, r13d
    xor edx, edx
    mov ecx, 60
    div ecx
    mov r13d, edx
    call u2s
    lea rsi, [s_m]
    call sappend
    mov eax, r13d
    call u2s
    lea rsi, [s_s]
    call sappend
    mov rsi, TMPB
    call tput_s
    jmp .out
.mem:
    cmp dword [bi_mem], 0
    jne .mm1
    lea rsi, [s_unknown]
    call tput_s
    call tnl
    jmp .out
.mm1:
    mov rdi, TMPB
    lea rsi, [s_mem_t]
    call sappend
    mov eax, [bi_mem]
    shr eax, 10
    call u2s
    lea rsi, [s_mem_u]
    call sappend
    mov eax, SYS_KB
    call u2s
    lea rsi, [s_mem_f]
    call sappend
    mov eax, [bi_mem]
    sub eax, SYS_KB
    shr eax, 10
    call u2s
    lea rsi, [s_mem_e]
    call sappend
    mov rsi, TMPB
    call tput_s
    jmp .out
.sleep:
    mov rsi, r15
    xor ecx, ecx
.sl1:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .sl2
    imul ecx, ecx, 10
    add ecx, eax
    inc rsi
    jmp .sl1
.sl2:
    mov ebx, ecx
    call wait_secs
    jmp .out
.shutdown:
    lea rsi, [s_bye]
    call tput_s
    mov eax, [t_row]
    call term_row
    mov dx, 0x604
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004
    out dx, ax
    lea rsi, [s_halt]
    call tput_s
    jmp .out
.cmatrix:
    call cmatrix
    call term_redraw
    jmp .out
.q:
    mov byte [t_fs], 1
    call term_redraw
    jmp .out
.ps:
    lea rsi, [s_ps]
    call tput_s
    xor r13d, r13d
.psl:
    mov eax, r13d
    shl eax, 7
    mov rbx, TASKS
    add rbx, rax
    cmp dword [rbx+T_STATE], 0
    je .psn
    mov rdi, TMPB
    mov eax, r13d
    call u2s
    lea rsi, [s_2sp]
    call sappend
    mov rsi, [rbx+T_TITLE]
    test rsi, rsi
    jnz .pst2
    lea rsi, [s_shellnm]
.pst2:
    call sappend
    mov byte [rdi], 10
    mov byte [rdi+1], 0
    mov rsi, TMPB
    call tput_s
.psn:
    inc r13d
    cmp r13d, NTASK
    jb .psl
    jmp .out
.kill:
    mov rsi, r14
    call skipsp
    cmp byte [rsi], '0'
    jb .kusage
    cmp byte [rsi], '9'
    ja .kusage
    call parse_num
    test eax, eax
    jz .kdeny
    cmp eax, NTASK
    jae .kbad
    cmp eax, [task_cur]
    je .kdeny
    mov ebx, eax
    shl ebx, 7
    add rbx, TASKS
    cmp dword [rbx+T_STATE], 0
    je .kbad
    call task_kill
    jmp .out
.kusage:
    lea rsi, [s_kusage]
    call tput_s
    jmp .out
.kdeny:
    lea rsi, [s_kdeny]
    call tput_s
    jmp .out
.kbad:
    lea rsi, [s_kbad]
    call tput_s
    jmp .out
.whoami:
    lea rsi, [SB_USER]
    call tput_s
    call tnl
    jmp .out
.ifc:
    call tc_ifconfig
    jmp .out
.ping:
    mov rsi, r14
    call tc_ping
    jmp .out
.nsl:
    mov rsi, r14
    call tc_nslookup
    jmp .out
.dhcp:
    call tc_dhcp
    jmp .out
.denied:
    lea rsi, [s_denied]
    call tput_s
    jmp .out.calc:
    mov byte [calc_err], 0
    mov rsi, r14
    call ex_expr
    mov r13d, eax
    call skipsp
    cmp byte [rsi], 0
    jne .cerr
    cmp byte [calc_err], 0
    jne .cerr
    test r13d, r13d
    jns .cprint
    mov al, '-'
    call tput_c
    neg r13d
.cprint:
    mov eax, r13d
    mov rdi, TMPB
    call u2s
    mov rsi, TMPB
    call tput_s
    call tnl
    jmp .out
.cerr:
    lea rsi, [s_cerr]
    call tput_s
    jmp .out
.cow:
    mov rsi, r14
    cmp byte [rsi], 0
    jne .cw1
    lea rsi, [s_moo]
.cw1:
    mov r13, rsi
    call strlen
    cmp eax, 60
    jbe .cw2
    mov eax, 60
.cw2:
    mov r12d, eax
    mov al, ' '
    call tput_c
    lea ecx, [r12+2]
.cw3:
    mov al, '_'
    call tput_c
    dec ecx
    jnz .cw3
    call tnl
    mov al, '<'
    call tput_c
    mov al, ' '
    call tput_c
    mov rsi, r13
    mov ecx, r12d
.cw4:
    lodsb
    call tput_c
    dec ecx
    jnz .cw4
    mov al, ' '
    call tput_c
    mov al, '>'
    call tput_c
    call tnl
    mov al, ' '
    call tput_c
    lea ecx, [r12+2]
.cw5:
    mov al, '-'
    call tput_c
    dec ecx
    jnz .cw5
    call tnl
    lea rsi, [s_cow]
    call tput_s
    jmp .out
.sudo:
    mov rsi, r15
    lea rdi, [v_k]
    call strcmp
    jne .sd1
    mov byte [sudo_on], 0
    jmp .ok
.sd1:
    cmp byte [sudo_on], 0
    jne .ok
    lea rsi, [s_pwp]
    call tput_s
    mov eax, [t_row]
    call term_row
    call term_caret
    xor r13d, r13d
.sd2:
    call getkey
    cmp al, 13
    je .sd5
    cmp al, 8
    je .sd3
    cmp al, 32
    jb .sd2
    cmp al, 0xDF
    ja .sd2
    cmp r13d, 30
    jae .sd2
    mov [PWA+r13], al
    inc r13d
    mov al, '*'
    call tput_c
    jmp .sd4
.sd3:
    test r13d, r13d
    jz .sd2
    dec r13d
    dec dword [t_col]
    mov eax, [t_row]
    imul eax, COLS
    add eax, [t_col]
    mov byte [TBUF+rax], ' '
.sd4:
    mov eax, [t_row]
    call term_row
    call term_caret
    jmp .sd2
.sd5:
    mov byte [PWA+r13], 0
    call tnl
    mov rsi, PWA
    call hash_str
    cmp eax, [SB_HASH]
    jne .sd6
    mov byte [sudo_on], 1
    jmp .ok
.sd6:
    lea rsi, [s_sorry]
    call tput_s
    jmp .out
.ok:
    lea rsi, [s_ok]
    call tput_s
    jmp .out
.nofile:
    lea rsi, [s_nofile]
    call tput_s
    jmp .out
.notxep:
    lea rsi, [s_notxep]
    call tput_s
    jmp .out
.badpath:
    lea rsi, [s_bad]
    call tput_s
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

app_term:
    mov byte [t_fs], 0
    call term_setmode
    lea rsi, [s_term_t]
    call draw_win
    lea rsi, [s_nil]
    call set_status
    cmp byte [t_init], 0
    jne .go
    mov byte [t_init], 1
    call term_clear_buf
    lea rsi, [s_banner]
    call tput_s
    call term_prompt
.go:
    mov byte [t_quit], 0
    mov byte [t_scr], 0
    call term_all
    call term_caret
.key:
    call getkey
    cmp al, 27
    je .esc
    cmp al, 13
    je .enter
    cmp al, 8
    je .bs
    cmp al, 32
    jb .key
    cmp al, 0xDF
    ja .key
    mov ecx, [t_inlen]
    cmp ecx, 80
    jae .key
    mov [CMDBUF+rcx], al
    inc dword [t_inlen]
    call tput_c
    jmp .upd
.bs:
    mov ecx, [t_inlen]
    test ecx, ecx
    jz .key
    dec ecx
    mov [t_inlen], ecx
    mov eax, [t_col]
    dec eax
    mov [t_col], eax
    mov edx, [t_row]
    imul edx, COLS
    add edx, eax
    mov byte [TBUF+rdx], ' '
.upd:
    cmp byte [t_scr], 0
    jne .full
    mov eax, [t_row]
    call term_row
    call term_caret
    jmp .key
.full:
    mov byte [t_scr], 0
    call term_all
    call term_caret
    jmp .key
.enter:
    mov ecx, [t_inlen]
    mov byte [CMDBUF+rcx], 0
    call tnl
    call term_exec
    cmp byte [t_quit], 0
    jne .ret
    call term_prompt
    mov byte [t_scr], 0
    call term_all
    call term_caret
    jmp .key
.esc:
    cmp byte [t_fs], 0
    jne .key
.ret:
    mov byte [t_fs], 0
    ret

VWMAP   equ 0x370000                ; image x map

; ================================================================ IMAGES ====
app_images:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov dword [im_sel], 0
.build:
    xor r9d, r9d                    ; count
    mov rdi, FSBUF
    mov ecx, MAXF
.s: cmp byte [rdi], 0
    je .n
    mov rsi, rdi
    call ext4
    cmp eax, 0x706D622E
    jne .n
    cmp r9d, 20
    jae .n
    mov [ITEMS+r9*8], rdi
    inc r9d
.n: add rdi, SLOT
    dec ecx
    jnz .s
    mov [im_n], r9d
.draw:
    lea rsi, [s_img_t]
    call draw_win
    mov byte [g_tr], 0
    SETC g_bg, C_WIN
    SETC g_fg, C_TXT
    cmp dword [im_n], 0
    jne .lst
    lea rsi, [s_noimg]
    mov eax, 2
    mov edx, 2
    call puts_cell
    jmp .key
.lst:
    xor r8d, r8d
.l: cmp r8d, [im_n]
    jae .key
    mov ecx, r8d
    shl ecx, 4
    add ecx, GY+16
    cmp r8d, [im_sel]
    jne .ns
    push rcx
    mov eax, C_ACC
    mov ebx, GX
    mov esi, WW-24
    mov edx, 16
    call rect
    pop rcx
    mov dword [g_fg], 0xFFFFFF
    ACCSET g_bg
    jmp .pn
.ns:
    SETC g_fg, C_TXT
    SETC g_bg, C_WIN
.pn:
    mov rsi, [ITEMS+r8*8]
    mov ebx, GX+8
    call text
    inc r8d
    jmp .l
.key:
    SETC g_bg, C_WIN
    call getkey
    cmp al, 27
    je .exit
    cmp dword [im_n], 0
    je .key
    cmp al, K_DN
    jne .k1
    mov eax, [im_sel]
    inc eax
    cmp eax, [im_n]
    jae .draw
    mov [im_sel], eax
    jmp .draw
.k1:
    cmp al, K_UP
    jne .k2
    cmp dword [im_sel], 0
    je .draw
    dec dword [im_sel]
    jmp .draw
.k2:
    cmp al, 13
    jne .key
    mov eax, [im_sel]
    mov rax, [ITEMS+rax*8]
    call viewer_show
    jmp .draw
.exit:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

viewer_show:                        ; rax = slot (.bmp)
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r15, rax
    lea rsi, [s_img_t]
    call draw_win
    lea rbx, [r15+64]
    cmp word [rbx], 'BM'
    jne .bad
    mov eax, [rbx+14]
    cmp eax, 40
    jb .bad
    mov r8d, [rbx+18]               ; width
    mov r9d, [rbx+22]               ; height
    movzx r10d, word [rbx+28]
    cmp dword [rbx+30], 0
    jne .bad
    cmp r8d, 1
    jl .bad
    cmp r8d, 4096
    jg .bad
    mov r13d, 1                     ; 1 = bottom-up
    test r9d, r9d
    jns .h1
    neg r9d
    xor r13d, r13d
.h1:
    cmp r9d, 1
    jl .bad
    cmp r9d, 4096
    jg .bad
    cmp r10d, 24
    je .okb
    cmp r10d, 32
    je .okb
    cmp r10d, 4
    je .okb
    cmp r10d, 8
    jne .bad
.okb:
    mov eax, r8d
    imul eax, r10d
    add eax, 31
    shr eax, 5
    shl eax, 2
    mov r11d, eax                   ; stride
    mov eax, [rbx+10]
    lea r14, [rbx+rax]              ; pixel data
    mov eax, r11d
    imul eax, r9d
    add eax, [rbx+10]
    cmp eax, [r15+48]
    ja .bad
    mov eax, [rbx+14]
    lea rbp, [rbx+14]
    add rbp, rax                    ; palette
    ; scale (16.16) = min(AW/w, AH/h)
    mov eax, 784*65536
    xor edx, edx
    div r8d
    mov ecx, eax
    mov eax, 556*65536
    xor edx, edx
    div r9d
    cmp eax, ecx
    jae .sc1
    mov ecx, eax
.sc1:
    cmp ecx, 65536
    jb .sc2
    shr ecx, 16
    shl ecx, 16
.sc2:
    mov eax, r8d
    imul rax, rcx
    shr rax, 16
    jnz .dw1
    mov eax, 1
.dw1:
    mov [vw_dw], eax
    mov eax, r9d
    imul rax, rcx
    shr rax, 16
    jnz .dh1
    mov eax, 1
.dh1:
    mov [vw_dh], eax
    mov eax, 784
    sub eax, [vw_dw]
    shr eax, 1
    add eax, WX+8
    mov [vw_ox], eax
    mov eax, 556
    sub eax, [vw_dh]
    shr eax, 1
    add eax, WY+HDRH+8
    mov [vw_oy], eax
    ; x map
    xor ecx, ecx
.xm:
    mov eax, ecx
    imul eax, r8d
    xor edx, edx
    div dword [vw_dw]
    mov [VWMAP+rcx*4], eax
    inc ecx
    cmp ecx, [vw_dw]
    jb .xm
    xor r12d, r12d                  ; dy
.ry:
    mov eax, r12d
    imul eax, r9d
    xor edx, edx
    div dword [vw_dh]
    test r13d, r13d
    jz .td
    mov ecx, r9d
    dec ecx
    sub ecx, eax
    mov eax, ecx
.td:
    imul eax, r11d
    lea rsi, [r14+rax]
    mov ecx, [vw_oy]
    add ecx, r12d
    imul rcx, [cur_pitch]
    mov eax, [vw_ox]
    lea rdi, [rcx+rax*4]
    add rdi, [cur_fb]
    xor ecx, ecx
.rx:
    mov eax, [VWMAP+rcx*4]
    cmp r10d, 24
    je .p24
    cmp r10d, 32
    je .p32
    cmp r10d, 4
    je .p4
    movzx eax, byte [rsi+rax]
    mov eax, [rbp+rax*4]
    jmp .pw
.p4:
    mov rdx, rax
    shr rdx, 1
    movzx edx, byte [rsi+rdx]
    test al, 1
    jnz .p4l
    shr edx, 4
    jmp .p4d
.p4l:
    and edx, 15
.p4d:
    mov eax, [rbp+rdx*4]
    jmp .pw
.p24:
    lea rdx, [rax+rax*2]
    mov eax, [rsi+rdx]
    jmp .pw
.p32:
    mov eax, [rsi+rax*4]
.pw:
    and eax, 0xFFFFFF
    mov [rdi+rcx*4], eax
    inc ecx
    cmp ecx, [vw_dw]
    jb .rx
    inc r12d
    cmp r12d, [vw_dh]
    jb .ry
    mov rsi, r15
    call set_status
    jmp .wait
.bad:
    mov byte [g_tr], 0
    SETC g_bg, C_WIN
    SETC g_fg, C_TXT
    lea rsi, [s_badimg]
    mov eax, 2
    mov edx, 2
    call puts_cell
.wait:
    call getkey
    cmp al, 27
    jne .wait
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---------------------------------------------------------------- samples ----
ensure_samples:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [p_www]
    call fs_find
    test rax, rax
    jnz .have
    lea rsi, [p_www]
    call fs_create
    test rax, rax
    jz .out
    call fs_save
.have:
    lea rbx, [sample_tab]
.l: mov rsi, [rbx]
    test rsi, rsi
    jz .bmp
    push rsi
    call fs_find
    pop rsi
    test rax, rax
    jnz .nx
    mov rdx, [rbx+8]
    call fs_mk
    test rax, rax
    jz .nx
    call fs_save
.nx:
    add rbx, 16
    jmp .l
.bmp:
    lea rsi, [p_sbmp]
    call fs_find
    test rax, rax
    jnz .out
    lea rsi, [p_sbmp]
    call fs_create
    test rax, rax
    jz .out
    mov rbx, rax
    lea rdi, [rbx+64]
    lea rsi, [bmp_hdr]
    mov ecx, 54
    rep movsb
    xor edx, edx                    ; y
.by:
    xor ecx, ecx                    ; x
.bx:
    mov eax, ecx
    shl eax, 2
    stosb                           ; B
    mov eax, edx
    shl eax, 2
    stosb                           ; G
    mov eax, ecx
    add eax, edx
    add eax, eax
    mov esi, 255
    sub esi, eax
    jns .r1
    xor esi, esi
.r1: mov eax, esi
    stosb                           ; R
    inc ecx
    cmp ecx, 64
    jb .bx
    inc edx
    cmp edx, 64
    jb .by
    mov dword [rbx+48], 54+64*64*3
    mov rax, rbx
    call fs_save
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---------------------------------------------------------------- data -------

sample_tab:
    dq p_www_idx, d_w_index
    dq p_w_xpl, d_w_xpl
    dq p_w_keys, d_w_keys
    dq p_w_net, d_w_net
    dq 0, 0

bmp_hdr:
    db 'B','M'
    dd 54+64*64*3
    dd 0
    dd 54
    dd 40
    dd 64
    dd 64
    dw 1
    dw 24
    dd 0
    dd 64*64*3
    dd 2835
    dd 2835
    dd 0
    dd 0

d_w_index:
    db "<title>Centtrix</title>",10
    db "<h1>Centtrix pages</h1>",10
    db "<p>This browser reads pages stored on the Centtrix disk (put your own .htm files in /base/www or /home) and plain http:// pages from the network.</p>",10
    db "<p>Press <b>g</b> and type an address such as example.com, then Enter.</p>",10
    db "<ul>",10
    db "<li><a href=",34,"xpl.htm",34,">XPL language guide</a></li>",10
    db "<li><a href=",34,"keys.htm",34,">Editor and keys</a></li>",10
    db "<li><a href=",34,"net.htm",34,">About the internet</a></li>",10
    db "<li><a href=",34,"/base/readme.txt",34,">readme.txt</a></li>",10
    db "</ul>",10
    db "<hr>",10
    db "<p>Tab: next link. Enter: open. Backspace: back. Space: page down. Esc: close.</p>",10,0
d_w_xpl:
    db "<title>XPL guide</title>",10
    db "<h1>XPL</h1>",10
    db "<p>XPL is the Centtrix language. Programs are .xep files written in the editor and run with :r.</p>",10
    db "<h2>Commands</h2>",10
    db "<pre>",10
    db "say text         print a line",10
    db "print text       print without newline",10
    db "let n 5          set variable n",10
    db "add n 1          n = n + 1",10
    db "sub n 1          n = n - 1",10
    db "mul n 2          n = n * 2",10
    db "at x y           move text cursor",10
    db "color n          set color 0..15",10
    db "clear            clear window",10
    db "box x y w h      filled box",10
    db "wait n           pause",10
    db "repeat n / next  loop",10
    db "end              stop",10
    db "</pre>",10
    db "<p><a href=",34,"index.htm",34,">Back to index</a></p>",10,0
d_w_keys:
    db "<title>Keys</title>",10
    db "<h1>Editor and keys</h1>",10
    db "<h2>Editor (vim like)</h2>",10
    db "<ul>",10
    db "<li>i: insert mode, Esc: normal mode</li>",10
    db "<li>:w save, :q quit, :wq both, :r run .xep</li>",10
    db "<li>Esc in normal mode closes the editor</li>",10
    db "</ul>",10
    db "<h2>Desktop</h2>",10
    db "<ul>",10
    db "<li>Arrows move, Enter opens, Esc goes back</li>",10
    db "</ul>",10
    db "<p><a href=",34,"index.htm",34,">Back to index</a></p>",10,0
d_w_net:
    db "<title>Internet</title>",10
    db "<h1>About the internet</h1>",10
    db "<p>Centtrix has a driver for Intel e1000 network cards (the default card in QEMU, VirtualBox and VMware). It gets an address by DHCP and can look up names, ping and fetch web pages over http and https.</p>",10
    db "<p>https:// works with TLS 1.2 (X25519, AES-128-GCM). The connection is encrypted, but Centtrix does not check the server certificate, so it cannot tell a real site from an impostor: do not type passwords. Sites that only offer TLS 1.3 or other ciphers cannot be opened.</p>",10
    db "<p>Pictures, scripts, styles and forms are not supported: pages are shown as text with clickable links.</p>",10
    db "<p><a href=",34,"http://example.com",34,">Try http://example.com</a></p>",10
db "<p><a href=",34,"index.htm",34,">Back to index</a></p>",10,0


; ================================================================ MAIN ======
kmain:
    cld
    mov eax, [bi_w]
    mov [scr_w], eax
    mov eax, [bi_h]
    mov [scr_h], eax
    call wm_init
    call fs_init
    lea rsi, [p_cfg]
    call fs_find
    push rax
    call cfg_load
    pop rax
    call cfg_clamp
    call apply_theme
    call mouse_init
    movzx eax, byte [SB_WALL]
    call wp_gen
    call base_from_wall
    lea rax, [font_ui]
    mov [g_uf], rax
    mov dword [TASKS+T_STATE], 1
    mov dword [ntasks], 1
    call tod_sec
    mov [boot_tod], eax
    call ensure_samples
    lea rsi, [p_cfg]
    call fs_find
    test rax, rax
    jnz .hascfg
    call cfg_write
.hascfg:
    call splash_screen
    call shell_init
    call desk_draw
    call login_screen
.idle:
    call pollkey
    call shell_step
    jmp .idle

; =============================================================== DATA =======

palette:
    dd 0x2E3436, 0xE01B24, 0x26A269, 0xE5A50A
    dd 0x3584E4, 0x9141AC, 0x2AA1B3, 0xDEDDDA
    dd 0x77767B, 0xF66151, 0x57E389, 0xF8E45C
    dd 0x62A0EA, 0xDC8ADD, 0x93DDC2, 0x000000

%macro lbl 1
%%s: db %1, 0
     times 16-($-%%s) db 0
%endmacro

dirdesc:
    lbl "system files"
    lbl "deleted files"
    lbl "your files"
lbltab:
    lbl "Files"
    lbl "Terminal"
    lbl "Editor"
    lbl "Browser"
    lbl "Images"
    lbl "Monitor"
    lbl "Settings"
    lbl "About"

s_ps1        db "centtrix:",0
s_ps2        db "$ ",0





; ---- padding: kernel area, then the empty filesystem area ------------------
; ---- begin layouts.inc
lay_tab:
lay_en_n:
    db 0,27,49,50,51,52,53,54,55,56,57,48,45,61,8,9,113,119,101,114,116,121,117,105,111,112,91,93,13,0,97,115,100,102,103,104,106,107,108,59,39,96,0,92,122,120,99,118,98,110,109,44,46,47,0,0,0,32,0,0,0,0,0,0
lay_en_s:
    db 0,27,33,64,35,36,37,94,38,42,40,41,95,43,8,9,81,87,69,82,84,89,85,73,79,80,123,125,13,0,65,83,68,70,71,72,74,75,76,58,34,126,0,124,90,88,67,86,66,78,77,60,62,63,0,0,0,32,0,0,0,0,0,0
lay_en_l:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0,0,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0
lay_ru_n:
    db 0,27,49,50,51,52,53,54,55,56,57,48,45,61,8,9,169,182,179,170,165,173,163,184,185,167,181,186,13,0,180,187,162,160,175,176,174,171,164,166,189,193,0,92,191,183,177,172,168,178,188,161,190,46,0,0,0,32,0,0,0,0,0,0
lay_ru_s:
    db 0,27,33,34,35,59,37,58,63,42,40,41,95,43,8,9,137,150,147,138,133,141,131,152,153,135,149,154,13,0,148,155,130,128,143,144,142,139,132,134,157,192,0,47,159,151,145,140,136,146,156,129,158,44,0,0,0,32,0,0,0,0,0,0
lay_ru_l:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0
lay_es_n:
    db 0,27,49,50,51,52,53,54,55,56,57,48,39,209,8,9,113,119,101,114,116,121,117,105,111,112,96,43,13,0,97,115,100,102,103,104,106,107,108,200,240,96,0,92,122,120,99,118,98,110,109,44,46,45,0,0,0,32,0,0,0,0,0,0
lay_es_s:
    db 0,27,33,34,35,36,37,38,47,40,41,61,63,208,8,9,81,87,69,82,84,89,85,73,79,80,94,42,13,0,65,83,68,70,71,72,74,75,76,207,241,126,0,124,90,88,67,86,66,78,77,59,58,95,0,0,0,32,0,0,0,0,0,0
lay_es_l:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0

; ---- end layouts.inc
; ---- begin assets.inc
font_mono:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0
    db 0,10,128,0,0,0,0,0,0,11,144,0,0,11,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,213,123,0,0,213,123,0,0,213,123,0,0,213,123,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,12,68,208,0,30,23,160,0,76,10,96,95,255,255,252,0,182,61,0,1,225,122,0
    db 255,255,255,242,8,144,211,0,11,98,224,0,14,38,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,4,112,0,2,190,234,32,10,181,135,112,11,116,112,0,5,218,146,0
    db 0,40,189,112,0,4,116,241,10,85,120,224,3,190,236,64,0,4,112,0,0,4,112,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,61,232,0,0,182,44,48,0,182,44,48,17,61,232,57,179,0,91,163,0
    db 75,130,174,177,16,6,161,136,0,6,161,137,0,0,174,194,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,249,0,7,194,0,0,5,209,0,0,6,235,0,0,77,44,128,122
    db 153,2,229,136,154,0,94,211,79,113,61,208,6,222,214,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,183,0,0,4,208,0,0,10,144,0,0,14,80,0,0,63,16,0,0,95,0,0,0,95,0,0
    db 0,63,16,0,0,14,80,0,0,10,144,0,0,4,224,0,0,0,183,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,152,0,0,0,46,32,0,0,11,112,0,0,7,192,0,0,4,240,0,0,3,242,0,0,3,242,0
    db 0,4,240,0,0,7,192,0,0,11,128,0,0,46,32,0,0,152,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,8,80,0,10,88,87,128,1,157,215,0,1,157,215,0,10,88,87,128
    db 0,8,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,112,0,0,10,112,0,0,10,112,0,127,255,255,245
    db 0,10,112,0,0,10,112,0,0,10,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,13,192,0,0,13,176,0,0,47,80,0,0,108,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,207,249,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,14,176,0,0,14,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,160,0,0,46,48,0,0,139,0,0,1,229,0,0,7,192,0
    db 0,13,96,0,0,109,0,0,0,200,0,0,4,225,0,0,11,144,0,0,63,32,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,174,233,0,9,211,78,112,14,112,9,192,47,64,7,224,63,59,150,240
    db 47,64,7,224,14,112,9,192,9,211,78,112,1,174,233,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,7,255,240,0,0,5,240,0,0,5,240,0,0,5,240,0,0,5,240,0
    db 0,5,240,0,0,5,240,0,0,5,240,0,5,255,255,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,5,206,216,0,11,81,78,112,0,0,11,160,0,0,30,112,0,0,172,0
    db 0,9,210,0,0,157,32,0,9,210,0,0,31,255,255,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,190,216,0,10,81,78,96,0,0,11,144,0,0,78,96,0,143,249,0
    db 0,0,77,128,0,0,8,192,42,49,77,160,6,207,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,1,222,0,0,9,206,0,0,76,110,0,1,212,110,0,8,160,110,0
    db 62,32,110,0,111,255,255,244,0,0,110,0,0,0,110,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,11,255,255,32,11,128,0,0,11,128,0,0,11,239,215,0,0,1,110,96
    db 0,0,10,176,0,0,10,176,42,49,94,96,7,223,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,141,250,16,8,229,22,80,14,96,0,0,47,142,235,32,63,194,44,160
    db 47,96,6,224,14,96,6,224,10,194,44,160,1,174,234,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,192,0,0,12,128,0,0,79,32,0,0,170,0,0,1,229,0
    db 0,7,208,0,0,13,128,0,0,95,32,0,0,186,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,190,234,16,12,178,61,144,14,96,9,176,10,178,45,112,1,207,250,0
    db 13,145,43,160,63,48,6,224,30,145,43,192,4,206,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,232,0,13,161,78,112,47,48,9,176,47,48,9,208,13,161,78,224
    db 3,206,217,208,0,0,9,176,7,81,110,64,2,191,214,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,176,0,0,14,176,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,14,176,0,0,14,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,176,0,0,14,176,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,13,192,0,0,13,176,0,0,47,80,0,0,108,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,22,181,0,74,235,97,93,199,32,0
    db 93,199,32,0,0,74,235,97,0,0,22,181,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,245,0,0,0,0
    db 0,0,0,0,127,255,255,245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,122,80,0,0,39,206,147,0,0,3,141,195
    db 0,3,141,195,39,206,147,0,122,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,158,234,16,7,114,62,128,0,0,13,128,0,1,172,16,0,10,160,0
    db 0,13,96,0,0,0,0,0,0,14,112,0,0,14,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,141,252,64,10,196,22,225,77,16,0,166,167,7,237,184,197,62,50,200
    db 211,106,0,136,196,62,50,200,152,7,237,184,62,32,0,0,8,213,16,0,0,108,238,112,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,31,208,0,0,109,243,0,0,185,184,0,1,229,125,0,6,225,63,48
    db 10,176,13,128,30,255,255,192,95,32,5,242,172,0,0,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,14,255,234,32,14,96,44,176,14,96,8,208,14,96,44,160,14,255,253,32
    db 14,96,41,209,14,96,3,243,14,96,24,225,14,255,236,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,109,253,80,6,246,19,144,13,144,0,0,31,96,0,0,47,80,0,0
    db 15,96,0,0,12,144,0,0,5,246,20,144,0,109,253,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,254,197,0,63,50,127,80,63,48,10,192,63,48,7,224,63,48,6,240
    db 63,48,7,224,63,48,10,192,63,50,127,80,63,254,197,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,208,12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,176
    db 12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,241,9,192,0,0,9,192,0,0,9,192,0,0,9,255,255,176
    db 9,192,0,0,9,192,0,0,9,192,0,0,9,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,141,236,48,9,229,21,128,47,96,0,0,95,32,0,0,111,0,175,240
    db 79,32,4,240,46,96,4,240,9,212,23,240,0,142,253,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224,63,255,255,224
    db 63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,11,255,255,144,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0
    db 0,12,144,0,0,12,144,0,0,12,144,0,11,255,255,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,175,255,16,0,0,79,16,0,0,79,16,0,0,79,16,0,0,79,16
    db 0,0,79,16,66,0,110,0,109,50,187,0,25,222,178,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,6,228,63,48,110,64,63,54,228,0,63,143,80,0,63,237,144,0
    db 63,84,245,0,63,48,142,32,63,48,12,176,63,48,3,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,10,176,0,0,10,176,0,0,10,176,0,0,10,176,0,0,10,176,0,0
    db 10,176,0,0,10,176,0,0,10,176,0,0,10,255,255,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,143,112,10,245,141,192,29,229,140,195,106,229,140,136,181,229,140,45,208,229
    db 140,12,144,229,140,0,0,229,140,0,0,229,140,0,0,229,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,176,5,224,63,227,5,224,63,169,5,224,63,78,21,224,63,58,133,224    db 63,52,213,224,63,48,202,224,63,48,111,224,63,48,14,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,233,0,11,194,61,128,31,80,8,208,79,32,5,241,79,32,5,241
    db 79,32,5,241,31,80,8,208,11,194,61,128,2,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,12,255,235,48,12,144,43,209,12,144,3,243,12,144,3,243,12,144,43,209
    db 12,255,235,48,12,144,0,0,12,144,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,233,0,11,194,61,128,31,80,8,208,79,32,5,241,79,32,5,241
    db 79,32,5,240,31,80,8,208,11,194,61,128,2,191,251,16,0,0,142,32,0,0,11,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,255,233,16,47,64,78,144,47,64,10,176,47,64,61,128,47,255,248,0
    db 47,65,126,32,47,64,12,144,47,64,5,242,47,64,0,201,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,190,233,16,13,162,39,96,47,48,0,0,13,163,0,0,3,174,234,32
    db 0,0,59,176,0,0,5,224,11,65,59,176,5,206,235,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,191,255,255,249,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0
    db 0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224
    db 31,64,7,224,15,64,7,208,12,162,44,160,3,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,141,0,1,246,63,32,5,241,13,112,9,176,9,176,13,112,5,224,63,32
    db 0,228,124,0,0,168,184,0,0,108,227,0,0,31,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,230,0,0,140,199,0,0,170,169,0,0,183,139,14,176,213,92,61,224,242
    db 62,121,181,224,15,181,138,192,13,225,79,160,11,192,14,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,64,4,244,8,208,12,128,1,216,141,16,0,78,228,0,0,30,208,0
    db 0,156,200,0,4,227,78,48,29,128,9,192,157,0,1,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,141,16,2,229,29,128,11,176,5,226,78,32,0,170,216,0,0,46,208,0
    db 0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,13,255,255,245,0,0,9,209,0,0,79,64,0,1,216,0,0,10,192,0
    db 0,94,48,0,1,231,0,0,10,176,0,0,15,255,255,247,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,31,250,0,0,31,32,0,0,31,32,0,0,31,32,0,0,31,32,0,0,31,32,0,0,31,32,0
    db 0,31,32,0,0,31,32,0,0,31,32,0,0,31,32,0,0,31,250,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,32,0,0,11,144,0,0,4,225,0,0,0,200,0,0,0,109,0,0
    db 0,13,96,0,0,7,192,0,0,1,229,0,0,0,139,0,0,0,46,48,0,0,10,160,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,207,224,0,0,5,224,0,0,5,224,0,0,5,224,0,0,5,224,0,0,5,224,0,0,5,224,0
    db 0,5,224,0,0,5,224,0,0,5,224,0,0,5,224,0,0,207,224,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,46,209,0,0,186,201,0,8,193,46,80,77,32,4,210,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,255,255,253,0,0,0,0
    db 0,0,0,0,0,0,0,0,1,184,0,0,0,27,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,233,0,9,97,61,112,0,0,8,176
    db 5,206,255,176,31,97,9,176,47,81,78,176,7,239,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,12,112,0,0,12,112,0,0,12,112,0,0,12,112,0,0,12,157,235,32,12,227,44,160,12,144,5,224
    db 12,112,4,241,12,144,5,224,12,227,44,160,12,157,235,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,236,64,4,246,19,128,10,160,0,0
    db 11,128,0,0,10,160,0,0,4,246,19,128,0,92,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,9,160,0,0,9,160,0,0,9,160,0,0,9,160,3,206,202,160,12,161,95,160,47,48,11,160
    db 79,16,9,160,47,48,11,160,12,161,95,160,3,206,202,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,158,234,16,10,195,43,160,31,48,4,224
    db 63,255,255,241,31,32,0,0,11,179,21,160,1,157,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,3,207,192,0,10,160,0,0,12,96,0,0,13,80,0,12,255,255,192,0,13,80,0,0,13,80,0
    db 0,13,80,0,0,13,80,0,0,13,80,0,0,13,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,206,202,160,12,178,95,160,47,48,11,160
    db 79,16,9,160,47,48,11,160,12,178,94,160,2,206,202,160,0,0,10,128,6,97,78,48,1,174,214,0,0,0,0,0
    db 0,0,0,0,12,112,0,0,12,112,0,0,12,112,0,0,12,112,0,0,12,156,252,32,12,211,45,128,12,128,9,160
    db 12,112,8,176,12,112,8,176,12,112,8,176,12,112,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,9,160,0,0,0,0,0,0,0,0,0,0,0,0,0,7,255,160,0,0,9,160,0,0,9,160,0
    db 0,9,160,0,0,9,160,0,0,9,160,0,13,255,255,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,4,240,0,0,0,0,0,0,0,0,0,0,0,0,0,4,255,240,0,0,4,240,0,0,4,240,0
    db 0,4,240,0,0,4,240,0,0,4,240,0,0,4,240,0,0,4,224,0,0,8,192,0,13,253,64,0,0,0,0,0
    db 0,0,0,0,8,176,0,0,8,176,0,0,8,176,0,0,8,176,0,0,8,176,27,160,8,177,202,0,8,204,160,0
    db 8,251,226,0,8,176,172,0,8,176,29,144,8,176,4,245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,15,255,16,0,0,47,16,0,0,47,16,0,0,47,16,0,0,47,16,0,0,47,16,0,0,47,16,0
    db 0,47,16,0,0,47,32,0,0,14,112,0,0,5,239,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,109,221,142,160,110,44,178,242,108,10,128,211
    db 108,10,128,212,108,10,128,212,108,10,128,212,108,10,128,212,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,156,252,32,12,211,45,128,12,128,9,160
    db 12,112,8,176,12,112,8,176,12,112,8,176,12,112,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,174,233,16,11,194,61,128,15,64,7,208
    db 47,48,6,224,15,64,7,208,11,178,61,128,2,190,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,157,234,16,12,227,44,144,12,128,6,224
    db 12,112,4,240,12,128,6,224,12,211,44,160,12,157,235,16,12,112,0,0,12,112,0,0,12,112,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,190,202,176,11,178,78,176,15,64,10,176
    db 47,48,8,176,15,64,10,176,11,178,78,176,2,190,201,176,0,0,8,176,0,0,8,176,0,0,8,176,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,186,207,246,0,191,97,0,0,186,0,0
    db 0,184,0,0,0,184,0,0,0,184,0,0,0,184,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,190,232,0,9,194,40,48,8,194,0,0
    db 1,140,217,16,0,0,45,112,9,97,61,112,3,190,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,94,0,0,0,94,0,0,63,255,255,144,0,94,0,0,0,94,0,0
    db 0,94,0,0,0,94,0,0,0,63,64,0,0,9,239,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,8,176,12,112,8,176,12,112,8,176
    db 12,112,8,176,12,112,10,176,9,194,78,176,2,207,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,16,4,225,13,96,9,160,8,176,14,80
    db 2,242,94,0,0,199,169,0,0,124,228,0,0,31,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,229,0,0,139,168,0,0,184,123,12,144,212
    db 62,28,194,241,14,120,183,192,11,228,126,144,8,224,47,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,112,10,176,3,227,109,32,0,109,228,0
    db 0,30,192,0,0,171,215,0,6,209,62,64,62,64,7,226,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,32,2,243,12,128,8,192,7,208,13,96
    db 1,228,94,16,0,170,170,0,0,78,228,0,0,13,208,0,0,12,128,0,0,95,32,0,13,231,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,160,0,0,62,80,0,1,215,0
    db 0,11,144,0,0,156,0,0,6,210,0,0,11,255,255,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,3,223,112,0,9,177,0,0,10,144,0,0,10,144,0,0,45,112,0,10,252,16,0,0,78,96,0
    db 0,11,144,0,0,10,144,0,0,10,144,0,0,9,193,0,0,3,207,112,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0
    db 0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,10,128,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,10,236,16,0,0,45,96,0,0,11,112,0,0,11,128,0,0,10,177,0,0,2,223,112,0,9,210,0
    db 0,11,144,0,0,11,128,0,0,12,112,0,0,46,96,0,10,235,16,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,43,236,81,116
    db 101,21,206,161,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,94,211,0,0,223,251,0,0,223,251,0
    db 0,94,211,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,31,208,0,0,109,243,0,0,185,184,0,1,229,125,0,6,225,63,48
    db 10,176,13,128,30,255,255,192,95,32,5,242,172,0,0,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,14,255,255,192,14,96,0,0,14,96,0,0,14,255,235,48,14,96,43,208
    db 14,96,3,243,14,96,3,243,14,96,42,208,14,255,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,14,255,234,32,14,96,44,176,14,96,8,208,14,96,44,160,14,255,253,32
    db 14,96,41,209,14,96,3,243,14,96,24,225,14,255,236,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,10,255,255,244,10,176,0,0,10,176,0,0,10,176,0,0,10,176,0,0
    db 10,176,0,0,10,176,0,0,10,176,0,0,10,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,208,9,192,7,208,9,192,7,208,10,176,7,208,11,176,7,208
    db 11,144,7,208,13,128,7,208,31,112,7,208,207,255,255,250,197,0,0,138,197,0,0,138,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,208,12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,176
    db 12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,156,11,129,230,46,75,136,208,9,187,158,96,2,253,238,0,5,255,255,32
    db 10,158,220,128,30,75,135,208,109,11,130,244,185,11,128,185,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,190,216,0,10,81,78,96,0,0,11,144,0,0,78,96,0,143,249,0
    db 0,0,77,128,0,0,8,192,42,49,77,160,6,207,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,13,224,63,48,95,224,63,48,186,224,63,51,213,224,63,57,133,224
    db 63,61,21,224,63,137,5,224,63,211,5,224,63,176,5,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,126,229,0,0,0,0,0,0,0,0,0,63,48,13,224,63,48,95,224,63,48,186,224,63,51,213,224,63,57,133,224
    db 63,61,21,224,63,137,5,224,63,211,5,224,63,176,5,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,6,228,63,48,110,64,63,54,228,0,63,143,80,0,63,237,144,0
    db 63,84,245,0,63,48,142,32,63,48,12,176,63,48,3,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,255,255,224,4,241,6,224,4,241,6,224,4,241,6,224,4,241,6,224
    db 5,240,6,224,6,224,6,224,44,176,6,224,235,32,6,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,143,112,10,245,141,192,29,229,140,195,106,229,140,136,181,229,140,45,208,229
    db 140,12,144,229,140,0,0,229,140,0,0,229,140,0,0,229,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224,63,255,255,224
    db 63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,233,0,11,194,61,128,31,80,8,208,79,32,5,241,79,32,5,241
    db 79,32,5,241,31,80,8,208,11,194,61,128,2,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,224,63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224
    db 63,48,6,224,63,48,6,224,63,48,6,224,63,48,6,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,12,255,235,48,12,144,43,209,12,144,3,243,12,144,3,243,12,144,43,209
    db 12,255,235,48,12,144,0,0,12,144,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,109,253,80,6,246,19,144,13,144,0,0,31,96,0,0,47,80,0,0
    db 15,96,0,0,12,144,0,0,5,246,20,144,0,109,253,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,191,255,255,249,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0
    db 0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,64,4,242,11,160,10,176,6,225,30,80,0,214,109,0,0,139,184,0
    db 0,46,242,0,0,12,176,0,0,95,64,0,13,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,8,239,253,96,79,108,168,225,141,12,145,245,156,12,144,231
    db 141,12,145,245,63,92,168,225,6,223,253,96,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,64,4,244,8,208,12,128,1,216,141,16,0,78,228,0,0,30,208,0
    db 0,156,200,0,4,227,78,48,29,128,9,192,157,0,1,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,140,0,11,160,140,0,11,160,140,0,11,160,140,0,11,160,140,0,11,160
    db 140,0,11,160,140,0,11,160,140,0,11,160,143,255,255,248,0,0,0,168,0,0,0,168,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,48,6,224,63,48,6,224,63,48,6,224,31,112,42,224,7,239,236,224
    db 0,0,6,224,0,0,6,224,0,0,6,224,0,0,6,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,94,11,130,242,94,11,130,242,94,11,130,242,94,11,130,242,94,11,130,242
    db 94,11,130,242,94,11,130,242,94,11,130,242,95,255,255,242,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,169,15,55,192,169,15,55,192,169,15,55,192,169,15,55,192,169,15,55,192
    db 169,15,55,192,169,15,55,192,169,15,55,192,175,255,255,250,0,0,0,138,0,0,0,138,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,207,243,0,0,3,243,0,0,3,243,0,0,3,255,235,48,3,243,43,209
    db 3,243,3,243,3,243,3,243,3,243,43,209,3,255,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,171,0,2,244,171,0,2,244,171,0,2,244,175,235,50,244,171,27,194,244
    db 171,5,243,244,171,5,243,244,171,27,194,244,175,235,50,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,255,235,48,12,144,43,209
    db 12,144,3,243,12,144,3,243,12,144,43,209,12,255,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,8,238,179,0,41,34,174,32,0,0,13,128,0,0,10,176,9,255,255,192
    db 0,0,10,176,0,0,13,128,41,34,158,32,8,238,179,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,171,8,238,80,171,63,71,225,171,124,0,229,171,154,0,215,175,250,0,216
    db 171,154,0,215,171,124,0,229,171,63,70,225,171,8,238,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,255,244,12,195,2,244,14,112,2,244,12,194,2,244,2,191,255,244
    db 0,156,2,244,3,244,2,244,11,176,2,244,79,48,2,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,233,0,9,97,61,112,0,0,8,176
    db 5,206,255,176,31,97,9,176,47,81,78,176,7,239,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,6,189,48,2,205,117,16,12,128,0,0,46,174,233,16,79,178,61,128,63,64,7,208
    db 47,48,6,224,31,64,7,208,11,178,61,128,2,190,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,255,232,0,11,128,79,48,11,128,79,32
    db 11,255,250,0,11,128,45,96,11,128,46,112,11,255,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,255,255,112,7,192,0,0,7,192,0,0
    db 7,192,0,0,7,192,0,0,7,192,0,0,7,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,255,255,112,6,208,12,112,6,208,12,112
    db 7,192,12,112,8,176,12,112,10,160,12,112,111,255,255,243,106,0,0,195,106,0,0,195,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,158,234,16,10,195,43,160,31,48,4,224
    db 63,255,255,241,31,32,0,0,11,179,21,160,1,157,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,78,42,132,226,10,186,141,112,2,253,222,0
    db 6,239,255,48,11,124,170,144,47,42,132,224,139,10,128,213,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,233,16,9,81,61,128,0,0,61,96
    db 0,127,250,0,0,0,59,144,10,49,59,160,5,207,234,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,12,176,12,112,127,176,12,114,235,176
    db 12,122,152,176,12,190,24,176,12,246,8,176,12,176,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,210,76,0,0,126,229,0,0,0,0,0,12,112,12,176,12,112,127,176,12,114,235,176
    db 12,122,152,176,12,190,24,176,12,246,8,176,12,176,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,176,27,160,8,177,202,0,8,204,160,0
    db 8,251,226,0,8,176,172,0,8,176,29,144,8,176,4,245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,255,255,176,6,208,8,176,6,208,8,176
    db 6,192,8,176,7,192,8,176,27,144,8,176,204,32,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,173,0,1,232,175,96,8,248,173,209,46,216
    db 169,184,169,184,169,45,209,184,169,0,0,184,169,0,0,184,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,8,176,12,112,8,176,12,112,8,176
    db 12,255,255,176,12,112,8,176,12,112,8,176,12,112,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,174,233,16,11,194,61,128,15,64,7,208
    db 47,48,6,224,15,64,7,208,11,178,61,128,2,190,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,176,12,112,8,176,12,112,8,176
    db 12,112,8,176,12,112,8,176,12,112,8,176,12,112,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,157,234,16,12,227,44,144,12,128,6,224
    db 12,112,4,240,12,128,6,224,12,211,44,160,12,157,235,16,12,112,0,0,12,112,0,0,12,112,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,236,64,4,246,19,128,10,160,0,0
    db 11,128,0,0,10,160,0,0,4,246,19,128,0,92,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,144,0,10,144,0,0,10,144,0
    db 0,10,144,0,0,10,144,0,0,10,144,0,0,10,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,32,2,243,12,128,8,192,7,208,13,96
    db 1,228,94,16,0,170,170,0,0,78,228,0,0,13,208,0,0,12,128,0,0,95,32,0,13,231,0,0,0,0,0,0
    db 0,0,0,0,0,11,128,0,0,11,128,0,0,11,128,0,0,11,128,0,5,223,251,48,30,123,154,192,94,11,131,241
    db 109,11,130,242,94,11,132,241,30,123,154,192,5,207,251,48,0,11,128,0,0,11,128,0,0,11,128,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,112,10,176,3,227,109,32,0,109,228,0
    db 0,30,192,0,0,171,215,0,6,209,62,64,62,64,7,226,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,78,0,14,64,78,0,14,64,78,0,14,64
    db 78,0,14,64,78,0,14,64,78,0,14,64,79,255,255,242,0,0,0,210,0,0,0,210,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,8,176,12,112,8,176,11,161,26,176
    db 4,223,237,176,0,0,8,176,0,0,8,176,0,0,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,77,10,129,241,77,10,129,241,77,10,129,241
    db 77,10,129,241,77,10,129,241,77,10,129,241,79,255,255,241,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,137,14,54,192,137,14,54,192,137,14,54,192
    db 137,14,54,192,137,14,54,192,137,14,54,192,143,255,255,233,0,0,0,91,0,0,0,91,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,224,0,0,4,224,0,0,4,224,0,0
    db 4,255,254,144,4,224,4,245,4,224,4,229,4,255,254,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,109,0,0,243,109,0,0,243,109,0,0,243
    db 111,253,112,243,109,22,242,243,109,5,242,243,111,253,112,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,0,0,12,112,0,0,12,112,0,0
    db 12,255,236,48,12,112,26,192,12,112,26,192,12,255,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,222,197,0,8,49,127,48,0,0,11,144
    db 0,239,255,176,0,0,10,144,8,49,110,48,4,222,197,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,139,6,237,80,139,47,102,226,139,110,0,229
    db 143,252,0,215,139,109,0,229,139,46,86,226,139,6,237,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,191,255,80,9,194,14,80,9,193,14,80
    db 2,191,255,80,0,154,14,80,3,226,14,80,11,128,14,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,171,63,48,0,0,0,0,12,255,255,208,12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,176
    db 12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,201,95,0,0,0,0,0,1,158,234,16,10,195,43,160,31,48,4,224
    db 63,255,255,241,31,32,0,0,11,179,21,160,1,157,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,169,0,0,9,144,0,0,0,0,0,3,190,233,0,9,97,61,112,0,0,8,176
    db 5,206,255,176,31,97,9,176,47,81,78,176,7,239,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,154,0,0,8,160,0,0,0,0,0,1,158,234,16,10,195,43,160,31,48,4,224
    db 63,255,255,241,31,32,0,0,11,179,21,160,1,157,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,169,0,0,9,144,0,0,0,0,0,7,255,160,0,0,9,160,0,0,9,160,0
    db 0,9,160,0,0,9,160,0,0,9,160,0,13,255,255,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,169,0,0,9,144,0,0,0,0,0,2,174,233,16,11,194,61,128,15,64,7,208
    db 47,48,6,224,15,64,7,208,11,178,61,128,2,190,233,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,169,0,0,9,144,0,0,0,0,0,12,112,8,176,12,112,8,176,12,112,8,176
    db 12,112,8,176,12,112,10,176,9,194,78,176,2,207,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,246,140,0,0,0,0,0,0,0,0,0,12,112,8,176,12,112,8,176,12,112,8,176
    db 12,112,8,176,12,112,10,176,9,194,78,176,2,207,185,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,189,45,0,2,180,233,0,0,0,0,0,12,156,252,32,12,211,45,128,12,128,9,160
    db 12,112,8,176,12,112,8,176,12,112,8,176,12,112,8,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,2,227,0,0,11,96,0,0,0,0,0,0,31,208,0,0,109,243,0,0,185,184,0,1,229,125,0,6,225,63,48
    db 10,176,13,128,30,255,255,192,95,32,5,242,172,0,0,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,1,212,0,0,9,128,0,0,0,0,0,12,255,255,208,12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,176
    db 12,144,0,0,12,144,0,0,12,144,0,0,12,255,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,2,227,0,0,11,96,0,0,0,0,0,11,255,255,144,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0
    db 0,12,144,0,0,12,144,0,0,12,144,0,11,255,255,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,2,227,0,0,11,96,0,0,0,0,0,2,190,233,0,11,194,61,128,31,80,8,208,79,32,5,241,79,32,5,241
    db 79,32,5,241,31,80,8,208,11,194,61,128,2,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,2,227,0,0,11,96,0,0,0,0,0,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224
    db 31,64,7,224,15,64,7,208,12,162,44,160,3,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,246,140,0,0,0,0,0,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224,31,64,7,224
    db 31,64,7,224,15,64,7,208,12,162,44,160,3,190,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,189,61,0,2,181,233,0,0,0,0,0,63,176,5,224,63,227,5,224,63,169,5,224,63,78,21,224,63,58,133,224
    db 63,52,213,224,63,48,202,224,63,48,111,224,63,48,14,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,192,0,0,9,192,0,0,0,0,0
    db 0,9,176,0,0,10,144,0,0,126,48,0,6,228,0,0,11,144,0,0,10,194,40,80,2,190,216,16,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,144,0,0,11,144,0,0,0,0,0
    db 0,10,128,0,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0,0,11,144,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,143,46,181,246,143,46,181,246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,16,18,34,40,177
    db 158,238,238,246,0,0,9,160,0,0,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,96,0,0,45,98,34,33
    db 159,238,238,231,28,112,0,0,1,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,64,0,0,28,112,0,0,170,0,0,6,193,0
    db 10,61,48,0,13,231,0,0,7,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,64,6,144,6,228,110,64,0,110,228,0
    db 0,110,228,0,6,228,110,64,11,64,7,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,110,212,0,1,210,76,0,1,210,76,0,0,126,212,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,28,160,0,1,205,218,0,0,58,115,0
    db 0,10,112,0,0,10,112,0,0,10,112,0,0,10,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,112,0,0,10,112,0,0,10,112,0
    db 0,10,112,0,0,58,115,0,1,205,218,0,0,28,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
font_ui:
    db 19,0,0,0,14,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,8,4,0,4,46,4,0,4,84,4,0,7,160,4,0,9,255,4,0,9,94,5,0,14
    db 227,5,0,9,66,6,0,4,104,6,0,5,161,6,0,5,218,6,0,7,38,7,0,9,133,7,0,4,171,7,0,6
    db 228,7,0,4,10,8,0,5,67,8,0,9,162,8,0,6,219,8,0,9,58,9,0,9,153,9,0,9,248,9,0,9
    db 87,10,0,9,182,10,0,8,2,11,0,9,97,11,0,9,192,11,0,4,230,11,0,4,12,12,0,9,107,12,0,9
    db 202,12,0,9,41,13,0,7,117,13,0,14,250,13,0,10,89,14,0,9,184,14,0,10,23,15,0,10,118,15,0,8
    db 194,15,0,8,14,16,0,10,109,16,0,10,204,16,0,4,242,16,0,8,62,17,0,9,157,17,0,8,233,17,0,13
    db 110,18,0,11,224,18,0,11,82,19,0,9,177,19,0,11,35,20,0,9,130,20,0,9,225,20,0,9,64,21,0,10
    db 159,21,0,10,254,21,0,14,131,22,0,10,226,22,0,10,65,23,0,9,160,23,0,5,217,23,0,5,18,24,0,5
    db 75,24,0,7,151,24,0,6,208,24,0,5,9,25,0,8,85,25,0,9,180,25,0,8,0,26,0,9,95,26,0,8
    db 171,26,0,5,228,26,0,9,67,27,0,8,143,27,0,3,181,27,0,3,219,27,0,8,39,28,0,3,77,28,0,12
    db 191,28,0,8,11,29,0,8,87,29,0,9,182,29,0,9,21,30,0,5,78,30,0,7,154,30,0,5,211,30,0,8
    db 31,31,0,8,107,31,0,11,221,31,0,8,41,32,0,8,117,32,0,8,193,32,0,6,250,32,0,5,51,33,0,6
    db 108,33,0,9,203,33,0,8,23,34,0,10,118,34,0,9,213,34,0,9,52,35,0,8,128,35,0,11,242,35,0,8
    db 62,36,0,13,195,36,0,9,34,37,0,11,148,37,0,11,6,38,0,9,101,38,0,10,196,38,0,13,73,39,0,10
    db 168,39,0,11,26,40,0,10,121,40,0,9,216,40,0,10,55,41,0,9,150,41,0,9,245,41,0,12,103,42,0,10
    db 198,42,0,10,37,43,0,10,132,43,0,13,9,44,0,14,142,44,0,11,0,45,0,12,114,45,0,9,209,45,0,10
    db 48,46,0,14,181,46,0,9,20,47,0,8,96,47,0,8,172,47,0,8,248,47,0,6,49,48,0,9,144,48,0,8
    db 220,48,0,11,78,49,0,7,154,49,0,8,230,49,0,8,50,50,0,8,126,50,0,8,202,50,0,11,60,51,0,8
    db 136,51,0,8,212,51,0,8,32,52,0,9,127,52,0,8,203,52,0,7,23,53,0,8,99,53,0,10,194,53,0,8
    db 14,54,0,8,90,54,0,8,166,54,0,12,24,55,0,12,138,55,0,9,233,55,0,10,72,56,0,8,148,56,0,8
    db 224,56,0,12,82,57,0,8,158,57,0,8,234,57,0,8,54,58,0,8,130,58,0,8,206,58,0,3,244,58,0,8
    db 64,59,0,8,140,59,0,8,216,59,0,8,36,60,0,10,131,60,0,8,207,60,0,4,245,60,0,11,103,61,0,10
    db 198,61,0,10,37,62,0,11,151,62,0,7,227,62,0,4,9,63,0,12,123,63,0,13,0,64,0,13,133,64,0,12
    db 247,64,0,9,86,65,0,6,143,65,0,12,1,66,0,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,176,11,176,11,176,10,176,10,160,10,160
    db 10,160,5,80,0,0,10,160,10,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 9,180,241,0,9,180,240,0,8,179,240,0,7,146,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,0,152,0,0,92,0,182,0,0,122,0,211,0,47,255
    db 255,255,144,1,198,20,209,16,0,211,5,192,0,1,241,8,160,0,191,255,255,254,0,6,176,12,80,0,8,144,14,48
    db 0,10,112,31,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,80,0,0,0,0,208,0,0,0,125,253,129,0,8,232,216,233,0,13,144,208,124,0,13,144,208
    db 0,0,7,251,209,0,0,0,91,254,145,0,0,0,215,219,0,0,0,208,79,32,47,80,208,95,32,11,231,216,235,0
    db 1,157,253,145,0,0,0,208,0,0,0,0,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,174,177,0,9,160,0,6,209,183,0,78,16
    db 0,7,160,137,1,214,0,0,5,211,199,8,176,0,0,0,157,161,62,32,0,0,0,0,0,199,0,0,0,0,0,7
    db 192,59,198,0,0,0,46,48,185,78,16,0,0,184,0,212,14,48,0,5,209,0,183,47,16,0,29,64,0,77,232,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,142,233,0,0,5,245,79,96,0,7,208,13,112
    db 0,4,243,127,48,0,0,190,246,0,0,1,191,160,0,0,12,213,246,45,32,79,48,126,127,0,79,16,10,251,0,29
    db 180,75,250,0,3,190,235,78,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,9,176,9,176,8,176,7,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,64,0,110,16,0,186,0,1,245,0,3,242,0
    db 6,224,0,8,192,0,7,208,0,5,224,0,3,242,0,0,215,0,0,125,0,0,30,64,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,59,16,0,14,112,0,9,208,0,3,242,0,0,245,0,0,215,0,0,185,0,0
    db 185,0,0,214,0,1,244,0,6,225,0,11,128,0,63,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,0,0,28,77,76,16,5,207,197,0,24,222,216,16,24,30,24,16,0,11,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,195,0,0,0,0,228,0,0,1,34,229,34,0,11,255,255,254,0,0,0,228
    db 0,0,0,0,228,0,0,0,0,179,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10
    db 192,12,128,14,64,29,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,15,255,248,3,51,49,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,144,11,176
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,144,0,13,96,0,47,16,0,108,0,0
    db 168,0,0,228,0,3,225,0,7,176,0,11,112,0,14,48,0,78,0,0,138,0,0,50,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,236,48,0,4,248,74,226,0,11,160,0,216
    db 0,14,80,0,140,0,47,48,0,109,0,63,32,0,94,0,47,48,0,109,0,15,80,0,140,0,11,160,0,216,0,4
    db 248,74,226,0,0,92,236,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,2,191,128,62,189,128,105,13,128,16,13,128,0,13,128,0,13,128,0,13,128
    db 0,13,128,0,13,128,0,13,128,0,13,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,141,235,48,0,7,230,91,209,0,12,128,1,229,0,3,16,1,245,0,0,0
    db 7,225,0,0,0,62,112,0,0,1,218,0,0,0,28,193,0,0,0,173,32,0,0,8,245,51,50,0,14,255,255,249
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,141,236,64,0,8,231,74,226,0,11,96,1,230,0,0,0,0,229,0,0,2,58
    db 209,0,0,11,254,80,0,0,0,22,246,0,0,0,0,172,0,28,64,0,171,0,11,215,72,246,0,1,158,236,96,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,46,208,0,0,0,158,208,0,0,3,232,208,0,0,11,151,208,0,0,94,23,208
    db 0,0,215,7,208,0,7,209,7,208,0,30,131,56,211,16,79,255,255,255,64,0,0,7,208,0,0,0,7,208,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,4,255,255,244,0,6,227,51,49,0,8,192,0,0,0,9,176,32,0,0,11,222,254,96,0
    db 6,131,41,243,0,0,0,0,216,0,0,0,0,170,0,11,112,0,216,0,8,231,74,226,0,0,141,236,48,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,75,237,96,0,3,233,73,245,0,9,160,0,169,0,14,80,16,0,0,31,93,254,112,0,63
    db 229,22,245,0,63,128,0,171,0,31,80,0,140,0,12,128,0,186,0,5,247,73,244,0,0,109,236,80,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,111,255,255,245,19,51,55,243,0,0,11,176,0,0,63,64,0,0,172,0,0,2,245,0,0,9,208,0,0,30
    db 96,0,0,141,0,0,1,231,0,0,7,225,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,236,64,0,7,230,58,226,0,11,144,0,230,0
    db 10,144,0,229,0,5,229,57,209,0,1,191,255,96,0,11,195,22,245,0,47,64,0,171,0,47,64,0,171,0,11,213
    db 55,246,0,2,157,237,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,235,48,0,9,230,74,225,0,15,96,0,215,0,63
    db 48,0,171,0,31,80,0,204,0,10,212,41,236,0,1,191,251,139,0,0,1,16,169,0,12,96,1,228,0,10,230,92
    db 192,0,1,158,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,48,12,208,4,64,0,0,0,0,0,0,9,144,11,176,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,209,7,176,0,0,0,0,0,0,2,32
    db 10,176,12,112,14,48,27,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,121,0,0,1,126,214,0,1,125,214,0,0,12,230,0,0,0,5,206
    db 113,0,0,0,5,206,130,0,0,0,5,202,0,0,0,0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,255,255,251,0,1,51,51,50,0,1,51,51
    db 50,0,8,255,255,251,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,6,146,0,0,0,3,206,146,0,0,0,4,190,146,0,0,0,4,222,16,0,0,108,231
    db 0,1,109,231,16,0,7,231,16,0,0,2,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,206,213,0,46,164,159,48,92,16,14
    db 112,0,0,31,80,0,1,205,16,0,29,210,0,0,95,32,0,0,89,0,0,0,0,0,0,0,124,16,0,0,125,16
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,156,238,183,0,0,0,94,165,34,92,194,0,2
    db 230,0,0,0,155,0,10,176,43,236,183,29,80,13,80,202,37,248,10,128,31,34,242,0,184,7,160,63,4,224,0,168
    db 7,160,31,34,242,0,184,9,144,13,80,201,38,251,45,80,10,176,44,235,92,232,0,2,230,0,0,0,0,0,0,94
    db 165,33,70,0,0,0,2,156,238,218,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,3,251,0,0,0,8,207,32,0,0,12,125,112,0,0,63,57,192,0,0,141,5
    db 242,0,0,217,0,231,0,3,246,51,188,0,8,255,255,255,32,13,144,0,14,128,63,64,0,10,192,142,0,0,5,243
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,12,255,254,161,0,12,163,53,218,0,12,144,0,142,0,12,144,0,125,0,12,146,37,215
    db 0,12,255,255,178,0,12,144,2,189,16,12,144,0,31,80,12,144,0,14,80,12,163,52,174,32,12,255,254,196,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,25,222,215,0,1,205,117,142,144,8,226,0,5,242,13,128,0,0,131,31,64,0,0,0
    db 63,48,0,0,0,31,64,0,0,0,13,112,0,0,131,8,226,0,5,243,1,221,117,142,144,0,25,222,215,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,12,255,253,145,0,12,163,70,221,32,12,144,0,29,144,12,144,0,6,240,12,144,0,3,243,12
    db 144,0,1,244,12,144,0,3,243,12,144,0,6,240,12,144,0,29,144,12,163,54,221,32,12,255,253,145,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,12,255,255,247,12,163,51,50,12,144,0,0,12,144,0,0,12,163,51,48,12,255,255,242,12,144,0,0,12,144
    db 0,0,12,144,0,0,12,163,51,50,12,255,255,248,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,246,12,163,51,49,12,144,0,0,12,144,0,0,12,144
    db 0,0,12,255,255,224,12,163,51,48,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222
    db 198,0,1,206,117,159,128,7,226,0,7,242,13,144,0,1,181,15,80,0,0,0,47,48,1,51,50,47,48,6,255,249
    db 14,96,0,0,216,9,209,0,4,244,1,221,101,126,160,0,25,222,216,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,3
    db 243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,12,163,51,53,243,12,255,255,255,243,12,144,0,3,243,12
    db 144,0,3,243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,12,144,12,144,12,144,12,144,12,144,12,144
    db 12,144,12,144,12,144,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 9,192,0,0,9,192,0,0,9,192,0,0,9,192,0,0,9,192,0,0,9,192,0,0,9,192,92,0,9,192,79,48
    db 12,160,29,180,111,96,3,206,216,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,62,144,12,144,2,219,0,12,144,28,193,0,12,144,190,32
    db 0,12,136,243,0,0,12,206,246,0,0,12,245,142,32,0,12,144,29,176,0,12,144,4,246,0,12,144,0,158,32,12
    db 144,0,29,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0
    db 0,12,144,0,0,12,144,0,0,12,144,0,0,12,163,51,49,12,255,255,244,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,244
    db 0,0,10,247,0,12,250,0,0,30,247,0,12,190,16,0,109,215,0,12,142,96,0,185,215,0,12,138,176,2,244,215
    db 0,12,133,242,7,208,215,0,12,128,231,12,128,215,0,12,128,156,47,48,215,0,12,128,63,140,0,215,0,12,128,12
    db 231,0,215,0,12,128,7,242,0,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 12,226,0,0,246,0,12,250,0,0,246,0,12,175,64,0,246,0,12,138,192,0,246,0,12,146,231,0,246,0,12,144
    db 142,16,246,0,12,144,29,144,246,0,12,144,5,243,246,0,12,144,0,187,230,0,12,144,0,63,246,0,12,144,0,9
    db 246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222,198,0,0,1,205,117,143,144,0,8,226
    db 0,5,243,0,13,128,0,0,201,0,31,64,0,0,155,0,63,48,0,0,141,0,31,64,0,0,155,0,13,128,0,0
    db 201,0,8,226,0,5,243,0,1,205,117,143,144,0,0,25,222,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,12,255,253,145,0,12,163,54,218,0,12,144,0,95,16,12,144,0,63,48,12,144,0,95,16,12,163,54,218,0,12
    db 255,253,145,0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,25,222,198,0,0,1,205,117,143,144,0,8,226,0,5,243,0,13,128,0,0,201,0,31,64,0,0,155
    db 0,63,48,0,0,141,0,31,64,0,0,155,0,13,128,7,64,200,0,8,226,7,231,244,0,1,205,117,223,128,0,0
    db 25,222,206,112,0,0,0,0,4,194,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,253,145,0,12,163,54,218,0,12,144,0,95
    db 16,12,144,0,63,48,12,144,0,94,0,12,163,53,219,0,12,255,255,161,0,12,144,12,176,0,12,144,5,244,0,12
    db 144,0,188,0,12,144,0,79,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,125,237,129,0,7,231,71,233,0,13,128,0,92,0
    db 13,144,0,0,0,7,250,64,0,0,0,109,254,129,0,0,0,57,234,0,0,0,0,95,16,45,64,0,79,32,12,197
    db 20,204,0,2,191,255,178,0,0,1,49,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,111,255,255,255,96,19,53,245,51,16,0,3,243,0,0,0
    db 3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243
    db 0,0,0,3,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,12,144
    db 0,3,244,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,11,160,0,4,243,9,209,0,9,224,2,236,101,159
    db 112,0,42,238,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,0,0,4,243,63,64,0,9,192,13,144,0,14,128,8,208,0
    db 79,48,3,244,0,156,0,0,201,0,216,0,0,141,3,242,0,0,47,56,192,0,0,12,124,112,0,0,7,207,32,0
    db 0,2,252,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,156,0,0,236,0,1,245,95,16,4,255,16,5
    db 241,31,80,8,190,64,8,192,12,128,11,140,128,12,144,9,176,14,88,176,30,80,5,224,63,21,224,79,16,1,244,124
    db 1,244,140,0,0,199,169,0,199,185,0,0,138,213,0,138,213,0,0,93,241,0,94,241,0,0,31,192,0,31,192,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,112,0,13,160,7,226,0,142,32,0,203,3,246
    db 0,0,63,91,176,0,0,9,238,32,0,0,3,251,0,0,0,11,207,80,0,0,110,41,209,0,2,232,1,233,0,10
    db 208,0,95,64,95,64,0,11,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,111,48,0,10,208,12,176,0,79,80,4,245,0,203,0
    db 0,173,6,243,0,0,46,109,144,0,0,8,238,16,0,0,1,232,0,0,0,0,231,0,0,0,0,231,0,0,0,0
    db 231,0,0,0,0,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,254,0,19,51,51,217,0,0,0,8,225,0,0
    db 0,63,96,0,0,0,187,0,0,0,6,243,0,0,0,29,128,0,0,0,157,16,0,0,3,245,0,0,0,12,179,51
    db 51,0,63,255,255,255,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,8,255,80,8,193,0,8,176,0,8,176,0,8,176,0,8,176,0,8,176,0,8,176
    db 0,8,176,0,8,176,0,8,176,0,8,177,0,8,255,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,153,0,0,93,0,0,31,32,0,12,112,0,8,160,0,4,224,0,0,227,0,0,184,0,0,123,0,0,63,16
    db 0,13,80,0,10,144,0,2,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,249,0,1,169
    db 0,0,169,0,0,169,0,0,169,0,0,169,0,0,169,0,0,169,0,0,169,0,0,169,0,0,169,0,1,169,0,63
    db 249,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,175,64,0,3
    db 234,176,0,10,162,227,0,47,48,154,0,37,0,37,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,255,255,255,51,51,51,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,160,0,2,226,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,3,190,234,16,29,180,93,128,2,16,9,176,1,89,191,192,45,216,105,192,110,0,9,192,79,97,94,192,8,255,184
    db 192,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,80,0,0,0,14,80,0,0,0,14,80,0,0,0,14,107,237,80,0,14,231,56,243,0,14,144,0
    db 186,0,14,96,0,140,0,14,96,0,140,0,14,160,0,186,0,14,231,56,244,0,14,107,237,80,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,141,235,48,9,213,75,225,31,80,1,97,79,16,0,0,79,16,0,0
    db 31,80,1,113,9,213,75,225,0,141,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,200,0,0,0,0,200,0,0,0,0,200,0,1,158
    db 231,200,0,10,213,75,232,0,47,80,1,232,0,79,0,0,200,0,79,16,0,200,0,47,80,2,232,0,10,213,75,232
    db 0,1,174,231,184,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,235,48,10,196,58,209,47
    db 32,1,229,95,255,255,248,79,33,17,17,30,80,0,97,8,213,58,242,0,141,236,64,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,158,192,5,246,48,6,208,0,223,255,160
    db 23,209,16,6,208,0,6,208,0,6,208,0,6,208,0,6,208,0,6,208,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,1,158,231,184,0,10,213,75,232,0,47,80,1,232,0,79,16,0,200,0,79,0,0,200,0,47,64,1,232,0
    db 10,213,59,232,0,1,174,232,200,0,0,0,0,200,0,10,163,56,244,0,2,190,236,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,0,0,14,80,0,0,14,80,0,0,14,107,237,64,14
    db 213,59,208,14,128,4,242,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,28,80,26,64,0,0,14,80,14,80,14
    db 80,14,80,14,80,14,80,14,80,14,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,28,80,26,64,0
    db 0,14,80,14,80,14,80,14,80,14,80,14,80,14,80,14,80,14,80,111,48,232,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,80,0,0,14,80,0,0,14,80,0,0,14,80,27,193,14,80,188,16,14,90,210,0,14
    db 207,80,0,14,203,209,0,14,82,234,0,14,80,79,96,14,80,8,227,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,14,80,14,80,14,80,14,80,14,80,14,80,14,80,14,80,14
    db 80,14,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,107,233,26,237,80,14,198,110,201,75,224,14,112,9
    db 208,3,243,14,80,8,192,1,243,14,80,8,192,1,243,14,80,8,192,1,243,14,80,8,192,1,243,14,80,8,192,1
    db 243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,91,237,64,14,197,59,208,14
    db 128,4,242,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,141,235,48,9,213,74,225,31,80,0,215,79,16,0,170,79,16,0,170,31,80,0,215,9,213,58,225,0
    db 141,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,107,237,80,0,14,231,56,243,0,14
    db 144,0,186,0,14,96,0,140,0,14,96,0,140,0,14,160,0,186,0,14,231,56,244,0,14,107,237,80,0,14,80,0
    db 0,0,14,80,0,0,0,10,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,158,231,184,0,10,213,75,232,0,47,80
    db 1,232,0,79,0,0,200,0,79,16,0,200,0,47,80,2,232,0,10,213,75,232,0,1,174,231,200,0,0,0,0,200
    db 0,0,0,0,200,0,0,0,0,150,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,108,224,14,214,64,14,112,0,14,80,0,14,80,0,14,80,0,14,80,0,14,80,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,3,190,232,0,13,179,94,80,15,112,1,0,9,252,131,0,0,72,207,80,4,0,12,160,47,147
    db 94,128,5,223,233,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,10,112,0,11,144,0,223,255,32,28,145,0,11,144,0,11,144,0,11,144,0,11,144,0,10,195
    db 0,3,223,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,13
    db 128,4,244,10,212,74,244,2,190,196,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,0,1,245,47,64,6,225,11
    db 144,11,144,6,224,47,64,1,228,125,0,0,169,184,0,0,93,227,0,0,14,192,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,126,0,31,144,8,208,47,48,110,192,12,144,13,112,152,241,31
    db 64,9,176,212,197,94,0,4,226,224,153,155,0,0,232,176,92,198,0,0,174,112,30,226,0,0,111,48,11,192,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,96,10,192,7,225,94,48,0,201,200
    db 0,0,63,192,0,0,94,209,0,1,215,201,0,9,192,79,64,79,64,9,209,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,141,0,1,245,47,64,6,225,12,144,11,144,6,224,47,64,1,228,125,0,0,169,184,0,0,93,227,0,0,14,192
    db 0,0,13,112,0,3,142,16,0,14,197,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,255,176,3,51,95,96,0,0,202,0,0,9,209,0,0,95,64
    db 0,2,232,0,0,11,211,51,32,63,255,255,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,6,162,0,95,113,0,139,0,0,154,0,0,154,0,3,216,0,15,177,0,7
    db 230,0,0,170,0,0,154,0,0,139,0,0,110,48,0,10,227,0,0,0,0,0,0,0,0,0,3,160,0,4,208,0
    db 4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208,0,4,208
    db 0,4,208,0,4,208,0,4,208,0,4,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,144,0,4
    db 229,0,0,184,0,0,168,0,0,169,0,0,141,80,0,27,240,0,125,64,0,169,0,0,168,0,0,184,0,3,229,0
    db 62,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,0,0,0,4,239,144,45,16,11,165
    db 249,142,0,10,80,93,230,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,5,80,0,0,207,250,0,3,255,255,16,2,255,254,0,0,126,213,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,3,251,0,0,0,8,207,32,0,0,12,125,112,0,0,63,57,192,0,0,141,5,242,0,0
    db 217,0,231,0,3,246,51,188,0,8,255,255,255,32,13,144,0,14,128,63,64,0,10,192,142,0,0,5,243,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,12,255,255,246,0,12,163,51,49,0,12,144,0,0,0,12,144,0,0,0,12,147,49,0,0,12,255
    db 255,195,0,12,144,4,189,0,12,144,0,47,48,12,144,0,63,48,12,147,52,204,0,12,255,254,162,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,12,255,254,161,0,12,163,53,218,0,12,144,0,142,0,12,144,0,125,0,12,146,37,215,0,12,255,255
    db 178,0,12,144,2,189,16,12,144,0,31,80,12,144,0,14,80,12,163,52,174,32,12,255,254,196,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 12,255,255,247,12,163,51,49,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0,12,144,0,0
    db 12,144,0,0,12,144,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,250,0,0,13,147,51,186,0,0,14
    db 96,0,170,0,0,15,80,0,170,0,0,31,64,0,170,0,0,63,32,0,170,0,0,94,0,0,170,0,0,141,0,0
    db 170,0,0,202,0,0,170,0,22,246,51,51,187,32,111,255,255,255,255,192,110,0,0,0,8,192,110,0,0,0,8,192
    db 19,0,0,0,2,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255
    db 255,247,12,163,51,50,12,144,0,0,12,144,0,0,12,163,51,48,12,255,255,242,12,144,0,0,12,144,0,0,12,144
    db 0,0,12,163,51,50,12,255,255,248,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,128,0,230,0,46,128,9,226,0,230,0,158
    db 16,1,233,0,230,2,247,0,0,126,32,230,10,208,0,0,13,144,230,63,80,0,0,8,255,255,254,0,0,0,46,131
    db 232,62,112,0,0,157,0,230,7,226,0,3,245,0,230,0,218,0,12,176,0,230,0,95,48,111,48,0,230,0,12,192
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,236,64,0,8,231,74,226,0,11,96,1,230
    db 0,0,0,0,229,0,0,2,58,209,0,0,11,254,80,0,0,0,22,246,0,0,0,0,172,0,28,64,0,171,0,11
    db 215,72,246,0,1,158,236,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,9,246,0,12,144,0,63,246,0
    db 12,144,0,187,230,0,12,144,5,243,246,0,12,144,29,160,246,0,12,144,142,32,246,0,12,146,231,0,246,0,12,138
    db 208,0,246,0,12,175,80,0,246,0,12,250,0,0,246,0,12,226,0,0,246,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,130,211,0,0,0,2,189,112,0,0
    db 0,0,0,0,0,0,12,144,0,9,246,0,12,144,0,63,246,0,12,144,0,187,230,0,12,144,5,243,246,0,12,144
    db 29,160,246,0,12,144,142,32,246,0,12,146,231,0,246,0,12,138,208,0,246,0,12,175,80,0,246,0,12,250,0,0
    db 246,0,12,226,0,0,246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,62,128,12,144,0,204,0,12
    db 144,7,227,0,12,144,63,96,0,12,147,203,0,0,12,255,244,0,0,12,144,189,16,0,12,144,46,144,0,12,144,5
    db 245,0,12,144,0,174,32,12,144,0,29,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,255,255,244,0,63,67,52,244,0,79
    db 16,1,244,0,110,0,1,244,0,125,0,1,244,0,140,0,1,244,0,155,0,1,244,0,170,0,1,244,0,200,0,1
    db 244,22,244,0,1,244,110,144,0,1,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,244,0,0,10,247,0
    db 12,250,0,0,30,247,0,12,190,16,0,109,215,0,12,142,96,0,185,215,0,12,138,176,2,244,215,0,12,133,242,7
    db 208,215,0,12,128,231,12,128,215,0,12,128,156,47,48,215,0,12,128,63,140,0,215,0,12,128,12,231,0,215,0,12
    db 128,7,242,0,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,3,243,12,144,0
    db 3,243,12,144,0,3,243,12,144,0,3,243,12,163,51,53,243,12,255,255,255,243,12,144,0,3,243,12,144,0,3,243
    db 12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222,198,0,0
    db 1,205,117,143,144,0,8,226,0,5,243,0,13,128,0,0,201,0,31,64,0,0,155,0,63,48,0,0,141,0,31,64
    db 0,0,155,0,13,128,0,0,201,0,8,226,0,5,243,0,1,205,117,143,144,0,0,25,222,198,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,12,255,255,255,243,12,163,51,53,243,12,144,0,3,243,12,144,0,3,243,12,144,0
    db 3,243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243,12,144,0,3,243
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,12,255,253,145,0,12,163,54,218,0,12,144,0,95,16,12,144,0,63,48,12,144,0,95
    db 16,12,163,54,218,0,12,255,253,145,0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,25,222,215,0,1,205,117,142,144,8,226,0,5,242,13,128,0,0,131,31,64,0,0,0
    db 63,48,0,0,0,31,64,0,0,0,13,112,0,0,131,8,226,0,5,243,1,221,117,142,144,0,25,222,215,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,111,255,255,255,96,19,53,245,51,16,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0
    db 3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,3,243,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,142,16,0,63,80,47,96,0,141,0,10,192,0,216,0,4,243,4,242,0,0,201,10,192,0,0,110
    db 14,96,0,0,30,142,16,0,0,9,250,0,0,0,3,244,0,0,1,58,192,0,0,5,253,48,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,13,112,0,0,0,6,158,200,48,0,1,206,190,204,247,0,10,210,13,112,111,64,15
    db 80,13,112,11,144,63,48,13,112,9,176,31,64,13,112,10,160,13,144,13,112,46,112,4,250,93,150,220,0,0,75,239
    db 253,145,0,0,0,13,128,0,0,0,0,6,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,112,0,13,160,7,226,0,142,32
    db 0,203,3,246,0,0,63,91,176,0,0,9,238,32,0,0,3,251,0,0,0,11,207,80,0,0,110,41,209,0,2,232
    db 1,233,0,10,208,0,95,64,95,64,0,11,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,7,208,12,144,0,7,208,12
    db 144,0,7,208,12,144,0,7,208,12,144,0,7,208,12,144,0,7,208,12,144,0,7,208,12,144,0,7,208,12,144,0
    db 7,208,12,163,51,56,226,12,255,255,255,253,0,0,0,0,109,0,0,0,0,109,0,0,0,0,35,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,96,0,12,144,14,96,0,12,144,14,96
    db 0,12,144,14,112,0,12,144,12,144,0,12,144,8,247,53,175,144,0,141,253,173,144,0,0,0,12,144,0,0,0,12
    db 144,0,0,0,12,144,0,0,0,12,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,230,0,63,48
    db 12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230
    db 0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,163,51,231,51,95,48,12
    db 255,255,255,255,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144
    db 0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63
    db 48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,144,0,230,0,63,48,12,163,51
    db 231,51,95,81,12,255,255,255,255,255,243,0,0,0,0,0,1,243,0,0,0,0,0,1,243,0,0,0,0,0,0,65
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 111,255,208,0,0,0,18,40,208,0,0,0,0,7,208,0,0,0,0,7,208,0,0,0,0,7,255,254,197,0,0,7
    db 211,52,159,64,0,7,208,0,12,144,0,7,208,0,10,176,0,7,208,0,12,144,0,7,211,51,159,48,0,7,255,254
    db 197,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,0,3,243,12,144,0,0,3,243,12,144
    db 0,0,3,243,12,144,0,0,3,243,12,163,49,0,3,243,12,255,255,212,3,243,12,144,2,174,35,243,12,144,0,15
    db 83,243,12,144,0,31,83,243,12,147,52,189,19,243,12,255,254,179,3,243,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,12,144,0,0,0,12,163,49,0,0,12,255,255,212,0,12
    db 144,2,174,32,12,144,0,15,80,12,144,0,31,80,12,147,52,189,16,12,255,254,179,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,92,237,162,0,6,249,86,206,48,14,144,0,12,176,41,32,0,5,242,0,0,51,51,244,0,3,255,255,246,0,0
    db 0,1,245,40,32,0,4,242,14,128,0,11,176,6,249,86,206,48,0,92,237,162,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,12,144,0,75,237,162,0,12,144,6,250,86,206,48,12,144,46,128,0,28,160,12,144,110,16,0,5
    db 241,12,146,171,0,0,1,244,12,255,250,0,0,0,230,12,144,155,0,0,1,244,12,144,110,16,0,5,241,12,144,46
    db 128,0,28,160,12,144,6,250,86,206,48,12,144,0,76,237,162,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,1,157,255,252,0,10,214,51,172,0,31,80,0,156,0,63,48,0,156,0,14,80,0,156,0,11,213,51
    db 172,0,1,175,255,252,0,0,188,0,156,0,4,245,0,156,0,12,176,0,156,0,111,64,0,156,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,190,234,16,29,180,93,128,2,16,9,176,1,89,191,192,45,216,105,192
    db 110,0,9,192,79,97,94,192,8,255,184,192,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,48,0,124,255,227,6,231,67,16,13,80,0,0,46,92,236,48,78,197,58,225
    db 95,64,1,230,95,0,0,185,63,16,0,200,30,80,1,230,9,213,59,208,0,157,235,32,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,236,48,14,99,75,192,14,64,42,176,14,255,253,32,14,81,41,208,14,64,3,243,14,98,57,241
    db 14,255,253,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,14,255,253,14,115,50,14,80,0,14,80,0,14,80,0,14,80,0,14,80,0,14
    db 80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,243,0,0,231,52,243,0,0,244,2,243,0,2,242
    db 2,243,0,4,240,2,243,0,7,192,2,243,0,46,147,52,244,16,207,255,255,255,80,200,0,0,14,80,200,0,0,14
    db 80,50,0,0,4,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,1,157,235,48,10,196,58,209,47,32,1,229,95,255,255,248,79,33,17,17,30,80,0,97
    db 8,213,58,242,0,141,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 62,96,14,80,46,112,5,228,14,81,217,0,0,110,62,91,176,0,0,11,255,255,16,0,0,79,110,125,128,0,1,217
    db 14,84,244,0,9,209,14,80,157,16,79,80,14,80,29,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,5,222,196,0,30,114,157,0,0,1,156,0,0,78,210,0,0,2,173,0,19,0,63,64,63,114
    db 159,32,7,223,213,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,5,244,14,80,29,244,14,80,156,244,14,84
    db 227,244,14,92,113,244,14,188,1,244,14,244,1,244,14,144,1,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,16,1,0,0,182,62,16,0,59,197,0,0,0,0,0,14,80
    db 5,244,14,80,29,244,14,80,156,244,14,84,227,244,14,92,113,244,14,188,1,244,14,244,1,244,14,144,1,244,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,14,80,9,226,14,80,95,80,14,82,233,0,14,123,209,0,14,255,144,0,14,85
    db 246,0,14,80,126,64,14,80,10,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,255,255,240,5,243,54,240,5,224
    db 5,240,6,208,5,240,7,208,5,240,8,176,5,240,61,128,5,240,219,16,5,240,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,243,0,7,251,0,14,232,0,12,219,0,14,158,0,62,155,0
    db 14,110,80,155,155,0,14,89,176,229,155,0,14,83,229,224,155,0,14,80,205,128,155,0,14,80,111,32,155,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,1,244,14,80,1,244,14,80,1,244
    db 14,115,51,244,14,255,255,244,14,80,1,244,14,80,1,244,14,80,1,244,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,141,235,48,9,213,74,225,31,80,0,215,79,16,0,170,79,16,0,170,31,80,0,215,9,213,58,225,0,141,235,48
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,14,255,255,243,14,115,52,243,14,96,2,243,14,96,2,243,14,96,2,243
    db 14,96,2,243,14,96,2,243,14,96,2,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,107
    db 237,80,0,14,231,56,243,0,14,144,0,186,0,14,96,0,140,0,14,96,0,140,0,14,160,0,186,0,14,231,56,244
    db 0,14,107,237,80,0,14,80,0,0,0,14,80,0,0,0,10,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,235,48,9,213,75,225,31
    db 80,1,97,79,16,0,0,79,16,0,0,31,80,1,113,9,213,75,225,0,141,235,48,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,223,255,255,96,34,126,34,16,0,109,0,0,0,109,0,0,0,109,0,0,0,109,0,0,0,109,0,0,0
    db 109,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,0,1,245,47,64,6,225,12,144,11,144,6,224,47,64,1
    db 228,125,0,0,169,184,0,0,93,227,0,0,14,192,0,0,13,112,0,3,142,16,0,14,197,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,199,0,0,0,0,199,0,0,0,0,199,0
    db 0,0,141,255,197,0,9,213,217,143,64,31,80,199,10,176,79,16,199,6,208,79,16,199,6,208,31,80,199,10,176,9
    db 213,217,143,64,0,141,255,197,0,0,0,199,0,0,0,0,199,0,0,0,0,100,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,62,96,10,192,7,225
    db 94,48,0,201,200,0,0,63,192,0,0,94,209,0,1,215,201,0,9,192,79,64,79,64,9,209,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,14,80,2,243,14,80,2,243,14,80,2,243,14,80,2,243,14,80,2,243,14,80,2,243,14,115
    db 52,245,14,255,255,255,0,0,0,47,0,0,0,47,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,4,240,14,80,4,240,14,96,4,240,11,195
    db 22,240,3,207,255,240,0,2,36,240,0,0,4,240,0,0,4,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,14,80,13,96,13,112,14,80,13,96,13,112,14,80,13,96,13,112,14,80,13,96
    db 13,112,14,80,13,96,13,112,14,80,13,96,13,112,14,115,61,115,61,112,14,255,255,255,255,112,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,80,13,96
    db 13,112,14,80,13,96,13,112,14,80,13,96,13,112,14,80,13,96,13,112,14,80,13,96,13,112,14,80,13,96,13,112
    db 14,115,61,115,61,129,14,255,255,255,255,247,0,0,0,0,0,215,0,0,0,0,0,215,0,0,0,0,0,50,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,223,248,0,0,0,0,200,0,0,0,0,201,50,0,0,0,207,255,231,0,0,200,1,143
    db 32,0,200,0,47,80,0,201,51,174,32,0,207,255,213,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,80,0,0,244,14,80,0,0,244,14,115,32,0,244,14,255,254,80,244,14,80,42,224,244
    db 14,80,5,242,244,14,115,75,208,244,14,255,252,48,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 14,80,0,0,14,80,0,0,14,115,32,0,14,255,254,80,14,80,42,224,14,80,5,241,14,115,75,208,14,255,252,48
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,206,216,0,46,148,93,144,36,0,6,241,0,127,255,243,0,18,37,242
    db 59,32,8,224,30,180,110,112,3,206,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,64,5,206,215,0,14,64,95,115,110,112,14,64,186,0,7,208,14,255,247,0,4,241,14,82,200,0
    db 5,224,14,64,156,0,9,192,14,64,63,147,127,80,14,64,4,206,214,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,6,223,255,176,63,130,42,176,95,0,9,176,47,113,25,176,5,239,255,176,4,244
    db 9,176,12,160,9,176,126,32,9,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,185
    db 12,112,0,101,7,64,0,0,0,0,12,255,255,247,12,163,51,50,12,144,0,0,12,144,0,0,12,163,51,48,12,255
    db 255,242,12,144,0,0,12,144,0,0,12,144,0,0,12,163,51,50,12,255,255,248,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,131,24,32,1,213,46,64,0,0
    db 0,0,1,157,235,48,10,196,58,209,47,32,1,229,95,255,255,248,79,33,17,17,30,80,0,97,8,213,58,242,0,141
    db 236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,1,213,0,0,8,176,0,0,2,16,0,3,190,234,16,29,180,93,128,2,16,9,176,1,89,191,192,45,216
    db 105,192,110,0,9,192,79,97,94,192,8,255,184,192,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,169,0,0,3,226,0,0,1,32,0,1,157,235,48,10,196
    db 58,209,47,32,1,229,95,255,255,248,79,33,17,17,30,80,0,97,8,213,58,242,0,141,236,64,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,240,10,128,0,0,14,80,14,80,14,80
    db 14,80,14,80,14,80,14,80,14,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,154,0,0,2,226,0,0,1,32,0,0,141,235,48,9,213,74,225,31,80,0,215,79,16,0,170,79,16,0,170
    db 31,80,0,215,9,213,58,225,0,141,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,186,0,0,3,209,0,0,0,0,0,14,80,1,244,14,80,1,244
    db 14,80,1,244,14,80,1,244,14,80,1,244,13,128,4,244,10,212,74,244,2,190,196,244,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,214,46,64,0,131,25,32
    db 0,0,0,0,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,13,128,4,244,10,212,74,244
    db 2,190,196,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,108,88,16,0,132,186,0,0,0,0,0,14,91,237,64,14,197,59,208,14,128,4,242,14,80,1,244
    db 14,80,1,244,14,80,1,244,14,80,1,244,14,80,1,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,30,80,0,0,0,138,0,0,0,0,0,0,0,0,3,251,0,0,0,8,207,32,0,0,12,125
    db 112,0,0,63,57,192,0,0,141,5,242,0,0,217,0,231,0,3,246,51,188,0,8,255,255,255,32,13,144,0,14,128
    db 63,64,0,10,192,142,0,0,5,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,141,0,0,1,212,0,0,0,0,0,12,255,255,247,12,163,51,50,12,144,0,0,12,144,0,0,12
    db 163,51,48,12,255,255,242,12,144,0,0,12,144,0,0,12,144,0,0,12,163,51,50,12,255,255,248,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,230,7,176,0,0,12,144,12,144,12,144,12,144,12,144,12
    db 144,12,144,12,144,12,144,12,144,12,144,0,0,0,0,0,0,0,0,0,0,0,0,7,176,0,0,0,0,13,80,0
    db 0,0,0,18,0,0,0,0,25,222,198,0,0,1,205,117,143,144,0,8,226,0,5,243,0,13,128,0,0,201,0,31
    db 64,0,0,155,0,63,48,0,0,141,0,31,64,0,0,155,0,13,128,0,0,201,0,8,226,0,5,243,0,1,205,117
    db 143,144,0,0,25,222,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,10,176,0,0,0,46,32,0,0,0,0,0,0,12,144,0,3,244,12,144,0,3,244
    db 12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,11,160,0,4,243,9,209
    db 0,9,224,2,236,101,159,112,0,42,238,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,13,113,213,0,0,8,64,131,0,0,0,0,0,0,12,144,0,3,244,12,144,0,3,244,12
    db 144,0,3,244,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,12,144,0,3,244,11,160,0,4,243,9,209,0
    db 9,224,2,236,101,159,112,0,42,238,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,5,199,114,0,0,0,6,74,176,0,0,0,0,0,0,0,0,12,226,0,0,246,0,12,250,0
    db 0,246,0,12,175,64,0,246,0,12,138,192,0,246,0,12,146,231,0,246,0,12,144,142,16,246,0,12,144,29,144,246
    db 0,12,144,5,243,246,0,12,144,0,187,230,0,12,144,0,63,246,0,12,144,0,9,246,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,144,0,0,11,144,0,0,0,0,0,0,8,96,0,0
    db 13,112,0,1,190,32,0,11,211,0,0,63,48,0,0,95,32,11,112,30,163,143,64,4,206,214,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,176,9,144,0,0,6,112,10,160,10,160,10,176,10,176,11
    db 176,11,176,4,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,144,8,144,8,160,11,176,10,176,10,192,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,26,32,0,0,0,0,0,11,210,0,0,0,0,0,0,173,32,0,0,0,0,0,8,210,0,5,255,255,255,254,235
    db 0,1,51,51,51,55,211,0,0,0,0,0,142,48,0,0,0,0,9,227,0,0,0,0,0,44,48,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,9,80,0,0,0,0,0,158,48,0,0,0,0,9,211,0,0,0,0,0,156,32,0,0,0,0,6
    db 253,255,255,255,250,0,1,186,51,51,51,50,0,0,11,194,0,0,0,0,0,0,189,32,0,0,0,0,0,10,80,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,5,192,0,0,0,0,94,112,0,16,0,5,231,0,4,211,0,94,112
    db 0,0,174,53,231,0,0,0,10,238,112,0,0,0,0,151,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,177,0,121,0,2
    db 219,23,228,0,0,45,222,64,0,0,8,252,16,0,0,126,93,177,0,5,228,2,218,0,1,48,0,35,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4
    db 222,128,14,132,229,47,16,167,14,115,229,4,222,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,10,96,0,0,0,0,159,229,0,0,0,9,219,142,64,0,0,142,59,119,227,0,6,228,12,112,158,32,2
    db 80,12,112,6,0,0,0,12,112,0,0,0,0,12,112,0,0,0,0,12,112,0,0,0,0,12,112,0,0,0,0,12
    db 112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,112,0,0,0,0,12,112,0,0,0
    db 0,12,112,0,0,0,0,12,112,0,0,0,0,12,112,0,0,2,64,12,112,5,0,6,228,12,112,142,32,0,142,43
    db 118,228,0,0,9,203,142,64,0,0,0,175,229,0,0,0,0,10,96,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
font_uib:
    db 19,0,0,0,14,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,8,4,0,4,46,4,0,4,84,4,0,7,160,4,0,9,255,4,0,9,94,5,0,14
    db 227,5,0,9,66,6,0,5,123,6,0,5,180,6,0,5,237,6,0,8,57,7,0,9,152,7,0,4,190,7,0,7
    db 10,8,0,4,48,8,0,5,105,8,0,9,200,8,0,6,1,9,0,9,96,9,0,9,191,9,0,9,30,10,0,9
    db 125,10,0,9,220,10,0,8,40,11,0,9,135,11,0,9,230,11,0,4,12,12,0,5,69,12,0,9,164,12,0,9
    db 3,13,0,9,98,13,0,8,174,13,0,14,51,14,0,10,146,14,0,9,241,14,0,10,80,15,0,10,175,15,0,8
    db 251,15,0,8,71,16,0,10,166,16,0,10,5,17,0,4,43,17,0,8,119,17,0,10,214,17,0,8,34,18,0,13
    db 167,18,0,11,25,19,0,11,139,19,0,9,234,19,0,11,92,20,0,9,187,20,0,9,26,21,0,9,121,21,0,10
    db 216,21,0,10,55,22,0,14,188,22,0,10,27,23,0,10,122,23,0,9,217,23,0,5,18,24,0,5,75,24,0,5
    db 132,24,0,7,208,24,0,7,28,25,0,5,85,25,0,8,161,25,0,9,0,26,0,8,76,26,0,9,171,26,0,8
    db 247,26,0,5,48,27,0,9,143,27,0,9,238,27,0,4,20,28,0,4,58,28,0,8,134,28,0,4,172,28,0,13
    db 49,29,0,9,144,29,0,9,239,29,0,9,78,30,0,9,173,30,0,6,230,30,0,8,50,31,0,5,107,31,0,9
    db 202,31,0,8,22,32,0,12,136,32,0,8,212,32,0,8,32,33,0,8,108,33,0,6,165,33,0,5,222,33,0,6
    db 23,34,0,9,118,34,0,7,194,34,0,10,33,35,0,9,128,35,0,9,223,35,0,8,43,36,0,12,157,36,0,8
    db 233,36,0,14,110,37,0,9,205,37,0,11,63,38,0,11,177,38,0,10,16,39,0,10,111,39,0,13,244,39,0,10
    db 83,40,0,11,197,40,0,10,36,41,0,9,131,41,0,10,226,41,0,9,65,42,0,9,160,42,0,12,18,43,0,10
    db 113,43,0,11,227,43,0,10,66,44,0,14,199,44,0,14,76,45,0,12,190,45,0,13,67,46,0,9,162,46,0,10
    db 1,47,0,14,134,47,0,9,229,47,0,8,49,48,0,8,125,48,0,8,201,48,0,6,2,49,0,9,97,49,0,8
    db 173,49,0,12,31,50,0,7,107,50,0,9,202,50,0,9,41,51,0,8,117,51,0,8,193,51,0,11,51,52,0,9
    db 146,52,0,9,241,52,0,8,61,53,0,9,156,53,0,8,232,53,0,7,52,54,0,8,128,54,0,11,242,54,0,8
    db 62,55,0,9,157,55,0,8,233,55,0,12,91,56,0,12,205,56,0,9,44,57,0,11,158,57,0,8,234,57,0,8
    db 54,58,0,12,168,58,0,8,244,58,0,8,64,59,0,8,140,59,0,8,216,59,0,8,36,60,0,4,74,60,0,9
    db 169,60,0,9,8,61,0,9,103,61,0,9,198,61,0,10,37,62,0,8,113,62,0,4,151,62,0,11,9,63,0,10
    db 104,63,0,10,199,63,0,11,57,64,0,8,133,64,0,4,171,64,0,13,48,65,0,13,181,65,0,13,58,66,0,12
    db 172,66,0,9,11,67,0,6,68,67,0,12,182,67,0,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,244,11,243,11,243,11,243,11,243,10,242
    db 10,242,5,113,0,16,11,244,9,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 10,243,221,0,9,242,205,0,8,241,204,0,8,240,188,0,1,48,34,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,79,48,172,0,0,111,16,202,0,0,141,0,232,0,47,255
    db 255,255,176,39,235,121,248,80,0,247,7,240,0,72,249,107,230,32,207,255,255,255,32,8,224,14,128,0,10,192,31,96
    db 0,12,160,63,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,64,0,0,0,0,208,0,0,0,125,254,145,0,9,254,237,252,0,14,225,208,207,48,31,225,208
    db 18,16,11,254,227,0,0,1,158,255,180,0,0,1,218,254,32,37,48,208,159,96,79,208,208,191,96,12,254,237,253,16
    db 1,157,254,162,0,0,0,208,0,0,0,0,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,190,178,0,8,208,0,8,229,216,0,62,64
    db 0,10,176,170,0,201,0,0,9,211,217,7,209,0,0,2,223,210,46,80,0,0,0,2,0,186,0,0,0,0,0,5
    db 226,27,236,32,0,0,30,112,142,93,144,0,0,172,0,171,10,176,0,4,227,0,141,61,144,0,29,128,0,45,253,48
    db 0,0,0,0,0,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,142,234,16,0,5,252,175,128,0,8,243,14,160
    db 0,6,246,111,112,0,1,222,251,0,0,2,207,225,3,32,29,250,249,63,128,111,144,175,191,96,111,144,28,254,16,46
    db 250,158,254,32,3,190,235,111,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,10,243,0,9,242,0,8,241,0,8,240,0,1,48,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,43,112,0,159,80,0,238,0,4,249,0,7,247,0,9,245,0,11,243,0,11,243,0,9,245,0,6
    db 247,0,2,252,0,0,175,48,0,79,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,91,80,0
    db 47,192,0,11,243,0,6,248,0,3,250,0,1,252,0,0,237,0,0,237,0,2,251,0,4,249,0,8,245,0,13,208
    db 0,95,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,96,0,11,140,140
    db 80,4,207,248,16,8,238,236,64,8,76,105,48,0,10,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,182,0,0,0,1,248,0
    db 0,0,1,248,0,0,12,255,255,255,48,6,136,251,136,16,0,1,248,0,0,0,1,248,0,0,0,0,50,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,33,11,242,13,192,14,128,47,64,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,31,255,249,0,24,136,133,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,16,11,243,9,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,224,0,14,176,0
    db 63,112,0,143,32,0,189,0,1,233,0,5,246,0,9,241,0,12,192,0,47,128,0,111,64,0,174,16,0,51,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,236,112,0,5,254,173
    db 248,0,12,244,2,238,16,47,192,0,159,80,79,160,0,127,112,95,144,0,111,128,79,160,0,127,112,47,192,0,159,80
    db 12,243,1,238,16,5,254,173,248,0,0,92,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,191,224,78,239,224,108,62,224,49,14,224,0,14,224
    db 0,14,224,0,14,224,0,14,224,0,14,224,0,14,224,0,14,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,236,80,0,10,253,174,244,0,15,208,5,250,0,22
    db 64,3,251,0,0,0,8,247,0,0,0,95,193,0,0,3,238,48,0,0,62,228,0,0,2,223,80,0,0,29,252,153
    db 152,0,47,255,255,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,237,112,0,9,253,173,246,0,14,209,3,252,0,0,0
    db 3,251,0,0,5,141,212,0,0,10,255,146,0,0,0,39,253,0,1,16,0,207,48,63,208,1,223,32,12,253,174,250
    db 0,1,157,253,129,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,79,246,0,0,0,207,246,0,0,7,251,246,0,0,30,199
    db 246,0,0,159,71,246,0,3,250,7,246,0,11,243,7,246,0,79,216,139,251,96,95,255,255,255,160,0,0,7,246,0
    db 0,0,7,246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,7,255,255,249,0,8,250,153,149,0,10,242,0,0,0,11,242,101,16
    db 0,12,254,255,211,0,7,181,24,251,0,0,0,0,223,0,2,32,0,207,16,14,225,2,237,0,9,253,157,247,0,0
    db 141,237,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,59,237,128,0,3,238,190,249,0,10,244,1,238,16,31,192,0,34,0
    db 63,152,222,161,0,95,236,139,251,0,79,225,0,207,32,47,176,0,159,64,13,225,0,223,16,6,253,156,249,0,0,109
    db 237,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,127,255,255,248,73,153,156,248,0,0,13,242,0,0,95,160,0,0,207,48,0,4,251,0
    db 0,11,244,0,0,63,192,0,0,175,80,0,2,253,0,0,9,247,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,237,112,0,8,253,157,247
    db 0,13,242,3,252,0,11,241,2,251,0,5,236,140,228,0,2,191,255,162,0,13,245,22,252,0,79,160,0,191,48,79
    db 176,0,223,48,12,252,140,251,0,2,157,253,145,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,141,236,80,0,10,252,157,245,0
    db 47,192,2,236,0,95,144,0,207,16,63,176,1,239,48,12,251,141,239,64,2,174,215,175,32,18,32,0,206,0,31,209
    db 5,250,0,10,253,190,227,0,1,157,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,80,12,244,6,161,0,0,0,0,0,16,11,243
    db 9,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,7,228,0,9,245,0,0,32,0,0,0,0,0,0,0,2,65,0,11,242,0,13,192,0,15,128,0,46,64,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,108,0,0,1,125,253,0,1,142,253,113,0,13,251,80,0,0,11,254,146,0,0,0,75,255,164
    db 0,0,0,58,254,0,0,0,0,40,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,5,153,153,153,0,10,255,255,255,0,0,0,0,0,0,0,0,0,0,0,10,255,255,255,0
    db 6,153,153,153,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,8,146,0,0,0,8,255,163,0,0,0,74,255,164,0,0,0,40,239,64,0,0,108,254,48,2,142,253,113,0,9
    db 252,96,0,0,6,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,206,217,16,46,234,207,144,110,128,47,208,0,0,63,192,0,2
    db 223,96,0,29,246,0,0,95,128,0,0,73,48,0,0,1,0,0,0,143,112,0,0,110,80,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,1,155,238,201,32,0,0,94,234,135,173,231,0,2,236,48,0,1,159,64,11    db 226,26,237,190,12,192,15,144,174,137,254,7,241,63,113,248,0,158,5,244,95,83,245,0,142,4,244,63,97,248,0,174
    db 6,242,15,144,190,120,239,108,192,11,226,43,237,75,236,48,3,252,32,0,0,0,0,0,110,234,135,140,48,0,0,2
    db 156,239,219,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,5,255,96,0,0,10,254,176,0,0,14,203,241,0,0,95,151,246,0,0,159,83,251,0,0,238,16,223,16
    db 4,253,136,207,96,9,255,255,255,176,13,241,0,14,241,79,192,0,10,246,143,128,0,5,251,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,15,255,254,179,0,15,233,156,253,0,15,208,0,223,48,15,208,0,223,32,15,230,106,248,0,15,255,255,213,0,15
    db 208,3,223,64,15,208,0,127,128,15,208,0,143,128,15,233,154,255,64,15,255,254,197,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,25,222,215,16,2,223,219,239,176,9,249,0,28,245,15,225,0,4,182,63,176,0,0,0,95,144,0,0,0,63,160
    db 0,0,0,31,209,0,5,166,10,249,0,29,245,2,223,219,239,160,0,25,222,215,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15
    db 255,253,162,0,15,234,172,254,48,15,208,0,127,176,15,208,0,12,242,15,208,0,9,245,15,208,0,7,246,15,208,0
    db 9,245,15,208,0,12,242,15,208,0,127,176,15,233,172,254,48,15,255,253,162,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,255,250,15
    db 233,153,150,15,208,0,0,15,208,0,0,15,233,153,147,15,255,255,245,15,208,0,0,15,208,0,0,15,208,0,0,15
    db 233,153,150,15,255,255,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,15,255,255,249,15,233,153,149,15,208,0,0,15,208,0,0,15,208,0,0,15,255,255,242,15
    db 233,153,145,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222,215,0,1,223,219,239,160
    db 9,250,0,29,245,14,225,0,5,182,47,176,0,0,0,95,144,3,119,118,79,160,7,255,251,31,208,0,3,250,10,248
    db 0,10,246,2,239,219,223,192,0,42,222,216,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,0,7,247,15,208,0,7,247,15
    db 208,0,7,247,15,208,0,7,247,15,233,153,155,247,15,255,255,255,247,15,208,0,7,247,15,208,0,7,247,15,208,0
    db 7,247,15,208,0,7,247,15,208,0,7,247,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,15,208,15,208,15,208,15,208,15,208,15,208,15,208,15,208,15,208,15,208,15
    db 208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,242,0,0,11,242,0
    db 0,11,242,0,0,11,242,0,0,11,242,0,0,11,242,0,0,11,242,126,96,11,242,111,144,14,224,46,250,207,160,4
    db 206,234,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,15,208,0,95,226,15,208,3,239,64,15,208,29,246,0,15,208,191,144,0,15,215,252,0,0,15
    db 238,254,16,0,15,253,159,160,0,15,226,29,245,0,15,208,5,253,16,15,208,0,175,144,15,208,0,46,243,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208
    db 0,0,15,208,0,0,15,233,153,147,15,255,255,246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,254,0,0,47,253,0,15,255
    db 80,0,127,253,0,15,223,160,0,190,237,0,15,204,225,2,250,237,0,15,200,246,7,246,237,0,15,212,251,12,242,237
    db 0,15,208,222,31,176,237,0,15,208,159,127,112,237,0,15,208,63,223,32,237,0,15,208,13,251,0,237,0,15,208,8
    db 247,0,237,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,246,0,5,250,0,15
    db 254,16,5,250,0,15,239,144,5,250,0,15,203,243,5,250,0,15,212,251,5,250,0,15,208,191,85,250,0,15,208,63
    db 213,250,0,15,208,9,249,250,0,15,208,1,238,250,0,15,208,0,111,250,0,15,208,0,12,250,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,25,222,199,0,0,2,223,219,239,176,0,9,249,0,28,246,0,15,225,0
    db 3,252,0,63,176,0,0,238,0,95,144,0,0,223,0,63,160,0,0,238,0,15,225,0,3,252,0,10,249,0,28,246
    db 0,2,223,219,239,176,0,0,25,222,199,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,254,162,0,15
    db 233,156,253,0,15,208,0,191,80,15,208,0,159,112,15,208,0,207,80,15,232,155,253,0,15,255,254,162,0,15,208,0
    db 0,0,15,208,0,0,0,15,208,0,0,0,15,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222,199
    db 0,0,2,223,219,239,176,0,9,249,0,28,246,0,15,225,0,3,252,0,63,176,0,0,238,0,95,144,0,0,223,0
    db 63,160,0,0,237,0,15,225,26,131,251,0,10,249,6,253,246,0,2,223,219,255,176,0,0,25,222,206,193,0,0,0
    db 0,3,199,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,15,255,254,162,0,15,233,156,253,0,15,208,0,191,80,15,208,0,143,96,15
    db 208,0,207,64,15,232,155,253,0,15,255,255,210,0,15,208,30,225,0,15,208,8,248,0,15,208,1,238,32,15,208,0
    db 143,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,125,237,146,0,9,254,173,252,0,14,225,0,207,64,31,225,0,1,0,11,254
    db 148,0,0,1,158,255,196,0,0,1,91,254,32,37,32,0,143,96,79,176,0,175,96,12,253,173,253,16,2,157,253,163
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,127,255,255,255,176,73,155,252,153,96,0,5,249,0,0,0,5,249,0,0,0,5,249
    db 0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9
    db 245,15,208,0,9,245,15,208,0,9,245,14,224,0,10,244,11,247,0,62,241,4,255,203,239,128,0,75,238,198,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,143,128,0,6,251,63,208,0,10,246,13,242,0,14,241,9,247,0,79,176,4,252,0,159,112
    db 0,223,16,223,32,0,159,98,252,0,0,79,166,247,0,0,13,218,242,0,0,9,254,192,0,0,4,255,112,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,159,112,0,239,64,3,253,95,160,4,255,128,6,249,31,208,7,254,176,10
    db 245,12,242,11,235,224,13,241,9,246,14,200,243,31,192,5,249,63,149,247,95,144,1,252,111,81,250,143,80,0,206,159
    db 16,204,175,16,0,159,204,0,158,220,0,0,95,249,0,95,249,0,0,31,245,0,31,245,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,46,226,0,30,243,7,251,0,159,128,0,207,83,253,16,0,63,203,244,0,0
    db 9,255,160,0,0,3,255,80,0,0,11,255,209,0,0,111,170,248,0,2,238,34,239,48,11,247,0,127,192,111,192,0
    db 12,247,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,127,176,0,12,246,13,245,0,95,208,5,252,0,207,80,0,191,85,251,0,0,63
    db 203,243,0,0,10,255,160,0,0,2,255,32,0,0,0,238,0,0,0,0,238,0,0,0,0,238,0,0,0,0,238,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,79,255,255,255,96,41,153,153,255,48,0,0,9,248,0,0,0,79,208,0,0,0,223
    db 64,0,0,8,249,0,0,0,46,225,0,0,0,191,96,0,0,6,250,0,0,0,30,249,153,153,48,79,255,255,255,96
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,11,255,128,11,247,48,11,241,0,11,241,0,11,241,0,11,241,0,11,241,0,11,241,0,11,241,0,11,241,0
    db 11,241,0,11,247,48,11,255,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,174,0,0,127,48
    db 0,47,128,0,13,176,0,9,241,0,5,245,0,1,249,0,0,204,0,0,143,32,0,79,96,0,14,160,0,11,208,0
    db 2,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,95,253,0,39,237,0,0,221,0,0,221,0
    db 0,221,0,0,221,0,0,221,0,0,221,0,0,221,0,0,221,0,0,221,0,38,237,0,95,253,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,191,112,0,3,251,208,0,10,194,246,0
    db 63,96,173,0,54,0,38,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,255,255,255,144,119,119,119,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,10,226,0,1,232,0,0,18,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,235,32,30,233,159,192,4,64,13,241,2,123,223,242,62,234,124
    db 242,127,96,13,242,95,199,191,242,9,238,154,242,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,0,0,0,31,176,0,0,0,31,176,0,0,0,31
    db 184,238,128,0,31,237,157,248,0,31,225,2,254,0,31,176,0,223,16,31,192,0,223,16,31,242,2,254,0,31,237,157
    db 248,0,31,184,222,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,236,80,10,251,158,243
    db 63,192,5,180,111,144,0,0,111,144,0,0,63,192,5,181,10,251,158,243,1,157,236,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,252,0
    db 0,0,0,252,0,0,0,0,252,0,2,190,213,252,0,12,251,157,252,0,63,208,5,252,0,111,144,1,252,0,111,144
    db 2,252,0,79,208,6,252,0,12,251,157,252,0,2,190,213,236,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,1,157,235,64,11,251,158,226,63,160,5,248,111,255,255,250,95,148,68,67,63,176,3,114,10,250,141,245,1
    db 157,253,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,158,224,5,253,144,8,246,0,223,255,224,107,250,112,8,245,0,8,245,0,8,245,0,8,245,0,8,245,0,8,245
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,174,213,237,0,12,251,157,253,0,63,208,5,253,0,111,144,0
    db 253,0,111,128,0,253,0,79,176,4,253,0,12,250,141,253,0,2,190,213,237,0,0,32,2,252,0,13,233,124,247,0
    db 3,190,253,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176
    db 0,0,0,31,176,0,0,0,31,176,0,0,0,31,183,222,128,0,31,237,174,245,0,31,225,7,249,0,31,192,3,250
    db 0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,144,29,144,0,0,31,176,31,176,31,176
    db 31,176,31,176,31,176,31,176,31,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,144,29,144,0,0
    db 47,176,47,176,47,176,47,176,47,176,47,176,47,176,47,176,47,176,191,144,235,16,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,31,176,0,0,31,176,0,0,31,176,0,0,31,176,28,245,31,176,191,112,31,185,249,0,31,239
    db 224,0,31,253,247,0,31,194,239,48,31,176,95,193,31,176,10,248,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,31,176,31,176,31,176,31,176,31,176,31,176,31,176,31,176,31,176,31,176
    db 31,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,168,236,53,206,161,0,31,220,191
    db 205,174,247,0,31,225,11,246,5,250,0,31,176,9,243,3,250,0,31,176,9,243,3,250,0,31,176,9,243,3,250,0
    db 31,176,9,243,3,250,0,31,176,9,243,3,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,167,222,128,0,31,221,174,245,0,31,225,7,249,0,31,192
    db 3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,236,64,0,10,251,158,243,0,63,192,5,250,0,111,144,1
    db 253,0,111,144,1,253,0,63,192,5,250,0,10,251,142,243,0,1,157,236,64,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,31,184,238,128,0,31,237,157,248,0,31,225,2,254,0,31,176,0,223
    db 16,31,192,0,223,16,31,242,2,254,0,31,237,157,248,0,31,183,222,144,0,31,176,0,0,0,31,176,0,0,0,28
    db 144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,190,213,236,0,12,251,157,252,0,63,208,5,252,0,111,144,1,252,0
    db 111,144,2,252,0,63,208,6,252,0,12,251,157,252,0,2,190,213,252,0,0,0,0,252,0,0,0,0,252,0,0,0
    db 0,186,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31
    db 169,229,31,238,164,31,242,0,31,192,0,31,176,0,31,176,0,31,176,0,31,176,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,206
    db 234,32,30,231,159,176,63,192,4,32,12,254,183,16,1,122,239,192,38,64,29,241,63,216,159,208,5,206,234,32,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,208
    db 0,12,240,0,223,255,128,109,247,64,12,240,0,12,240,0,12,240,0,12,240,0,11,250,64,3,207,144,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3
    db 250,0,15,224,7,250,0,12,252,173,250,0,3,206,196,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,159,96,2,252,79,160,7,247,13,224,12,242,8,245,47,176,3,249,111,96,0,205,174,16,0,127,234,0,0,47
    db 245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,159,80,47,208,9,245
    db 95,144,111,242,12,241,31,192,157,246,31,176,11,241,201,217,95,112,7,245,246,172,143,48,3,250,242,111,189,0,0,223
    db 192,31,249,0,0,159,128,12,245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 79,176,11,244,10,245,95,144,2,236,206,16,0,127,246,0,0,143,247,0,3,250,190,32,12,243,79,176,111,144,10,245
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,159,96,2,252,79,160,7,247,13,224,12,242,8,245,47,176,3,249,127,96
    db 0,205,190,16,0,127,234,0,0,47,245,0,0,30,224,0,7,191,112,0,30,233,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,255,255,224,24,136,191,192
    db 0,1,222,32,0,11,246,0,0,127,160,0,4,253,16,0,29,250,136,129,63,255,255,242,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,117,0,46,249,0,127,96,0,159
    db 48,0,159,32,3,222,16,31,214,0,28,250,0,0,191,16,0,159,32,0,143,64,0,111,180,0,9,234,0,0,0,0
    db 0,0,0,0,0,4,196,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0
    db 6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,6,246,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,94,178,0,41,250,0,0,237,0,0,205,0,0,206,0,0,175,97,0,43,247,0,110,213,0
    db 191,32,0,205,0,0,221,0,41,250,0,94,178,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 103,32,19,16,8,255,212,111,64,13,194,191,253,16,3,32,6,130,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,38,32,0,4,239,244,0,10,255,250,0,8,255
    db 249,0,1,190,178,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,255,96,0,0,10,254,176,0,0,14,203,241,0
    db 0,95,151,246,0,0,159,83,251,0,0,238,16,223,16,4,253,136,207,96,9,255,255,255,176,13,241,0,14,241,79,192
    db 0,10,246,143,128,0,5,251,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,255,249,0,15,233,153,149,0,15,208,0,0,0,15
    db 208,0,0,0,15,230,102,48,0,15,255,255,248,0,15,208,4,223,48,15,208,0,143,96,15,208,0,175,80,15,232,139
    db 253,16,15,255,254,179,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,254,179,0,15,233,156,253,0,15,208,0,223,48,15,208
    db 0,223,32,15,230,106,248,0,15,255,255,213,0,15,208,3,223,64,15,208,0,127,128,15,208,0,143,128,15,233,154,255
    db 64,15,255,254,197,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,15,255,255,249,15,233,153,149,15,208,0,0,15,208,0,0,15,208,0,0,15
    db 208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,15,208,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255
    db 255,255,32,0,13,249,153,223,32,0,14,208,0,191,32,0,15,192,0,191,32,0,47,176,0,191,32,0,79,144,0,191
    db 32,0,111,128,0,191,32,0,159,80,0,191,32,0,222,16,0,191,32,75,253,153,153,223,164,127,255,255,255,255,246,127
    db 96,0,0,7,246,127,96,0,0,7,246,36,16,0,0,2,66,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,15,255,255,250,15,233,153,150,15,208,0,0,15,208,0,0,15,233,153,147,15,255,255
    db 245,15,208,0,0,15,208,0,0,15,208,0,0,15,233,153,150,15,255,255,250,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,79,226
    db 0,191,48,9,250,10,248,0,191,48,47,226,2,254,16,191,48,159,144,0,159,128,191,49,238,16,0,30,225,191,56,247
    db 0,0,9,255,255,255,241,0,0,46,233,223,171,248,0,0,175,112,191,49,238,32,4,253,0,191,48,127,160,12,245,0
    db 191,48,29,244,111,192,0,191,48,6,252,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,141,237
    db 112,0,9,253,173,246,0,14,209,3,252,0,0,0,3,251,0,0,5,141,212,0,0,10,255,146,0,0,0,39,253,0
    db 1,16,0,207,48,63,208,1,223,32,12,253,174,250,0,1,157,253,129,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15
    db 208,0,12,250,0,15,208,0,111,250,0,15,208,1,222,250,0,15,208,8,249,250,0,15,208,47,213,250,0,15,208,191
    db 85,250,0,15,212,251,5,250,0,15,220,243,5,250,0,15,239,144,5,250,0,15,254,16,5,250,0,15,247,0,5,250
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 14,115,229,0,0,0,5,222,144,0,0,0,0,0,0,0,0,15,208,0,12,250,0,15,208,0,111,250,0,15,208,1
    db 222,250,0,15,208,8,249,250,0,15,208,47,213,250,0,15,208,191,85,250,0,15,212,251,5,250,0,15,220,243,5,250
    db 0,15,239,144,5,250,0,15,254,16,5,250,0,15,247,0,5,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 15,208,0,79,226,15,208,1,223,80,15,208,9,249,0,15,208,79,209,0,15,232,223,48,0,15,255,253,0,0,15,208
    db 159,128,0,15,208,29,243,0,15,208,5,252,0,15,208,0,175,128,15,208,0,46,243,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 95,255,255,248,0,111,185,155,248,0,127,96,6,248,0,143,80,6,248,0,159,64,6,248,0,175,48,6,248,0,191,16
    db 6,248,0,222,0,6,248,2,252,0,6,248,76,247,0,6,248,126,145,0,6,248,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,15,254,0,0,47,253,0,15,255,80,0,127,253,0,15,223,160,0,190,237,0,15,204,225,2,250,237,0
    db 15,200,246,7,246,237,0,15,212,251,12,242,237,0,15,208,222,31,176,237,0,15,208,159,127,112,237,0,15,208,63,223
    db 32,237,0,15,208,13,251,0,237,0,15,208,8,247,0,237,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,233,153,155,247,15,255,255,255
    db 247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,25,222,199,0,0,2,223,219,239,176,0,9,249,0,28,246,0,15,225,0,3,252,0,63,176,0
    db 0,238,0,95,144,0,0,223,0,63,160,0,0,238,0,15,225,0,3,252,0,10,249,0,28,246,0,2,223,219,239,176
    db 0,0,25,222,199,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,255,255,247,15,233,153,156,247,15,208
    db 0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7,247,15,208,0,7
    db 247,15,208,0,7,247,15,208,0,7,247,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,254,162,0,15,233,156,253,0,15,208,0
    db 191,80,15,208,0,159,112,15,208,0,207,80,15,232,155,253,0,15,255,254,162,0,15,208,0,0,0,15,208,0,0,0
    db 15,208,0,0,0,15,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,222,215,16,2,223,219,239,176,9,249,0,28
    db 245,15,225,0,4,182,63,176,0,0,0,95,144,0,0,0,63,160,0,0,0,31,209,0,5,166,10,249,0,29,245,2
    db 223,219,239,160,0,25,222,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,255,176,73,155,252,153,96,0,5,249,0,0
    db 0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5,249,0,0,0,5
    db 249,0,0,0,5,249,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,143,160,0,63,208,30,242,0,159,128,9,247,0,223,32,3
    db 253,4,251,0,0,191,57,245,0,0,95,142,208,0,0,13,239,128,0,0,7,255,32,0,0,3,251,0,0,2,173,244
    db 0,0,4,254,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,192,0,0,0,22,175,233,64,0,3,223
    db 255,255,250,0,11,247,47,194,191,112,47,176,47,192,47,192,95,144,47,192,13,224,63,160,47,192,14,208,30,226,47,192
    db 111,160,6,254,175,219,254,32,0,92,255,254,162,0,0,0,47,192,0,0,0,0,23,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,46,226,0,30,243,7,251,0,159,128,0,207,83,253,16,0,63,203,244,0,0,9,255,160,0,0,3,255,80,0,0
    db 11,255,209,0,0,111,170,248,0,2,238,34,239,48,11,247,0,127,192,111,192,0,12,247,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,15,208,0,11,243,0,15,208,0,11,243,0,15,208,0,11,243,0,15,208,0,11,243,0,15,208,0,11,243
    db 0,15,208,0,11,243,0,15,208,0,11,243,0,15,208,0,11,243,0,15,208,0,11,243,0,15,233,153,157,249,32,15
    db 255,255,255,255,48,0,0,0,0,175,48,0,0,0,0,175,48,0,0,0,0,36,16,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,192,0,15,208,31,192,0,15,208,31,192,0,15
    db 208,31,192,0,15,208,14,226,0,31,208,9,253,154,239,208,1,157,253,159,208,0,0,0,15,208,0,0,0,15,208,0
    db 0,0,15,208,0,0,0,15,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,1,252,0,63,176,15,208
    db 1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63
    db 176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,233,153,253,153,175,176,15,255,255
    db 255,255,255,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,1,252
    db 0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15
    db 208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,208,1,252,0,63,176,15,233,153,253,153
    db 175,214,15,255,255,255,255,255,251,0,0,0,0,0,2,251,0,0,0,0,0,2,251,0,0,0,0,0,0,67,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255
    db 244,0,0,0,73,157,244,0,0,0,0,10,244,0,0,0,0,10,244,0,0,0,0,10,255,254,198,0,0,10,250,137
    db 239,96,0,10,244,0,63,192,0,10,244,0,14,224,0,10,244,0,63,192,0,10,250,137,239,96,0,10,255,254,198,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,0,0,3,250,0,15,208,0,0,3,250
    db 0,15,208,0,0,3,250,0,15,208,0,0,3,250,0,15,255,254,179,3,250,0,15,232,138,254,35,250,0,15,208,0
    db 143,115,250,0,15,208,0,95,147,250,0,15,208,0,143,115,250,0,15,232,138,254,35,250,0,15,255,254,179,3,250,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,0,0,0,15,208,0,0,0,15,208,0,0
    db 0,15,208,0,0,0,15,255,254,179,0,15,232,138,254,32,15,208,0,143,112,15,208,0,95,144,15,208,0,143,112,15
    db 232,138,254,32,15,255,254,179,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,238,179,0,7,255,204,255,80,30,243,0,79,209
    db 58,112,0,9,245,0,1,136,139,248,0,2,255,255,249,0,0,0,6,247,76,128,0,10,245,30,227,0,95,208,6,255
    db 187,254,80,0,92,238,179,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,208,0,59,238,181,0,15,208,5
    db 255,204,255,112,15,208,30,245,0,62,226,15,208,95,160,0,7,248,15,231,191,96,0,4,250,15,255,255,80,0,2,251
    db 15,208,143,96,0,4,249,15,208,79,160,0,8,247,15,208,29,245,0,78,226,15,208,4,255,203,255,112,15,208,0,59
    db 238,180,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,173,255,255,32,11,252,153,223,32,63
    db 224,0,191,32,95,160,0,191,32,47,208,0,191,32,12,252,152,223,32,1,207,255,255,32,0,223,48,191,32,7,250,0
    db 191,32,29,243,0,191,32,127,160,0,191,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,235
    db 32,30,233,159,192,4,64,13,241,2,123,223,242,62,234,124,242,127,96,13,242,95,199,191,242,9,238,154,242,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,33,0,108,255
    db 247,6,253,169,113,13,176,0,0,79,107,237,96,95,219,142,244,127,176,5,250,127,128,0,252,95,128,1,252,47,192,5
    db 249,10,251,142,243,1,157,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,255,236,64,31,199,158,224,31,160,45
    db 208,31,255,253,48,31,179,75,145,31,160,7,246,31,199,125,245,31,255,254,128,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,255,255,31,216
    db 136,31,176,0,31,176,0,31,176,0,31,176,0,31,176,0,31,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,255,255,249,0,2,252,137,249,0,3,248,3,249,0,5,247,3,249,0,7,245,3,249,0,10,242,3,249,0,110,232
    db 137,252,96,207,255,255,255,176,207,0,0,15,176,207,0,0,15,176,52,0,0,4,48,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,235,64,11,251,158
    db 226,63,160,5,248,111,255,255,250,95,148,68,67,63,176,3,114,10,250,141,245,1,157,253,96,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,95,192,15,208,29,227,8,248,15,208,191,96,0,191,79
    db 215,249,0,0,47,255,255,208,0,0,127,191,236,245,0,2,238,47,211,253,16,11,246,15,208,159,144,111,192,15,208,29
    db 244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,206,214,0,63,216,223,48,18
    db 17,175,48,0,63,246,0,0,20,191,80,56,64,111,144,79,216,223,96,6,223,216,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,31,176,5,250,0,31,176,29,250,0,31,176,159,250,0,31,180,249,250,0,31,205,195
    db 250,0,31,255,51,250,0,31,248,3,250,0,31,192,3,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,16,1,16,0,0,216,61,96,0,0,77
    db 234,0,0,0,0,0,0,0,31,176,5,250,0,31,176,29,250,0,31,176,159,250,0,31,180,249,250,0,31,205,195,250
    db 0,31,255,51,250,0,31,248,3,250,0,31,192,3,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,31,176,10,248,31,176,95,192,31,177,239,48,31,219,247,0,31,255,245,0,31,178,238,32,31,176,111,192,31,176,10
    db 248,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,6,255,255,246,6,251,139,246,7,246,7,246,8,245,7,246,9,244,7
    db 246,11,242,7,246,143,192,7,246,221,64,7,246,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,31,253,0,11,255,64,31,239,48,31,239,64,31,191,144,127,191,64,31,188,224,206,143,64,31,184,243
    db 250,159,64,31,179,250,245,159,64,31,176,207,208,159,64,31,176,111,128,159,64,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0
    db 31,255,255,250,0,31,216,137,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,236,64,0,10,251,158,243,0,63,192,5,250,0,111
    db 144,1,253,0,111,144,1,253,0,63,192,5,250,0,10,251,142,243,0,1,157,236,64,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,31,255,255,249,31,216,138,249,31,176,5,249,31,176,5,249,31,176,5,249,31,176,5
    db 249,31,176,5,249,31,176,5,249,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,184,238,128,0
    db 31,237,157,248,0,31,225,2,254,0,31,176,0,223,16,31,192,0,223,16,31,242,2,254,0,31,237,157,248,0,31,183
    db 222,144,0,31,176,0,0,0,31,176,0,0,0,28,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,157,236,80,10,251,158,243,63,192,5,180
    db 111,144,0,0,111,144,0,0,63,192,5,181,10,251,158,243,1,157,236,80,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 223,255,255,192,120,191,168,96,0,127,96,0,0,127,96,0,0,127,96,0,0,127,96,0,0,127,96,0,0,127,96,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,159,96,2,252,79,160,7,247,13,224,12,242,8,245,47,176,3,249,127,96
    db 0,205,190,16,0,127,234,0,0,47,245,0,0,30,224,0,7,191,112,0,30,233,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,175,48,0,0,0,0,175,48,0,0,0,0
    db 175,48,0,0,0,141,255,235,64,0,10,252,223,174,243,0,63,208,175,53,251,0,111,144,175,48,237,0,111,144,175,48
    db 237,0,63,208,175,52,251,0,10,252,223,174,243,0,0,141,255,236,64,0,0,0,175,48,0,0,0,0,175,48,0,0
    db 0,0,88,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,79,176,11,244,10,245,95,144,2,236,206,16,0,127,246,0,0,143,247,0,3,250
    db 190,32,12,243,79,176,111,144,10,245,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,5,249
    db 0,31,176,5,249,0,31,176,5,249,0,31,176,5,249,0,31,176,5,249,0,31,176,5,249,0,31,216,138,252,80,31
    db 255,255,255,144,0,0,0,79,144,0,0,0,79,144,0,0,0,20,32,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,7,246,31,176,7,246,31,192,7
    db 246,14,244,24,246,7,255,255,246,0,55,122,246,0,0,7,246,0,0,7,246,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,14,192,13,224,31,176,14,192,13,224,31,176,14,192,13,224,31
    db 176,14,192,13,224,31,176,14,192,13,224,31,176,14,192,13,224,31,216,143,216,142,224,31,255,255,255,255,224,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31
    db 176,14,192,13,224,31,176,14,192,13,224,31,176,14,192,13,224,31,176,14,192,13,224,31,176,14,192,13,224,31,176,14
    db 192,13,224,31,216,143,216,142,231,31,255,255,255,255,254,0,0,0,0,0,222,0,0,0,0,0,222,0,0,0,0,0
    db 51,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,223,254,0,0,0,102,238,0,0,0,0,223,136,97,0,0,223,255,254,48,0
    db 222,1,143,144,0,222,0,63,176,0,223,136,207,112,0,223,255,216,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,0,0,207,0,31,176,0,0,207,0,31,216,133,0
    db 207,0,31,255,255,193,207,0,31,176,26,246,207,0,31,176,7,248,207,0,31,216,158,244,207,0,31,255,253,96,207,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,0,0,31,176,0,0,31,216
    db 133,0,31,255,255,193,31,176,26,246,31,176,7,248,31,216,158,244,31,255,253,96,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,4,190,218,16,46,233,191,192,57,64,10,245,0,31,255,248,1,20,73,247,95,144,11,244,30,250,191,176,3,190
    db 217,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,176,5,206,217,16
    db 31,176,79,233,191,176,31,176,191,80,12,243,31,255,255,16,8,246,31,215,223,32,9,245,31,176,175,96,13,242,31,176
    db 62,233,191,160,31,176,4,206,217,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 6,223,255,241,63,233,125,241,127,112,11,241,63,215,108,241,6,255,255,241,6,249,11,241,29,226,11,241,143,128,11,241
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,217,29,144,0,184,11,112,0,0,0,0
    db 15,255,255,250,15,233,153,150,15,208,0,0,15,208,0,0,15,233,153,147,15,255,255,245,15,208,0,0,15,208,0,0
    db 15,208,0,0,15,233,153,150,15,255,255,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,197,44,80,2,231,62,96,0,0,0,0,1,157,235,64,11,251,158,226
    db 63,160,5,248,111,255,255,250,95,148,68,67,63,176,3,114,10,250,141,245,1,157,253,96,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,234,0,0,8,225,0
    db 0,1,16,0,3,190,235,32,30,233,159,192,4,64,13,241,2,123,223,242,62,234,124,242,127,96,13,242,95,199,191,242
    db 9,238,154,242,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,205,16,0,5,244,0,0,1,32,0,1,157,235,64,11,251,158,226,63,160,5,248,111,255,255,250
    db 95,148,68,67,63,176,3,114,10,250,141,245,1,157,253,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,33,3,247,10,192,0,0,31,176,31,176,31,176,31,176,31,176,31,176,31,176,31,176
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,189,16,0,0,3
    db 245,0,0,0,1,32,0,0,1,157,236,64,0,10,251,158,243,0,63,192,5,250,0,111,144,1,253,0,111,144,1,253
    db 0,63,192,5,250,0,10,251,142,243,0,1,157,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,18,16,0,0,0,189,16,0,0,3,244
    db 0,0,0,0,0,0,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0
    db 15,224,7,250,0,12,252,173,250,0,3,206,196,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,216,29,128,0,1,183,28,112
    db 0,0,0,0,0,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,31,176,3,250,0,15
    db 224,7,250,0,12,252,173,250,0,3,206,196,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,109,136,80,0,0,214,205,48,0
    db 0,0,0,0,0,31,167,222,128,0,31,221,174,245,0,31,225,7,249,0,31,192,3,250,0,31,176,3,250,0,31,176
    db 3,250,0,31,176,3,250,0,31,176,3,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,30,176,0,0,0,110,32,0,0,0,0,0,0,0,5,255,96,0,0,10,254,176,0,0
    db 14,203,241,0,0,95,151,246,0,0,159,83,251,0,0,238,16,223,16,4,253,136,207,96,9,255,255,255,176,13,241,0
    db 14,241,79,192,0,10,246,143,128,0,5,251,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,174,16,0,2,245,0,0,0,0,0,15,255,255,250,15,233,153,150,15,208,0,0,15,208,0
    db 0,15,233,153,147,15,255,255,245,15,208,0,0,15,208,0,0,15,208,0,0,15,233,153,150,15,255,255,250,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,249,9,209,0,0,15,208,15,208,15,208,15,208,15
    db 208,15,208,15,208,15,208,15,208,15,208,15,208,0,0,0,0,0,0,0,0,0,0,0,0,9,226,0,0,0,0,46
    db 112,0,0,0,0,18,0,0,0,0,25,222,199,0,0,2,223,219,239,176,0,9,249,0,28,246,0,15,225,0,3,252
    db 0,63,176,0,0,238,0,95,144,0,0,223,0,63,160,0,0,238,0,15,225,0,3,252,0,10,249,0,28,246,0,2
    db 223,219,239,176,0,0,25,222,199,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,13,192,0,0,0,94,48,0,0,0,0,0,0,15,208,0,9,245,15,208,0
    db 9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,14,224,0,10,244
    db 11,247,0,62,241,4,255,203,239,128,0,75,238,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,62,99,230,0,0,44,82,197,0,0,0,0,0,0,15,208,0,9,245,15,208,0,9
    db 245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,15,208,0,9,245,14,224,0,10,244,11
    db 247,0,62,241,4,255,203,239,128,0,75,238,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,7,232,167,0,0,0,9,91,194,0,0,0,0,0,0,0,0,15,246,0,5,250,0,15
    db 254,16,5,250,0,15,239,144,5,250,0,15,203,243,5,250,0,15,212,251,5,250,0,15,208,191,85,250,0,15,208,63
    db 213,250,0,15,208,9,249,250,0,15,208,1,238,250,0,15,208,0,111,250,0,15,208,0,12,250,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,209,0,0,12,226,0,0,0,16,0,0,9,176
    db 0,0,46,208,0,3,239,80,0,30,228,0,0,95,160,5,96,63,211,95,208,10,255,255,80,0,71,114,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,211,11,244,0,16,7,161,10,242,10,242,10,243,11
    db 243,11,243,11,244,4,98,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,16,0,32,0,1,0,11
    db 243,4,250,0,206,32,9,210,3,232,0,173,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,123,16,0,0,0,0,0,111,177,0
    db 0,0,0,0,6,251,16,0,0,0,0,0,78,177,0,5,255,255,255,238,251,0,2,136,136,136,140,229,0,0,0,0
    db 1,190,80,0,0,0,0,28,229,0,0,0,0,0,158,80,0,0,0,0,0,20,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,177,0,0,0,0
    db 0,127,160,0,0,0,0,7,250,0,0,0,0,0,127,128,0,0,0,0,6,254,239,255,255,250,0,1,206,136,136,136
    db 133,0,0,28,211,0,0,0,0,0,1,206,64,0,0,0,0,0,28,225,0,0,0,0,0,1,64,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,80,0,0
    db 0,0,28,243,0,0,0,1,207,144,0,129,0,28,249,0,6,252,17,207,144,0,0,159,204,248,0,0,0,9,255,128
    db 0,0,0,0,136,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,3,177,0,104,0,7,252,22,253,16,0,143,223,210,0,0,10,255,32,0,0,111
    db 239,193,0,6,252,39,252,16,4,194,0,121,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,222,144,30,183,246,63,48,201,30,183,246
    db 5,222,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,160,0,0,0,0,95,249
    db 0,0,0,4,237,239,144,0,0,78,185,215,248,0,3,237,41,224,175,112,5,211,9,224,11,144,0,16,9,224,1,0
    db 0,0,9,224,0,0,0,0,9,224,0,0,0,0,9,224,0,0,0,0,9,224,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,9,224,0,0,0,0,9,224,0,0,0,0,9,224,0,0,0,0,9,224,0,0
    db 0,48,9,224,2,16,6,246,9,224,45,176,1,191,89,210,222,48,0,27,234,204,227,0,0,1,191,254,48,0,0,0
    db 27,227,0,0,0,0,1,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
font_uis:
    db 16,0,0,0,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,8,4,0,3,40,4,0,3,72,4,0,6,120,4,0,8,184,4,0,8,248,4,0,12
    db 88,5,0,8,152,5,0,4,184,5,0,4,216,5,0,4,248,5,0,6,40,6,0,8,104,6,0,3,136,6,0,6
    db 184,6,0,3,216,6,0,4,248,6,0,8,56,7,0,5,104,7,0,7,168,7,0,7,232,7,0,8,40,8,0,7
    db 104,8,0,7,168,8,0,7,232,8,0,7,40,9,0,7,104,9,0,3,136,9,0,4,168,9,0,8,232,9,0,8
    db 40,10,0,8,104,10,0,6,152,10,0,12,248,10,0,8,56,11,0,8,120,11,0,9,200,11,0,9,24,12,0,7
    db 88,12,0,7,152,12,0,9,232,12,0,9,56,13,0,3,88,13,0,7,152,13,0,8,216,13,0,7,24,14,0,11
    db 120,14,0,9,200,14,0,9,24,15,0,8,88,15,0,9,168,15,0,8,232,15,0,8,40,16,0,8,104,16,0,9
    db 184,16,0,8,248,16,0,12,88,17,0,8,152,17,0,8,216,17,0,8,24,18,0,4,56,18,0,4,88,18,0,4
    db 120,18,0,6,168,18,0,5,216,18,0,4,248,18,0,7,56,19,0,7,120,19,0,7,184,19,0,7,248,19,0,7
    db 56,20,0,4,88,20,0,7,152,20,0,7,216,20,0,3,248,20,0,3,24,21,0,7,88,21,0,3,120,21,0,11
    db 216,21,0,7,24,22,0,7,88,22,0,7,152,22,0,7,216,22,0,5,8,23,0,6,56,23,0,4,88,23,0,7
    db 152,23,0,7,216,23,0,10,40,24,0,7,104,24,0,7,168,24,0,7,232,24,0,5,24,25,0,4,56,25,0,5
    db 104,25,0,8,168,25,0,7,232,25,0,8,40,26,0,8,104,26,0,8,168,26,0,7,232,26,0,10,56,27,0,7
    db 120,27,0,12,216,27,0,7,24,28,0,9,104,28,0,9,184,28,0,8,248,28,0,9,72,29,0,11,168,29,0,9
    db 248,29,0,9,72,30,0,9,152,30,0,8,216,30,0,9,40,31,0,8,104,31,0,8,168,31,0,10,248,31,0,8
    db 56,32,0,9,136,32,0,8,200,32,0,11,40,33,0,12,136,33,0,10,216,33,0,11,56,34,0,8,120,34,0,9
    db 200,34,0,12,40,35,0,8,104,35,0,7,168,35,0,7,232,35,0,7,40,36,0,5,88,36,0,8,152,36,0,7
    db 216,36,0,10,40,37,0,6,88,37,0,7,152,37,0,7,216,37,0,6,8,38,0,7,72,38,0,9,152,38,0,7
    db 216,38,0,7,24,39,0,7,88,39,0,7,152,39,0,7,216,39,0,6,8,40,0,7,72,40,0,8,136,40,0,7
    db 200,40,0,7,8,41,0,7,72,41,0,10,152,41,0,10,232,41,0,8,40,42,0,9,120,42,0,7,184,42,0,7
    db 248,42,0,10,72,43,0,7,136,43,0,7,200,43,0,7,8,44,0,7,72,44,0,7,136,44,0,3,168,44,0,7
    db 232,44,0,7,40,45,0,7,104,45,0,7,168,45,0,8,232,45,0,7,40,46,0,3,72,46,0,9,152,46,0,9
    db 232,46,0,9,56,47,0,9,136,47,0,6,184,47,0,3,216,47,0,10,40,48,0,11,136,48,0,11,232,48,0,11
    db 72,49,0,8,136,49,0,5,184,49,0,10,8,50,0,10,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,13,80,13,80,13,80,13,80,13,80,13,64,1,0,8,48,13,96
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,108,96,11,91,80,11,91,80,4,36,32,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,150,8,112,0,195,11,64,78,254,239,229,2,208,13,0,4,176,44,0,5,160,74,0,174,238,238,176
    db 10,80,150,0,13,32,195,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,16,0
    db 0,9,64,0,3,191,234,16,13,153,107,160,31,41,66,80,11,203,64,0,0,125,233,16,0,9,107,176,39,9,67,224
    db 46,137,107,192,5,207,234,32,0,9,64,0,0,2,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,3,221,64,2,210,0,9,100,176,10,96,0,9,100,176,91,0,0,3,221,66,210
    db 0,0,0,0,10,96,0,0,0,0,91,7,220,16,0,2,210,13,25,96,0,10,96,13,25,96,0,91,0,7,220,16
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,2,206,178,0,10,161,184,0,9,144,199,0,3,236,177,0,3,238,32,0,30,105,178,224,108,0,188,192
    db 62,64,111,128,6,222,198,227,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,96
    db 11,80,11,80,4,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,138
    db 0,229,4,224,7,160,9,128,11,112,10,128,8,160,5,208,0,213,0,121,0,0,0,0,0,0,0,0,0,0,93,0
    db 13,80,9,160,5,192,3,224,1,241,2,240,5,208,8,160,13,64,75,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,1,119,16,60,170,195,4,238,64,60,153,195,0,102,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,48,0
    db 0,9,128,0,0,9,128,0,12,239,238,192,0,9,128,0,0,9,128,0,0,4,48,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,48,13,64
    db 30,0,59,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 63,255,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,7,48,13,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,46
    db 0,106,0,166,0,210,3,208,7,144,11,80,14,16,76,0,136,0,83,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,1,174,214,0,10,177,78,48,30,32,9,144,77,0,6,176,92,0,4,208,77,0,5,192,31,32,9,144
    db 10,161,78,48,1,174,214,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,5,237,0,109,141,0,66,93,0,0,93,0,0,93,0,0,93,0,0,93,0,0,93,0,0,93,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,213,0,12,146,110,32,10,16,13,80
    db 0,0,46,16,0,1,200,0,0,10,176,0,0,156,16,0,8,193,0,0,47,255,255,112,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,214,0,13,146,95,48,6,16,13,80
    db 0,1,110,16,0,63,245,0,0,0,93,80,37,0,8,160,46,113,77,112,5,206,216,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,205,0,0,7,221,0,0,46,93,0
    db 0,183,77,0,5,192,77,0,29,64,77,0,95,255,255,241,0,0,77,0,0,0,77,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,255,255,48,10,112,0,0,12,96,0,0
    db 13,189,214,0,7,98,94,48,0,0,10,128,6,16,10,128,13,145,78,64,3,206,214,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,158,232,0,9,178,61,96,30,32,3,48
    db 61,125,215,0,95,162,78,80,79,16,8,160,31,16,8,160,10,161,78,80,2,174,215,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,64,0,0,62,16,0,0,184,0
    db 0,3,226,0,0,10,144,0,0,62,32,0,0,169,0,0,2,226,0,0,10,160,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,214,0,12,162,95,48,14,64,13,80
    db 10,162,110,16,2,223,246,0,13,113,77,80,77,0,8,160,46,97,76,112,5,206,216,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,213,0,29,129,94,32,78,0,10,128
    db 78,0,10,160,29,129,94,176,3,206,184,144,20,0,10,112,30,113,110,16,4,206,195,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,16,14,112,3,16,0,0,0,0,7,48,13,96
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,32,12,144,2,16,0,0,0,0,4,48,13,64
    db 30,0,59,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,24,128
    db 0,24,234,48,8,234,48,0,12,197,0,0,0,92,197,0,0,0,92,128,0,0,0,32,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,11,255,255,160,0,0,0,0,11,255,255,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,113,0,0
    db 4,190,113,0,0,3,173,112,0,0,93,176,0,109,197,0,10,197,0,0,2,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,238,144,110,50,214,52,0,168,0,5,227,0,94,80
    db 0,184,0,0,66,0,0,115,0,0,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,4,156,185,48,0,0,157,98,54,213,0,6,193,0,0,45,32,13,64,141,170
    db 40,144,46,7,178,111,36,192,76,11,80,13,34,208,76,11,80,13,35,192,30,7,177,95,87,144,11,97,157,165,202,16
    db 2,216,16,0,16,0,0,25,205,220,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,11,224,0,0,46,181,0,0,122,106,0,0,196,30,16,3,208,10,96,8,255,255,176,13,48,0,226
    db 62,0,0,167,154,0,0,108,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,235,32,14,48,43,160,14,48,6,192,14,48,60,112,14,238,252,48,14,48,8,208,14,48,1,243
    db 14,48,23,225,14,255,236,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,92,237,112,0,6,230,38,216,0,14,80,0,61,0,62,0,0,0,0,93,0,0,0,0
    db 62,0,0,0,0,14,80,0,60,0,6,230,37,216,0,0,108,237,128,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,235,32,0,14,48,40,226
    db 0,14,48,0,169,0,14,48,0,92,0,14,48,0,62,0,14,48,0,92,0,14,48,0,169,0,14,48,40,226,0,14
    db 255,218,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,255,96,14,48,0,0,14,48,0,0,14,48,0,0,14,255,255,32,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,255,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,255,96,14,48,0,0,14,48,0,0,14,48,0,0,14,255,254,0,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,108,237,128,0,8,213,37,217,0,30,64,0,58,0,78,0,0,0,0,77,0,63,255,64
    db 47,16,0,15,32,13,112,0,94,0,5,230,37,216,0,0,92,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,0,93,0,14,48,0,93
    db 0,14,48,0,93,0,14,48,0,93,0,14,255,255,253,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14
    db 48,0,93,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48
    db 14,48,14,48,14,48,14,48,14,48,14,48,14,48,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,108,0,0,0,108,0,0,0,108,0,0,0,108,0,0,0,108,0,18,0,108,0,124,0,124,0
    db 63,82,201,0,7,238,161,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,48,4,229,14,48,62,96,14,50,216,0,14,76,144,0,14,206,160,0,14,178,229,0,14,48,110,32
    db 14,48,10,176,14,48,1,214,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,255,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,14,208,0,1,236,0,14,228,0,6,236,0,14,169,0,12,172,0,14,94,16,62
    db 108,0,14,44,96,138,108,0,14,39,176,212,108,0,14,34,229,208,108,0,14,32,173,128,108,0,14,32,95,32,108,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,176,0,63,0,14,229,0,63,0,14,125,16,63,0,14,60,128,63,0,14,51,227,63,0
    db 14,48,156,63,0,14,48,29,143,0,14,48,5,239,0,14,48,0,175,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,237,112,0,6,230,37,216
    db 0,14,80,0,62,32,62,0,0,12,80,93,0,0,11,112,62,0,0,12,80,14,80,0,62,32,6,230,37,217,0,0
    db 92,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,234,32,14,48,43,160,14,48,5,224,14,48,5,224,14,48,43,160,14,255,234,32,14,48,0,0
    db 14,48,0,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,92,237,112,0,6,230,37,216,0,14,80,0,62,32,62,0,0,12,80,93,0,0,11,112
    db 62,0,0,12,80,14,80,122,62,32,6,230,45,232,0,0,92,237,228,0,0,0,0,89,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,235,48,14,48,26,192,14,48,4,224
    db 14,48,26,192,14,255,252,32,14,48,155,0,14,48,47,64,14,48,10,160,14,48,3,243,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,190,234,16,12,146,60,160,31,32,2,80
    db 12,181,0,0,1,125,233,16,0,0,59,176,39,0,3,224,46,114,58,176,4,206,234,32,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,243,0,11,112,0,0,11,112,0
    db 0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,0,93,0,14,48,0,93
    db 0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,13,96,0,124,0,8,213,37,230,0,0
    db 125,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,154,0,0,124,62,16,0,183,13,96,2,242,8,176,7,192,2,225,12,112,0,198,46,16,0,123,123,0
    db 0,30,182,0,0,11,225,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,153,0,13,160,0,199,93,0,46,224,1,242,31,16,106,211,5,208,12,80,167,167
    db 8,144,9,144,211,107,12,96,5,195,224,46,31,16,1,231,160,13,108,0,0,188,96,9,217,0,0,143,32,5,245,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,62,48,1,214,8,192,10,176,0,199,94,32,0,62,214,0,0,11,225,0,0,93,184,0,2,229,62,64
    db 10,160,8,209,109,16,0,200,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,125,16,0,201,12,128,6,225,4,226,30,96,0,170,139,0,0,46,227,0,0,9,176,0,0,8,160,0
    db 0,8,160,0,0,8,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,95,255,255,192,0,0,29,96,0,0,155,0,0,4,226,0,0,29,112,0,0,140,0,0,3,227,0,0
    db 12,112,0,0,79,255,255,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,234
    db 11,96,11,96,11,96,11,96,11,96,11,96,11,96,11,96,11,96,10,234,0,0,0,0,0,0,0,0,0,0,166,0
    db 106,0,46,0,12,48,9,128,5,176,1,225,0,181,0,137,0,60,0,7,0,0,0,0,0,0,0,0,0,0,94,241
    db 0,241,0,241,0,241,0,241,0,241,0,241,0,241,0,241,0,241,94,225,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,1,234,0,8,157,48,30,39,160,88,1,161,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,255,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,80
    db 3,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,7,222,194,0,45,65,170,0,0,2,140,0,25,220,189,0,109,16,109,0
    db 125,17,205,0,26,236,141,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,47,0,0,0,47,0,0,0,47,126,215,0,47,161,62,80,47,32,10,160,47,0,7,176,47,32,10,160
    db 47,161,62,80,46,126,231,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,180,0,13,113,109,16,94,0,1,0,108,0,0,0,94,0,2,0
    db 29,113,94,16,3,206,196,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,10,112,0,0,10,112,4,206,171,112,29,113,111,112,94,0,12,112,108,0,10,112,94,0,12,112
    db 30,112,111,112,4,206,170,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,196,0,13,112,110,16,77,0,13,80,111,238,238,96,92,0,0,0
    db 29,96,77,32,3,206,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,190,9,178
    db 10,128,223,237,10,128,10,128,10,128,10,128,10,128,10,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,206,186,112,29,113,111,112,94,0,13,112,108,0,11,112,94,0,12,112
    db 30,113,111,112,4,206,170,112,0,0,11,96,12,114,110,48,4,189,198,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,47,0,0,0,47,0,0,0,47,109,230,0,47,146,126,16,47,32,14,48,47,0,14,48,47,0,14,48
    db 47,0,14,48,47,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,22,0,61,32
    db 0,0,47,0,47,0,47,0,47,0,47,0,47,0,47,0,0,0,0,0,0,0,0,0,0,0,0,0,22,0,61,32
    db 0,0,47,0,47,0,47,0,47,0,47,0,47,0,47,0,93,0,230,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,47,0,0,0,47,0,0,0,47,0,155,16,47,8,193,0,47,109,32,0,47,236,16,0,47,44,144,0
    db 47,2,230,0,47,0,94,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,0
    db 47,0,47,0,47,0,47,0,47,0,47,0,47,0,47,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,46,126,194,190,177,0,47,130,174,82
    db 215,0,47,16,93,0,137,0,47,0,92,0,137,0,47,0,92,0,137,0,47,0,92,0,137,0,47,0,92,0,137,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,46,109,230,0,47,146,126,16,47,32,14,48,47,0,14,48,47,0,14,48
    db 47,0,14,48,47,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,197,0,13,113,94,32,94,0,12,112,108,0,9,144,94,0,12,112
    db 29,112,94,32,3,206,213,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,46,126,215,0,47,161,62,80,47,32,10,160,47,0,7,176,47,32,10,160
    db 47,161,62,80,47,126,231,0,47,0,0,0,47,0,0,0,21,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,206,186,112,29,113,111,112,94,0,12,112,108,0,10,112,94,0,12,112
    db 30,112,111,112,4,206,171,112,0,0,10,112,0,0,10,112,0,0,4,48,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,46,142,64,47,162,16,47,32,0,47,0,0,47,0,0,47,0,0,47,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,222,161,47,65,149,30,97,0
    db 5,206,162,0,2,185,61,33,170,7,222,178,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,32
    db 14,48,223,232,14,48,14,48,14,48,14,48,12,80,6,217,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,0,14,48,47,0,14,48,47,0,14,48,47,0,14,48,31,16,30,48
    db 14,129,143,48,5,222,125,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,138,0,14,64,62,16,77,0,12,80,153,0,7,160,227,0,2,228,208,0
    db 0,188,128,0,0,111,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,138,0,202,0,213,62,1,221,2,225,14,53,173,38,176
    db 10,121,105,106,112,6,188,37,173,48,1,220,1,221,0,0,201,0,201,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,78,32,140,0
    db 9,162,227,0,1,219,128,0,0,143,16,0,2,234,144,0,11,145,228,0,93,16,109,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,154,0,14,80
    db 62,0,78,0,13,80,153,0,8,160,212,0,3,228,208,0,0,218,144,0,0,143,64,0,0,93,0,0,2,184,0,0
    db 30,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,255,252,0
    db 0,1,214,0,0,10,160,0,0,109,16,0,2,228,0,0,12,144,0,0,95,255,253,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,93,96,0,199,0,0,226,0,0,226,0,5,224,0
    db 63,112,0,4,225,0,0,226,0,0,210,0,0,200,16,0,76,96,0,0,0,0,0,0,3,48,8,128,8,128,8,128
    db 8,128,8,128,8,128,8,128,8,128,8,128,8,128,8,128,8,128,8,128,8,128,0,0,0,0,0,0,0,0,0,0
    db 0,94,96,0,5,208,0,0,240,0,0,240,0,0,215,16,0,78,80,0,213,0,0,240,0,0,240,0,6,208,0,76
    db 80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,6,235,33,176,13,92,182,192,11,3,206,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,1,190,144,0,7,255,243,0,6,255,242,0,0,139,96,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,224,0,0,46,181,0,0,122,106,0
    db 0,196,30,16,3,208,10,96,8,255,255,176,13,48,0,226,62,0,0,167,154,0,0,108,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,255,80,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,235,48,14,48,41,208,14,48,3,241,14,48,41,192,14,255,235,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,235,32,14,48,43,160,14,48,6,192
    db 14,48,60,112,14,238,252,48,14,48,8,208,14,48,1,243,14,48,23,225,14,255,236,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,255,96,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,79,255,255,80,0,92,0,13
    db 80,0,123,0,13,80,0,138,0,13,80,0,152,0,13,80,0,182,0,13,80,0,228,0,13,80,6,208,0,13,80,127
    db 255,255,255,244,122,0,0,0,213,121,0,0,0,180,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,255,96,14,48,0,0,14,48,0,0,14,48,0,0,14,255,255,32,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,255,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,63,64,12,96,11,176,9,192,12,96,78,32,1,229,12,96,200,0,0,109,12,102
    db 209,0,0,31,255,255,144,0,0,154,12,99,226,0,3,226,12,96,155,0,12,128,12,96,30,80,109,16,12,96,7,209
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,3,190,214,0,13,146,95,48,6,16,13,80,0,1,110,16,0,63,245,0,0,0,93,80,37,0,8,160
    db 46,113,77,112,5,206,216,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,48,0,175,0,14,48,5,239,0,14,48,29,127,0,14,48,140,63,0,14,51,227,63,0
    db 14,59,144,63,0,14,141,16,63,0,14,229,0,63,0,14,176,0,63,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,24,8,16,0,0,9,201,0,0,0,0,0,0,0,14,48,0,175,0,14,48,5,239
    db 0,14,48,29,127,0,14,48,140,63,0,14,51,227,63,0,14,59,144,63,0,14,141,16,63,0,14,229,0,63,0,14
    db 176,0,63,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,48,3,228,14,48,29,128,14,48,156,0,14,53,226,0,14,255,144,0,14,52,227,0,14,48,141,16
    db 14,48,11,160,14,48,2,230,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,143,255,254,0,0,168,0,78,0,0,183,0,78,0,0,198,0,78,0,0,213,0,78,0
    db 0,228,0,78,0,1,242,0,78,0,6,208,0,78,0,126,80,0,78,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,208,0,1,236,0
    db 14,228,0,6,236,0,14,169,0,12,172,0,14,94,16,62,108,0,14,44,96,138,108,0,14,39,176,212,108,0,14,34
    db 229,208,108,0,14,32,173,128,108,0,14,32,95,32,108,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,0,93,0,14,48,0,93
    db 0,14,48,0,93,0,14,48,0,93,0,14,255,255,253,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14
    db 48,0,93,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,92,237,112,0,6,230,37,216,0,14,80,0,62,32,62,0,0,12,80,93,0,0,11,112
    db 62,0,0,12,80,14,80,0,62,32,6,230,37,217,0,0,92,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,255,255,253,0,14,48,0,93
    db 0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14
    db 48,0,93,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,255,234,32,14,48,43,160,14,48,5,224,14,48,5,224,14,48,43,160,14,255,234,32,14,48,0,0
    db 14,48,0,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,92,237,112,0,6,230,38,216,0,14,80,0,61,0,62,0,0,0,0,93,0,0,0,0
    db 62,0,0,0,0,14,80,0,60,0,6,230,37,216,0,0,108,237,128,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,243,0,11,112,0,0,11,112,0
    db 0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,11,112,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,139,0,3,242,46,48,9,160,10,160,30,64
    db 3,225,93,0,0,182,183,0,0,91,226,0,0,13,160,0,0,45,64,0,8,232,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,169,0,0,0,91,238,165
    db 0,8,215,186,126,112,30,48,169,4,224,77,0,169,0,227,77,0,169,0,226,30,80,169,6,208,5,234,204,174,80,0
    db 56,220,114,0,0,0,135,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,62,48,1,214,8,192,10,176,0,199,94,32,0,62,214,0,0,11,225,0,0,93,184,0,2,229,62,64
    db 10,160,8,209,109,16,0,200,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,14,48,0,154,0,14,48,0,154,0,14,48,0,154,0,14,48,0,154,0,14,48,0,154,0
    db 14,48,0,154,0,14,48,0,154,0,14,48,0,154,0,14,255,255,255,128,0,0,0,10,128,0,0,0,9,112,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,16,0,198,47,16,0,198,47,16,0,198
    db 31,32,0,198,12,179,38,230,3,206,235,214,0,0,0,198,0,0,0,198,0,0,0,198,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,13,80,11,112
    db 14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48
    db 13,80,11,112,14,48,13,80,11,112,14,255,255,255,255,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,13,80,11,112
    db 14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48,13,80,11,112,14,48
    db 13,80,11,112,14,48,13,80,11,112,14,255,255,255,255,245,0,0,0,0,0,197,0,0,0,0,0,181,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,126,239,48,0,0,0,14,48,0
    db 0,0,14,48,0,0,0,14,48,0,0,0,14,255,236,64,0,14,48,40,224,0,14,48,1,243,0,14,48,24,224,0
    db 14,254,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,14,48,0,0,153,0,14,48,0,0,153,0,14,48,0,0,153,0,14,48,0,0
    db 153,0,14,255,236,64,153,0,14,48,40,224,153,0,14,48,1,242,153,0,14,48,24,224,153,0,14,238,236,64,153,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,48,0,0,14,255,236,64,14,48,40,224,14,48,1,242
    db 14,48,24,224,14,238,236,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,1,158,235,48,0,11,197,40,227,0,62,32,0,154,0,0,0,0,77,0,0,11,255,255,0
    db 0,0,0,62,0,60,32,0,139,0,12,180,39,227,0,2,174,235,48,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,48,5,206,215,0
    db 14,48,110,98,93,128,14,48,229,0,3,226,14,51,224,0,0,197,14,238,208,0,0,183,14,51,224,0,0,197,14,48
    db 229,0,3,226,14,48,110,98,93,144,14,48,6,206,215,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,207,255,160,46,97,8,160,78,0,8,160
    db 31,96,8,160,4,239,255,160,1,228,8,160,8,192,8,160,30,96,8,160,125,0,8,160,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,222,194,0
    db 45,65,170,0,0,2,140,0,25,220,189,0,109,16,109,0,125,17,205,0,26,236,141,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,3,189,202,32,12,64,0,0,75,157,197,0
    db 110,113,110,32,125,0,11,96,107,0,10,128,77,0,12,96,13,112,94,16,3,206,196,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,254,197,0
    db 46,0,125,0,46,1,139,0,47,238,228,0,46,0,62,0,46,0,63,32,47,238,232,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,255,240,47,0,0,47,0,0
    db 47,0,0,47,0,0,47,0,0,47,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,255,255,32,4,192,14,32,6,176,14,32,7,160,14,32,9,128,14,32
    db 30,48,14,32,207,255,255,242,197,0,0,226,180,0,0,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,196,0,13,112,110,16,77,0,13,80,111,238,238,96,92,0,0,0
    db 29,96,77,32,3,206,198,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,78,32,183,6,209,8,176,183,46,64,0,184,183,199,0
    db 0,79,255,224,0,0,200,183,200,0,9,192,183,46,64,94,32,183,5,226,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,222,112,60,19,241,0,5,208
    db 0,142,96,0,1,228,90,18,229,25,222,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,0,63,48,47,0,207,48,47,6,190,48,47,45,62,48,47,168,14,48
    db 47,209,14,48,47,64,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 1,128,113,0,0,140,144,0,0,0,0,0,47,0,63,48,47,0,207,48,47,6,190,48,47,45,62,48,47,168,14,48
    db 47,209,14,48,47,64,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,47,0,125,47,4,227,47,46,96,47,253,0,47,12,128,47,3,229,47,0,110,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,255,255,0
    db 8,144,47,0,9,128,47,0,10,128,47,0,11,96,47,0,30,48,47,0,218,0,47,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,47,176,0,143,96,46,210,0,221,96,46,152,5,204,96,47,77,10,124,96,47,13,78,44,96,47,8,202,12,96,47
    db 2,245,12,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,0,14,48,47,0,14,48,47,0,14,48,47,255,255,48,47,0,14,48
    db 47,0,14,48,47,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,197,0,13,113,94,32,94,0,12,112,108,0,9,144,94,0,12,112
    db 29,112,94,32,3,206,213,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,255,255,48,47,0,14,48,47,0,14,48,47,0,14,48,47,0,14,48
    db 47,0,14,48,47,0,14,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,46,126,215,0,47,161,62,80,47,32,10,160,47,0,7,176,47,32,10,160
    db 47,161,62,80,47,126,231,0,47,0,0,0,47,0,0,0,21,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,3,206,180,0,13,113,109,16,94,0,1,0,108,0,0,0,94,0,2,0
    db 29,113,94,16,3,206,196,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,222,255,232,0,198,0,0,198,0,0,198,0,0,198,0,0,198,0,0,198,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,154,0,14,80
    db 62,0,78,0,13,80,153,0,8,160,212,0,3,228,208,0,0,218,144,0,0,143,64,0,0,93,0,0,2,184,0,0
    db 30,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,160,0,0,7,160,0,3,206,253,80
    db 13,119,180,227,78,7,160,184,108,7,160,138,94,7,160,184,29,119,180,227,3,206,253,80,0,7,160,0,0,7,160,0
    db 0,1,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,78,32,140,0
    db 9,162,227,0,1,219,128,0,0,143,16,0,2,234,144,0,11,145,228,0,93,16,109,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,0,14,48
    db 47,0,14,48,47,0,14,48,47,0,14,48,47,0,14,48,47,0,14,48,47,255,255,224,0,0,2,240,0,0,2,208
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,0,31,0
    db 47,0,31,0,31,16,31,0,13,129,79,0,4,222,223,0,0,0,31,0,0,0,31,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,47,0,168,3,224,47,0,168,3,224,47,0,168,3,224,47,0,168,3,224,47,0,168,3,224,47,0,168,3,224,47
    db 255,255,255,224,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,0,168,3,224,47,0,168,3,224,47,0,168,3,224
    db 47,0,168,3,224,47,0,168,3,224,47,0,168,3,224,47,255,255,255,252,0,0,0,0,92,0,0,0,0,75,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,205,240,0,0
    db 1,240,0,0,1,240,0,0,1,255,253,96,1,240,6,241,1,240,5,225,1,255,253,96,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,47,0,0,62,0,47,0,0,62,0,47,0,0,62,0,47,255,214,62,0,47,0,110,62,0,47,0,94,62,0,47
    db 255,214,62,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,47,0,0,0,47,0,0,0,47,0,0,0,47,255,214,0,47,0,110,16
    db 47,0,94,16,47,255,214,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,7,222,161,0,78,65,186,0,34,0,63,16,0,206,239,48,18,0,63,16
    db 78,49,171,0,7,238,161,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,46,0,76,236,64,46,1,230,22,225,46,6,208,0,214
    db 47,239,176,0,168,46,6,208,0,214,46,1,230,6,225,46,0,76,236,64,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,238,235,0
    db 109,32,107,0,93,16,107,0,25,253,235,0,8,176,107,0,30,64,107,0,139,0,107,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,80,51,0,2,226,152,0,0,0,0,0,14,255,255,96,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,255,32,14,48,0,0,14,48,0,0,14,48,0,0,14,255,255,112,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,64,65,0,5,208,197,0,0,0,0,0,3,206,196,0
    db 13,112,110,16,77,0,13,80,111,238,238,96,92,0,0,0,29,96,77,32,3,206,198,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,80,0,0,13,48,0,0,19,0,0,7,222,194,0
    db 45,65,170,0,0,2,140,0,25,220,189,0,109,16,109,0,125,17,205,0,26,236,141,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,112,0,0,10,112,0,0,4,0,0,3,206,196,0
    db 13,112,110,16,77,0,13,80,111,238,238,96,92,0,0,0,29,96,77,32,3,206,198,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,4,128,11,80,3,0,47,0,47,0,47,0,47,0,47,0,47,0,47,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,128,0,0,9,128,0,0,4,0,0,3,206,197,0
    db 13,113,94,32,94,0,12,112,108,0,9,144,94,0,12,112,29,112,94,32,3,206,213,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,128,0,0,10,96,0,0,3,0,0,47,0,14,48
    db 47,0,14,48,47,0,14,48,47,0,14,48,31,16,30,48,14,129,143,48,5,222,125,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,64,66,0,5,208,198,0,0,0,0,0,47,0,14,48
    db 47,0,14,48,47,0,14,48,47,0,14,48,31,16,30,48,14,129,143,48,5,222,125,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,33,0,1,202,193,0,1,32,0,0,46,109,230,0
    db 47,146,126,16,47,32,14,48,47,0,14,48,47,0,14,48,47,0,14,48,47,0,14,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,117,0,0,2,209,0,0,1,32,0,0,11,224,0,0,46,181,0,0,122,106,0
    db 0,196,30,16,3,208,10,96,8,255,255,176,13,48,0,226,62,0,0,167,154,0,0,108,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,1,145,0,0,7,144,0,0,2,16,0,14,255,255,96,14,48,0,0,14,48,0,0
    db 14,48,0,0,14,255,255,32,14,48,0,0,14,48,0,0,14,48,0,0,14,255,255,112,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,2,144,9,112,3,0,14,48,14,48,14,48,14,48,14,48,14,48,14,48,14,48,14,48
    db 0,0,0,0,0,0,0,0,0,0,39,0,0,0,0,152,0,0,0,0,64,0,0,0,92,237,112,0,6,230,37,216
    db 0,14,80,0,62,32,62,0,0,12,80,93,0,0,11,112,62,0,0,12,80,14,80,0,62,32,6,230,37,217,0,0
    db 92,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,56,0,0,0,0,181
    db 0,0,0,0,48,0,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0
    db 14,48,0,93,0,13,96,0,124,0,8,213,37,230,0,0,125,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,36,4,16,0,0,108,13,80,0,0,0,0,0,0,14,48,0,93,0,14,48,0,93
    db 0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,14,48,0,93,0,13,96,0,124,0,8,213,37,230,0,0
    db 125,237,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,133,32,0,0,39,122
    db 0,0,0,0,0,0,0,14,176,0,63,0,14,229,0,63,0,14,125,16,63,0,14,60,128,63,0,14,51,227,63,0
    db 14,48,156,63,0,14,48,29,143,0,14,48,5,239,0,14,48,0,175,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,93,16,0,40,0,0,20,0
    db 0,109,0,3,231,0,46,96,0,108,0,52,78,50,215,8,238,160,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,13,96,7,48,2,16,13,80,13,80,13,80,13,80,13,80,11,80,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,7,48,71,0,130,13,96,124,1,229,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,32,0,0,0,0,1,213,0,0,0,0,0,61,80,0,0,0,0,2,197,0,8,255,255,254,222,32,0,0
    db 0,3,196,0,0,0,0,93,48,0,0,0,1,195,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,17,0,0,0,0,1,199,0,0,0,0,28,128,0,0,0,1,199,0,0,0,0,9,237,255,255,254,0,1,184
    db 0,0,0,0,0,10,177,0,0,0,0,0,151,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,165,0,0,0,0,11,177,0,4,48,0,187,16,0,6,228,11,177,0,0,0,110
    db 187,16,0,0,0,6,177,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 8,112,8,128,2,215,125,32,0,46,226,0,0,125,215,0,7,210,45,96,4,32,2,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,236,32,61,23,160,61,23,160,8,236,32,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,136,0,0,0,8,221,128,0,0,140,136,200,0,8,210,136,45,112,4,32,136,2,64
    db 0,0,136,0,0,0,0,136,0,0,0,0,136,0,0,0,0,136,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,136,0,0,0,0,136,0
    db 0,0,0,136,0,0,0,0,136,0,0,4,32,136,2,64,8,210,136,45,112,0,140,136,200,0,0,8,221,128,0,0
    db 0,136,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
font_uil:
    db 39,0,0,0,30,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,8,4,0,8,164,4,0,10,103,5,0,16,159,6,0,19,37,8,0,20,171,9,0,30
    db 244,11,0,20,122,13,0,10,61,14,0,11,39,15,0,11,17,16,0,16,73,17,0,20,207,18,0,10,146,19,0,14
    db 163,20,0,10,102,21,0,11,80,22,0,20,214,23,0,13,231,24,0,19,109,26,0,19,243,27,0,20,121,29,0,19
    db 255,30,0,19,133,32,0,17,228,33,0,19,106,35,0,19,240,36,0,10,179,37,0,10,118,38,0,20,252,39,0,20
    db 130,41,0,20,8,43,0,16,64,44,0,30,137,46,0,22,54,48,0,20,188,49,0,22,105,51,0,22,22,53,0,18
    db 117,54,0,18,212,55,0,22,129,57,0,22,46,59,0,8,202,59,0,17,41,61,0,21,214,62,0,17,53,64,0,28
    db 87,66,0,23,43,68,0,23,255,69,0,19,133,71,0,23,89,73,0,20,223,74,0,20,101,76,0,20,235,77,0,22
    db 152,79,0,22,69,81,0,31,181,83,0,22,98,85,0,21,15,87,0,20,149,88,0,11,127,89,0,11,105,90,0,11
    db 83,91,0,14,100,92,0,14,117,93,0,11,95,94,0,17,190,95,0,19,68,97,0,17,163,98,0,19,41,100,0,18
    db 136,101,0,12,114,102,0,19,248,103,0,18,87,105,0,8,243,105,0,8,143,106,0,17,238,107,0,8,138,108,0,27
    db 172,110,0,18,11,112,0,18,106,113,0,19,240,114,0,19,118,116,0,12,96,117,0,16,152,118,0,11,130,119,0,18
    db 225,120,0,18,64,122,0,25,59,124,0,17,154,125,0,18,249,126,0,17,88,128,0,14,105,129,0,11,83,130,0,14
    db 100,131,0,20,234,132,0,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,95,255,208,0,0,79,255,208,0,0,79,255,208,0,0,79,255,208,0
    db 0,79,255,192,0,0,63,255,192,0,0,63,255,192,0,0,63,255,192,0,0,47,255,176,0,0,47,255,176,0,0,47
    db 255,176,0,0,31,255,160,0,0,31,255,160,0,0,31,255,160,0,0,13,221,128,0,0,0,0,0,0,0,0,0,0
    db 0,0,4,152,32,0,0,79,255,208,0,0,159,255,243,0,0,127,255,241,0,0,10,237,96,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,15,255,192,47,255,160,0,0,14,255,176,31,255,160,0,0,14,255,160,15,255,144,0,0
    db 13,255,160,14,255,144,0,0,12,255,144,14,255,128,0,0,12,255,128,13,255,112,0,0,11,255,128,12,255,112,0,0
    db 11,255,112,12,255,96,0,0,9,221,96,10,221,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,240,0,5,255,176,0,0,0,3,255,208,0,7
    db 255,144,0,0,0,5,255,176,0,10,255,96,0,0,0,7,255,144,0,12,255,64,0,0,0,10,255,112,0,14,255,16
    db 0,0,0,12,255,64,0,31,254,0,0,0,239,255,255,255,255,255,255,255,208,2,255,255,255,255,255,255,255,255,176,5
    db 255,255,255,255,255,255,255,255,128,0,0,127,249,0,0,191,244,0,0,0,0,159,247,0,0,239,241,0,0,0,0,207
    db 244,0,2,255,208,0,0,0,0,239,241,0,5,255,176,0,0,78,238,255,254,238,239,255,254,233,0,111,255,255,255,255
    db 255,255,255,247,0,159,255,255,255,255,255,255,255,244,0,0,10,255,96,0,14,255,16,0,0,0,12,255,64,0,47,253
    db 0,0,0,0,14,255,16,0,95,251,0,0,0,0,47,253,0,0,127,249,0,0,0,0,79,251,0,0,159,247,0,0
    db 0,0,127,249,0,0,191,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,28,144,0,0,0
    db 0,0,0,0,0,31,176,0,0,0,0,0,0,0,0,31,176,0,0,0,0,0,0,1,139,239,253,167,16,0,0,0
    db 0,126,255,255,255,255,213,0,0,0,8,255,255,255,255,255,255,80,0,0,79,255,252,143,216,223,255,226,0,0,191,255
    db 144,31,176,27,255,247,0,0,239,255,16,31,176,3,255,251,0,0,239,255,16,31,176,0,51,50,0,0,207,255,144,31
    db 176,0,0,0,0,0,143,255,253,127,176,0,0,0,0,0,12,255,255,255,233,64,0,0,0,0,1,175,255,255,255,254
    db 129,0,0,0,0,4,174,255,255,255,253,48,0,0,0,0,1,95,239,255,255,210,0,0,0,0,0,31,178,142,255,250
    db 0,0,0,0,0,31,176,4,255,254,0,6,170,164,0,31,176,0,223,255,32,6,255,249,0,31,176,1,255,254,0,3
    db 255,255,80,31,176,26,255,252,0,0,191,255,251,127,216,223,255,246,0,0,29,255,255,255,255,255,255,160,0,0,2,175
    db 255,255,255,255,232,16,0,0,0,4,155,239,253,184,32,0,0,0,0,0,0,31,176,0,0,0,0,0,0,0,0,31
    db 176,0,0,0,0,0,0,0,0,27,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,25,206,217,16,0,0,0,0,95,249,0,0,0,0,1,223,255,255,210,0,0,0,2,239,209,0,0
    db 0,0,9,255,200,207,250,0,0,0,10,255,64,0,0,0,0,13,255,16,14,254,0,0,0,111,249,0,0,0,0,0
    db 31,252,0,11,255,32,0,2,239,209,0,0,0,0,0,47,251,0,11,255,32,0,11,255,48,0,0,0,0,0,14,254
    db 0,13,255,16,0,111,248,0,0,0,0,0,0,12,255,113,111,252,0,2,239,192,0,0,0,0,0,0,4,255,255,255
    db 245,0,11,255,48,0,0,0,0,0,0,0,110,255,254,96,0,127,247,0,0,0,0,0,0,0,0,1,87,81,0,3
    db 239,192,0,0,0,0,0,0,0,0,0,0,0,0,12,254,32,0,0,0,0,0,0,0,0,0,0,0,0,143,247,0
    db 1,140,237,162,0,0,0,0,0,0,0,3,255,176,0,28,255,255,254,32,0,0,0,0,0,0,28,254,32,0,143,253
    db 139,255,176,0,0,0,0,0,0,143,246,0,0,223,242,0,239,240,0,0,0,0,0,4,255,160,0,0,255,208,0,191
    db 243,0,0,0,0,0,29,254,32,0,0,255,192,0,175,243,0,0,0,0,0,159,245,0,0,0,239,224,0,207,242,0
    db 0,0,0,4,255,160,0,0,0,191,248,21,255,208,0,0,0,0,29,253,16,0,0,0,63,255,255,255,96,0,0,0
    db 0,175,245,0,0,0,0,5,239,255,231,0,0,0,0,0,0,0,0,0,0,0,0,20,117,32,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,1,156,238,183,0,0,0,0,0,0,78,255,255,255,193,0,0,0,0,1,239,255,255,255,250,0
    db 0,0,0,8,255,249,68,191,255,32,0,0,0,11,255,192,0,31,255,80,0,0,0,13,255,160,0,14,255,96,0,0
    db 0,11,255,224,0,127,255,48,0,0,0,7,255,247,8,255,251,0,0,0,0,1,223,255,207,255,226,0,0,0,0,0
    db 95,255,255,253,48,0,0,0,0,0,29,255,255,161,0,0,0,0,0,4,223,255,255,160,0,4,68,16,0,94,255,253
    db 255,248,0,31,255,80,1,239,255,97,207,255,96,63,255,64,7,255,248,0,29,255,244,143,255,16,10,255,243,0,2,239
    db 254,223,252,0,10,255,243,0,0,62,255,255,247,0,7,255,249,0,0,6,255,255,209,0,2,239,255,165,53,158,255,255
    db 176,0,0,111,255,255,255,255,255,255,248,0,0,7,239,255,255,255,248,175,255,96,0,0,24,189,253,184,32,29,255,244
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,15,255,192,0,0,14,255,176,0,0,14,255,160,0,0,13,255,160,0,0,12,255,144,0,0,12,255,128,0
    db 0,11,255,128,0,0,11,255,112,0,0,9,221,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,52,68,0,0,0,0,223,252,0,0,0,6,255,246,0,0,0,13,255,225,0,0,0,95,255,144,0,0
    db 0,175,255,80,0,0,0,239,254,0,0,0,4,255,250,0,0,0,7,255,247,0,0,0,10,255,244,0,0,0,13,255
    db 241,0,0,0,31,255,208,0,0,0,47,255,192,0,0,0,63,255,176,0,0,0,95,255,160,0,0,0,95,255,160,0
    db 0,0,63,255,176,0,0,0,47,255,192,0,0,0,31,255,224,0,0,0,12,255,242,0,0,0,9,255,246,0,0,0
    db 6,255,250,0,0,0,1,239,254,0,0,0,0,175,255,64,0,0,0,95,255,160,0,0,0,12,255,225,0,0,0,5
    db 255,247,0,0,0,0,207,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,4,68,48,0,0,0,9,255,226,0,0,0,3,255,249,0,0,0,0,207,254
    db 32,0,0,0,127,255,112,0,0,0,47,255,192,0,0,0,12,255,242,0,0,0,8,255,247,0,0,0,4,255,250,0
    db 0,0,1,255,253,0,0,0,0,223,255,16,0,0,0,191,255,48,0,0,0,175,255,80,0,0,0,159,255,96,0,0
    db 0,143,255,112,0,0,0,127,255,112,0,0,0,143,255,96,0,0,0,159,255,80,0,0,0,191,255,48,0,0,0,239
    db 254,0,0,0,3,255,252,0,0,0,7,255,248,0,0,0,12,255,243,0,0,0,47,255,192,0,0,0,127,255,112,0
    db 0,0,223,254,16,0,0,5,255,248,0,0,0,11,255,225,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,246,0,0,0,0,0,0,63,245,0,0
    db 0,0,28,96,47,244,4,210,0,0,143,251,47,244,159,250,0,0,126,255,239,254,255,232,0,0,1,126,255,255,232,16
    db 0,0,0,42,255,255,196,0,0,0,58,255,255,255,255,180,0,0,175,254,111,247,223,253,0,0,46,162,31,244,25,245
    db 0,0,3,0,47,245,0,48,0,0,0,0,63,246,0,0,0,0,0,0,21,82,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,142,235,0,0,0,0,0
    db 0,0,0,159,252,0,0,0,0,0,0,0,0,159,252,0,0,0,0,0,0,0,0,159,252,0,0,0,0,0,0,0
    db 0,159,252,0,0,0,0,0,18,34,34,175,252,34,34,33,0,0,95,255,255,255,255,255,255,248,0,0,95,255,255,255
    db 255,255,255,248,0,0,95,255,255,255,255,255,255,248,0,0,0,0,0,159,252,0,0,0,0,0,0,0,0,159,252,0
    db 0,0,0,0,0,0,0,159,252,0,0,0,0,0,0,0,0,159,252,0,0,0,0,0,0,0,0,159,252,0,0,0
    db 0,0,0,0,0,141,218,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,255,208,0,0,63,255,144,0
    db 0,95,255,80,0,0,143,255,16,0,0,175,251,0,0,0,207,247,0,0,0,223,243,0,0,1,255,208,0,0,3,221
    db 128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,239,255,255,255,253,0,0,239
    db 255,255,255,253,0,0,239,255,255,255,253,0,0,51,51,51,51,51,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,5,168,16,0,0,79,255,192,0,0,159,255,242,0,0,111,255,224,0,0,10,237,80,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,255,176,0,0,0,14,255,128,0,0,0,63
    db 255,64,0,0,0,127,254,0,0,0,0,191,250,0,0,0,0,239,247,0,0,0,4,255,242,0,0,0,8,255,208,0
    db 0,0,12,255,144,0,0,0,31,255,80,0,0,0,111,255,16,0,0,0,159,252,0,0,0,0,223,248,0,0,0,2
    db 255,244,0,0,0,7,255,224,0,0,0,10,255,176,0,0,0,14,255,112,0,0,0,79,255,48,0,0,0,143,253,0
    db 0,0,0,207,250,0,0,0,1,255,246,0,0,0,5,255,242,0,0,0,9,255,208,0,0,0,13,255,144,0,0,0
    db 47,255,80,0,0,0,111,255,16,0,0,0,35,50,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,90,222,237,147,0,0,0,0,0,43,255,255,255,255,144,0,0,0,1,223,255,255,255,255,250,0,0,0,10
    db 255,255,150,107,255,255,112,0,0,79,255,246,0,0,159,255,225,0,0,175,255,144,0,0,12,255,247,0,0,239,255,48
    db 0,0,7,255,251,0,3,255,253,0,0,0,2,255,254,0,6,255,251,0,0,0,0,239,255,32,7,255,249,0,0,0
    db 0,223,255,64,8,255,248,0,0,0,0,191,255,80,8,255,248,0,0,0,0,191,255,80,7,255,249,0,0,0,0,223
    db 255,64,6,255,251,0,0,0,0,239,255,32,3,255,253,0,0,0,2,255,254,0,0,239,255,48,0,0,7,255,252,0
    db 0,175,255,144,0,0,12,255,247,0,0,79,255,246,0,0,159,255,225,0,0,11,255,255,150,107,255,255,112,0,0,2
    db 223,255,255,255,255,251,0,0,0,0,43,255,255,255,255,161,0,0,0,0,0,90,223,237,148,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,255,255,128,0,0,3,207,255,255,128,0,0,110,255,255
    db 255,128,0,8,255,255,207,255,128,0,10,255,212,127,255,128,0,10,250,16,127,255,128,0,9,96,0,127,255,128,0,1
    db 0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255
    db 128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0
    db 0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128,0,0,0,0,127,255,128
    db 0,0,0,0,127,255,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,155,222,202,96,0,0
    db 0,0,1,142,255,255,255,252,64,0,0,0,9,255,255,255,255,255,227,0,0,0,95,255,250,101,142,255,252,0,0,0
    db 207,255,96,0,2,223,255,80,0,1,255,253,0,0,0,127,255,128,0,2,204,201,0,0,0,95,255,144,0,0,0,0
    db 0,0,0,127,255,112,0,0,0,0,0,0,0,207,255,48,0,0,0,0,0,0,7,255,250,0,0,0,0,0,0,0
    db 95,255,226,0,0,0,0,0,0,4,239,255,80,0,0,0,0,0,0,78,255,247,0,0,0,0,0,0,5,239,255,112
    db 0,0,0,0,0,0,95,255,247,0,0,0,0,0,0,5,255,255,112,0,0,0,0,0,0,111,255,247,0,0,0,0
    db 0,0,6,255,255,128,0,0,0,0,0,0,111,255,251,85,85,85,85,64,0,1,255,255,255,255,255,255,255,208,0,1
    db 255,255,255,255,255,255,255,208,0,1,255,255,255,255,255,255,255,208,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1
    db 139,222,219,130,0,0,0,0,0,126,255,255,255,254,112,0,0,0,7,255,255,255,255,255,247,0,0,0,95,255,251,100
    db 107,255,255,48,0,0,191,255,112,0,0,159,255,144,0,0,222,237,0,0,0,63,255,192,0,0,0,0,0,0,0,63
    db 255,176,0,0,0,0,0,0,0,159,255,112,0,0,0,0,0,1,74,255,252,0,0,0,0,0,12,255,255,255,161,0
    db 0,0,0,0,12,255,255,247,16,0,0,0,0,0,12,255,255,255,248,0,0,0,0,0,1,18,73,239,255,144,0,0
    db 0,0,0,0,0,79,255,243,0,0,0,0,0,0,0,11,255,247,0,2,68,66,0,0,0,8,255,249,0,6,255,251
    db 0,0,0,11,255,248,0,2,255,255,96,0,0,111,255,244,0,0,175,255,251,118,123,255,255,176,0,0,28,255,255,255
    db 255,255,253,16,0,0,2,175,255,255,255,255,162,0,0,0,0,3,155,223,219,147,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,143,255,251,0,0,0,0,0,0,3,255,255,251,0,0,0,0,0,0,11,255,255,251,0
    db 0,0,0,0,0,111,255,255,251,0,0,0,0,0,1,239,253,255,251,0,0,0,0,0,10,255,244,255,251,0,0,0
    db 0,0,79,255,144,255,251,0,0,0,0,0,223,254,16,255,251,0,0,0,0,8,255,246,0,255,251,0,0,0,0,62
    db 255,176,0,255,251,0,0,0,0,191,255,48,0,255,251,0,0,0,6,255,248,0,0,255,251,0,0,0,30,255,209,0
    db 0,255,251,0,0,0,159,255,80,0,0,255,251,0,0,4,255,252,68,68,68,255,252,68,32,7,255,255,255,255,255,255
    db 255,255,144,7,255,255,255,255,255,255,255,255,144,7,255,255,255,255,255,255,255,255,144,0,0,0,0,0,1,255,251,0
    db 0,0,0,0,0,0,1,255,251,0,0,0,0,0,0,0,1,255,251,0,0,0,0,0,0,0,1,255,251,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,8,255,255,255,255,255,255,64,0,0,10,255,255,255,255,255,255,64,0,0,11,255
    db 255,255,255,255,255,64,0,0,12,255,213,85,85,85,85,16,0,0,14,255,176,0,0,0,0,0,0,0,15,255,144,0
    db 0,0,0,0,0,0,47,255,112,0,0,0,0,0,0,0,79,255,100,173,254,181,0,0,0,0,111,255,191,255,255,255
    db 145,0,0,0,127,255,255,255,255,255,250,0,0,0,143,255,232,66,91,255,255,80,0,0,1,70,48,0,0,159,255,208
    db 0,0,0,0,0,0,0,29,255,242,0,0,0,0,0,0,0,10,255,245,0,0,0,0,0,0,0,8,255,246,0,0
    db 86,101,0,0,0,10,255,244,0,0,223,255,16,0,0,30,255,242,0,0,175,255,160,0,0,159,255,176,0,0,63,255
    db 252,100,108,255,254,48,0,0,6,255,255,255,255,255,247,0,0,0,0,126,255,255,255,253,80,0,0,0,0,1,139,223
    db 236,129,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,57,222,236,163,0,0,0,0,0,8,255,255,255,255
    db 145,0,0,0,0,175,255,255,255,255,251,0,0,0,7,255,255,184,139,255,255,128,0,0,30,255,248,0,0,111,255,224
    db 0,0,127,255,144,0,0,11,255,244,0,0,207,255,48,0,0,3,85,83,0,1,255,252,0,0,0,0,0,0,0,4
    db 255,249,2,141,238,200,16,0,0,6,255,248,94,255,255,255,212,0,0,7,255,249,255,255,255,255,254,32,0,8,255,255
    db 252,82,55,239,255,176,0,8,255,255,176,0,0,46,255,245,0,7,255,255,32,0,0,7,255,249,0,5,255,253,0,0
    db 0,4,255,250,0,2,255,253,0,0,0,5,255,250,0,0,223,255,48,0,0,9,255,248,0,0,127,255,193,0,0,79
    db 255,243,0,0,29,255,254,116,89,255,255,128,0,0,3,239,255,255,255,255,252,0,0,0,0,61,255,255,255,255,145,0
    db 0,0,0,0,107,239,237,163,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,255,255,255,255,255,16,12,255,255,255,255,255,255,255,16,12
    db 255,255,255,255,255,255,255,16,4,85,85,85,85,86,255,254,16,0,0,0,0,0,9,255,248,0,0,0,0,0,0,46
    db 255,225,0,0,0,0,0,0,159,255,128,0,0,0,0,0,2,239,254,16,0,0,0,0,0,9,255,248,0,0,0,0
    db 0,0,46,255,226,0,0,0,0,0,0,159,255,128,0,0,0,0,0,2,239,254,32,0,0,0,0,0,9,255,249,0
    db 0,0,0,0,0,46,255,226,0,0,0,0,0,0,159,255,144,0,0,0,0,0,2,239,254,32,0,0,0,0,0,9
    db 255,249,0,0,0,0,0,0,46,255,226,0,0,0,0,0,0,159,255,144,0,0,0,0,0,2,239,254,32,0,0,0
    db 0,0,9,255,249,0,0,0,0,0,0,46,255,226,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,139,222,219,130,0,0,0,0,0
    db 126,255,255,255,254,128,0,0,0,6,255,255,255,255,255,249,0,0,0,63,255,251,82,73,255,255,80,0,0,159,255,160
    db 0,0,143,255,176,0,0,191,255,64,0,0,31,255,208,0,0,159,255,64,0,0,31,255,176,0,0,95,255,144,0,0
    db 127,255,128,0,0,11,255,249,48,40,255,253,16,0,0,1,175,255,255,255,255,178,0,0,0,0,24,255,255,255,250,32
    db 0,0,0,5,239,255,255,255,255,247,0,0,0,95,255,249,49,56,239,255,128,0,1,223,255,96,0,0,79,255,226,0
    db 5,255,252,0,0,0,10,255,247,0,7,255,249,0,0,0,7,255,250,0,7,255,251,0,0,0,9,255,250,0,4,255
    db 255,64,0,0,62,255,247,0,0,207,255,232,49,55,239,255,225,0,0,29,255,255,255,255,255,254,80,0,0,2,175,255
    db 255,255,255,180,0,0,0,0,3,155,223,220,164,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,156,239,235
    db 113,0,0,0,0,0,126,255,255,255,254,80,0,0,0,10,255,255,255,255,255,245,0,0,0,111,255,251,101,125,255,254
    db 32,0,1,239,255,112,0,1,175,255,144,0,5,255,251,0,0,0,30,255,225,0,7,255,247,0,0,0,11,255,245,0
    db 8,255,247,0,0,0,10,255,248,0,6,255,250,0,0,0,13,255,249,0,2,255,255,64,0,0,159,255,250,0,0,159
    db 255,232,49,75,255,255,250,0,0,29,255,255,255,255,249,255,250,0,0,3,207,255,255,255,133,255,249,0,0,0,7,206
    db 253,163,6,255,246,0,0,0,0,0,0,0,9,255,243,0,2,102,100,0,0,0,30,255,224,0,2,255,253,0,0,0
    db 127,255,144,0,0,207,255,144,0,5,255,255,48,0,0,95,255,252,135,175,255,249,0,0,0,9,255,255,255,255,255,193
    db 0,0,0,0,142,255,255,255,250,16,0,0,0,0,2,155,238,218,64,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,8,203,48,0,0,111,255,208,0
    db 0,159,255,242,0,0,95,255,208,0,0,7,202,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,168,16,0,0,79,255,192,0,0,159,255,242,0,0,111,255,224
    db 0,0,10,237,80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,222,128,0,0,47
    db 255,244,0,0,79,255,247,0,0,29,255,227,0,0,2,154,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,170,144,0,0,47,255,176,0,0
    db 95,255,112,0,0,127,255,32,0,0,159,253,0,0,0,191,249,0,0,0,223,245,0,0,0,255,224,0,0,2,255,176
    db 0,0,1,68,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5
    db 193,0,0,0,0,0,0,0,6,223,241,0,0,0,0,0,0,23,223,255,241,0,0,0,0,0,40,239,255,255,225,0
    db 0,0,0,57,239,255,255,215,16,0,0,0,58,255,255,255,197,0,0,0,0,75,255,255,254,163,0,0,0,0,0,159
    db 255,253,130,0,0,0,0,0,0,159,255,230,0,0,0,0,0,0,0,143,255,255,216,32,0,0,0,0,0,5,191,255
    db 255,234,48,0,0,0,0,0,4,175,255,255,252,80,0,0,0,0,0,3,159,255,255,253,128,0,0,0,0,0,2,142
    db 255,255,241,0,0,0,0,0,0,1,125,255,241,0,0,0,0,0,0,0,0,109,241,0,0,0,0,0,0,0,0,0
    db 80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,255,255
    db 255,255,255,255,243,0,0,15,255,255,255,255,255,255,243,0,0,15,255,255,255,255,255,255,243,0,0,5,85,85,85,85
    db 85,85,81,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,15,255,255,255,255,255,255,243,0,0,15,255,255,255,255,255,255,243,0,0,15,255,255,255,255,255,255,243,0
    db 0,5,85,85,85,85,85,85,81,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,11,97,0,0,0,0,0,0,0,0,13,254,129,0,0,0,0,0,0,0,13,255,254,146,0,0,0
    db 0,0,0,12,255,255,255,163,0,0,0,0,0,1,108,255,255,255,164,0,0,0,0,0,0,74,255,255,255,181,0,0
    db 0,0,0,0,40,239,255,255,197,0,0,0,0,0,0,22,207,255,251,0,0,0,0,0,0,0,77,255,251,0,0,0
    db 0,0,1,109,255,255,250,0,0,0,0,2,158,255,255,252,96,0,0,0,4,175,255,255,252,80,0,0,0,6,207,255
    db 255,251,64,0,0,0,0,13,255,255,250,48,0,0,0,0,0,13,255,233,32,0,0,0,0,0,0,13,232,16,0,0
    db 0,0,0,0,0,5,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,58,206,236,164,0,0,0,10,255,255,255,255,161,0,0,159,255,255,255,255,250,0
    db 5,255,255,148,73,255,255,96,10,255,247,0,0,143,255,144,12,255,241,0,0,63,255,192,1,17,16,0,0,63,255,192
    db 0,0,0,0,0,175,255,144,0,0,0,0,9,255,255,48,0,0,0,3,207,255,247,0,0,0,0,62,255,254,96,0
    db 0,0,0,191,255,178,0,0,0,0,2,255,252,16,0,0,0,0,4,255,246,0,0,0,0,0,5,255,244,0,0,0
    db 0,0,2,68,65,0,0,0,0,0,0,0,0,0,0,0,0,0,0,121,96,0,0,0,0,0,9,255,248,0,0,0
    db 0,0,14,255,252,0,0,0,0,0,12,255,251,0,0,0,0,0,3,206,194,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,2,106,205,239,237,183,48,0,0,0,0,0,0,0,3,175,255,255,255,255,255
    db 252,80,0,0,0,0,0,0,159,255,255,255,254,255,255,255,251,32,0,0,0,0,27,255,255,200,66,0,2,89,239,255
    db 227,0,0,0,0,175,255,212,0,0,0,0,0,23,255,253,32,0,0,7,255,251,16,0,0,0,0,0,0,78,255,176
    db 0,0,30,255,193,0,3,173,237,146,106,163,5,255,244,0,0,127,255,48,0,110,255,255,254,191,245,0,191,251,0,0
    db 207,251,0,5,255,255,255,255,255,245,0,95,254,16,1,255,246,0,13,255,213,18,110,255,245,0,31,255,64,5,255,242
    db 0,111,254,16,0,5,255,245,0,13,255,96,6,255,224,0,159,247,0,0,0,223,245,0,12,255,112,7,255,208,0,191
    db 244,0,0,0,191,245,0,11,255,112,8,255,208,0,207,243,0,0,0,191,245,0,12,255,96,7,255,208,0,175,245,0
    db 0,0,207,245,0,13,255,64,6,255,224,0,159,248,0,0,1,239,245,0,31,255,32,5,255,242,0,111,254,16,0,7
    db 255,246,0,95,251,0,1,255,246,0,13,255,213,19,143,255,252,52,223,247,0,0,207,251,0,6,255,255,255,255,207,255
    db 255,255,209,0,0,143,255,48,0,110,255,255,253,41,255,255,253,48,0,0,30,255,193,0,3,156,203,113,0,56,153,96
    db 0,0,0,8,255,251,16,0,0,0,0,0,0,0,0,0,0,0,0,191,255,213,0,0,0,0,0,0,0,0,0,0
    db 0,0,28,255,255,216,82,16,19,87,186,0,0,0,0,0,0,0,159,255,255,255,255,255,255,255,16,0,0,0,0,0
    db 0,4,175,255,255,255,255,255,254,80,0,0,0,0,0,0,0,2,106,205,239,236,185,81,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,223,255,248,0,0,0,0,0,0,0,3,255,255,253,0,0,0,0,0,0,0,9,255,255,255,64,0
    db 0,0,0,0,0,13,255,207,255,144,0,0,0,0,0,0,79,255,125,255,224,0,0,0,0,0,0,159,255,57,255,245
    db 0,0,0,0,0,0,239,253,4,255,250,0,0,0,0,0,5,255,249,0,239,254,16,0,0,0,0,10,255,245,0,175
    db 255,96,0,0,0,0,30,255,225,0,111,255,176,0,0,0,0,95,255,176,0,30,255,241,0,0,0,0,175,255,96,0
    db 10,255,247,0,0,0,1,239,254,16,0,5,255,252,0,0,0,6,255,255,255,255,255,255,255,32,0,0,11,255,255,255
    db 255,255,255,255,112,0,0,31,255,255,255,255,255,255,255,192,0,0,127,255,179,51,51,51,62,255,243,0,0,191,255,112
    db 0,0,0,10,255,248,0,2,255,255,32,0,0,0,5,255,253,0,7,255,252,0,0,0,0,1,239,255,64,12,255,248
    db 0,0,0,0,0,191,255,144,47,255,243,0,0,0,0,0,111,255,224,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,223,255,255,255,253,185,48,0,0,0,223,255,255,255,255,255,249,0,0,0,223,255,255,255,255
    db 255,255,128,0,0,223,255,101,85,104,239,255,243,0,0,223,255,32,0,0,29,255,246,0,0,223,255,32,0,0,8,255
    db 249,0,0,223,255,32,0,0,7,255,247,0,0,223,255,32,0,0,11,255,243,0,0,223,255,32,0,2,175,255,144,0
    db 0,223,255,221,221,223,255,231,0,0,0,223,255,255,255,255,254,115,0,0,0,223,255,255,255,255,255,255,112,0,0,223
    db 255,32,0,19,143,255,246,0,0,223,255,32,0,0,5,255,254,16,0,223,255,32,0,0,0,207,255,64,0,223,255,32
    db 0,0,0,175,255,96,0,223,255,32,0,0,0,191,255,96,0,223,255,32,0,0,5,255,255,48,0,223,255,101,85,87
    db 175,255,253,0,0,223,255,255,255,255,255,255,244,0,0,223,255,255,255,255,255,253,80,0,0,223,255,255,255,254,203,113
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,156,239,236,147,0,0,0,0
    db 0,3,191,255,255,255,255,162,0,0,0,0,78,255,255,255,255,255,254,48,0,0,3,239,255,254,185,173,255,255,210,0
    db 0,12,255,255,128,0,0,110,255,251,0,0,111,255,244,0,0,0,4,255,255,48,0,207,255,144,0,0,0,0,175,255
    db 128,1,255,254,32,0,0,0,0,56,136,80,5,255,252,0,0,0,0,0,0,0,0,7,255,250,0,0,0,0,0,0
    db 0,0,8,255,248,0,0,0,0,0,0,0,0,8,255,248,0,0,0,0,0,0,0,0,7,255,250,0,0,0,0,0
    db 0,0,0,5,255,252,0,0,0,0,0,0,0,0,1,255,254,32,0,0,0,0,55,119,80,0,207,255,144,0,0,0
    db 0,175,255,128,0,111,255,244,0,0,0,4,255,255,48,0,13,255,255,112,0,0,110,255,250,0,0,3,239,255,254,185
    db 173,255,255,209,0,0,0,94,255,255,255,255,255,254,48,0,0,0,3,191,255,255,255,255,145,0,0,0,0,0,4,157
    db 239,236,147,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,223,255,255,255,237,183,32,0,0,0,0,223,255,255,255,255,255,233,16,0,0,0,223,255,255,255,255,255,255,194
    db 0,0,0,223,255,135,119,155,239,255,252,16,0,0,223,255,32,0,0,26,255,255,144,0,0,223,255,32,0,0,0,111
    db 255,226,0,0,223,255,32,0,0,0,12,255,247,0,0,223,255,32,0,0,0,5,255,251,0,0,223,255,32,0,0,0
    db 1,255,254,0,0,223,255,32,0,0,0,0,239,255,16,0,223,255,32,0,0,0,0,207,255,32,0,223,255,32,0,0
    db 0,0,207,255,32,0,223,255,32,0,0,0,0,239,255,16,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0
    db 0,0,5,255,251,0,0,223,255,32,0,0,0,12,255,247,0,0,223,255,32,0,0,0,127,255,225,0,0,223,255,32
    db 0,0,26,255,255,144,0,0,223,255,118,103,155,239,255,252,0,0,0,223,255,255,255,255,255,255,194,0,0,0,223,255
    db 255,255,255,255,232,16,0,0,0,223,255,255,255,237,183,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223
    db 255,255,255,255,255,255,96,0,223,255,255,255,255,255,255,96,0,223,255,255,255,255,255,255,96,0,223,255,101,85,85,85
    db 85,32,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255
    db 32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,255,255,255,255,250,0,0,223,255,255,255,255,255,250
    db 0,0,223,255,255,255,255,255,250,0,0,223,255,101,85,85,85,83,0,0,223,255,32,0,0,0,0,0,0,223,255,32
    db 0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0
    db 0,223,255,101,85,85,85,85,32,0,223,255,255,255,255,255,255,112,0,223,255,255,255,255,255,255,112,0,223,255,255,255
    db 255,255,255,112,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255
    db 255,255,255,255,255,48,0,223,255,255,255,255,255,255,48,0,223,255,255,255,255,255,255,48,0,223,255,101,85,85,85,85
    db 16,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32
    db 0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,255,255,255,255,244,0
    db 0,223,255,255,255,255,255,244,0,0,223,255,255,255,255,255,244,0,0,223,255,101,85,85,85,81,0,0,223,255,32,0
    db 0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0
    db 223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,156,239,236,147,0,0,0,0,0,2,175,255,255,255,255,146
    db 0,0,0,0,62,255,255,255,255,255,254,32,0,0,2,239,255,254,169,189,255,255,209,0,0,11,255,255,128,0,0,127
    db 255,250,0,0,79,255,246,0,0,0,6,255,255,48,0,191,255,176,0,0,0,0,191,255,128,0,239,255,48,0,0,0
    db 0,55,119,80,4,255,253,0,0,0,0,0,0,0,0,6,255,251,0,0,0,0,0,0,0,0,7,255,249,0,0,0
    db 17,17,17,17,16,8,255,248,0,0,0,255,255,255,255,208,7,255,249,0,0,0,255,255,255,255,208,6,255,251,0,0
    db 0,255,255,255,255,208,2,255,254,16,0,0,0,0,31,255,192,0,223,255,128,0,0,0,0,95,255,160,0,127,255,227
    db 0,0,0,1,207,255,96,0,29,255,254,96,0,0,59,255,253,16,0,4,255,255,253,185,172,255,255,245,0,0,0,94
    db 255,255,255,255,255,255,96,0,0,0,3,207,255,255,255,255,212,0,0,0,0,0,4,156,239,237,165,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,32,0,0,0
    db 0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0
    db 0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0
    db 0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,255
    db 255,255,255,255,255,255,48,0,223,255,255,255,255,255,255,255,255,48,0,223,255,255,255,255,255,255,255,255,48,0,223,255
    db 101,85,85,85,85,223,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223
    db 255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0
    db 223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48,0,223,255,32,0,0,0,0,207,255,48
    db 0,223,255,32,0,0,0,0,207,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223
    db 255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223
    db 255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223,255,32,0,223
    db 255,32,0,223,255,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0
    db 11,255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0
    db 0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11
    db 255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,0,0
    db 0,0,0,11,255,244,0,0,0,0,0,0,11,255,244,0,13,238,225,0,0,11,255,244,0,13,255,242,0,0,11,255
    db 243,0,10,255,244,0,0,13,255,240,0,8,255,251,0,0,95,255,208,0,3,255,255,182,88,255,255,128,0,0,143,255
    db 255,255,255,252,0,0,0,9,255,255,255,255,179,0,0,0,0,57,206,236,166,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,223,255,32,0,0,0,78,255,251,0,0,223,255,32,0,0,2,239,255,193,0,0,223,255,32,0,0,29,255,253
    db 32,0,0,223,255,32,0,0,191,255,227,0,0,0,223,255,32,0,10,255,255,64,0,0,0,223,255,32,0,143,255,246
    db 0,0,0,0,223,255,32,6,255,255,128,0,0,0,0,223,255,32,79,255,249,0,0,0,0,0,223,255,34,239,255,176
    db 0,0,0,0,0,223,255,44,255,254,16,0,0,0,0,0,223,255,143,255,255,128,0,0,0,0,0,223,255,255,255,255
    db 243,0,0,0,0,0,223,255,255,187,255,252,0,0,0,0,0,223,255,252,18,239,255,128,0,0,0,0,223,255,210,0
    db 111,255,244,0,0,0,0,223,255,48,0,11,255,253,16,0,0,0,223,255,32,0,2,239,255,144,0,0,0,223,255,32
    db 0,0,111,255,244,0,0,0,223,255,32,0,0,10,255,253,16,0,0,223,255,32,0,0,2,239,255,160,0,0,223,255
    db 32,0,0,0,95,255,245,0,0,223,255,32,0,0,0,10,255,254,32,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223
    db 255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0
    db 0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255
    db 32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0
    db 0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32
    db 0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,223,255,32,0,0,0,0,0
    db 0,223,255,101,85,85,85,84,0,0,223,255,255,255,255,255,252,0,0,223,255,255,255,255,255,252,0,0,223,255,255,255
    db 255,255,252,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,223,255,255,80,0,0,0,0,10,255,255,248,0,0,223,255,255,160,0,0,0,0,30,255,255,248
    db 0,0,223,255,255,225,0,0,0,0,111,255,255,248,0,0,223,255,255,246,0,0,0,0,191,255,255,248,0,0,223,254
    db 223,251,0,0,0,2,255,252,255,248,0,0,223,254,175,255,32,0,0,7,255,248,255,248,0,0,223,254,95,255,128,0
    db 0,12,255,214,255,248,0,0,223,255,31,255,208,0,0,63,255,151,255,248,0,0,223,255,11,255,243,0,0,143,255,87
    db 255,248,0,0,223,255,7,255,249,0,0,223,254,23,255,248,0,0,223,255,18,255,254,0,4,255,250,7,255,248,0,0
    db 223,255,16,191,255,80,9,255,245,7,255,248,0,0,223,255,16,111,255,144,13,255,224,7,255,248,0,0,223,255,16,30
    db 255,208,63,255,144,7,255,248,0,0,223,255,16,10,255,242,127,255,64,7,255,248,0,0,223,255,16,4,255,246,175,253
    db 0,7,255,248,0,0,223,255,16,0,223,250,239,248,0,7,255,248,0,0,223,255,16,0,143,254,255,243,0,7,255,248
    db 0,0,223,255,16,0,63,255,255,192,0,7,255,248,0,0,223,255,16,0,12,255,255,112,0,7,255,248,0,0,223,255
    db 16,0,7,255,255,16,0,7,255,248,0,0,223,255,16,0,1,239,251,0,0,7,255,248,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,209,0,0,0,0,127
    db 255,144,0,0,223,255,249,0,0,0,0,127,255,144,0,0,223,255,255,48,0,0,0,127,255,144,0,0,223,255,255,192
    db 0,0,0,127,255,144,0,0,223,255,255,247,0,0,0,127,255,144,0,0,223,254,207,254,32,0,0,127,255,144,0,0
    db 223,255,95,255,160,0,0,127,255,144,0,0,223,255,27,255,245,0,0,127,255,144,0,0,223,255,36,255,253,16,0,127
    db 255,144,0,0,223,255,48,175,255,144,0,127,255,144,0,0,223,255,48,46,255,243,0,127,255,144,0,0,223,255,48,7
    db 255,252,0,127,255,144,0,0,223,255,48,0,207,255,96,127,255,144,0,0,223,255,48,0,79,255,225,111,255,144,0,0
    db 223,255,48,0,9,255,248,111,255,144,0,0,223,255,48,0,1,223,254,111,255,144,0,0,223,255,48,0,0,95,255,191
    db 255,144,0,0,223,255,48,0,0,11,255,255,255,144,0,0,223,255,48,0,0,2,239,255,255,144,0,0,223,255,48,0
    db 0,0,127,255,255,144,0,0,223,255,48,0,0,0,12,255,255,144,0,0,223,255,48,0,0,0,4,255,255,144,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,156,239,236,148,0,0,0,0,0,0,2,191,255,255,255,255,179
    db 0,0,0,0,0,78,255,255,255,255,255,254,80,0,0,0,3,239,255,254,185,190,255,255,227,0,0,0,12,255,255,112
    db 0,0,127,255,253,0,0,0,95,255,244,0,0,0,4,255,255,96,0,0,207,255,144,0,0,0,0,159,255,192,0,1
    db 255,254,32,0,0,0,0,46,255,242,0,5,255,252,0,0,0,0,0,12,255,246,0,7,255,250,0,0,0,0,0,10
    db 255,247,0,8,255,248,0,0,0,0,0,8,255,248,0,8,255,248,0,0,0,0,0,8,255,248,0,7,255,250,0,0
    db 0,0,0,10,255,247,0,5,255,252,0,0,0,0,0,12,255,246,0,1,255,254,32,0,0,0,0,30,255,242,0,0
    db 207,255,144,0,0,0,0,159,255,192,0,0,111,255,244,0,0,0,3,255,255,96,0,0,12,255,255,112,0,0,126,255
    db 253,0,0,0,3,239,255,254,185,190,255,255,227,0,0,0,0,78,255,255,255,255,255,254,80,0,0,0,0,3,191,255
    db 255,255,255,179,0,0,0,0,0,0,4,156,239,237,148,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,255,255,254,200,16,0,0,0,223,255,255,255,255,255
    db 230,0,0,0,223,255,255,255,255,255,255,112,0,0,223,255,101,85,121,239,255,226,0,0,223,255,32,0,0,45,255,249
    db 0,0,223,255,32,0,0,5,255,252,0,0,223,255,32,0,0,1,255,254,0,0,223,255,32,0,0,1,255,255,0,0
    db 223,255,32,0,0,4,255,254,0,0,223,255,32,0,0,11,255,251,0,0,223,255,32,0,37,207,255,244,0,0,223,255
    db 255,255,255,255,255,144,0,0,223,255,255,255,255,255,249,16,0,0,223,255,255,255,255,251,48,0,0,0,223,255,84,68
    db 67,16,0,0,0,0,223,255,32,0,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,0,223,255,32,0,0,0
    db 0,0,0,0,223,255,32,0,0,0,0,0,0,0,223,255,32,0,0,0,0,0,0,0,223,255,32,0,0,0,0,0
    db 0,0,223,255,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,4,156,239,236,148,0,0,0,0,0,0,2,191,255,255,255,255,179,0,0,0,0,0,78
    db 255,255,255,255,255,254,80,0,0,0,3,239,255,254,185,190,255,255,227,0,0,0,12,255,255,112,0,0,127,255,253,0
    db 0,0,95,255,244,0,0,0,4,255,255,96,0,0,207,255,144,0,0,0,0,159,255,192,0,1,255,254,32,0,0,0
    db 0,46,255,242,0,5,255,252,0,0,0,0,0,12,255,246,0,7,255,250,0,0,0,0,0,10,255,247,0,8,255,248
    db 0,0,0,0,0,8,255,248,0,8,255,248,0,0,0,0,0,8,255,248,0,7,255,250,0,0,0,0,0,9,255,247
    db 0,5,255,252,0,0,0,0,0,11,255,246,0,1,255,254,32,0,72,135,16,30,255,242,0,0,207,255,144,0,45,255
    db 144,127,255,192,0,0,111,255,244,0,4,255,248,239,255,96,0,0,12,255,255,112,0,127,255,255,253,0,0,0,3,239
    db 255,254,185,175,255,255,227,0,0,0,0,78,255,255,255,255,255,255,80,0,0,0,0,3,191,255,255,255,255,255,160,0
    db 0,0,0,0,4,156,239,237,152,255,247,0,0,0,0,0,0,0,0,0,0,175,255,64,0,0,0,0,0,0,0,0
    db 0,25,170,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,223,255,255,255,254,200,32,0,0,0,223,255,255,255,255,255,231,0,0,0,223,255
    db 255,255,255,255,255,112,0,0,223,255,101,85,121,239,255,227,0,0,223,255,32,0,0,45,255,250,0,0,223,255,32,0
    db 0,5,255,252,0,0,223,255,32,0,0,1,255,254,0,0,223,255,32,0,0,1,255,255,0,0,223,255,32,0,0,4
    db 255,253,0,0,223,255,32,0,0,28,255,251,0,0,223,255,84,68,104,223,255,245,0,0,223,255,255,255,255,255,255,144
    db 0,0,223,255,255,255,255,255,249,0,0,0,223,255,255,255,255,255,96,0,0,0,223,255,32,0,159,255,192,0,0,0
    db 223,255,32,0,46,255,245,0,0,0,223,255,32,0,8,255,253,0,0,0,223,255,32,0,1,239,255,112,0,0,223,255
    db 32,0,0,127,255,225,0,0,223,255,32,0,0,13,255,248,0,0,223,255,32,0,0,6,255,254,32,0,223,255,32,0
    db 0,0,207,255,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,122,206,236,166,0,0,0,0,0,109,255,255,255,255
    db 213,0,0,0,6,255,255,255,255,255,255,64,0,0,79,255,253,151,121,239,255,226,0,0,191,255,160,0,0,28,255,248
    db 0,0,239,255,32,0,0,4,255,251,0,0,255,255,16,0,0,0,68,67,0,0,207,255,144,0,0,0,0,0,0,0
    db 143,255,252,113,0,0,0,0,0,0,28,255,255,255,200,64,0,0,0,0,2,175,255,255,255,253,129,0,0,0,0,4
    db 174,255,255,255,253,48,0,0,0,0,1,72,207,255,255,210,0,0,0,0,0,0,1,142,255,250,0,0,0,0,0,0
    db 0,4,255,254,0,6,170,164,0,0,0,0,223,255,32,8,255,250,0,0,0,1,255,255,16,3,255,255,96,0,0,27
    db 255,252,0,0,191,255,252,134,121,239,255,246,0,0,29,255,255,255,255,255,255,160,0,0,2,175,255,255,255,255,232,0
    db 0,0,0,3,155,222,236,167,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,12,255,255,255,255,255,255,255,255,144,12
    db 255,255,255,255,255,255,255,255,144,12,255,255,255,255,255,255,255,255,144,4,85,85,86,255,254,85,85,85,48,0,0,0
    db 1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255
    db 253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0
    db 0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0
    db 0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0
    db 0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0
    db 1,255,253,0,0,0,0,0,0,0,1,255,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0
    db 1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0
    db 0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0
    db 0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32
    db 0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,223,255,32,0,0,0,1,255,254,0,0,207,255
    db 64,0,0,0,3,255,253,0,0,191,255,112,0,0,0,6,255,252,0,0,143,255,226,0,0,0,29,255,248,0,0,47
    db 255,252,48,0,3,207,255,243,0,0,8,255,255,252,169,207,255,255,144,0,0,0,175,255,255,255,255,255,251,16,0,0
    db 0,6,223,255,255,255,254,96,0,0,0,0,0,23,190,255,235,129,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,255,243,0,0,0,0,0,111,255,224,12,255,249,0,0
    db 0,0,0,191,255,144,7,255,253,0,0,0,0,1,239,255,64,2,255,255,64,0,0,0,6,255,253,0,0,191,255,144
    db 0,0,0,10,255,249,0,0,111,255,208,0,0,0,30,255,243,0,0,30,255,244,0,0,0,95,255,208,0,0,10,255
    db 249,0,0,0,175,255,128,0,0,5,255,254,0,0,1,239,255,48,0,0,0,239,255,64,0,5,255,252,0,0,0,0
    db 159,255,144,0,10,255,248,0,0,0,0,79,255,224,0,14,255,242,0,0,0,0,13,255,244,0,79,255,192,0,0,0
    db 0,8,255,248,0,159,255,112,0,0,0,0,3,255,252,0,223,255,32,0,0,0,0,0,207,255,34,255,251,0,0,0
    db 0,0,0,143,255,102,255,246,0,0,0,0,0,0,47,255,170,255,241,0,0,0,0,0,0,12,255,237,255,176,0,0
    db 0,0,0,0,7,255,255,255,96,0,0,0,0,0,0,1,255,255,254,16,0,0,0,0,0,0,0,191,255,250,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,63,255,241,0,0,0,14,255,248,0,0,0,8,255,251,0,13,255,245,0,0,0,63,255,252,0,0
    db 0,11,255,248,0,10,255,249,0,0,0,127,255,255,16,0,0,14,255,244,0,6,255,252,0,0,0,191,255,255,64,0
    db 0,79,255,224,0,2,255,255,16,0,0,239,255,255,128,0,0,143,255,160,0,0,223,255,80,0,3,255,251,255,192,0
    db 0,191,255,112,0,0,159,255,128,0,7,255,231,255,241,0,0,239,255,32,0,0,95,255,192,0,11,255,180,255,245,0
    db 3,255,253,0,0,0,31,255,225,0,14,255,145,255,248,0,7,255,249,0,0,0,12,255,244,0,63,255,96,207,252,0
    db 10,255,245,0,0,0,8,255,248,0,127,255,32,159,255,16,14,255,241,0,0,0,4,255,251,0,191,253,0,95,255,80
    db 63,255,192,0,0,0,0,239,254,0,239,250,0,31,255,128,111,255,128,0,0,0,0,191,255,34,255,246,0,12,255,176
    db 159,255,64,0,0,0,0,127,255,85,255,242,0,8,255,208,191,254,0,0,0,0,0,63,255,136,255,192,0,4,255,242
    db 239,251,0,0,0,0,0,13,255,171,255,144,0,0,239,246,255,247,0,0,0,0,0,10,255,222,255,80,0,0,191,252
    db 255,243,0,0,0,0,0,6,255,255,255,16,0,0,143,255,255,224,0,0,0,0,0,2,255,255,252,0,0,0,79,255
    db 255,160,0,0,0,0,0,0,207,255,248,0,0,0,14,255,255,96,0,0,0,0,0,0,159,255,244,0,0,0,11,255
    db 255,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,5,255,255,80,0,0,0,9,255,253,16,0,175,255,209,0,0,0,79
    db 255,244,0,0,29,255,249,0,0,1,223,255,144,0,0,5,255,255,80,0,9,255,253,16,0,0,0,159,255,209,0,79
    db 255,244,0,0,0,0,29,255,248,0,207,255,144,0,0,0,0,5,255,254,38,255,253,16,0,0,0,0,0,159,255,157
    db 255,244,0,0,0,0,0,0,29,255,255,255,128,0,0,0,0,0,0,4,255,255,253,16,0,0,0,0,0,0,0,175
    db 255,245,0,0,0,0,0,0,0,1,223,255,251,0,0,0,0,0,0,0,10,255,255,255,96,0,0,0,0,0,0,111
    db 255,223,255,226,0,0,0,0,0,2,239,255,75,255,251,0,0,0,0,0,11,255,250,3,255,255,112,0,0,0,0,127
    db 255,226,0,143,255,227,0,0,0,3,239,255,96,0,13,255,252,0,0,0,12,255,251,0,0,3,255,255,112,0,0,143
    db 255,226,0,0,0,143,255,243,0,4,255,255,80,0,0,0,12,255,252,0,29,255,250,0,0,0,0,3,255,255,128,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,46,255,249,0,0,0
    db 0,3,255,255,96,7,255,255,48,0,0,0,11,255,252,0,0,207,255,176,0,0,0,95,255,244,0,0,79,255,245,0
    db 0,0,207,255,160,0,0,10,255,253,0,0,6,255,254,32,0,0,2,239,255,112,0,29,255,247,0,0,0,0,127,255
    db 225,0,143,255,192,0,0,0,0,12,255,248,1,239,255,64,0,0,0,0,4,255,254,23,255,250,0,0,0,0,0,0
    db 175,255,142,255,226,0,0,0,0,0,0,46,255,255,255,128,0,0,0,0,0,0,7,255,255,253,16,0,0,0,0,0
    db 0,0,207,255,245,0,0,0,0,0,0,0,0,95,255,192,0,0,0,0,0,0,0,0,79,255,176,0,0,0,0,0
    db 0,0,0,79,255,176,0,0,0,0,0,0,0,0,79,255,176,0,0,0,0,0,0,0,0,79,255,176,0,0,0,0
    db 0,0,0,0,79,255,176,0,0,0,0,0,0,0,0,79,255,176,0,0,0,0,0,0,0,0,79,255,176,0,0,0
    db 0,0,0,0,0,79,255,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6
    db 255,255,255,255,255,255,255,253,0,6,255,255,255,255,255,255,255,253,0,6,255,255,255,255,255,255,255,251,0,2,85,85
    db 85,85,85,111,255,227,0,0,0,0,0,0,0,207,255,112,0,0,0,0,0,0,9,255,251,0,0,0,0,0,0,0
    db 95,255,226,0,0,0,0,0,0,1,239,255,96,0,0,0,0,0,0,10,255,251,0,0,0,0,0,0,0,111,255,226
    db 0,0,0,0,0,0,2,239,255,80,0,0,0,0,0,0,11,255,250,0,0,0,0,0,0,0,127,255,209,0,0,0
    db 0,0,0,3,239,255,64,0,0,0,0,0,0,12,255,249,0,0,0,0,0,0,0,143,255,209,0,0,0,0,0,0
    db 3,255,254,48,0,0,0,0,0,0,28,255,246,0,0,0,0,0,0,0,143,255,180,85,85,85,85,85,0,3,255,255
    db 255,255,255,255,255,253,0,5,255,255,255,255,255,255,255,253,0,5,255,255,255,255,255,255,255,253,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 63,255,255,250,0,0,63,255,255,250,0,0,63,255,255,250,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255
    db 144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0
    db 0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0
    db 63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255
    db 144,0,0,0,63,255,144,0,0,0,63,255,144,0,0,0,63,255,255,249,0,0,63,255,255,250,0,0,63,255,255,250
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,127,254,0,0,0,0,47,255,64,0,0,0,13,255,128,0,0,0,9,255,192,0,0
    db 0,5,255,241,0,0,0,1,255,245,0,0,0,0,207,249,0,0,0,0,143,253,0,0,0,0,79,255,32,0,0,0
    db 14,255,112,0,0,0,11,255,160,0,0,0,7,255,224,0,0,0,3,255,244,0,0,0,0,239,248,0,0,0,0,175
    db 251,0,0,0,0,111,255,16,0,0,0,47,255,80,0,0,0,13,255,144,0,0,0,9,255,192,0,0,0,5,255,242
    db 0,0,0,1,255,246,0,0,0,0,207,250,0,0,0,0,143,253,0,0,0,0,79,255,48,0,0,0,14,255,112,0
    db 0,0,11,255,176,0,0,0,2,51,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,255,255,255,80,0,7,255,255,255,80,0,7
    db 255,255,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111
    db 255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80
    db 0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0
    db 0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111,255,80,0,0,0,111
    db 255,80,0,7,255,255,255,80,0,7,255,255,255,80,0,7,255,255,255,80,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,255,243,0,0,0,0,79,255,250,0,0
    db 0,0,191,254,255,32,0,0,3,255,199,255,144,0,0,10,255,97,239,242,0,0,47,254,16,143,249,0,0,159,248,0
    db 46,254,16,2,255,226,0,9,255,128,9,255,144,0,3,255,225,5,102,32,0,0,86,98,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,255,255,255,255,255,255,255,255,255
    db 255,255,255,255,255,255,255,255,255,255,255,17,17,17,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 127,255,64,0,0,0,11,255,176,0,0,0,2,239,243,0,0,0,0,127,249,0,0,0,0,7,136,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,40,205,253,200,16,0,0,0,6,255
    db 255,255,255,229,0,0,0,127,255,255,255,255,254,64,0,1,239,255,130,2,159,255,192,0,3,156,231,0,0,13,255,241
    db 0,0,0,0,0,0,11,255,243,0,0,0,0,0,36,142,255,244,0,0,0,106,207,255,255,255,244,0,0,78,255,255
    db 255,255,255,244,0,3,239,255,235,151,57,255,244,0,10,255,249,16,0,10,255,244,0,13,255,224,0,0,12,255,244,0
    db 13,255,224,0,0,63,255,244,0,10,255,249,16,5,239,255,244,0,5,255,255,237,255,252,255,244,0,0,143,255,255,255
    db 152,255,244,0,0,4,189,254,181,8,255,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0
    db 0,0,0,255,253,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0
    db 0,255,253,2,157,238,182,0,0,0,0,255,253,45,255,255,255,177,0,0,0,255,253,207,255,255,255,251,0,0,0,255
    db 255,253,116,107,255,255,80,0,0,255,255,210,0,0,191,255,192,0,0,255,255,96,0,0,47,255,241,0,0,255,255,0
    db 0,0,12,255,245,0,0,255,253,0,0,0,10,255,246,0,0,255,252,0,0,0,9,255,247,0,0,255,253,0,0,0
    db 10,255,246,0,0,255,255,16,0,0,12,255,245,0,0,255,255,96,0,0,47,255,241,0,0,255,255,210,0,0,191,255
    db 176,0,0,255,255,253,116,107,255,255,64,0,0,255,253,223,255,255,255,250,0,0,0,255,252,62,255,255,255,177,0,0
    db 0,255,252,2,157,254,182,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,157,238,202,64
    db 0,0,0,0,159,255,255,255,251,16,0,0,10,255,255,255,255,255,193,0,0,95,255,249,83,126,255,248,0,0,223,255
    db 96,0,3,239,254,0,5,255,252,0,0,0,140,150,16,8,255,247,0,0,0,0,0,0,10,255,245,0,0,0,0,0
    db 0,11,255,244,0,0,0,0,0,0,10,255,245,0,0,0,0,0,0,9,255,247,0,0,0,0,0,0,5,255,252,0
    db 0,0,157,167,16,1,223,255,96,0,3,239,254,0,0,95,255,249,67,109,255,248,0,0,10,255,255,255,255,255,193,0
    db 0,1,175,255,255,255,251,16,0,0,0,4,157,238,218,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,255,176,0,0,0,0
    db 0,0,0,47,255,176,0,0,0,0,0,0,0,47,255,176,0,0,0,0,0,0,0,47,255,176,0,0,0,0,0,0
    db 0,47,255,176,0,0,0,24,206,236,112,47,255,176,0,0,3,223,255,255,251,63,255,176,0,0,30,255,255,255,255,175
    db 255,176,0,0,175,255,249,84,143,255,255,176,0,1,239,255,112,0,4,255,255,176,0,6,255,252,0,0,0,175,255,176
    db 0,9,255,247,0,0,0,95,255,176,0,10,255,245,0,0,0,63,255,176,0,11,255,244,0,0,0,31,255,176,0,10
    db 255,245,0,0,0,63,255,176,0,9,255,247,0,0,0,95,255,176,0,6,255,253,0,0,0,175,255,176,0,2,239,255
    db 112,0,4,255,255,176,0,0,143,255,249,84,143,255,255,176,0,0,30,255,255,255,255,159,255,176,0,0,3,223,255,255
    db 251,31,255,176,0,0,0,24,206,236,112,31,255,176,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 4,173,238,201,64,0,0,0,0,159,255,255,255,250,16,0,0,10,255,255,255,255,255,160,0,0,95,255,230,34,110,255
    db 246,0,0,207,254,32,0,3,255,252,0,5,255,248,0,0,0,159,255,32,8,255,244,0,0,0,111,255,96,10,255,255
    db 255,255,255,255,255,112,11,255,255,255,255,255,255,255,128,10,255,250,170,170,170,170,170,80,9,255,245,0,0,0,0,0
    db 0,5,255,248,0,0,0,0,0,0,1,223,254,32,0,0,174,185,16,0,111,255,230,33,58,255,252,0,0,11,255,255
    db 255,255,255,228,0,0,1,175,255,255,255,254,64,0,0,0,4,157,239,219,113,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,49,0,0,0,6,223,255,227,0,0,159,255,255,225,0,5
    db 255,255,255,176,0,8,255,250,33,32,0,11,255,244,0,0,0,11,255,242,0,0,191,255,255,255,255,160,191,255,255,255
    db 255,160,191,255,255,255,255,160,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0
    db 0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11
    db 255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,11,255,242,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,24,206,236,112,15,255,192,0,0,3
    db 223,255,255,251,31,255,192,0,0,29,255,255,255,255,159,255,192,0,0,159,255,250,84,143,255,255,192,0,1,239,255,112
    db 0,5,255,255,192,0,5,255,253,0,0,0,191,255,192,0,9,255,248,0,0,0,95,255,192,0,10,255,246,0,0,0
    db 63,255,192,0,11,255,244,0,0,0,31,255,192,0,10,255,245,0,0,0,47,255,192,0,9,255,247,0,0,0,79,255
    db 192,0,7,255,251,0,0,0,159,255,192,0,3,255,255,80,0,2,239,255,192,0,0,191,255,247,50,110,255,255,192,0
    db 0,62,255,255,255,255,175,255,192,0,0,4,239,255,255,252,47,255,192,0,0,0,41,222,236,113,31,255,192,0,0,0
    db 0,0,0,0,31,255,176,0,0,0,1,0,0,0,79,255,160,0,0,57,234,0,0,0,175,255,112,0,0,223,255,180
    db 33,74,255,254,32,0,0,78,255,255,255,255,255,244,0,0,0,4,223,255,255,255,253,80,0,0,0,0,5,172,221,186
    db 96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,255,252,0,0,0,0,0,0,0,255,252,0,0,0,0,0,0,0,255,252,0,0,0,0,0,0,0,255,252,0,0
    db 0,0,0,0,0,255,252,0,0,0,0,0,0,0,255,252,2,157,237,181,0,0,0,255,252,61,255,255,255,144,0,0
    db 255,252,207,255,255,255,245,0,0,255,255,252,117,142,255,253,0,0,255,255,176,0,4,255,255,32,0,255,255,48,0,0
    db 191,255,64,0,255,254,0,0,0,159,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255
    db 253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143
    db 255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253
    db 0,0,0,143,255,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,16,0,0,175,248,0,4,255,255,16,3,255,254,16,0
    db 126,214,0,0,0,0,0,0,0,0,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0
    db 255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0
    db 255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,2,16,0,0,175,248,0,4,255,255,16,3,255,254,16,0,126,214,0,0
    db 0,0,0,0,0,0,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0
    db 255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0
    db 255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,2,255,251,0,42,255,249,0,255,255,245,0,255,255,144,0,254
    db 198,0,0,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0
    db 0,255,253,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,255,253,0,0
    db 0,0,0,0,0,255,253,0,0,7,255,254,48,0,255,253,0,0,95,255,244,0,0,255,253,0,4,239,255,96,0,0
    db 255,253,0,46,255,248,0,0,0,255,253,1,223,255,144,0,0,0,255,253,11,255,251,0,0,0,0,255,253,175,255,209
    db 0,0,0,0,255,255,255,255,96,0,0,0,0,255,255,255,255,209,0,0,0,0,255,255,254,255,250,0,0,0,0,255
    db 255,148,255,255,96,0,0,0,255,253,0,159,255,226,0,0,0,255,253,0,29,255,251,0,0,0,255,253,0,3,255,255
    db 112,0,0,255,253,0,0,143,255,227,0,0,255,253,0,0,12,255,252,0,0,255,253,0,0,3,239,255,128,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255
    db 253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255
    db 253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255,253,0,0,255
    db 253,0,0,255,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,255,250,2,173,237,96,0,40,222,219,64,0,0,0,255,250,62,255,255,248,3,223,255,255,248,0,0,0,255,251,223
    db 255,255,255,45,255,255,255,255,48,0,0,255,254,250,103,207,255,223,215,105,255,255,160,0,0,255,255,144,0,29,255,254
    db 16,0,111,255,192,0,0,255,255,16,0,8,255,249,0,0,15,255,224,0,0,255,253,0,0,6,255,247,0,0,13,255
    db 240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,255
    db 253,0,0,6,255,246,0,0,13,255,240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,255,253,0,0,6
    db 255,246,0,0,13,255,240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,255,253,0,0,6,255,246,0,0
    db 13,255,240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,255,253,0,0,6,255,246,0,0,13,255,240,0
    db 0,255,253,0,0,6,255,246,0,0,13,255,240,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,255,250,2,157,237,181,0,0,0,255,250,61,255,255,255,144,0,0,255,250,207,255,255,255,245,0,0,255,254,252
    db 117,142,255,253,0,0,255,255,176,0,4,255,255,16,0,255,255,48,0,0,191,255,64,0,255,254,0,0,0,159,255,96
    db 0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0
    db 0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0
    db 255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,4,157,239,218,80,0,0,0,0,159,255,255,255,252,32,0,0,10,255,255,255,255,255,209,0,0,95,255,249,84
    db 126,255,248,0,0,223,255,96,0,3,239,255,48,5,255,252,0,0,0,159,255,144,8,255,247,0,0,0,63,255,192,10
    db 255,245,0,0,0,31,255,208,11,255,244,0,0,0,14,255,224,10,255,245,0,0,0,31,255,208,9,255,247,0,0,0
    db 63,255,192,5,255,252,0,0,0,159,255,144,1,223,255,96,0,3,239,255,48,0,95,255,249,67,126,255,249,0,0,10
    db 255,255,255,255,255,209,0,0,1,175,255,255,255,252,32,0,0,0,4,157,239,218,80,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,255,252,2,157,238,182,0,0,0,0,255,252,45,255,255,255,177,0,0
    db 0,255,252,207,255,255,255,251,0,0,0,255,255,253,116,107,255,255,80,0,0,255,255,210,0,0,191,255,192,0,0,255
    db 255,96,0,0,47,255,241,0,0,255,255,0,0,0,12,255,245,0,0,255,253,0,0,0,10,255,246,0,0,255,252,0
    db 0,0,9,255,247,0,0,255,253,0,0,0,10,255,246,0,0,255,255,16,0,0,12,255,245,0,0,255,255,96,0,0
    db 63,255,241,0,0,255,255,210,0,0,191,255,176,0,0,255,255,253,116,107,255,255,64,0,0,255,253,207,255,255,255,250
    db 0,0,0,255,253,62,255,255,255,177,0,0,0,255,253,2,157,254,182,0,0,0,0,255,253,0,0,0,0,0,0,0
    db 0,255,253,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,0,255,253,0,0,0,0,0,0,0,0,255
    db 253,0,0,0,0,0,0,0,0,221,219,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,24,206,236,112,31,255,176,0,0,3,223,255
    db 255,251,31,255,176,0,0,46,255,255,255,255,175,255,176,0,0,175,255,249,84,143,255,255,176,0,2,255,255,112,0,4
    db 255,255,176,0,6,255,252,0,0,0,175,255,176,0,9,255,247,0,0,0,95,255,176,0,10,255,245,0,0,0,63,255
    db 176,0,11,255,244,0,0,0,31,255,176,0,10,255,245,0,0,0,63,255,176,0,9,255,247,0,0,0,95,255,176,0
    db 6,255,253,0,0,0,175,255,176,0,1,239,255,112,0,4,255,255,176,0,0,143,255,249,84,143,255,255,176,0,0,30
    db 255,255,255,255,175,255,176,0,0,3,223,255,255,251,63,255,176,0,0,0,24,206,236,112,47,255,176,0,0,0,0,0
    db 0,0,47,255,176,0,0,0,0,0,0,0,47,255,176,0,0,0,0,0,0,0,47,255,176,0,0,0,0,0,0,0
    db 47,255,176,0,0,0,0,0,0,0,47,255,176,0,0,0,0,0,0,0,45,221,160,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,255,251,4,190,246,0,255,251,95,255,246,0,255,251,223,255,246,0,255,255,254,168,132,0,255,255,210
    db 0,0,0,255,255,64,0,0,0,255,254,0,0,0,0,255,253,0,0,0,0,255,253,0,0,0,0,255,253,0,0,0
    db 0,255,253,0,0,0,0,255,253,0,0,0,0,255,253,0,0,0,0,255,253,0,0,0,0,255,253,0,0,0,0,255
    db 253,0,0,0,0,255,253,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,41,206,253,183,16,0,0,8,255,255,255,255,227,0,0,127,255,254,223,255,254,32
    db 0,239,255,96,1,175,255,144,3,255,250,0,0,28,184,80,3,255,252,0,0,0,0,0,1,239,255,199,48,0,0,0
    db 0,127,255,255,254,183,32,0,0,7,239,255,255,255,248,0,0,0,22,189,255,255,255,128,0,0,0,0,38,207,255,241
    db 0,2,64,0,0,13,255,243,7,223,244,0,0,12,255,243,5,255,254,80,2,159,255,208,0,191,255,255,239,255,255,64
    db 0,27,255,255,255,255,229,0,0,0,74,206,237,183,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,110,238,112,0,0,0,127,255,112,0,0,0,127,255,112,0,0
    db 0,127,255,112,0,0,191,255,255,255,250,0,191,255,255,255,250,0,191,255,255,255,250,0,0,127,255,112,0,0,0,127
    db 255,112,0,0,0,127,255,112,0,0,0,127,255,112,0,0,0,127,255,112,0,0,0,127,255,112,0,0,0,127,255,112
    db 0,0,0,127,255,112,0,0,0,127,255,112,0,0,0,111,255,144,0,0,0,79,255,213,51,0,0,30,255,255,250,0
    db 0,6,255,255,253,0,0,0,75,223,219,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,253,0,0,0,143,255,96
    db 0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0
    db 0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0
    db 255,253,0,0,0,143,255,96,0,255,253,0,0,0,143,255,96,0,255,253,0,0,0,159,255,96,0,223,255,16,0,0
    db 207,255,96,0,191,255,144,0,6,255,255,96,0,143,255,250,102,175,239,255,96,0,30,255,255,255,255,143,255,96,0,5
    db 239,255,255,246,95,255,96,0,0,42,206,235,64,95,255,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,95,255,192,0,0,0,63,255,208,14
    db 255,243,0,0,0,143,255,128,9,255,248,0,0,0,207,255,48,3,255,252,0,0,3,255,252,0,0,223,255,32,0,8
    db 255,247,0,0,143,255,112,0,12,255,242,0,0,47,255,192,0,47,255,176,0,0,12,255,242,0,127,255,96,0,0,7
    db 255,247,0,191,254,16,0,0,1,255,251,1,255,250,0,0,0,0,191,254,5,255,245,0,0,0,0,111,255,73,255,224
    db 0,0,0,0,30,255,141,255,144,0,0,0,0,10,255,223,255,48,0,0,0,0,4,255,255,253,0,0,0,0,0,0
    db 223,255,248,0,0,0,0,0,0,159,255,242,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,79,255,192,0,0,111,255,144,0,0,175,255,112,14,255,241,0,0,175,255,192,0,0
    db 223,255,32,10,255,245,0,0,223,255,241,0,2,255,253,0,6,255,248,0,2,255,255,245,0,6,255,249,0,2,255,251
    db 0,6,255,239,248,0,10,255,244,0,0,207,254,0,9,255,159,252,0,13,255,224,0,0,143,255,64,12,255,63,254,0
    db 47,255,176,0,0,79,255,112,31,254,12,255,64,111,255,96,0,0,14,255,176,95,251,9,255,112,159,255,32,0,0,10
    db 255,208,143,247,5,255,176,207,252,0,0,0,6,255,242,191,243,1,255,208,239,248,0,0,0,2,255,245,239,224,0,207
    db 244,255,244,0,0,0,0,207,250,255,160,0,143,250,255,224,0,0,0,0,143,255,255,96,0,79,255,255,160,0,0,0
    db 0,79,255,255,32,0,14,255,255,96,0,0,0,0,14,255,252,0,0,10,255,255,32,0,0,0,0,10,255,248,0,0
    db 6,255,252,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,255,249,0,0,6,255,252,0,2,239,255,48,0,29,255
    db 243,0,0,127,255,176,0,159,255,144,0,0,12,255,244,2,255,253,16,0,0,4,255,251,9,255,245,0,0,0,0,159
    db 255,111,255,176,0,0,0,0,30,255,255,254,32,0,0,0,0,6,255,255,247,0,0,0,0,0,2,255,255,242,0,0
    db 0,0,0,10,255,255,250,0,0,0,0,0,95,255,207,255,64,0,0,0,1,223,253,30,255,209,0,0,0,8,255,247
    db 7,255,248,0,0,0,63,255,209,1,223,255,48,0,0,191,255,96,0,111,255,192,0,6,255,251,0,0,11,255,247,0
    db 30,255,243,0,0,3,255,254,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,95,255,192,0,0,0,63,255,224,13,255,243,0,0,0,143,255
    db 144,9,255,248,0,0,0,207,255,48,3,255,252,0,0,3,255,252,0,0,207,255,32,0,8,255,247,0,0,127,255,112
    db 0,13,255,241,0,0,47,255,192,0,63,255,176,0,0,11,255,242,0,143,255,80,0,0,6,255,247,0,223,254,0,0
    db 0,1,239,251,3,255,249,0,0,0,0,159,254,7,255,243,0,0,0,0,79,255,75,255,208,0,0,0,0,13,255,142
    db 255,112,0,0,0,0,8,255,239,255,32,0,0,0,0,2,255,255,251,0,0,0,0,0,0,207,255,246,0,0,0,0
    db 0,0,127,255,225,0,0,0,0,0,0,127,255,144,0,0,0,0,0,0,191,255,64,0,0,0,0,34,23,255,252,0
    db 0,0,0,0,143,255,255,245,0,0,0,0,0,207,255,255,112,0,0,0,0,1,223,254,197,0,0,0,0,0,0,1
    db 16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,239,255,255,255,255,255,224,0,0,239,255,255,255,255,255,224,0
    db 0,239,255,255,255,255,255,208,0,0,52,68,68,68,239,255,80,0,0,0,0,0,10,255,249,0,0,0,0,0,0,127
    db 255,193,0,0,0,0,0,3,255,254,48,0,0,0,0,0,29,255,246,0,0,0,0,0,0,175,255,160,0,0,0,0
    db 0,7,255,253,16,0,0,0,0,0,79,255,244,0,0,0,0,0,1,223,255,112,0,0,0,0,0,11,255,251,0,0
    db 0,0,0,0,127,255,245,51,51,51,49,0,3,255,255,255,255,255,255,244,0,4,255,255,255,255,255,255,244,0,4,255
    db 255,255,255,255,255,244,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,3,86,0,0,0,0,7,223,255,16,0,0,0,175,255,255,16,0,0,4,255,255,218,0,0,0
    db 8,255,248,0,0,0,0,10,255,241,0,0,0,0,11,255,208,0,0,0,0,11,255,208,0,0,0,0,11,255,208,0
    db 0,0,0,11,255,208,0,0,0,0,13,255,192,0,0,0,0,111,255,160,0,0,0,155,255,255,64,0,0,0,239,255
    db 180,0,0,0,0,239,252,64,0,0,0,0,239,255,251,16,0,0,0,20,207,255,128,0,0,0,0,46,255,192,0,0
    db 0,0,12,255,208,0,0,0,0,11,255,208,0,0,0,0,11,255,208,0,0,0,0,11,255,208,0,0,0,0,11,255
    db 224,0,0,0,0,10,255,243,0,0,0,0,7,255,252,48,0,0,0,2,239,255,255,16,0,0,0,95,255,255,16,0
    db 0,0,2,140,222,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,221,211,0,0,0,7,255,243,0,0,0,7,255,243,0
    db 0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0
    db 7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255
    db 243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0
    db 0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0
    db 7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255
    db 243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0,0,0,7,255,243,0
    db 0,0,7,255,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,7,237,181,0,0,0,0,7,255,255,210,0,0,0,7,255,255,250,0,0,0,0,38,239,255,16,0,0
    db 0,0,143,255,64,0,0,0,0,95,255,80,0,0,0,0,79,255,96,0,0,0,0,79,255,96,0,0,0,0,79,255
    db 96,0,0,0,0,79,255,112,0,0,0,0,47,255,209,0,0,0,0,9,255,254,165,0,0,0,0,141,255,249,0,0
    db 0,0,22,255,249,0,0,0,4,239,255,249,0,0,0,13,255,249,49,0,0,0,63,255,160,0,0,0,0,79,255,112
    db 0,0,0,0,79,255,96,0,0,0,0,79,255,96,0,0,0,0,79,255,96,0,0,0,0,95,255,80,0,0,0,0
    db 143,255,64,0,0,0,22,239,255,16,0,0,7,255,255,250,0,0,0,7,255,255,194,0,0,0,7,237,181,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,92,237,163,0,0,57
    db 151,0,0,7,255,255,255,112,0,127,251,0,0,30,255,255,255,250,51,223,250,0,0,127,255,134,207,255,255,255,245,0
    db 0,143,250,0,9,255,255,255,192,0,0,140,198,0,0,77,255,250,16,0,0,0,0,0,0,0,20,16,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,54,48,0,0,0,0,0,77,255,253,80,0,0,0,3,239,255,255,244
    db 0,0,0,11,255,255,255,253,0,0,0,15,255,255,255,255,32,0,0,47,255,255,255,255,48,0,0,14,255,255,255,255
    db 16,0,0,9,255,255,255,250,0,0,0,1,207,255,255,209,0,0,0,0,8,206,217,16,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0
icon_masks:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,17,17,17,17,16,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,25,153,153,153,153,150,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,170
    db 170,170,170,170,96,0,0,0,0,0,0,0,0,0,0,0,0,0,25,169,153,153,153,153,166,17,17,17,17,17,17,17
    db 17,16,0,0,0,0,25,170,170,170,170,170,170,153,153,153,153,153,153,153,153,146,0,0,0,0,46,255,255,255,255,255
    db 255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0
    db 0,0,30,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255
    db 255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255
    db 255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0
    db 0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255
    db 255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,30,255,255,255,255,255
    db 255,255,255,255,255,255,255,255,255,243,0,0,0,0,12,255,255,255,255,255,255,255,255,255,255,255,255,255,255,226,0,0
    db 0,0,2,174,255,255,255,255,255,255,255,255,255,255,255,255,251,48,0,0,0,0,0,2,51,51,51,51,51,51,51,51
    db 51,51,51,51,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,17,17,17,17,17,17,17,17,17,17,17,17,0,0,0,0,0,0,0,37,102,102,102,102
    db 102,102,102,102,102,102,102,102,83,0,0,0,0,0,3,118,102,102,102,102,102,102,102,102,102,102,102,102,103,64,0,0
    db 0,0,39,102,102,102,102,102,102,102,102,102,102,102,102,102,102,115,0,0,0,0,86,102,102,102,102,102,102,102,102,102
    db 102,102,102,102,102,101,0,0,0,0,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102
    db 102,102,102,102,102,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,102,102,102,102,102,102,102,102,102,102,102
    db 102,102,16,0,0,1,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,92,232,86
    db 102,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,175,255,166,102,102,102,102,102,102,102,102,102,102,16,0
    db 0,1,102,102,102,191,255,252,118,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,105,239,255,233,86,102,102
    db 102,102,102,102,102,102,16,0,0,1,102,102,102,102,124,255,255,182,102,102,102,102,102,102,102,102,16,0,0,1,102,102
    db 102,102,102,174,255,250,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,102,102,158,255,250,102,102,102,102,102,102
    db 102,102,16,0,0,1,102,102,102,102,108,255,255,198,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,88,239,255
    db 250,102,102,102,102,102,102,102,102,102,16,0,0,1,102,102,102,175,255,253,133,102,102,102,102,102,102,102,102,102,16,0
    db 0,1,102,102,102,175,255,182,102,102,103,119,119,119,102,102,102,102,16,0,0,1,102,102,102,92,232,86,102,102,206,238
    db 238,238,198,102,102,102,16,0,0,1,102,102,102,103,118,102,102,103,255,255,255,255,248,102,102,102,16,0,0,1,102,102
    db 102,102,102,102,102,102,173,221,221,221,182,102,102,102,16,0,0,1,102,102,102,102,102,102,102,102,102,102,102,102,102,102
    db 102,102,16,0,0,1,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,16,0,0,0,86,102,102,102,102,102
    db 102,102,102,102,102,102,102,102,102,102,0,0,0,0,55,102,102,102,102,102,102,102,102,102,102,102,102,102,102,115,0,0
    db 0,0,4,118,102,102,102,102,102,102,102,102,102,102,102,102,103,80,0,0,0,0,0,53,102,102,102,102,102,102,102,102
    db 102,102,102,102,99,0,0,0,0,0,0,0,17,17,17,17,17,17,17,17,17,17,17,17,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,34,34,34,34,34,34,34,0,0,0,0
    db 0,0,0,0,0,0,0,0,29,238,238,238,238,238,238,238,96,0,0,0,0,0,0,0,0,0,0,0,46,255,255,255
    db 255,255,255,255,165,0,0,0,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,153,80,0,0,0,0,0,0
    db 0,0,0,0,46,255,255,255,255,255,255,255,152,149,0,0,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255
    db 152,137,80,0,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,152,136,149,0,0,0,0,0,0,0,0,0
    db 46,255,255,255,255,255,255,255,152,152,137,80,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,238,238,238,227
    db 0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255
    db 255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0
    db 0,0,0,0,46,255,254,238,238,238,238,238,238,239,255,243,0,0,0,0,0,0,0,0,46,255,226,17,17,17,17,17
    db 17,29,255,243,0,0,0,0,0,0,0,0,46,255,228,51,51,51,51,51,51,61,255,243,0,0,0,0,0,0,0,0
    db 46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243
    db 0,0,0,0,0,0,0,0,46,255,254,238,238,238,238,238,238,239,255,243,0,0,0,0,0,0,0,0,46,255,226,17
    db 17,17,17,17,17,29,255,243,0,0,0,0,0,0,0,0,46,255,228,51,51,51,51,51,51,61,255,243,0,0,0,0
    db 0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255
    db 255,255,255,243,0,0,0,0,0,0,0,0,46,255,254,238,238,238,238,255,255,255,255,243,0,0,0,0,0,0,0,0
    db 46,255,226,17,17,17,17,223,255,255,255,243,0,0,0,0,0,0,0,0,46,255,228,51,51,51,51,223,255,255,255,243
    db 0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255
    db 255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0
    db 0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255
    db 255,255,255,243,0,0,0,0,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0
    db 3,51,51,51,51,51,51,51,51,51,51,49,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,18,33,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,21,156,222,237,202,97,0,0,0,0,0,0,0,0,0,0,0,0,0,24,223
    db 255,255,255,255,254,146,0,0,0,0,0,0,0,0,0,0,0,6,223,255,255,218,173,255,255,254,112,0,0,0,0,0
    db 0,0,0,0,0,159,255,221,253,101,86,223,220,255,250,16,0,0,0,0,0,0,0,0,10,255,233,110,248,103,118,127
    db 231,158,255,193,0,0,0,0,0,0,0,0,159,253,116,175,197,102,102,91,251,70,207,250,0,0,0,0,0,0,0,6
    db 255,233,136,223,184,152,137,138,254,152,141,255,112,0,0,0,0,0,0,30,255,255,255,255,255,255,255,255,255,255,255,255
    db 243,0,0,0,0,0,0,143,252,187,172,254,187,187,187,186,223,218,187,191,250,0,0,0,0,0,1,223,214,86,90,251
    db 86,85,85,101,175,181,102,92,254,32,0,0,0,0,5,255,166,118,108,250,103,102,102,102,159,214,102,104,255,112,0,0    db 0,0,9,254,118,102,109,249,102,102,102,102,143,230,102,102,239,176,0,0,0,0,12,253,102,102,110,248,86,102,102,102
    db 127,231,102,101,207,208,0,0,0,0,13,252,103,119,126,248,103,119,119,119,127,248,119,118,191,226,0,0,0,0,46,255
    db 238,238,239,255,238,238,238,238,239,255,238,238,255,243,0,0,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,243,0,0,0,0,29,252,120,135,142,249,120,136,136,135,143,249,120,135,191,226,0,0,0,0,12,252,86,102,110,248
    db 86,102,102,102,127,247,102,101,191,209,0,0,0,0,10,254,118,102,109,249,102,102,102,102,143,231,102,102,223,176,0,0
    db 0,0,6,255,150,102,108,250,102,102,102,102,159,214,102,104,255,112,0,0,0,0,1,239,213,102,90,251,86,102,102,101
    db 175,197,102,92,255,48,0,0,0,0,0,159,250,137,139,253,136,136,136,152,223,184,152,159,251,0,0,0,0,0,0,46
    db 255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,0,0,0,0,7,255,235,187,239,202,187,187,172,254,187,174,255
    db 144,0,0,0,0,0,0,0,175,252,100,175,197,101,86,91,251,69,191,252,0,0,0,0,0,0,0,0,28,255,232,110
    db 248,103,118,126,247,141,255,210,0,0,0,0,0,0,0,0,1,175,255,205,253,101,101,207,219,255,251,32,0,0,0,0
    db 0,0,0,0,0,8,239,255,255,201,156,255,255,255,144,0,0,0,0,0,0,0,0,0,0,0,58,239,255,255,255,255
    db 254,180,0,0,0,0,0,0,0,0,0,0,0,0,0,39,189,239,254,219,115,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,35,50,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,34,34,34,34
    db 34,34,34,34,34,34,34,34,16,0,0,0,0,0,3,190,238,238,238,238,238,238,238,238,238,238,238,238,235,64,0,0
    db 0,0,62,255,255,255,255,255,255,255,255,255,255,255,255,255,255,228,0,0,0,0,191,255,255,255,255,255,255,255,255,255
    db 255,255,255,255,255,252,0,0,0,1,239,255,255,255,254,255,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255
    db 255,251,66,58,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,176,0,0,159,255,255,255,255,255,255,255
    db 255,255,48,0,0,2,239,255,255,48,16,0,46,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,254,16,0,0
    db 13,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,48,0,0,30,255,255,255,255,255,255,255,255,255,48,0
    db 0,2,239,255,255,160,0,0,143,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,249,32,40,255,255,255,255
    db 255,255,255,255,255,255,48,0,0,2,239,255,255,255,237,239,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,255,48,0,0,2,239,255,255,255,250,143,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,255,192,10
    db 255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,254,22,96,191,255,255,255,250,127,255,255,255,255,48,0
    db 0,2,239,255,255,243,91,181,13,255,255,255,193,8,255,255,255,255,48,0,0,2,239,255,255,84,187,187,50,239,255,254
    db 32,0,143,255,255,255,48,0,0,2,239,255,247,75,187,187,178,63,255,244,6,130,8,255,255,255,48,0,0,2,239,255
    db 164,187,187,187,186,21,255,96,107,186,96,127,255,255,48,0,0,2,239,251,91,187,187,187,171,144,121,6,187,171,185,39
    db 255,255,48,0,0,1,239,214,187,187,187,187,186,184,0,91,187,187,171,181,143,255,48,0,0,0,207,139,187,187,187,187
    db 187,171,117,187,187,187,187,188,154,253,0,0,0,0,71,155,187,187,187,187,187,187,187,187,187,187,187,186,186,150,0,0
    db 0,0,0,34,34,34,34,34,34,34,34,34,34,34,34,34,34,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,18,33,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,55
    db 172,238,238,203,116,0,0,0,0,0,0,0,0,0,0,0,0,0,108,255,255,255,255,255,255,199,16,0,0,0,0,0
    db 0,0,0,0,0,92,255,255,249,68,175,255,255,255,214,0,0,0,0,0,0,0,0,0,8,255,255,255,160,0,10,255
    db 255,255,255,160,0,0,0,0,0,0,0,0,175,255,255,255,48,17,3,255,250,68,159,252,16,0,0,0,0,0,0,10
    db 255,255,255,255,48,17,3,255,160,0,10,255,192,0,0,0,0,0,0,143,255,255,255,255,160,0,10,255,48,17,3,255
    db 249,0,0,0,0,0,3,255,255,255,255,255,250,68,175,255,48,17,3,255,255,80,0,0,0,0,11,255,255,164,74,255
    db 255,255,255,255,160,0,10,255,255,208,0,0,0,0,63,255,250,0,0,175,255,255,255,255,250,68,175,255,255,245,0,0
    db 0,0,143,255,243,1,16,63,255,255,255,255,255,255,255,255,255,250,0,0,0,0,207,255,243,1,16,63,255,255,255,255
    db 255,255,255,255,255,253,0,0,0,0,223,255,250,0,0,175,255,255,255,255,255,255,255,255,255,254,32,0,0,2,239,255
    db 255,164,74,255,255,255,255,255,255,255,255,255,255,255,48,0,0,2,239,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,255,48,0,0,0,223,255,255,255,255,255,255,255,255,255,255,254,239,255,255,254,32,0,0,0,207,255,164,74,255,255
    db 255,255,255,255,253,98,37,207,255,253,0,0,0,0,159,250,0,0,175,255,255,255,255,255,210,0,0,28,255,250,0,0
    db 0,0,79,243,1,16,63,255,255,255,255,255,96,16,1,4,255,245,0,0,0,0,12,243,1,16,63,255,255,255,255,254
    db 32,0,0,0,223,209,0,0,0,0,4,250,0,0,175,255,255,255,255,254,32,0,0,0,223,96,0,0,0,0,0,159
    db 148,74,255,255,255,255,255,255,80,16,1,3,251,0,0,0,0,0,0,11,255,255,255,255,255,255,255,255,209,0,0,12
    db 209,0,0,0,0,0,0,1,191,255,255,255,255,255,255,255,252,65,3,205,32,0,0,0,0,0,0,0,26,255,255,255
    db 255,255,255,255,255,253,223,193,0,0,0,0,0,0,0,0,0,109,255,255,255,255,255,255,255,255,231,0,0,0,0,0
    db 0,0,0,0,0,1,141,255,255,255,255,255,255,216,32,0,0,0,0,0,0,0,0,0,0,0,1,89,206,255,255,236
    db 149,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,35,51,16,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,24,136,136,129,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,243,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,243,0,0,0,0,0,0,0,0,0,0,0,0,3,128,0,0
    db 79,255,255,245,0,0,8,48,0,0,0,0,0,0,0,0,45,251,32,16,95,255,255,245,1,2,191,210,0,0,0,0
    db 0,0,0,2,223,255,211,0,111,255,255,246,0,61,255,253,32,0,0,0,0,0,0,61,255,255,254,82,175,255,255,250
    db 37,239,255,255,211,0,0,0,0,0,0,143,255,255,255,254,255,255,255,255,239,255,255,255,248,0,0,0,0,0,0,28
    db 255,255,255,255,255,255,255,255,255,255,255,255,193,0,0,0,0,0,0,2,223,255,255,255,255,255,255,255,255,255,255,253
    db 32,0,0,0,0,0,0,0,62,255,255,255,255,255,255,255,255,255,255,227,0,0,0,0,0,0,0,1,5,239,255,255
    db 255,254,239,255,255,255,255,80,16,0,0,0,0,0,0,0,0,239,255,255,251,82,37,175,255,255,254,32,0,0,0,0
    db 0,1,35,53,106,255,255,255,128,0,0,7,255,255,255,182,84,50,16,0,0,9,239,255,255,255,255,251,0,0,0,16
    db 175,255,255,255,255,254,144,0,0,10,255,255,255,255,255,245,0,0,0,0,63,255,255,255,255,255,160,0,0,10,255,255
    db 255,255,255,226,0,0,0,0,13,255,255,255,255,255,160,0,0,8,255,255,255,255,255,226,0,0,0,0,13,255,255,255
    db 255,255,160,0,0,8,255,255,255,255,255,244,0,0,0,0,63,255,255,255,255,255,160,0,0,8,239,255,255,255,255,250
    db 1,0,0,16,159,255,255,255,255,254,144,0,0,1,35,53,90,255,255,255,112,0,0,5,255,255,255,182,84,50,16,0
    db 0,0,0,0,1,239,255,255,250,49,3,159,255,255,255,48,0,0,0,0,0,0,0,1,5,239,255,255,255,253,223,255
    db 255,255,255,80,16,0,0,0,0,0,0,0,62,255,255,255,255,255,255,255,255,255,255,227,0,0,0,0,0,0,0,2
    db 223,255,255,255,255,255,255,255,255,255,255,253,32,0,0,0,0,0,0,28,255,255,255,255,255,255,255,255,255,255,255,255
    db 193,0,0,0,0,0,0,143,255,255,255,255,255,255,255,255,255,255,255,255,248,0,0,0,0,0,0,61,255,255,254,83
    db 191,255,255,251,69,239,255,255,211,0,0,0,0,0,0,2,223,255,211,0,111,255,255,246,0,61,255,253,32,0,0,0
    db 0,0,0,0,45,251,32,16,95,255,255,245,1,2,191,210,0,0,0,0,0,0,0,0,3,128,0,0,95,255,255,245
    db 0,0,8,48,0,0,0,0,0,0,0,0,0,0,0,0,63,255,255,243,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,63,255,255,243,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,25,170,170,145,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 2,34,34,33,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,222,238,238,237,96,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,29,255,255,255,255,242,0,0,0,0,0,0,0,0,0,0,0,0,0,0,30,255,255,255,255
    db 243,0,0,0,0,0,0,0,0,0,0,0,18,34,34,46,255,255,255,255,227,34,34,33,0,0,0,0,0,0,0,8
    db 238,238,238,239,255,255,255,255,254,238,238,238,160,0,0,0,0,0,0,31,255,255,255,255,255,255,255,255,255,255,255,255
    db 243,0,0,0,0,0,0,10,255,255,255,255,255,255,255,255,255,255,255,255,177,0,0,0,0,0,0,0,52,68,68,68
    db 68,68,68,68,68,68,68,67,0,0,0,0,0,0,0,0,13,238,238,238,238,238,238,238,238,238,238,210,0,0,0,0
    db 0,0,0,0,13,255,255,255,255,255,255,255,255,255,255,225,0,0,0,0,0,0,0,0,11,255,255,254,239,254,239,254
    db 239,255,255,208,0,0,0,0,0,0,0,0,10,255,255,146,159,226,46,249,41,255,255,192,0,0,0,0,0,0,0,0
    db 9,255,255,128,143,225,30,248,8,255,255,176,0,0,0,0,0,0,0,0,7,255,255,144,159,225,30,249,9,255,255,144
    db 0,0,0,0,0,0,0,0,6,255,255,144,159,225,30,249,9,255,255,128,0,0,0,0,0,0,0,0,4,255,255,144
    db 159,225,30,249,9,255,255,96,0,0,0,0,0,0,0,0,3,255,255,144,159,225,30,249,9,255,255,80,0,0,0,0
    db 0,0,0,0,2,239,255,144,159,225,30,249,9,255,255,48,0,0,0,0,0,0,0,0,0,223,255,144,159,225,30,249
    db 9,255,254,32,0,0,0,0,0,0,0,0,0,207,255,144,159,225,30,249,9,255,253,16,0,0,0,0,0,0,0,0
    db 0,191,255,144,159,225,30,249,9,255,252,0,0,0,0,0,0,0,0,0,0,175,255,144,159,225,30,249,9,255,251,0
    db 0,0,0,0,0,0,0,0,0,143,255,144,159,225,30,249,9,255,250,0,0,0,0,0,0,0,0,0,0,127,255,144
    db 159,225,30,249,9,255,248,0,0,0,0,0,0,0,0,0,0,95,255,237,239,253,223,254,222,255,247,0,0,0,0,0
    db 0,0,0,0,0,79,255,255,255,255,255,255,255,255,245,0,0,0,0,0,0,0,0,0,0,47,255,255,255,255,255,255
    db 255,255,244,0,0,0,0,0,0,0,0,0,0,3,51,51,51,51,51,51,51,51,48,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,18,33,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,21,156,222,237,202,97,0,0,0,0,0,0,0,0,0,0,0,0,0,24,223
    db 255,255,255,255,254,146,0,0,0,0,0,0,0,0,0,0,0,6,223,255,255,255,255,255,255,254,112,0,0,0,0,0
    db 0,0,0,0,0,159,255,255,255,255,255,255,255,255,250,16,0,0,0,0,0,0,0,0,10,255,255,255,255,255,255,255
    db 255,255,255,193,0,0,0,0,0,0,0,0,159,255,255,255,255,255,255,255,255,255,255,250,0,0,0,0,0,0,0,6
    db 255,255,255,255,255,179,42,255,255,255,255,255,112,0,0,0,0,0,0,30,255,255,255,255,255,32,1,239,255,255,255,255
    db 243,0,0,0,0,0,0,143,255,255,255,255,254,32,0,239,255,255,255,255,250,0,0,0,0,0,1,239,255,255,255,255
    db 255,162,25,255,255,255,255,255,254,32,0,0,0,0,5,255,255,255,255,255,255,254,239,255,255,255,255,255,255,112,0,0
    db 0,0,9,255,255,255,255,255,255,255,255,255,255,255,255,255,255,176,0,0,0,0,12,255,255,255,255,255,255,254,239,255
    db 255,255,255,255,255,208,0,0,0,0,13,255,255,255,255,255,255,130,39,255,255,255,255,255,255,226,0,0,0,0,46,255
    db 255,255,255,255,254,16,0,223,255,255,255,255,255,243,0,0,0,0,46,255,255,255,255,255,254,32,0,223,255,255,255,255
    db 255,243,0,0,0,0,30,255,255,255,255,255,254,32,0,223,255,255,255,255,255,226,0,0,0,0,12,255,255,255,255,255
    db 254,32,0,223,255,255,255,255,255,209,0,0,0,0,10,255,255,255,255,255,254,32,0,223,255,255,255,255,255,176,0,0
    db 0,0,6,255,255,255,255,255,254,32,0,223,255,255,255,255,255,112,0,0,0,0,1,239,255,255,255,255,254,32,0,223
    db 255,255,255,255,255,48,0,0,0,0,0,159,255,255,255,255,254,32,0,223,255,255,255,255,251,0,0,0,0,0,0,46
    db 255,255,255,255,254,32,0,223,255,255,255,255,243,0,0,0,0,0,0,7,255,255,255,255,254,16,0,223,255,255,255,255
    db 144,0,0,0,0,0,0,0,175,255,255,255,255,112,5,255,255,255,255,252,0,0,0,0,0,0,0,0,28,255,255,255
    db 255,253,223,255,255,255,255,210,0,0,0,0,0,0,0,0,1,175,255,255,255,255,255,255,255,255,251,32,0,0,0,0
    db 0,0,0,0,0,8,239,255,255,255,255,255,255,255,144,0,0,0,0,0,0,0,0,0,0,0,58,239,255,255,255,255
    db 255,180,0,0,0,0,0,0,0,0,0,0,0,0,0,39,189,239,254,219,115,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,35,50,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,18,34,34,34,34
    db 34,34,34,34,34,34,34,34,33,0,0,0,0,0,9,222,238,238,238,238,238,238,238,238,238,238,238,238,238,161,0,0
    db 0,0,159,255,255,255,255,255,255,255,255,255,255,255,255,255,255,250,0,0,0,1,239,254,238,238,238,238,238,238,238,238
    db 238,238,238,238,239,255,32,0,0,2,239,227,34,34,34,34,34,34,34,34,34,34,34,34,45,255,48,0,0,2,239,225
    db 0,0,0,0,0,0,0,0,0,0,0,0,13,255,48,0,0,2,239,226,0,0,0,0,0,0,0,0,172,32,0,0
    db 13,255,48,0,0,2,239,226,0,0,0,0,0,0,0,7,255,210,0,0,13,255,48,0,0,2,239,226,0,0,0,0
    db 0,0,0,79,237,253,32,0,13,255,48,0,0,2,239,226,0,0,0,0,0,0,1,223,130,223,210,0,13,255,48,0
    db 0,2,239,226,0,0,27,178,0,0,11,251,0,45,253,32,13,255,48,0,0,2,239,226,0,1,207,253,64,16,127,226
    db 1,2,223,211,13,255,48,0,0,2,239,226,0,28,253,175,246,4,255,80,0,0,45,250,13,255,48,0,0,2,239,226
    db 1,207,227,7,255,157,248,0,0,0,2,161,13,255,48,0,0,2,239,225,44,254,48,16,77,255,176,0,0,0,0,0
    db 13,255,48,0,0,2,239,224,143,227,0,0,2,205,32,0,0,0,0,0,13,255,48,0,0,2,239,225,25,64,0,0
    db 0,0,0,0,0,0,0,0,13,255,48,0,0,2,239,226,0,0,0,0,0,0,0,0,0,0,0,0,13,255,48,0
    db 0,2,239,226,0,0,0,0,0,0,0,0,0,0,0,0,13,255,48,0,0,2,239,226,0,0,0,0,0,0,0,0
    db 0,0,0,0,13,255,48,0,0,2,239,226,0,0,0,0,0,0,0,0,0,0,0,0,13,255,48,0,0,1,239,253
    db 221,221,221,221,221,221,221,221,221,221,221,221,223,255,48,0,0,0,175,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,251,0,0,0,0,26,239,255,255,255,255,255,255,255,255,255,255,255,255,255,178,0,0,0,0,0,35,51,51,51,51
    db 51,51,51,51,51,51,51,51,51,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,27,238,238,238,238,210,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,255,255,255,255
    db 226,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,51,51,51,51,16,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,18,34,34,34,34,34,34,34,34,34,34,34,34,33,0,0,0,0,0,59,238,238,238,238,238,238,238,238,238
    db 238,238,238,238,238,180,0,0,0,3,239,255,255,255,255,255,255,255,255,255,255,255,255,255,255,254,64,0,0,11,255,238
    db 239,238,239,254,239,254,238,254,238,255,238,255,238,239,192,0,0,30,254,50,79,98,46,146,41,226,38,244,34,233,34,189
    db 34,127,243,0,0,46,254,16,47,64,14,144,9,224,4,242,0,233,0,188,0,111,243,0,0,46,254,67,95,115,62,163
    db 58,227,55,245,51,234,51,189,51,143,243,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0
    db 0,46,255,238,239,238,239,254,239,254,238,254,238,255,238,255,238,239,243,0,0,46,254,50,79,98,46,146,41,226,38,244
    db 34,233,34,189,34,127,243,0,0,46,254,16,47,64,14,144,9,224,4,242,0,233,0,188,0,111,243,0,0,46,254,67
    db 95,115,62,163,58,227,55,245,51,234,51,189,51,143,243,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,255,243,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,46,255,255,255,249,136,136
    db 136,136,136,136,136,136,142,255,255,255,243,0,0,46,255,255,255,224,0,0,0,0,0,0,0,0,13,255,255,255,243,0
    db 0,46,255,255,255,225,0,0,0,0,0,0,0,0,13,255,255,255,243,0,0,46,255,255,255,250,170,170,170,170,170,170
    db 170,170,174,255,255,255,243,0,0,46,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,30,255,255
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,255,243,0,0,11,255,255,255,255,255,255,255,255,255,255,255,255,255,255
    db 255,255,208,0,0,4,239,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,80,0,0,0,76,255,255,255,255,255
    db 255,255,255,255,255,255,255,255,255,213,0,0,0,0,0,51,51,51,51,51,51,51,51,51,51,51,51,51,51,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,1,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 40,206,237,147,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,239,255,255,254,112,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,95,255,255,255,255,247,0,0,0,0,0,0,0,0,0,0,0,0,0,2,239,255,255,255,255
    db 255,48,0,0,0,0,0,0,0,0,0,0,0,0,8,255,255,255,255,255,255,160,0,0,0,0,0,0,0,0,0,0
    db 0,0,12,255,255,255,255,255,255,225,0,0,0,0,0,0,0,0,0,0,0,0,30,255,255,255,255,255,255,243,0,0
    db 0,0,0,0,0,0,0,0,0,0,30,255,255,255,255,255,255,243,0,0,0,0,0,0,0,0,0,0,0,0,13,255
    db 255,255,255,255,255,225,0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,255,255,255,255,176,0,0,0,0,0,0
    db 0,0,0,0,0,0,3,255,255,255,255,255,255,64,0,0,0,0,0,0,0,0,0,0,0,0,0,127,255,255,255,255
    db 249,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,255,255,255,255,144,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,74,223,254,181,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,19,49,0,16,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,1,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5
    db 156,222,237,201,81,0,0,0,0,0,0,0,0,0,0,0,0,0,7,223,255,255,255,255,253,129,0,0,0,0,0,0
    db 0,0,0,0,0,3,207,255,255,255,255,255,255,253,64,0,0,0,0,0,0,0,0,0,0,94,255,255,255,255,255,255
    db 255,255,246,0,0,0,0,0,0,0,0,0,5,239,255,255,255,255,255,255,255,255,255,96,0,0,0,0,0,0,0,0
    db 62,255,255,255,255,255,255,255,255,255,255,244,0,0,0,0,0,0,0,0,207,255,255,255,255,255,255,255,255,255,255,253
    db 16,0,0,0,0,0,0,6,255,255,255,255,255,255,255,255,255,255,255,255,128,0,0,0,0,0,0,13,255,255,255,255
    db 255,255,255,255,255,255,255,255,225,0,0,0,0,0,0,95,255,255,255,255,255,255,255,255,255,255,255,255,246,0,0,0
    db 0,0,0,142,238,238,238,238,238,238,238,238,238,238,238,238,234,0,0,0,0,0,0,18,34,34,34,34,34,34,34,34
    db 34,34,34,34,33,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,16,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,93,230,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,223,255,32,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,239,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,223,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,48,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,223,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,48
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,223,255,48,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,223,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,103,0,0,223,255,48,16,104,0,0
    db 0,0,0,0,0,0,0,0,0,8,255,48,0,223,255,48,2,239,144,0,0,0,0,0,0,0,0,0,0,111,255,193
    db 0,223,255,48,28,255,247,0,0,0,0,0,0,0,0,0,2,239,255,244,0,223,255,48,62,255,255,64,0,0,0,0
    db 0,0,0,0,10,255,255,80,0,223,255,48,3,239,255,192,0,0,0,0,0,0,0,0,63,255,247,0,0,223,255,48
    db 16,95,255,244,0,0,0,0,0,0,0,0,143,255,192,0,1,223,255,48,0,11,255,250,0,0,0,0,0,0,0,0
    db 191,255,112,0,1,239,255,32,0,5,255,253,0,0,0,0,0,0,0,0,223,255,48,0,0,110,232,0,0,2,239,254
    db 32,0,0,0,0,0,0,2,239,254,32,0,0,2,32,0,0,0,223,255,48,0,0,0,0,0,0,2,239,254,16,0
    db 0,0,0,0,0,0,223,255,48,0,0,0,0,0,0,0,223,255,48,0,0,0,0,0,0,2,239,254,32,0,0,0
    db 0,0,0,0,207,255,112,0,0,0,0,0,0,5,255,253,0,0,0,0,0,0,0,0,143,255,192,0,0,0,0,0
    db 0,10,255,250,0,0,0,0,0,0,0,0,63,255,246,1,0,0,0,0,16,79,255,245,0,0,0,0,0,0,0,0
    db 11,255,254,48,0,0,0,1,2,223,255,208,0,0,0,0,0,0,0,0,3,255,255,230,0,0,0,0,93,255,255,80
    db 0,0,0,0,0,0,0,0,0,127,255,255,181,32,2,90,255,255,249,0,0,0,0,0,0,0,0,0,0,9,255,255
    db 255,237,222,255,255,255,160,0,0,0,0,0,0,0,0,0,0,0,127,255,255,255,255,255,255,249,0,0,0,0,0,0
    db 0,0,0,0,0,0,4,207,255,255,255,255,252,80,0,0,0,0,0,0,0,0,0,0,0,0,0,5,173,239,254,218
    db 80,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,35,50,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,32,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,40,206,236,146,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5
    db 223,255,255,254,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,94,255,255,255,255,246,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,2,239,255,217,157,255,255,64,0,0,0,0,0,0,0,0,0,0,0,0,10,255,250,16,0,159
    db 255,192,0,0,0,0,0,0,0,0,0,0,0,0,63,255,192,1,16,11,255,245,0,0,0,0,0,0,0,0,0,0
    db 0,0,143,255,80,0,0,3,255,250,0,0,0,0,0,0,0,0,0,0,0,0,207,253,0,0,0,0,191,253,0,0
    db 0,0,0,0,0,0,0,0,0,0,223,250,0,0,0,0,143,254,32,0,0,0,0,0,0,0,0,0,0,2,239,248
    db 0,0,0,0,127,255,48,0,0,0,0,0,0,0,0,0,0,0,223,250,1,0,0,16,143,254,32,0,0,0,0,0
    db 0,0,0,0,0,0,223,250,0,0,0,0,143,254,16,0,0,0,0,0,0,0,0,0,0,1,223,250,34,34,34,34
    db 159,254,32,0,0,0,0,0,0,0,0,0,3,190,255,255,238,238,238,238,255,255,235,64,0,0,0,0,0,0,0,0
    db 62,255,255,255,255,255,255,255,255,255,255,228,0,0,0,0,0,0,0,0,191,255,255,255,255,255,255,255,255,255,255,252
    db 0,0,0,0,0,0,0,1,239,255,255,255,255,255,255,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255
    db 255,255,255,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,255,179,42,255,255,255,255,255,48,0,0,0
    db 0,0,0,2,239,255,255,255,255,32,1,239,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,254,32,0,239
    db 255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,255,161,25,255,255,255,255,255,48,0,0,0,0,0,0,2
    db 239,255,255,255,255,243,47,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,255,242,47,255,255,255,255,255
    db 48,0,0,0,0,0,0,2,239,255,255,255,255,242,47,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255
    db 255,253,223,255,255,255,255,255,48,0,0,0,0,0,0,1,239,255,255,255,255,255,255,255,255,255,255,255,48,0,0,0
    db 0,0,0,0,191,255,255,255,255,255,255,255,255,255,255,253,0,0,0,0,0,0,0,0,78,255,255,255,255,255,255,255
    db 255,255,255,245,0,0,0,0,0,0,0,0,4,207,255,255,255,255,255,255,255,255,253,80,0,0,0,0,0,0,0,0
    db 0,3,51,51,51,51,51,51,51,51,48,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,18,33,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,21,156,222,237,202,97,0,0,0,0,0,0,0,0,0,0,0,0,0,24,223
    db 255,255,255,255,254,146,0,0,0,0,0,0,0,0,0,0,0,6,223,255,255,255,255,255,255,254,112,0,0,0,0,0
    db 0,0,0,0,0,159,255,255,255,255,84,122,239,255,250,16,0,0,0,0,0,0,0,0,10,255,255,255,255,255,48,0
    db 39,239,255,193,0,0,0,0,0,0,0,0,159,255,255,255,255,255,48,16,0,43,255,250,0,0,0,0,0,0,0,6
    db 255,255,255,255,255,255,48,0,0,0,159,255,112,0,0,0,0,0,0,30,255,255,255,255,255,255,48,0,0,0,11,255
    db 243,0,0,0,0,0,0,143,255,255,255,255,255,255,48,0,0,0,1,239,250,0,0,0,0,0,1,239,255,255,255,255
    db 255,255,48,0,0,0,0,111,254,32,0,0,0,0,5,255,255,255,255,255,255,255,48,0,0,0,0,29,255,112,0,0
    db 0,0,9,255,255,255,255,255,255,255,48,0,0,0,0,9,255,176,0,0,0,0,12,255,255,255,255,255,255,255,48,0
    db 0,0,0,5,255,208,0,0,0,0,13,255,255,255,255,255,255,255,48,0,0,0,0,3,255,226,0,0,0,0,46,255
    db 255,255,255,255,255,255,48,0,0,0,0,2,239,243,0,0,0,0,46,255,255,255,255,255,255,255,48,0,0,0,0,1
    db 239,243,0,0,0,0,30,255,255,255,255,255,255,255,48,0,0,0,0,3,255,226,0,0,0,0,12,255,255,255,255,255
    db 255,255,48,0,0,0,0,5,255,209,0,0,0,0,10,255,255,255,255,255,255,255,48,0,0,0,0,8,255,176,0,0
    db 0,0,6,255,255,255,255,255,255,255,48,0,0,0,0,13,255,112,0,0,0,0,1,239,255,255,255,255,255,255,48,0
    db 0,0,0,95,255,48,0,0,0,0,0,159,255,255,255,255,255,255,48,0,0,0,1,223,251,0,0,0,0,0,0,46
    db 255,255,255,255,255,255,48,0,0,0,10,255,243,0,0,0,0,0,0,7,255,255,255,255,255,255,48,0,0,0,143,255
    db 144,0,0,0,0,0,0,0,175,255,255,255,255,255,48,16,0,26,255,252,0,0,0,0,0,0,0,0,28,255,255,255
    db 255,255,48,0,6,223,255,210,0,0,0,0,0,0,0,0,1,175,255,255,255,255,67,88,223,255,251,32,0,0,0,0
    db 0,0,0,0,0,8,239,255,255,255,239,255,255,255,144,0,0,0,0,0,0,0,0,0,0,0,58,239,255,255,255,255
    db 255,180,0,0,0,0,0,0,0,0,0,0,0,0,0,39,189,239,254,219,115,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,35,50,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,8,144,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,159,250,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,255,255,161,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,175,255,255,252,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,27,255,255,255,255
    db 194,0,0,0,0,0,0,0,0,0,0,0,0,0,1,207,255,255,255,255,253,32,0,0,0,0,0,0,0,0,0,0
    db 0,0,44,255,255,255,255,255,255,211,0,0,0,0,0,0,0,0,0,0,0,2,223,255,255,255,255,255,255,254,48,0
    db 0,0,0,0,0,0,0,0,0,61,255,255,255,255,255,255,255,255,228,1,0,0,0,0,0,0,0,0,3,239,255,255
    db 255,255,255,255,255,255,254,80,16,0,0,0,0,0,0,16,94,255,255,255,255,255,255,255,255,255,255,230,1,0,0,0
    db 0,0,1,5,239,255,255,255,255,255,255,255,255,255,255,255,96,0,0,0,0,0,0,111,255,255,255,255,255,255,255,255
    db 255,255,255,255,247,0,0,0,0,0,6,255,255,255,255,255,255,255,255,255,255,255,255,255,255,128,0,0,0,0,127,255
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,249,0,0,0,0,51,52,239,255,255,255,255,255,255,255,255,255,255,255
    db 83,52,0,0,0,0,0,1,239,255,255,255,255,255,255,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255
    db 255,255,255,255,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,254,238,238,239,255,255,255,255,48,0,0,0
    db 0,0,0,2,239,255,255,255,227,34,34,45,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,225,0,0,13
    db 255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,226,0,0,13,255,255,255,255,48,0,0,0,0,0,0,2
    db 239,255,255,255,226,0,0,13,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,226,0,0,13,255,255,255,255
    db 48,0,0,0,0,0,0,2,239,255,255,255,226,0,0,13,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255
    db 226,0,0,13,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,226,0,0,13,255,255,255,255,48,0,0,0
    db 0,0,0,2,239,255,255,255,226,0,0,13,255,255,255,255,48,0,0,0,0,0,0,2,239,255,255,255,226,0,0,13
    db 255,255,255,255,48,0,0,0,0,0,0,0,51,51,51,51,48,0,0,3,51,51,51,51,16,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,18,34,34,34,34,34,34,34,34,34,34,34,34,33,0,0,0,0,0,9,222,238,238,238,238
    db 238,238,238,238,238,238,238,238,238,161,0,0,0,0,159,255,255,255,255,255,255,255,255,255,255,255,255,255,255,250,0,0
    db 0,1,239,254,238,238,238,238,238,238,238,238,238,238,238,238,239,255,32,0,0,2,239,230,85,85,85,85,85,85,85,85
    db 85,85,85,85,94,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229
    db 69,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68
    db 77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68
    db 68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0
    db 0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68
    db 68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229
    db 68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68
    db 77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68
    db 68,68,68,68,68,68,68,68,77,255,48,0,0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0
    db 0,2,239,229,68,68,68,68,68,68,68,68,68,68,68,68,77,255,48,0,0,1,239,254,221,221,221,221,221,221,221,221
    db 221,221,221,221,223,255,48,0,0,0,175,255,255,255,255,255,255,255,255,255,255,255,255,255,255,251,0,0,0,0,26,239
    db 255,255,255,255,255,255,255,255,255,255,255,255,255,178,0,0,0,0,0,35,51,51,51,51,52,68,68,67,51,51,51,51
    db 51,0,0,0,0,0,0,0,0,0,0,0,174,238,238,236,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1
    db 255,255,255,255,48,0,0,0,0,0,0,0,0,0,0,0,0,0,18,35,239,255,255,255,66,33,0,0,0,0,0,0
    db 0,0,0,0,0,8,238,238,255,255,255,255,238,238,160,0,0,0,0,0,0,0,0,0,0,31,255,255,255,255,255,255
    db 255,255,243,0,0,0,0,0,0,0,0,0,0,10,255,255,255,255,255,255,255,255,177,0,0,0,0,0,0,0,0,0
    db 0,0,51,51,51,51,51,51,51,51,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
cursor_outline:
    db 0,48,0,0,0,0,0,0,106,230,0,0,0,0,0,0,191,255,112,0,0,0,0,0,191,255,248,0,0,0,0,0
    db 191,255,255,144,0,0,0,0,191,255,255,250,0,0,0,0,191,255,255,255,161,0,0,0,191,255,255,255,252,16,0,0
    db 191,255,255,255,255,194,0,0,191,255,255,255,255,253,48,0,191,255,255,255,255,255,227,0,191,255,255,255,255,255,254,64
    db 191,255,255,255,255,255,255,192,191,255,255,255,255,204,203,96,191,255,255,255,255,128,0,0,191,255,238,255,255,225,0,0
    db 191,255,71,255,255,246,0,0,191,229,2,239,255,252,0,0,58,64,16,175,255,255,80,0,0,0,0,63,255,255,80,0
    db 0,0,0,11,253,147,0,0,0,0,0,2,97,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
cursor_fill:
    db 0,0,0,0,0,0,0,0,3,0,0,0,0,0,0,0,9,176,0,0,0,0,0,0,8,251,16,0,0,0,0,0
    db 8,255,193,0,0,0,0,0,8,255,253,32,0,0,0,0,8,255,255,211,0,0,0,0,8,255,255,254,64,0,0,0
    db 8,255,255,255,229,1,0,0,8,255,255,255,255,96,0,0,8,255,255,255,255,247,0,0,8,255,255,255,255,255,145,0
    db 8,255,255,255,218,170,180,0,8,255,254,255,208,0,0,0,8,255,163,255,246,1,0,0,8,250,0,191,252,0,0,0
    db 9,176,0,79,255,48,0,0,4,16,0,12,255,144,0,0,0,0,0,6,255,242,0,0,0,0,0,1,220,113,0,0
    db 0,0,0,0,32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; ---- end assets.inc
; ---- begin logos.inc
logo_rainbow_64:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFF7F,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFD7FFF7F,0xFF000000,0xC78DBA7F,0xD390BF7F,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFC55AA55,0xFBFFFFFF,0x216DB65A,0x3C6FB45C,0xFF000000,0xFC55AA55,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB7FBF3F,0xFF000000,0x907EBA6E,0x0067C04F
    dd 0x0068BE51,0xA182BB71,0xFF000000,0xFCAAAA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFF7F
    dd 0xFE000000,0xE3ADC89A,0x0F6DB957,0x025FB749,0x0162B94B,0x1A6DB857,0xEFBFCF9F,0xFD7F7F00,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0x5874B861,0x0065C14D,0x035FB448,0x0460B44A,0x006AC252,0x7378B764,0xFF000000
    dd 0xFB7FBF3F,0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFB7FBF3F,0xFE000000,0xC98DC17A,0x0069BD52,0x035EB545,0x0060B549
    dd 0x0160B549,0x0260B649,0x076ABA56,0xD89CCA89,0xFE000000,0xFF000000,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0x5372B75E,0x0164BF4C,0x045FB549,0x005DB445,0x005DB445,0x045FB449,0x0068C250,0x6678BA62,0xFF000000,0xF1B6B6B6,0xFF000000,0xFE00FF00
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00
    dd 0xFD7F7F7F,0xF7BFDFBF,0x6A7EB86F,0xBA97C388,0x0364B64F,0x015FB547,0x005EB446,0x006AB954,0x0067B851,0x015DB446,0x015FB749,0x1066B553
    dd 0xB094C48A,0x3878B865,0xEEA5D296,0xFD7F7F7F,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0x827ABB68,0x006EC556,0x186DB859,0x005FB648,0x0061B64A,0x0054B03B,0x00AED8A1
    dd 0x009FD190,0x0054B03B,0x0061B64A,0x0060B64B,0x0F6DB85B,0x0069C451,0x6676B764,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB7FBF7F,0xFD7F7F00,0xE4AACFA0,0x0D6AB955,0x035EB845,0x005FB748
    dd 0x005FB548,0x0061B64A,0x0054B03B,0x00B3DAA5,0x00A4D295,0x0053B03B,0x0061B64A,0x015FB548,0x005FB648,0x045FB548,0x006BBD55,0xBE8DC07D
    dd 0xFE000000,0xFD7FFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFF000000,0xFF000000
    dd 0x6676BA64,0x0067C14E,0x0460B448,0x015FB447,0x0060B549,0x0061B64A,0x0055B03C,0x00B3D9A6,0x00A4D296,0x0054B03B,0x0062B64A,0x0060B548
    dd 0x015EB447,0x0362B54A,0x0066BE4C,0x3A73B95E,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFE00FF00,0xFF000000,0xBB87B77F,0xDAA5C7A5,0x1167B655,0x015FB649,0x0162B44B,0x0064B54C,0x005DB346,0x0061B54B,0x0055B03D,0x00B3D9A7
    dd 0x00A3D196,0x0052B03B,0x0062B64B,0x005FB548,0x0067B74F,0x0061B44B,0x015FB349,0x0266B751,0x8788BD77,0x5678B869,0xFDFFFFFF,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFEFFFF00,0xEA9DC29D,0x1075B558,0x2E7DB962,0x0069B64B,0x0069B649,0x0063B142,0x00BEDEB1
    dd 0x0092C778,0x0060B340,0x005DB23D,0x00B9DBA8,0x00A7D296,0x005AB13A,0x0065B645,0x007ABD5A,0x00D0E6C8,0x006DB753,0x0066B646,0x0067B648
    dd 0x006DB64F,0x0076C457,0xAE90C37A,0xFF000000,0xFCAAFF55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBFBF3F,0xFF000000,0x7AE7CB56,0x00EDD131,0x00DFC42C
    dd 0x00E0C12A,0x00E1C32C,0x00E1BE1E,0x00F1D988,0x00EAE8BD,0x00DFC021,0x00E2C01E,0x00EBDE9B,0x00E8DA87,0x00E1C01E,0x00E0BE1D,0x00E7E3A5
    dd 0x00F4E1A6,0x00E1BF21,0x00E0C32C,0x00E0C22A,0x04E0C229,0x01EBCB2C,0x37E4C646,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFEFFFF00
    dd 0xF1ECDAC8,0x16F2C638,0x01FFC622,0x04FBC224,0x00FAC123,0x00F9C223,0x00FCC222,0x00F5C329,0x00F3ECCD,0x00F8D46A,0x00FCBB07,0x00F4E09D
    dd 0x00F5DA85,0x00FCBB0A,0x00F9D15F,0x00F6EFD5,0x00F5C431,0x00FBC11F,0x00FAC225,0x00FAC124,0x01FAC125,0x01FBC121,0x02FAC930,0xCEEFD572
    dd 0xFEFFFF00,0xFCFFFF55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFCFFAA00,0xFF000000,0xA8F0CD5A,0x00FFCF2D,0x03F4C023,0x00F5C126,0x00F5C125,0x00F5C125,0x00F5C228,0x00F6BF1B
    dd 0x00F2D165,0x00F0F0DB,0x00F3C023,0x00F2E09D,0x00F3D87E,0x00F3BE1E,0x00F2EFDE,0x00F2D472,0x00F6BE17,0x00F5C228,0x00F5C125,0x00F5C126
    dd 0x00F5C227,0x04F5C125,0x00FFD12A,0x76F0C946,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xF6E2C68D,0xF7DFDFFF,0x5FF2C841,0x01FFCE27,0x04F6C024,0x00F7C022
    dd 0x00F6C126,0x00F6C125,0x00F6C125,0x00F7C128,0x00F5BE1A,0x00F2DF9D,0x00F3E4B3,0x00F1DE9E,0x00F1D886,0x00F4E3AE,0x00F2E0A1,0x00F6BF1A
    dd 0x00F6C227,0x00F6C025,0x00F6C125,0x00F6C125,0x00F6BE1B,0x02F6C125,0x00FECB25,0x3AF3C740,0x7CEFD06B,0xAFEFC856,0xFF000000,0xFCFFAA55
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBFBF3F,0xFF000000,0x9CF2CB52,0x46F2D05D
    dd 0x2DF2C73C,0x00FDC722,0x01F5C127,0x00F5C32B,0x00F6C124,0x00F6C126,0x00F6C024,0x00F6C126,0x00F7C225,0x00F5C124,0x00F3E5B6,0x00EFF1E5
    dd 0x00F0F0E5,0x00F3E3AE,0x00F5C020,0x00F7C223,0x00F6C126,0x00F6C025,0x00F7C123,0x00F4C32B,0x00F3D46D,0x00F6C32C,0x00F8C122,0x05F5C32D
    dd 0x00FFD63A,0x62F2C744,0xFF000000,0xFBFFBF3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFCFFAA00,0xFF000000,0x4EF2C842,0x00FFD52D,0x01F4C22B,0x00F7BF20,0x00F6C435,0x00F3E7BC,0x00F4C73C,0x00F7C020,0x00F5C026,0x00F6C025
    dd 0x00F7C228,0x00F7C022,0x00F5C12B,0x00F1E9C8,0x00F0E6BB,0x00F5C125,0x00F7C122,0x00F6C126,0x00F6C024,0x00F6C128,0x00F7BE19,0x00F4D675
    dd 0x00F2EAC7,0x00F5BF23,0x00F7C126,0x02F5C024,0x02FFC922,0x30F2C63D,0xFF000000,0xFEFF0000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFF000000,0xF7FFFFFF,0x1CF3C939,0x02FCC921,0x02F6C323,0x00F8C527,0x00F6C21A,0x00F3E7AF
    dd 0x00F3DE9A,0x00F6BF15,0x00F7C528,0x00F7C425,0x00F7C425,0x00F7C529,0x00F8BF14,0x00F2DF99,0x00F2D983,0x00F7C014,0x00F6C52A,0x00F6C425
    dd 0x00F7C427,0x00F7C423,0x00F4C22A,0x00F3EFD3,0x00F4D467,0x00F7C31B,0x00F7C528,0x01F6C427,0x00FAC724,0x0AF4C735,0xE1E5D490,0xFDFF7F7F
    dd 0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFF7F,0xFDFF7F7F,0xD0EEC877,0x01F5B931,0x01F6B523
    dd 0x00F5B525,0x00F6B627,0x00F6B621,0x00F3BC45,0x00F2EFDC,0x00F2C249,0x00F6B21E,0x00F5B528,0x00F5B425,0x00F5B527,0x00F5B019,0x00F2DDA2
    dd 0x00F1D68E,0x00F4AF17,0x00F5B428,0x00F5B426,0x00F7B82B,0x00F5B118,0x00F3DD96,0x00F2DBAB,0x00F6AF18,0x00F6B320,0x00F6B422,0x00F5B527
    dd 0x01F4B323,0x00FABC30,0xCBF0C966,0xFF000000,0xFCFFAA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFAA55
    dd 0xFF000000,0xBAE8A258,0x00FB902D,0x03F28522,0x00F38724,0x00F28622,0x00F1831E,0x00F07606,0x00F0B576,0x00F1DABC,0x00F1831D,0x00F28524
    dd 0x00F28524,0x00F28725,0x00F27E14,0x00F1CAA0,0x00EEC08F,0x00F27D15,0x00F28626,0x00F28727,0x00F38017,0x00F1A459,0x00F1E4D3,0x00EF8D32
    dd 0x00F08526,0x00F19A48,0x00F29235,0x00F28422,0x01F08322,0x01F48C2D,0xA2E9AF73,0xC9E2AE7A,0xFEFFFF00,0xFD7F7F7F,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFEFFFF00,0xFDFF7F00,0xCAE2AD7D,0x92E7A364,0x00FD902A,0x03F38825,0x00F2831D,0x00F1BB81,0x00F1DCC1,0x00F0C79C
    dd 0x00EDC18E,0x00F1F8F3,0x00F0BC86,0x00F17B10,0x00F38928,0x00F38927,0x00F37F15,0x00F0CA9F,0x00EEC08E,0x00F37E15,0x00F38A2A,0x00F4841E
    dd 0x00F08C2F,0x00F1EDE0,0x00EFEDE2,0x00F0D9BC,0x00F0E3CD,0x00F0E5D0,0x00F2A85E,0x00F3821B,0x00F48725,0x05F28927,0x0CFA9F46,0x61EA9443
    dd 0xFF000000,0xFBFF7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAA5500,0xFF000000,0x45EB9648,0x11F79C46,0x02F28825,0x00F38724
    dd 0x00F28522,0x00F19742,0x00F0B274,0x00F0C697,0x00F1CDA7,0x00EDC69D,0x00F0E9DA,0x00F0B274,0x00F27F16,0x00F48B2B,0x00F37F16,0x00F0CA9F
    dd 0x00EEC18F,0x00F38017,0x00F48824,0x00F28A2A,0x00F2E1C9,0x00EFCBA3,0x00F0AC69,0x00F0AD6A,0x00F09E50,0x00EF8C30,0x00F18623,0x00F38825
    dd 0x00F38724,0x04F38724,0x00FF9024,0x64EC8D33,0xFF000000,0xFBFF7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFF0000,0xFF000000
    dd 0x37EE9038,0x00FF8D22,0x03F28724,0x00F38724,0x00F38826,0x00F38520,0x00F37F15,0x00F27E14,0x00F28019,0x00F17C12,0x00EF9E4F,0x00F2F1E6
    dd 0x00EFAE6C,0x00F37F17,0x00F48119,0x00F0CBA0,0x00EFC493,0x00F47F14,0x00F28520,0x00F2DBBE,0x00F0CFAC,0x00F17F16,0x00F38015,0x00F38017
    dd 0x00F3811A,0x00F38622,0x00F38622,0x00F3841E,0x00F38825,0x04F38724,0x01FF8F26,0x5CEC913B,0xFDFF7F7F,0xFCFFAA00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFEFF0000,0xFEFFFFFF,0x32EE913A,0x01FD8B24,0x02F28724,0x00F38825,0x00F3821B,0x00F3841F,0x00F28928,0x00F38826
    dd 0x00F38826,0x00F38A28,0x00F38118,0x00F0A054,0x00F1F0E5,0x00F0B273,0x00F27706,0x00F1CDA2,0x00EFC28E,0x00F17A0D,0x00F1D7B8,0x00EFD5B5
    dd 0x00F0811B,0x00F48722,0x00F38926,0x00F38826,0x00F28724,0x00F38622,0x00F18D2F,0x00F19740,0x00F28621,0x04F28724,0x00FF9127,0x69EE9540
    dd 0xFF000000,0xFBFF7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFF0000,0xFF000000,0x37EE913E,0x00FE8B24,0x03F28626,0x00F2821D
    dd 0x00F1A45C,0x00F09D4E,0x00F3821C,0x00F38726,0x00F38624,0x00F38624,0x00F38828,0x00F27E17,0x00F09C52,0x00F0EFE6,0x00EFB274,0x00F0C799
    dd 0x00EBC497,0x00F0CDA6,0x00F1DAC2,0x00EF8524,0x00F48521,0x00F38725,0x00F38523,0x00F38524,0x00F38826,0x00F18018,0x00F2D3AF,0x00F2C595
    dd 0x00F17E16,0x04F38725,0x00FD8F28,0x75EC9E58,0xDCE1AE83,0xFCFF5555,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFAA00,0xF6FFFFFF
    dd 0x58EE9D44,0x00FF9425,0x04F38D24,0x00F48516,0x00F3BA77,0x00F3EAD5,0x00F08625,0x00F58B21,0x00F48D25,0x00F48C23,0x00F48B23,0x00F48D26
    dd 0x00F48619,0x00F19A3F,0x00F2E8CB,0x00F1EFE1,0x00F1F6ED,0x00F2D5AB,0x00F2881F,0x00F58B21,0x00F48D25,0x00F48C23,0x00F48B22,0x00F58F26
    dd 0x00F48316,0x00F1AA67,0x00F4EBD2,0x00F1902C,0x00F58B21,0x00F48C23,0x03F38C24,0x0BFB9D3C,0x59E99648,0xFF000000,0xFBBF7F00,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFEFF0000,0xFEFFFFFF,0x56D9725F,0x23EA6C4E,0x01EC5F2E,0x01E85E2E,0x00EA6131,0x00E65222,0x00ECB5A9,0x00F0C9A8,0x00E65722
    dd 0x00EA6132,0x00E95E2F,0x00E95E2F,0x00EA5E2E,0x00EA6032,0x00E95B26,0x00E4613B,0x00EED6D2,0x00EDC8C1,0x00E6562A,0x00EA5D2C,0x00EA5F31
    dd 0x00EA5E2E,0x00EA5E2F,0x00E96032,0x00E85B29,0x00E87442,0x00F3ECDD,0x00E6795C,0x00E95622,0x00E96032,0x00EA5F30,0x04E85D2E,0x00FA6732
    dd 0x70E67E52,0xFF000000,0xFBFF3F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAA0000,0xFF000000,0x4ADB5354,0x00F33C3C,0x03E03538,0x00E23639,0x00E2363A
    dd 0x00E03235,0x00DD433F,0x00F0E1DC,0x00E38787,0x00DD2428,0x00E3393C,0x00E13639,0x00E23639,0x00E13639,0x00E23A3E,0x00DE2626,0x00EAADA6
    dd 0x00E8A4A0,0x00DE2528,0x00E2393C,0x00E23538,0x00E23538,0x00E2373A,0x00E23538,0x00DC3233,0x00EECAC9,0x00E9A49E,0x00DF2F2F,0x00E2393D
    dd 0x00E13538,0x00E13639,0x04E23538,0x01EE3D40,0x91D7615C,0xFF000000,0xFBFF3F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBF3F3F,0xFF000000,0x72DC5E5C
    dd 0x02F1413D,0x04E33B36,0x00E33C37,0x00E33B37,0x00E43C38,0x00E3342F,0x00DF534D,0x00F0DED5,0x00E47974,0x00E1302C,0x00E4403B,0x00E33C38
    dd 0x00E33C38,0x00E43E3A,0x00E12F2A,0x00EAB3AD,0x00E9ABA5,0x00DF2D2A,0x00E43E3A,0x00E33C37,0x00E33D38,0x00E33C38,0x00DE3732,0x00EDC2B8
    dd 0x00E8B4AD,0x00D9211F,0x00E02F2C,0x00E0322E,0x00E33C37,0x00E23B37,0x01E33A36,0x00E74741,0xCBD27A6B,0xFF000000,0xFCAA5555,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFBBF3F3F,0xFF000000,0xA4D76767,0x00EF4542,0x03E23835,0x00E33A38,0x00E23A38,0x00E13F3D,0x00E04845,0x00DE4B48,0x00E6B0A9
    dd 0x00F5FFFF,0x00E16D69,0x00E02B2A,0x00E33E3D,0x00E23A38,0x00E43D3A,0x00E02D2A,0x00EBB3AE,0x00E9ACA7,0x00DF2B2A,0x00E43D3A,0x00E33C39
    dd 0x00E33D3A,0x00DD302E,0x00EAAEA6,0x00F3FEF7,0x00EBCEC7,0x00EAB6AE,0x00E9B8B0,0x00E78E89,0x00E13634,0x02E23B38,0x00ED3B38,0x31DB504C
    dd 0xFF000000,0xFEFF0000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFF000000,0xF9D4FFFF,0x19DD4544,0x00E93A37,0x01E23B38,0x00DF3735
    dd 0x00EBAFA9,0x00EFE1DA,0x00EFDFD9,0x00ECC4BE,0x00E6A29B,0x00F1E7DE,0x00E36C6B,0x00DF2C2B,0x00E33D3B,0x00E43D3A,0x00E02E2B,0x00ECB5AF
    dd 0x00E9ACA8,0x00DF2B29,0x00E43F3C,0x00E43B39,0x00DE2F2E,0x00EAACA8,0x00EDD0C9,0x00DC534F,0x00E4756E,0x00E7938E,0x00E89F99,0x00E57E7A
    dd 0x00E13735,0x01E23B38,0x03E63A37,0x1BE8504D,0x86D46960,0xFEFF0000,0xFCAA5555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFEFF0000,0xBAD27976
    dd 0x33E15755,0x01EB3B38,0x02E23B38,0x00E23A37,0x00E2514F,0x00E05C59,0x00DF4A48,0x00DF3735,0x00DF2826,0x00E27471,0x00F2EEE8,0x00E4817D
    dd 0x00DF2C2A,0x00E53F3C,0x00E02F2C,0x00ECB7B2,0x00E8ADA9,0x00DF2E2C,0x00E33B38,0x00DC3331,0x00EAB6B0,0x00EED1CB,0x00DD3E3C,0x00E1312E
    dd 0x00E1322F,0x00E12D2A,0x00E12B29,0x00E12F2D,0x00E23A38,0x00E33A37,0x04E13936,0x00F74440,0x8CD95D58,0xFF000000,0xFBBF3F3F,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFBBF3F3F,0xFF000000,0x58DB5D5B,0x00F54340,0x04E23936,0x00E43B37,0x00E43A37,0x00E43532,0x00E43330,0x00E33633,0x00E43B37
    dd 0x00E53F3B,0x00E22E2D,0x00E05E5D,0x00F1E8E0,0x00E89C97,0x00DE3230,0x00E12D28,0x00ECBBB4,0x00E9B1AB,0x00DE2723,0x00DD3D3B,0x00EEC6C0
    dd 0x00EDC6BD,0x00DD3834,0x00E43734,0x00E43D39,0x00E33B38,0x00E53E3A,0x00E43C38,0x00E43B38,0x00E33A38,0x01E33A37,0x01E73834,0x0FE04947
    dd 0xEBD8B2B2,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFF5555,0xFF000000,0xBDD86C6C,0x00E54544,0x02E03A38,0x00E13C3B,0x00E03C3A
    dd 0x00DE3A39,0x00DF3A3A,0x00E23E3C,0x00E03B39,0x00E03B39,0x00E13F3E,0x00DE3131,0x00DC5452,0x00EEE0D9,0x00EEB6AD,0x00D62D2C,0x00EABAB4
    dd 0x00E5AAA5,0x00D83634,0x00F4D7CE,0x00EABFBA,0x00DA3635,0x00DE3836,0x00E03E3C,0x00E03B3A,0x00E23E3B,0x00DC3436,0x00DE3C3C,0x00E03E3C
    dd 0x00E03B3B,0x04E03B39,0x00F34345,0x6CD75B5A,0xFF000000,0xFCFF5555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F007F,0xFD7FFFFF
    dd 0x319E4B80,0x00A33E86,0x039C3C80,0x0099397D,0x00A44B86,0x00A74F89,0x0099347B,0x009D3E82,0x009C3C80,0x009D3C80,0x009D4083,0x009D377A
    dd 0x00993F83,0x00D5C6D9,0x00E8D0CE,0x00DFC9CF,0x00DEC9CA,0x00EBD7D4,0x00C4A3C4,0x00963279,0x009E3D80,0x009A3E80,0x009B3C7F,0x009F4082
    dd 0x0097317A,0x00B06392,0x00E9CBCF,0x00A04681,0x029A3A7D,0x00A13E83,0x33A74B82,0xF2D79C9C,0xFD7F007F,0xFEFF00FF,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFCAA55AA,0xFF000000,0xB39361A1,0x01934398,0x028E3B92,0x0087338C,0x00A66AAA,0x00ECE7ED,0x009C5BA0,0x00842C89
    dd 0x00903F94,0x008E3C92,0x008C3B91,0x008D3E93,0x008C388E,0x008B3488,0x00C19CC2,0x00EFF0EA,0x00F1F4ED,0x00B98CB8,0x00852B82,0x008C3C91
    dd 0x008C3C91,0x008C3B90,0x008E3F93,0x00832D89,0x009D5CA0,0x00F0EEF0,0x00B182B3,0x0087328B,0x028E3C92,0x018F3E93,0x51985C9C,0xE1997FA1
    dd 0xFD7F007F,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD7F7F7F,0xF5B2B299,0x44945090,0x00943E92,0x03903E8E
    dd 0x008B338A,0x00B582B1,0x00F0EAE8,0x00AB6EA7,0x00872D85,0x00903C8E,0x00903B8E,0x008F3A8D,0x008F3C8E,0x00903D8F,0x00822580,0x00D7C1D3
    dd 0x00D2B6CD,0x00842682,0x00913E90,0x008F3B8D,0x00903A8C,0x00913E8F,0x00872E85,0x00A465A1,0x00F1EBEA,0x00B887B4,0x00882E86,0x00903B8D
    dd 0x028F3B8C,0x02913A90,0x0C91478E,0xE5A6899C,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAA55AA,0xFF000000
    dd 0xC6986B98,0x07924592,0x038F3B8E,0x008F3C8E,0x008F3C8F,0x00852C85,0x00AD75AC,0x00F3F0ED,0x00BC91B9,0x00872E88,0x008F388D,0x00913D8F
    dd 0x008F3A8D,0x008F3E8E,0x00893188,0x00D8C0D4,0x00CEB2CB,0x00872D86,0x00903D8F,0x008F3B8D,0x00903D8E,0x00842C84,0x00AD76AB,0x00E9DFE4
    dd 0x00A366A1,0x007B1B7A,0x008E398D,0x008F3C8E,0x058D398C,0x00994497,0xA79C5F99,0xFF000000,0xFCAA55AA,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0x56934F95,0x00983F97,0x058D3A8C,0x008F3B8F,0x008E3A8D,0x00802280,0x00934992
    dd 0x00E1D4DD,0x00D3B8D0,0x008E3A8D,0x00893188,0x00903F8F,0x008F3D8E,0x00883088,0x00DAC5D5,0x00D1B7CD,0x00862D85,0x00914090,0x008F3C8E
    dd 0x00842B84,0x00B486B2,0x00FEFFF7,0x00DACCD5,0x00B98DB4,0x00C7A6C3,0x00A05C9E,0x038A348A,0x009C449C,0x66945392,0xFF000000,0xFCAA55AA
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFF00FF,0xFE000000,0xF2C4B0C4,0x26944C94,0x00974098
    dd 0x0288358A,0x00A365A4,0x00D7C4D4,0x00D1BACF,0x00DED2DB,0x00EFF2EC,0x00E1D4DE,0x009E5E9E,0x00842D85,0x00913F90,0x00883389,0x00D9C6D4
    dd 0x00D1B9CE,0x00883188,0x008B378A,0x0089388B,0x00CFB4CE,0x00E3DDE1,0x00B188B0,0x00C2A1C0,0x00CFB8CE,0x00C9ABC7,0x029A569A,0x018F3B90
    dd 0x5C995496,0xFCFFFFFF,0xFC550055,0xFEFF00FF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F7F,0xFF000000,0xDCA07BA0,0x389E4995,0x0297338B,0x029E4C93,0x00C18BB4,0x00BC84B1,0x00AD65A2,0x00963D8B,0x00BC83B0,0x00F5E4E5
    dd 0x00C693BB,0x00873388,0x00882983,0x00DDC7D6,0x00D6BDD0,0x00842384,0x00924893,0x00E5CBD7,0x00E1C3D4,0x00973F8D,0x008A267F,0x008C2981
    dd 0x008D2983,0x008C2882,0x03922F85,0x019A3E91,0x6F945D96,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB7F3F7F,0xFF000000,0x896788B3,0x016E5BA7,0x046B4C9D,0x0065459B,0x0065459A
    dd 0x00644799,0x00684E9D,0x0066449A,0x00786FAD,0x00CBE4E8,0x00E4BFD2,0x007B4F98,0x00D0CEDA,0x00C1BBCF,0x009460A2,0x00F5E9EA,0x00A1B8D0
    dd 0x005F4493,0x006C4FA0,0x007057A4,0x006C53A0,0x0069529D,0x026E529F,0x036C53A4,0x007958A5,0xA2945596,0xFE00FFFF,0xFD7F7F7F,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC0055AA,0xFD7F7F7F,0x9E419DC5
    dd 0x0113A0DA,0x00039CDB,0x03069AD4,0x00059BD5,0x00049AD5,0x000499D5,0x00079BD7,0x000091D1,0x000790CA,0x008CD2E3,0x00D7ECEC,0x00DDE9E8
    dd 0x00E0EAE8,0x00D6EEED,0x0061BDDD,0x00008BCC,0x000598D4,0x000599D5,0x000498D4,0x000498D5,0x030496D2,0x000098D6,0x00109FDA,0x9F3AACD1
    dd 0xFF000000,0xFD007FFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFD007FFF,0xFF000000,0xB44EAACC,0x0D199DD3,0x00039AD9,0x040694D0,0x000796D2,0x000696D2,0x000695D2,0x000897D3
    dd 0x000696D3,0x00008DCF,0x004AAFD7,0x00E4EDE8,0x00DCEBEA,0x002EA3D4,0x00008ECF,0x000998D4,0x000796D2,0x000695D1,0x000796D1,0x040695D2
    dd 0x00059CDD,0x0E199CD5,0xA846A4C7,0xFF000000,0xFB3F3F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB007FBF,0xFF000000,0xCE62ABC5,0x2721A1D5,0x0007A1E1
    dd 0x010494D2,0x030695D2,0x000696D2,0x000696D2,0x000796D3,0x000B98D4,0x00008ACD,0x00BADCE3,0x00B0D9E3,0x00008BCD,0x000B98D4,0x000696D3
    dd 0x000696D2,0x030795D1,0x010495D2,0x0009A0E1,0x31229FD4,0xD46AB1C9,0xFF000000,0xFB3F7FBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFB3F7FBF,0xFF000000,0xEFBFBFBF,0x6933A4D4,0x00119CD5,0x00059DDD,0x010494D1,0x030695D1,0x010696D2,0x000796D3,0x000291D0,0x00BFDFE7
    dd 0x00B7DCE5,0x000290CF,0x000896D3,0x020796D2,0x020495D2,0x00059DDE,0x02139DD6,0x7135A5D2,0xF5E5CCB2,0xFF000000,0xFB007FBF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFFFF,0xFF000000,0xFF000000,0xBD4DAAC8,0x4125A2D4,0x00109CD8,0x00059DDE
    dd 0x000395D2,0x040796D3,0x020191CF,0x00BFDFE7,0x00B7DCE5,0x02008FCE,0x030794D3,0x00049BDB,0x000E9EDA,0x3F25A3D5,0xC456ACCF,0xFF000000
    dd 0xFF000000,0xFD7F7FFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xFC00AAAA
    dd 0xFF000000,0xFF000000,0xBD51ADD4,0x4D28A1D4,0x05139BD4,0x0008A1E1,0x000095D7,0x00C4E1E8,0x00BBDDE6,0x000096D9,0x0010A1DF,0x36229FD3
    dd 0xB44AADD2,0xFF000000,0xFF000000,0xFC00AAFF,0xFE00FFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC00AAAA,0xFE0000FF,0xFF000000,0xFF000000,0xD567BCD4,0x7831A6D1,0x251699D0,0x01C6E3E9
    dd 0x03C0E2E9,0x3A1498CF,0xA647AED4,0xFCFFFFAA,0xFF000000,0xFE0000FF,0xFD7FFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AAAA,0xFD007FFF
    dd 0xFF000000,0xFF000000,0xF8FFFFB6,0x1739A5D1,0x2439A6D1,0xFF000000,0xFF000000,0xFF000000,0xFC55AAAA,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AAAA,0xFB007FBF,0xFDFFFFFF,0x1B0A92CA,0x191697CF,0xFAFFFFFF,0xFC55AAFF,0xFD007F7F
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xFF000000,0xF4FFE7D0,0x121498CD
    dd 0x121D9ACF,0xF5FFFFE5,0xFF000000,0xFE00FFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xEDB8C6D4,0x0A1599CF,0x161194CD,0xF6E2C6AA,0xFF000000,0xFE00FFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xFF000000,0xE78AB4C9,0x071297CE,0x101197CE,0xEF9FBFBF,0xFF000000,0xFE00FFFF
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xDD78B4CA,0x021097CE
    dd 0x061499D0,0xE188BBD4,0xFF000000,0xFD7F7FFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F7F,0xFF000000,0xDC66AECC,0x060E97CF,0x06109AD1,0xDC6DB6D3,0xFF000000,0xFD7F7FFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFFFF,0xFF000000,0xD470B7CF,0x0012A4DF,0x00109CD7,0xE062ACCD,0xFF000000,0xFD007F7F
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE0000FF,0xF9D4AAAA,0x75319ED0
    dd 0x82379FD0,0xFCFFAAAA,0xFE00FFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB007FBF,0xFB007FBF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_rainbow_20:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD7F7F7F,0xFA99CC99,0xFA999999,0xFD7F7F7F
    dd 0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFB7FBF3F,0xFF000000,0x7268B453,0x7968B653,0xFF000000,0xFB7FBF3F,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFF7F,0xFF000000
    dd 0xD585B667,0x0263B74A,0x0664B64B,0xD385B96E,0xFF000000,0xFDFFFF7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0xD542B079,0x1258B648,0x016EBE62,0x016CBD60,0x0D59B749
    dd 0xC751B671,0xFF000000,0xFCAAAA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFDFFFF7F,0xFE00FF00,0xDEC1C15C,0x2D9FBE42,0x0097C85B,0x02A2C563,0x029FC45E,0x0097C65E,0x189BC143,0xCFB4C455,0xFF000000,0xFCAAAA55
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBFBF3F,0xFEFFFFFF,0x6CF2C539,0x00FFD321
    dd 0x05FFC73A,0x00F9DA84,0x00FAD981,0x04FDC83B,0x00FFD022,0x50F4C637,0xF3E9BF6A,0xFCFFAA00,0xFEFF0000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFCFFFF55,0xFF000000,0xBBF3CA3F,0x04FCCB2C,0x05F5CC51,0x00F5BA13,0x00F2D36B,0x00F2D166,0x00F5BC17
    dd 0x05F3CD5B,0x00FFD12B,0xADF2CD3E,0xFF000000,0xFBFFBF3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFAA55
    dd 0xFD7F7FFF,0x6CEF9332,0x00FF9F2F,0x04EFC58F,0x00F2A54F,0x00F29B3A,0x00F29A39,0x00F2AE61,0x03EFC187,0x01FC9829,0x53F09130,0xFF000000
    dd 0xFDFF7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFF0000,0xFF000000,0xFBFFFFFF,0x1CF28F28,0x00FA9533,0x02F39231
    dd 0x00F2AC5F,0x00F2B472,0x00F1B879,0x00F3A653,0x02F28C28,0x00FB9C3E,0x1FF38E26,0xF9D4D4AA,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFDFF7F7F,0xFF000000,0xD8DE6F68,0x0DEC5E2E,0x01EC8259,0x01EA7A46,0x00EA5117,0x00EA9C84,0x00EA967C,0x00EA4F14
    dd 0x00EB8857,0x00EB805A,0x08EC622C,0xD5E67F55,0xFF000000,0xFDFF7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFF7F7F,0xFF000000
    dd 0xD8DE5B5B,0x06E53536,0x01E65958,0x01E9A09E,0x00E44244,0x00E45251,0x00E35150,0x00E54C4D,0x01E89997,0x00E65655,0x08E33637,0xE1DD6666
    dd 0xFF000000,0xFDFF7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xE0D56262,0x0BD84046,0x01DC4B50,0x01D5424B
    dd 0x00DB767B,0x00E68882,0x00E68B86,0x00D96E74,0x02D63840,0x01E34C4E,0x1ED93F42,0xEDD46363,0xFF000000,0xFEFF0000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F007F,0xFD7F7F7F,0x398E3988,0x01AC61A4,0x03A4609C,0x00842781,0x00B88DB9,0x00B486B4,0x00862A81
    dd 0x04B17CAC,0x00AA5CA3,0x5F8C3C8A,0xFF000000,0xFB7F3F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAA55AA
    dd 0xFF000000,0x9A8D418F,0x009E499C,0x06CD9ABE,0x01AF65A2,0x00A960A0,0x00AB63A1,0x02B46FA6,0x03C48BB6,0x04944695,0xD28D448D,0xFEFF0000
    dd 0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F7F,0xFF000000,0x44447EBA,0x00338AD2
    dd 0x013D90C9,0x039EB9D3,0x0399BBD5,0x00378BC9,0x00307CC8,0x775472B0,0xFF000000,0xFD007FFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xFD7F7FFF,0xF200EBFF,0x6A08A6DB,0x070095D7,0x0049BCE6,0x0046BAE5,0x1A0097D9
    dd 0x9D0FB0DF,0xFF000000,0xFC5555AA,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xD71992CC,0x5A51B3DB,0x6356B3D9,0xEC2886BB,0xFF000000,0xFD7F007F,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xF900AAD4
    dd 0xFF000000,0xAF1395CC,0xB01394CB,0xFF000000,0xF900AAFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB007FBF,0xFD007FFF,0x931C9BCF,0x951A99CE,0xFE00FFFF
    dd 0xFB007FBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFE00FFFF,0xFF000000,0xE5279CCD,0xE62899CC,0xFF000000,0xFE00FFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_mono_64:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD00007F,0xFD000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFD7F7F7F,0xFF000000,0xC85C5C61,0xD15E5E5E,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFC000000,0xF9FFFFFF,0x231E1F27,0x381D2029,0xFDFFFFFF,0xFC000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFF000000,0x83393B41,0x00050813
    dd 0x00080B16,0x9842454A,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F
    dd 0xFE000000,0xDC7B7B83,0x0A151722,0x03020410,0x0201040F,0x12191B25,0xE89B9B9B,0xFE000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000,0x53292A32,0x00030612,0x03050713,0x04050712,0x00040713,0x6B303138,0xFF000000
    dd 0xFB3F3F3F,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFB000000,0xFF000000,0xC355555D,0x000E101B,0x03020410,0x00060813
    dd 0x01060814,0x02020410,0x0313151F,0xD26B6B71,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0x4B272931,0x01020511,0x03060813,0x00030511,0x00030511,0x04050713,0x00040613,0x5C2B2D35,0xFF000000,0xED8D8D8D,0xFF000000,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000
    dd 0xFD000000,0xF3949494,0x60393B41,0xB2636666,0x020D0F19,0x01030611,0x00040611,0x000D0F1B,0x000D0E1A,0x01050712,0x00030511,0x0B0F111C
    dd 0xA25F6265,0x312A2B32,0xEC939393,0xFD000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFF000000,0x7F313339,0x000B0E19,0x161C1E27,0x00030611,0x00080A15,0x00000008,0x00505158
    dd 0x0046484F,0x00000008,0x00070A15,0x00040713,0x09191B24,0x00060913,0x5D2D3037,0xFF000000,0xFC555555,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFA333333,0xFD000000,0xDD7F7F87,0x0B131620,0x0300030E,0x00020610
    dd 0x00050713,0x00070915,0x00000007,0x0055575D,0x00494B52,0x00000007,0x00070B14,0x01050813,0x00020510,0x0402050F,0x000E101B,0xB8565659
    dd 0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0x5E2D2F35,0x00040812,0x04050811,0x01050712,0x00050713,0x00070915,0x00000007,0x0056575D,0x004A4B51,0x00000007,0x00070A15,0x00060813
    dd 0x01040712,0x03060813,0x01020410,0x3222242C,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFE000000,0xFF000000,0xB357575A,0xD1858585,0x0D11141D,0x0102050F,0x01050713,0x00070916,0x00030511,0x00070915,0x00000008,0x0057585E
    dd 0x004A4B52,0x00000007,0x00080A15,0x00030611,0x00090B15,0x00070913,0x01040611,0x000A0C17,0x7E4D4F53,0x5136393D,0xFBFFFFFF,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFE000000,0xE78A8A8A,0x0E1D1E27,0x2A2B2C34,0x00060813,0x00060813,0x0000020C,0x0065666B
    dd 0x00303139,0x0002020D,0x00000009,0x0057585F,0x004A4B51,0x00000007,0x00040611,0x00181A23,0x0078787B,0x000C0E19,0x00030611,0x00040612
    dd 0x0012141E,0x000B0E19,0xA53E3E44,0xFF000000,0xFB3F3F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB00003F,0xFF000000,0x7B323439,0x00050914,0x00030511
    dd 0x00050712,0x00070914,0x00000008,0x00484A50,0x0078797C,0x0000000A,0x00010109,0x0057585F,0x004A4C51,0x00010109,0x00000009,0x0068696C
    dd 0x00616367,0x0000000A,0x00060A14,0x00050813,0x04030510,0x01010410,0x311E202A,0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFE000000
    dd 0xF0CCBBBB,0x15171A22,0x0101050F,0x03060913,0x00050813,0x00050813,0x00040712,0x0005070F,0x007C7D80,0x00393B43,0x00000000,0x005B5C61
    dd 0x004D4F54,0x00000000,0x002E3038,0x0088898A,0x000C0D16,0x00030510,0x00060A13,0x00050912,0x01060813,0x02030511,0x020D101A,0xCA4C5151
    dd 0xFE000000,0xFC000055,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFC000000,0xFF000000,0xA73F4245,0x000A0D18,0x03040611,0x00060A12,0x00060912,0x00050912,0x00070B14,0x00000009
    dd 0x002D2F36,0x00929194,0x0007080E,0x0057585E,0x00484A50,0x0007070D,0x00909091,0x0034353D,0x00000009,0x00070A14,0x00050912,0x00050912
    dd 0x00070915,0x04050713,0x00050914,0x6C2D2E35,0xFF000000,0xFCAAAAAA,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xF57F7F7F,0xF7FFFFFF,0x5B23252E,0x01040713,0x04050713,0x00040711
    dd 0x00060A13,0x00060912,0x00060912,0x00060A14,0x00000009,0x005E5F64,0x006D6E72,0x005C5D62,0x004B4C53,0x006E6E73,0x005F6064,0x00000008
    dd 0x00070A15,0x00050812,0x00050912,0x00040812,0x0000000A,0x02050812,0x00020510,0x4120212C,0x7E515155,0xA43A3A40,0xFF000000,0xFC555555
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB3F3F3F,0xFF000000,0x9B35353A,0x4C414247
    dd 0x2F1D1E28,0x00020310,0x02070915,0x000A0B16,0x00040711,0x00050912,0x00060912,0x00060913,0x00050712,0x0003040F,0x006F7074,0x00949498
    dd 0x00939397,0x0068696D,0x0001030C,0x00060813,0x00050813,0x00050912,0x00040712,0x00090B15,0x0042434A,0x00090C15,0x0002030F,0x0910121D
    dd 0x00161922,0x5D22252C,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFC000000,0xFF000000,0x4C25262D,0x000A0C18,0x020D0E1A,0x0001030F,0x000F111C,0x0077787C,0x0012151F,0x00030510,0x00060913,0x00050912
    dd 0x00060A13,0x00030611,0x00080912,0x007E7E82,0x00747579,0x0004060E,0x00040711,0x00060814,0x00050713,0x00070A15,0x00000008,0x0042444A
    dd 0x00848485,0x0004050E,0x00060813,0x01040612,0x0000020D,0x2D1D1F28,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xF6FFFFFF,0x1B191B26,0x0200020F,0x02040612,0x00060915,0x0000010A,0x006C6C71
    dd 0x005C5D62,0x00000006,0x00070B15,0x00050912,0x00050912,0x00080C15,0x00000005,0x005A5C62,0x004A4D52,0x00000005,0x00080B16,0x00050713
    dd 0x00060813,0x00040610,0x000A0C16,0x008C8C8E,0x002B2D35,0x0001010B,0x00070A15,0x01060813,0x00030511,0x0713151E,0xE2838383,0xFD7F7F7F
    dd 0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFD7F7F7F,0xCE68686D,0x0111131C,0x01020511
    dd 0x00060714,0x00060914,0x00030410,0x00181A23,0x00909093,0x001E2029,0x0001030C,0x00070A14,0x00050912,0x00070B14,0x00010107,0x00606166
    dd 0x0052545A,0x00010107,0x00070915,0x00050812,0x00070A15,0x00000006,0x005F6165,0x0068696E,0x00000006,0x0001040F,0x00020610,0x00050913
    dd 0x01030511,0x000E101B,0xCF4F4F55,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555
    dd 0xFF000000,0xB53E3E48,0x000C0F19,0x03030511,0x00050713,0x00020410,0x0000010D,0x00000000,0x003E3F45,0x0076777B,0x0001020B,0x00060913
    dd 0x00050913,0x00080B14,0x00000007,0x005F6066,0x00515259,0x00000007,0x00070915,0x00080A15,0x0000000A,0x002C2E36,0x00838285,0x00070811
    dd 0x00070812,0x001E2029,0x0010121C,0x00040612,0x02030511,0x010D0F1B,0xA05D5D63,0xC2606060,0xFE000000,0xFD000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFE000000,0xFD7F7F7F,0xC5656569,0x90505257,0x00090B17,0x03050813,0x0001010C,0x004D4D54,0x00797A7F,0x005A5B61
    dd 0x004E4F55,0x009FA0A1,0x004E5057,0x00000004,0x00080B15,0x00080B14,0x00000007,0x005F6066,0x00515359,0x00000007,0x00090B17,0x0001030E
    dd 0x000F1019,0x00939395,0x008E8E91,0x00747477,0x00828286,0x0088888B,0x0030313A,0x0001010C,0x00050713,0x050A0C17,0x1527282F,0x5A1B1D26
    dd 0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFF000000,0x4025252E,0x162A2B34,0x02070914,0x00050713
    dd 0x00040610,0x001B1D26,0x003F4148,0x0056585C,0x00616467,0x005B5B60,0x008C8C8F,0x00404148,0x00000006,0x000A0D17,0x00000006,0x005F6066
    dd 0x0052545A,0x00000008,0x00050712,0x000A0B15,0x00808184,0x005F6065,0x0038393F,0x00363940,0x0021242C,0x000B0E18,0x00040612,0x00060913
    dd 0x00050912,0x04050713,0x00020410,0x571E1F27,0xFF000000,0xFC000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFDFFFFFF
    dd 0x2E1C1E25,0x0000010E,0x02060813,0x00050712,0x00070A14,0x0001040F,0x00000008,0x00000007,0x00000008,0x00000004,0x0022242B,0x00949598
    dd 0x00383A41,0x00000007,0x00020209,0x005E6166,0x0053565C,0x00000006,0x0003040F,0x007A7B7F,0x00626267,0x00000006,0x00000008,0x0000000A
    dd 0x0000020D,0x00040712,0x00040711,0x0000040E,0x00050912,0x04050713,0x01050713,0x6310111B,0xFD7F7F7F,0xFB000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFE000000,0xFF000000,0xFBFFFFFF,0x2520232B,0x01010410,0x02060913,0x00050913,0x0000020C,0x0000030E,0x00080B16,0x00070A14
    dd 0x00070A14,0x00090C16,0x00000009,0x0026282F,0x00929395,0x003B3C44,0x00000000,0x00606367,0x004F5358,0x00000001,0x0075767A,0x006B6C71
    dd 0x00000008,0x00060913,0x00070B14,0x00070A14,0x00070914,0x00040711,0x000B0E19,0x001A1C25,0x00040610,0x04050813,0x00050813,0x691B1E27
    dd 0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0x3C171823,0x00030612,0x03060A13,0x0002050D
    dd 0x002D2F37,0x0022242D,0x0001030C,0x00070A14,0x00060912,0x00060912,0x00080B15,0x00000008,0x0023242C,0x00939396,0x003E3F45,0x00585A5F
    dd 0x0057595E,0x0064656B,0x00747579,0x0003040E,0x00050811,0x00060913,0x00050812,0x00050812,0x00060914,0x00000009,0x006D6F71,0x0053555B
    dd 0x00000008,0x03070914,0x00050813,0x713E3E46,0xDB5C5C63,0xFC000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xF5FFFFFF
    dd 0x55282A33,0x00030612,0x04070B14,0x00000009,0x00414349,0x008B8B8F,0x00070812,0x00050711,0x00070A13,0x00060912,0x00060912,0x00080B15
    dd 0x0000000A,0x00171821,0x00808185,0x008E8F91,0x009A9A9C,0x00636369,0x0000010C,0x00040811,0x00060A13,0x00060912,0x00050912,0x00080B15
    dd 0x00000007,0x003C3E45,0x008A8A8C,0x00080913,0x00040612,0x00050813,0x03060814,0x0D1D1F29,0x58272930,0xFF000000,0xFB000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFE000000,0xFDFFFFFF,0x543D3D44,0x2124252F,0x02040712,0x01050912,0x00060914,0x00000007,0x0063646A,0x00696A70,0x00000007
    dd 0x00070B14,0x00060912,0x00060912,0x00060912,0x00070B14,0x0000020D,0x000C0D15,0x00838487,0x006D6D73,0x00000009,0x00050812,0x00070A13
    dd 0x00060912,0x00060912,0x00070B14,0x0001040C,0x00161720,0x008E8F90,0x0024242E,0x0000010B,0x00070914,0x00050812,0x04050812,0x00010411
    dd 0x6A2E2F38,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000,0x48272730,0x00020411,0x03060913,0x00050912,0x00060913
    dd 0x00040711,0x00090A13,0x00898A8C,0x00474950,0x00000006,0x00080B15,0x00060912,0x00060912,0x00050912,0x00090C16,0x00000004,0x005D5E64
    dd 0x0057595E,0x00000006,0x00080C15,0x00060912,0x00050912,0x00060A13,0x00040710,0x00070911,0x00838486,0x00525358,0x00000008,0x00090B17
    dd 0x00050812,0x00050912,0x04040711,0x01090C17,0x9139393E,0xFF000000,0xFB003F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xFF000000,0x722D2F38
    dd 0x02060914,0x04050912,0x00050912,0x00050912,0x00060913,0x0000010C,0x0011131C,0x0086878A,0x0036373F,0x00000007,0x00080C15,0x00050912
    dd 0x00060912,0x00070B14,0x00010108,0x0063656A,0x005C5E64,0x00000007,0x00080B14,0x00050912,0x00060913,0x00050812,0x0000020C,0x0075777A
    dd 0x00616266,0x00000000,0x00000008,0x0000000A,0x00050913,0x00050912,0x01030511,0x000E111B,0xCE4E4E53,0xFF000000,0xFD7F7F7F,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFB3F3F3F,0xFF000000,0x9F42454D,0x000B0E18,0x03040710,0x00050912,0x00050812,0x00080A16,0x000E111B,0x0013151E,0x005A5B61
    dd 0x00A7A7A9,0x002C2E37,0x00000007,0x00080D15,0x00050912,0x00070B14,0x00000008,0x0063656A,0x005D5E64,0x00000007,0x00070B14,0x00060913
    dd 0x00060813,0x00000009,0x00626468,0x009D9E9F,0x0078797C,0x00686A6D,0x006A6C71,0x00484A51,0x0002040F,0x02060A13,0x00020510,0x3522232C
    dd 0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xF5FFFFFF,0x14151721,0x00020610,0x01060A13,0x0001040F
    dd 0x00616267,0x0089898C,0x00868689,0x00727377,0x0056575B,0x008D8F91,0x002C2D36,0x00000006,0x00080B15,0x00070A14,0x00000008,0x0065666B
    dd 0x005F6065,0x00000006,0x00080C16,0x00050812,0x00000007,0x00626367,0x007C7D80,0x00161720,0x0030323A,0x0045474E,0x00505259,0x003A3D44
    dd 0x00020410,0x01060913,0x03040611,0x1C1E202A,0x833F3F47,0xFE000000,0xFC000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xAE5E5E61
    dd 0x30292B33,0x01030610,0x02060A13,0x00040712,0x00151721,0x001E1F28,0x000F111B,0x0001040E,0x00000003,0x002F3038,0x00929295,0x003D3D45
    dd 0x00000006,0x00090B16,0x00000008,0x0065666C,0x005F6066,0x00010108,0x00050713,0x0001030D,0x006C6D70,0x0078797C,0x00080914,0x0000010C
    dd 0x0000000C,0x00000008,0x00000008,0x0000000A,0x00050813,0x00050812,0x04040612,0x00060815,0x8A32323A,0xFF000000,0xFB3F3F3F,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFB000000,0xFF000000,0x542F3138,0x00090C16,0x04050912,0x00050912,0x00050912,0x0001040F,0x0000030E,0x00020510,0x00060913
    dd 0x00080C16,0x00000009,0x0022242C,0x008F9193,0x00505157,0x00000008,0x00000009,0x0068696F,0x00626369,0x00000003,0x00060811,0x0077787B
    dd 0x00727377,0x0003040F,0x00030510,0x00070915,0x00070814,0x00080A16,0x00060814,0x00060814,0x00050713,0x01060813,0x02020410,0x10151722
    dd 0xEB999999,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFF000000,0xBB474B4E,0x000B0E19,0x03030710,0x00060912,0x00060912
    dd 0x00040711,0x00030710,0x00070B14,0x00060912,0x00060912,0x00080B15,0x0000000A,0x0015171F,0x0086878A,0x0067686D,0x00000003,0x0066686C
    dd 0x005B5E62,0x0006070B,0x00828385,0x00696A6E,0x0000010B,0x00040611,0x00060A14,0x00050812,0x00060915,0x0000020E,0x00080A14,0x00060914
    dd 0x00040712,0x04040612,0x00050815,0x6F2E2F38,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFCFFFFFF
    dd 0x301D2027,0x00030610,0x03060A13,0x00040710,0x000E111B,0x0011141D,0x0000020C,0x00080B14,0x00060912,0x00050912,0x00070B15,0x0000020D
    dd 0x00090A14,0x00747579,0x0075767B,0x00747679,0x00757679,0x00808184,0x00595A5F,0x0000000A,0x00050713,0x00060914,0x00050812,0x00070B15
    dd 0x00000009,0x0024262E,0x007D7E82,0x000E101A,0x0203050F,0x00040612,0x341B1C26,0xF4B9B9A2,0xFD000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFC555555,0xFF000000,0xB43D4047,0x030A0C17,0x02050712,0x0001020C,0x00272A32,0x008F8F92,0x0021232C,0x00000007
    dd 0x00080C15,0x00060912,0x00050912,0x00070A14,0x00030510,0x00000009,0x00535459,0x0097979A,0x0096979A,0x0045464C,0x00000007,0x00060914
    dd 0x00060913,0x00050713,0x00080A16,0x00000009,0x001F2129,0x00909293,0x003C3D44,0x0001020D,0x02050713,0x01080B16,0x4D393A41,0xDF57575F
    dd 0xFD000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFD000000,0xEBCCCCBF,0x3833343C,0x00030510,0x02070914
    dd 0x0000020C,0x003F4047,0x00919194,0x002C2D35,0x00000006,0x00070A13,0x00070A13,0x00050912,0x00060913,0x00070913,0x00000001,0x00717176
    dd 0x00636369,0x00000002,0x00080B16,0x00050813,0x00050813,0x00070916,0x00000008,0x00292A32,0x00939496,0x003F4047,0x00000007,0x00060814
    dd 0x01060814,0x0101040F,0x0A141621,0xE2727272,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFF000000
    dd 0xB6616568,0x021C1E27,0x0402040F,0x00060813,0x00060914,0x00000008,0x0032333A,0x00949597,0x004B4C52,0x0000000A,0x00040711,0x00070B14
    dd 0x00050812,0x00070A15,0x0001010B,0x006E6F74,0x00636369,0x00010109,0x00070A15,0x00060913,0x00070A15,0x00000007,0x0037383F,0x00838487
    dd 0x0025262E,0x00000000,0x00030512,0x00060814,0x05020410,0x000D0F1A,0xA345454D,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFF000000,0x5223242D,0x00040713,0x05050712,0x00050814,0x00040611,0x00000000,0x00101119
    dd 0x00818284,0x006A6B70,0x00050610,0x0000000C,0x00080B15,0x00070A14,0x0000000A,0x00707276,0x0066676B,0x00000008,0x00090B16,0x00050713
    dd 0x00000006,0x0044464C,0x00A8AAAA,0x00747578,0x0046474C,0x00595B60,0x001F212A,0x0301020D,0x00080B16,0x6A313136,0xFF000000,0xFC000055
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD000000,0xEFBFBFBF,0x261F222B,0x00030612
    dd 0x0201020D,0x00262930,0x00707176,0x0067696E,0x007B7D80,0x00959697,0x007E8082,0x0023242D,0x00000007,0x00080A15,0x0001010B,0x00717477
    dd 0x0067696D,0x0001010B,0x00020410,0x0003050F,0x0067696D,0x00848588,0x003F4147,0x0055565C,0x0063656A,0x005B5D62,0x02191B24,0x01070812
    dd 0x5932343B,0xFCFFFFFF,0xFC000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F7F,0xFF000000,0xDC747474,0x3321242B,0x0203040F,0x02171922,0x0043454B,0x003D3F46,0x00272931,0x000A0C14,0x0043444A,0x008F8F92
    dd 0x004E4E55,0x0000000B,0x00000006,0x0075777A,0x006B6C70,0x00000000,0x0013141D,0x007C7D81,0x00707275,0x000C0D17,0x00000007,0x0000000A
    dd 0x00000008,0x00000007,0x0300010D,0x000D101B,0x5B4C4C52,0xFCFFFFFF,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB3F3F3F,0xFF000000,0x80505258,0x0010131D,0x0400010D,0x00000008,0x00000009
    dd 0x0000000D,0x00040611,0x00000008,0x00191923,0x007D7E82,0x0078787C,0x00111218,0x006F7075,0x0066666C,0x0025262B,0x00919294,0x00515259
    dd 0x00000007,0x00030511,0x00080A16,0x00070A14,0x00070A15,0x02080A16,0x02030512,0x000D0F1B,0xA32F2F37,0xFEFFFFFF,0xFD000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000055,0xFD7F7F7F,0xA236363F
    dd 0x000F111C,0x00020411,0x03080A15,0x00070B14,0x00070A13,0x00060A12,0x00080B15,0x0000030D,0x0002040E,0x005E5F63,0x00898A8E,0x00858689
    dd 0x008C8D90,0x00898A8E,0x00393B42,0x00000007,0x00060914,0x00060A13,0x00050912,0x00050912,0x03060813,0x00010310,0x000E101B,0x9E414449
    dd 0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFD000000,0xFF000000,0xAD44444D,0x0C131620,0x00020510,0x04050812,0x00060A12,0x00060912,0x00060912,0x00070B14
    dd 0x00050912,0x00000006,0x002C2D35,0x008E8E91,0x0087888A,0x001B1C24,0x00000008,0x00080A15,0x00050912,0x00050912,0x00060913,0x04050812
    dd 0x00020510,0x0F161822,0xAB48484B,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000,0xCE626262,0x291D1E28,0x00050714
    dd 0x02030610,0x03060A12,0x00060912,0x00050912,0x00060912,0x00080C15,0x00000004,0x0074757A,0x006C6E72,0x00000005,0x00090C16,0x00050912
    dd 0x00050912,0x03060A12,0x0102050F,0x00060914,0x321D2027,0xD6696969,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFB00003F,0xFF000000,0xEFBFBFBF,0x682F3039,0x000E101B,0x00030710,0x01030610,0x03050912,0x01060A12,0x00060A13,0x0002020E,0x00797A7E    dd 0x00717276,0x0001010B,0x00070A14,0x02060913,0x02030710,0x00020610,0x0111141E,0x7334363D,0xF5FFFFE5,0xFF000000,0xFB003F3F,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD00007F,0xFF000000,0xFF000000,0xBF4F4F53,0x4622252D,0x000F111D,0x00030612
    dd 0x00020510,0x04060813,0x0201010D,0x00797A7E,0x00707176,0x0300000B,0x03040712,0x00020411,0x000D0F1A,0x4422242B,0xC359595D,0xFF000000
    dd 0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFC000000
    dd 0xFF000000,0xFF000000,0xC05D5961,0x4F2A2B34,0x0412141F,0x00070915,0x0000000A,0x007C7D81,0x0075757A,0x0000000A,0x000D101A,0x3721232B
    dd 0xB6494C50,0xFF000000,0xFF000000,0xFC000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFD000000,0xFF000000,0xFF000000,0xD36E6E73,0x7833333C,0x2616161F,0x01838487
    dd 0x047D7E82,0x3D171822,0xAA48484E,0xFEFFFFFF,0xFF000000,0xFD000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFD000000
    dd 0xFF000000,0xFF000000,0xF9FFFFFF,0x172B2D33,0x272A2B32,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFB000000,0xFF000000,0x20050811,0x1E161820,0xFEFFFFFF,0xFC555555,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xF5FFFFE5,0x13101219
    dd 0x141B1D25,0xF6FFFFFF,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xE6B7ADAD,0x0415171F,0x170F101A,0xF5E5E5CC,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xDE9A9292,0x0015161F,0x160A0D15,0xF3AAAA94,0xFF000000,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xDE646464,0x030C0D18
    dd 0x0515171F,0xE1A1A199,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD00007F,0xFF000000,0xD85B5B62,0x050A0C17,0x0610131B,0xDC747474,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xD169696E,0x0010121D,0x000E101A,0xDF5F5F5F,0xFF000000,0xFD000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xF9FFFFD4,0x70303039
    dd 0x7C32323A,0xFBFFFFFF,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_mono_20:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD000000,0xFA999999,0xFA999999,0xFD000000
    dd 0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xFF000000,0x70131520,0x7614161F,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000
    dd 0xD33F3F45,0x02080A15,0x05080A16,0xCF3A3F45,0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000,0xD3343439,0x11050713,0x01191B25,0x01181B24,0x0B050712
    dd 0xC42F2F38,0xFF000000,0xFC000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD000000,0xFE000000,0xDE36363D,0x2B0E101B,0x00181A24,0x0223252F,0x0220222B,0x001C1D27,0x160C0E19,0xCD282833,0xFF000000,0xFC000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xFEFFFFFF,0x6B181922,0x0000030E
    dd 0x05161820,0x004B4C53,0x00494A50,0x04181A22,0x00010410,0x4F151821,0xF24E4E4E,0xFC000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC000000,0xFF000000,0xBB21212D,0x050B0D19,0x0524262F,0x00000005,0x00383A41,0x0034363E,0x00000008
    dd 0x052D2F37,0x00080B16,0xAC1E212B,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000
    dd 0xFDFFFFFF,0x6B161822,0x000B0D19,0x04525359,0x0024272F,0x00141720,0x00131520,0x0031323B,0x034B4D52,0x01080915,0x5313141F,0xFF000000
    dd 0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xF9AAAAAA,0x1A0C0E19,0x0010131D,0x0110121B
    dd 0x0030323A,0x003D3F46,0x0042444B,0x00292A32,0x020A0C16,0x00181B24,0x1F090B15,0xF9AAAAAA,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFD000000,0xFF000000,0xD7393946,0x0D060812,0x01252730,0x01191C24,0x00000002,0x0044464D,0x003E4047,0x00000000
    dd 0x00272931,0x0025272F,0x08050812,0xD530303C,0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFF000000
    dd 0xD7333339,0x05060A13,0x011F212A,0x0158595F,0x0011141C,0x00181B24,0x00181B24,0x00191B23,0x0153545A,0x001D1F28,0x08070A14,0xE13B3B44
    dd 0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFF000000,0xDF373F3F,0x0B090C15,0x0110131C,0x010A0D16
    dd 0x0031333B,0x00404149,0x0043454B,0x002D2E36,0x02020410,0x0111131E,0x1E090B16,0xED464646,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFDFFFFFF,0x360A0C16,0x011F212B,0x0322242C,0x00000002,0x0045474D,0x003F4148,0x00000005
    dd 0x04373941,0x001B1D28,0x5F0C0F19,0xFF000000,0xFC000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC000000
    dd 0xFF000000,0x98161822,0x0011131D,0x0655575C,0x012C2E36,0x00252730,0x00272932,0x0233353D,0x0346474E,0x0310121D,0xD222272D,0xFE000000
    dd 0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD000000,0xFF000000,0x43151721,0x00070A15
    dd 0x01171821,0x0355565C,0x0352555B,0x0010111A,0x0001030F,0x76161823,0xFF000000,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD000000,0xF23A3A3A,0x6B141620,0x07000009,0x0031333B,0x002E3039,0x1A00010B
    dd 0x9E1F242A,0xFF000000,0xFC000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xD81A1A27,0x5B373941,0x653B3D43,0xEC1A2828,0xFF000000,0xFD000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xF9000000
    dd 0xFF000000,0xAE16191F,0xB1161620,0xFF000000,0xF9000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB000000,0xFD000000,0x91191B25,0x951A1C24,0xFE000000
    dd 0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xE5272731,0xE6282833,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_green_64:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFC55AA00,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFF000000
    dd 0xFF000000,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFD7F7F00,0xFF000000,0xC3669D37,0xB5609733,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFD007F00,0xECA1BB93,0x195C9F2B,0x11589E27,0xE885A66E,0xFD007F00,0xFD7F7F00
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0x6F66A23C,0x0057A520
    dd 0x0056A41F,0x6363A037,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55
    dd 0xFF000000,0xD174A64D,0x06579F24,0x03519E1E,0x03509C1D,0x0257A024,0xC275A753,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFE000000,0xFC555500,0xFDFFFFFF,0x4A5B9D2E,0x0055A31D,0x03519D1F,0x03519C1F,0x0055A31E,0x3C5E9F30,0xFD7F7FFF
    dd 0xFD7F7F00,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFA669933,0xFE000000,0xB974A750,0x005AA625,0x03509B1D,0x00519C1E
    dd 0x00529B1E,0x03519A1D,0x0059A624,0xA970A94A,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0x405E9D31,0x0154A11D,0x03519C1E,0x00509B1C,0x00509B1D,0x03529C1E,0x0153A01D,0x2F5E9E31,0xFEFFFFFF,0xEA6D9D48,0xFF000000,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00
    dd 0xFE00FF00,0xEA85B661,0x515D9F2D,0x9176AB4C,0x00539D21,0x00519D1E,0x00519B1D,0x0059A224,0x0059A224,0x00509B1D,0x01519B1E,0x00549F20
    dd 0x7675AD4E,0x205CA12C,0xC36EA148,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC55AA00,0xFF000000,0x6E60A031,0x005BAD22,0x005AA229,0x00519D1D,0x00539D1F,0x004D991A,0x006CAE33
    dd 0x006DB034,0x004D9A1A,0x00539D1F,0x01519B1E,0x0059A226,0x0055A51F,0x31599E2A,0xF79FBF9F,0xFD7F7F00,0xFEFFFF00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFA669933,0xFE00FF00,0xD470AB4D,0x0457A123,0x04519E1C,0x024F9B1C
    dd 0x00529C1F,0x00529D1F,0x004D991B,0x006BAE33,0x006CAF33,0x004D9A1A,0x00529C1F,0x00529C1F,0x02519C1E,0x04519A1E,0x0058A822,0x8A629F36
    dd 0xFF000000,0xFB3F7F00,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFF000000,0xFF000000
    dd 0x5A5B9F2C,0x0056A61F,0x03519C1E,0x00519C1E,0x00519D1E,0x00529F1F,0x004D9A1B,0x006CAE34,0x006EAF35,0x004D9A1A,0x00529C1F,0x00529C1F
    dd 0x00519B1E,0x02519C1F,0x02519E1D,0x13589D27,0xEF9FBF8F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFE000000,0xFF000000,0xAD63983B,0xBF7FAF5F,0x0A559E23,0x00529E1D,0x01529B1E,0x00589F23,0x00529C1F,0x00529C1F,0x004D991B,0x006DAD34
    dd 0x006FAF36,0x004D991A,0x00539C1F,0x00519B1E,0x0058A023,0x00539C1F,0x02519A1E,0x0055A11F,0x4C6DA844,0x475A992F,0xE3649A3F,0xFE000000
    dd 0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFE000000,0xDE8BB16C,0x05599E28,0x0E63A435,0x00529C1E,0x00529C1F,0x004E981B,0x0075B33B
    dd 0x0068AB31,0x004F9A1C,0x004D991B,0x006DAE34,0x006FAF35,0x004E991B,0x00519B1F,0x0059A124,0x007FB942,0x00569E21,0x00519B1E,0x01519B1E
    dd 0x00569F22,0x005BAB23,0x6D65A439,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555500,0xFF000000,0x6863A036,0x0056A61F,0x014F9A1B
    dd 0x00519D1F,0x00529F1F,0x004E9B1C,0x0060A629,0x007FBB43,0x00519C1E,0x004D991B,0x006DAE34,0x006EAF34,0x004E9A1B,0x004D991B,0x0077B43B
    dd 0x006FAE35,0x004D9A1A,0x00529C1F,0x00519B1E,0x04519B1D,0x03529E1C,0x10589B26,0xED8DAA7F,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000
    dd 0xEC93BB78,0x10549924,0x01519D1D,0x02529E20,0x00529F1F,0x00529F1F,0x00529F1F,0x004D9A1B,0x0076B43C,0x006EAF36,0x00489516,0x006FAF35
    dd 0x0070B236,0x00499717,0x0063A72C,0x007EB942,0x00519D1E,0x00519C1E,0x00519E1F,0x00529E1E,0x00529C1F,0x03509A1D,0x0059A522,0x936AA542
    dd 0xFE00FF00,0xFB3F7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFB3F7F3F,0xFE00FF00,0x9B68A33F,0x0057A522,0x03509B1D,0x00529F1F,0x00529F1F,0x00529F1F,0x00529F1F,0x00509D1D
    dd 0x00579F23,0x0084BE46,0x0057A022,0x006CAE33,0x0071B136,0x00509B1C,0x0084BC46,0x005FA528,0x004E9B1B,0x00529F1F,0x00529F1F,0x00529F1F
    dd 0x00529E1F,0x03519B1F,0x0155A41F,0x445C9F2E,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC005500,0xFF000000,0x555E9F30,0x0157A41F,0x04529E1E,0x00519E1E
    dd 0x00529F1F,0x00529F1F,0x00529F1F,0x0053A020,0x004E9B1B,0x0067A92F,0x0080BB43,0x0071B037,0x0071B036,0x007CB73F,0x006DAE34,0x004E9A1B
    dd 0x00539F1F,0x00529F1F,0x00529F1F,0x00529E1E,0x004F9A1C,0x01519B1E,0x0053A01E,0x255A9D2A,0x796CA346,0x8C58992C,0xFF000000,0xFC55AA55
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0x9B609B38,0x475F9D36
    dd 0x245FA32E,0x00539F1C,0x01539B1F,0x0056A022,0x00519F1E,0x00529F1F,0x00529F1F,0x00529F1F,0x00539F20,0x004E9A1C,0x006EAF35,0x0086BE48
    dd 0x0085BC47,0x0072B138,0x004F9B1C,0x00529E1F,0x00529F1F,0x00529F1F,0x00529F1F,0x00519C1D,0x006DAC33,0x00569E22,0x00519B1D,0x03569B22
    dd 0x005DA72A,0x39579B27,0xFF000000,0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD007F00,0xFF000000,0x4361A532,0x005AA922,0x00549920,0x00529B1D,0x00539C1F,0x007CB741,0x005AA326,0x00509E1D,0x00529F1F,0x00529F1F
    dd 0x00529F1F,0x0052A01F,0x004D9A1B,0x0076B43B,0x0079B73E,0x004D9A1A,0x00529E1F,0x00529F1F,0x00529F1F,0x0053A020,0x004E9A1B,0x0068AB32
    dd 0x007FB943,0x00519A1D,0x00529B1E,0x01509B1E,0x02509D1B,0x10579C27,0xE98BAD68,0xFF000000,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFF000000,0xF2B0C4B0,0x18599E29,0x03529F1C,0x02519A1D,0x00529B1E,0x004D991B,0x0072B339
    dd 0x0079B63E,0x004D9B1A,0x0053A020,0x00519F1F,0x00519F1F,0x00529F20,0x004D991B,0x006CAE34,0x006FB336,0x004C9C1B,0x0053A01F,0x00529F1F
    dd 0x00529F1F,0x00519D1E,0x00529C1E,0x0082BC47,0x0062A82C,0x004F9A1C,0x00529D1F,0x00519C1E,0x01519B1E,0x0058A025,0xC270A34B,0xFD7F7F00
    dd 0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFF7F,0xFD7F7F7F,0xCB75AB53,0x01559E23,0x01519C1D
    dd 0x00519C1E,0x00519D1E,0x00519D1E,0x00549F20,0x0081BA43,0x0060A529,0x004E9B1C,0x00529F1F,0x00529F1F,0x00539F20,0x004D991B,0x006EAF34
    dd 0x0070B237,0x004D9C1B,0x00539F20,0x00529F1F,0x0053A020,0x004D9B1B,0x0071B036,0x0071B137,0x004C991A,0x004F9C1D,0x004F9D1D,0x00529D1F
    dd 0x03519A1D,0x0059A323,0xAA699F42,0xFF000000,0xFB3F7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55
    dd 0xFF000000,0xB85D9A32,0x0057A322,0x02509C1D,0x00519D1E,0x00549F20,0x00539E20,0x004A9818,0x005EA428,0x007FBB45,0x00529C1E,0x00529E1E
    dd 0x00529F1F,0x0053A020,0x004D9B1B,0x006EB035,0x0071B238,0x004D9C1B,0x00539F1F,0x00539F20,0x004E9C1C,0x0061A72B,0x0081BA43,0x00519B1E
    dd 0x00549C20,0x0061A62A,0x005BA425,0x00519B1E,0x03509B1D,0x0058A423,0x7878AB53,0xCE629C39,0xFD7F7F00,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFE000000,0xFD7F7F7F,0xCC6EA541,0x8076A852,0x0057A221,0x03519B1D,0x004F9B1C,0x006EB134,0x007EB942,0x0074B23A
    dd 0x0071B23A,0x008CC34F,0x0074B23A,0x004D9A1A,0x00539F1F,0x00529F1F,0x004D9B1B,0x006FB036,0x0072B138,0x004D9B1B,0x0053A020,0x00509D1D
    dd 0x00559E20,0x0084BC45,0x0086BE49,0x007CB843,0x007CB740,0x007DB841,0x0064A92C,0x00509C1D,0x00529F1F,0x02519B1F,0x0664A732,0x3E559926
    dd 0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFF000000,0x405CA02C,0x0663A733,0x03519B1F,0x00529D1E
    dd 0x00519B1E,0x00559E21,0x005EA528,0x0066AB2F,0x006CAF35,0x0068AC31,0x007DB840,0x006EAF35,0x004D9A1B,0x0053A020,0x004D9C1B,0x006EB035
    dd 0x0072B238,0x004E9C1C,0x00519D1E,0x00549D20,0x0080BA44,0x006CAE32,0x005CA427,0x005DA628,0x0055A021,0x004F9A1D,0x00509D1D,0x0053A020
    dd 0x00519F1F,0x03519C1E,0x0055A41D,0x43529A20,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFBFFFFFF
    dd 0x2E5BA12D,0x0051A11A,0x02519D1F,0x00529F1F,0x00529E1F,0x00519E1F,0x004F9C1C,0x004E9B1B,0x004D9A1A,0x004C9919,0x00569F21,0x0082BF45
    dd 0x006AAE32,0x004D9B1B,0x004E9D1C,0x006DB034,0x0072B238,0x004C9B1B,0x00509B1D,0x007CB740,0x0070B138,0x004B9A1A,0x004F9B1C,0x004F9B1C
    dd 0x00519D1E,0x00529F1F,0x00529F1F,0x004F9D1D,0x00519F1F,0x03509D1E,0x0156A320,0x42539921,0xFEFFFF00,0xFD7F7F00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFEFFFF00,0xFF000000,0xFAFFFFFF,0x295EA02F,0x0152A11D,0x02519F1F,0x00529E1F,0x004F9D1C,0x004F9E1D,0x0052A020,0x00529F1F
    dd 0x00539F20,0x0053A020,0x004F9D1D,0x0056A122,0x0081BC45,0x006DAF35,0x00489817,0x006EB135,0x006FB236,0x00499817,0x007CB843,0x0074B33A
    dd 0x004C9B1A,0x00529F1F,0x00529F20,0x00529F1F,0x00529F1F,0x00519F1E,0x0053A020,0x005DA628,0x00509C1E,0x03519C1E,0x0056A41F,0x455A9D2A
    dd 0xFF000000,0xFD007F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFF000000,0x41589D28,0x0055A51F,0x03519F1F,0x004F9B1C
    dd 0x0062A82C,0x0061A82B,0x004F9C1C,0x00539F1F,0x00529F1F,0x00529F1F,0x0053A020,0x004F9D1D,0x0056A022,0x007FBA43,0x006DAF34,0x0070B136
    dd 0x0075B53A,0x0075B33B,0x0076B43D,0x00509B1C,0x00529F1F,0x00529F1F,0x00529F1F,0x00529F1F,0x00529F1F,0x004D9A1A,0x0075B53B,0x0072B239
    dd 0x004E981B,0x03529B1F,0x0055A31F,0x4F68A33E,0xE467A04B,0xFD007F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFCFFFFFF
    dd 0x5463A237,0x0055A61F,0x0453A01F,0x004E9C1C,0x0063A92D,0x0085BE49,0x00559F20,0x00509E1E,0x00529F1F,0x00529F1E,0x00529F1E,0x0053A020
    dd 0x00509E1E,0x00519D1E,0x0079B73D,0x0084BD47,0x0086BD4A,0x0072B23A,0x004E9A1B,0x00529E1F,0x00529F1F,0x00529F1F,0x00529F1F,0x00539F20
    dd 0x004E9B1B,0x0062A72B,0x0080BA44,0x00539C1F,0x00529B1E,0x00529D1E,0x02519C1E,0x0461A72E,0x485A9C2C,0xFF000000,0xFD7FFF00,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFD7F7F00,0xFF000000,0x6065A139,0x1762A831,0x0251A01E,0x01519E1F,0x00529F1F,0x004D991A,0x0070AE35,0x007BB73F,0x004D9C1C
    dd 0x00529F1F,0x00529F1E,0x00529F1D,0x00529F1E,0x00539F20,0x00519D1E,0x004E9A1B,0x0079B63F,0x0077B53D,0x004C9A1A,0x00529F1F,0x00529F1F
    dd 0x00529F1F,0x00529F1F,0x00539F1F,0x00509D1D,0x00559E21,0x0084BD49,0x005EA327,0x004F991C,0x00529C1F,0x00519C1E,0x03519B1E,0x0054A41C
    dd 0x4960A133,0xFF000000,0xFD007F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFF000000,0x4463A335,0x0055A71E,0x03519D1F,0x00529F1F,0x00529F1F
    dd 0x00529D1F,0x00509B1C,0x007FBB44,0x006FB137,0x004C9B1A,0x00539F1F,0x00529E1E,0x00529F1F,0x00529F1F,0x0053A020,0x004D991A,0x006FB036
    dd 0x0073B43A,0x004D991B,0x00539F1F,0x00529F1F,0x00529F1F,0x00529F1F,0x00519F1F,0x00519E1D,0x007BB740,0x006EB036,0x004F9A1B,0x00539D20
    dd 0x00529C1F,0x00529C1F,0x04519B1E,0x0159A622,0x6E66A33A,0xFF000000,0xFB3F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB3F7F00,0xFF000000,0x7063A537
    dd 0x0256A720,0x04529E1E,0x00529F1F,0x00529F1F,0x00519F1F,0x004F9F1D,0x00519D1D,0x007FB943,0x006AAE33,0x004D9C1B,0x0053A020,0x00519F1F
    dd 0x00529F1F,0x0053A020,0x004E9B1B,0x0070B037,0x0074B53A,0x004C9B1A,0x00529F1F,0x00519E1E,0x00529F1F,0x00529F1F,0x004E9C1B,0x007AB841
    dd 0x0076B43C,0x00499617,0x004E991C,0x004E9A1C,0x00529B1E,0x00529C1F,0x02509B1D,0x0059A323,0xB4699F40,0xFF000000,0xFC55AA55,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFB3F7F3F,0xFF000000,0xA76BA542,0x0058A624,0x03509D1D,0x00529F1F,0x00529F1F,0x0054A121,0x0056A122,0x0059A124,0x0071B139
    dd 0x008EC451,0x0063AA2D,0x004C9B1A,0x00539F20,0x00529F1F,0x00539F20,0x004D9C1B,0x0070B137,0x0074B43A,0x004C9A19,0x00529F1F,0x00529F1F
    dd 0x00529F1F,0x004E9C1C,0x0072B239,0x0085BD48,0x007DB942,0x0079B63F,0x0077B43D,0x006DAF35,0x00529D1E,0x02519B1F,0x0053A01E,0x1F599D2A
    dd 0xFCFFFFFF,0xFF000000,0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFF000000,0xF7FFDFFF,0x1B589D28,0x0053A11D,0x02529F1F,0x00509D1D
    dd 0x0071B237,0x007FBA43,0x007EBA44,0x0075B43C,0x0068AB30,0x0085BE48,0x0065AA2F,0x004C991A,0x00529F1F,0x00539F20,0x004D9C1B,0x0071B238
    dd 0x0076B43D,0x004C9A1A,0x00539F1F,0x00519E1F,0x004D9C1B,0x0072B238,0x007DB942,0x00549E20,0x005BA226,0x0063A92D,0x0068AB31,0x0064A72D
    dd 0x00529B1E,0x01529B1F,0x02519D1D,0x0E5EA42C,0x79619A37,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFE000000,0xBB70A54B
    dd 0x2967A839,0x0152A01D,0x02529D1F,0x00529C1E,0x00559F21,0x0056A022,0x00529E1E,0x004E9C1C,0x004C9B1A,0x005BA427,0x0084BE47,0x006CAE33
    dd 0x004D9B1B,0x0053A020,0x004E9C1B,0x0071B138,0x0075B43B,0x004E9C1B,0x00529E1F,0x00509B1C,0x0077B53B,0x007BB73E,0x00529C1E,0x00509A1D
    dd 0x00509A1D,0x004E991C,0x004E981B,0x004F991C,0x00529C1E,0x00529C1E,0x04519B1E,0x0059A821,0x68619E36,0xFF000000,0xFB3F7F00,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFB3F7F00,0xFF000000,0x5566A339,0x005AA922,0x04519B1E,0x00529E1F,0x00529D1E,0x00519C1E,0x00519B1D,0x00519F1F,0x00539F20
    dd 0x0053A020,0x004E9C1C,0x00579F22,0x0083BE46,0x0073B339,0x004F9C1C,0x004D9C1B,0x0073B339,0x0075B43B,0x004C9A1A,0x00519C1E,0x007AB73E
    dd 0x0078B63D,0x004F9C1C,0x00509B1D,0x00529D1F,0x00519D1E,0x00529C1F,0x00529C1F,0x00529C1F,0x00529C1F,0x01529C1F,0x02519C1C,0x08589E27
    dd 0xD889B068,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0xB97BAE57,0x0157A224,0x02509C1D,0x00529F1F,0x00529E1E
    dd 0x00519C1D,0x00509C1D,0x00529F1F,0x00529F1F,0x00529F1F,0x00539F1F,0x004F9D1D,0x00539F1F,0x007CB941,0x0079B73E,0x004D9A1B,0x0071B438
    dd 0x0075B63B,0x004E9A1B,0x007DB941,0x0074B43A,0x004D9B1A,0x004F9E1D,0x00519F1F,0x00519E1E,0x00519F1E,0x004F9B1C,0x00539B1E,0x00529C1F
    dd 0x00519B1E,0x04519B1E,0x0057A820,0x595A9B2C,0xFF000000,0xFC55AA00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFEFFFFFF
    dd 0x315FA031,0x0054A31E,0x03519D1F,0x00519B1E,0x00569F21,0x0057A223,0x004F9C1C,0x00539F20,0x00529F1F,0x00529F1F,0x00529F20,0x00509E1E
    dd 0x004F9B1D,0x0074B43A,0x007FBB42,0x0076B43B,0x007CB940,0x0080BB45,0x006DAE33,0x004D9B1B,0x00519E1E,0x00529F1F,0x00519F1F,0x00539E1F
    dd 0x004E9B1B,0x005AA224,0x007DB740,0x00579F22,0x02509A1D,0x01539F1E,0x225CA12D,0xE589B075,0xFE00FF00,0xFD7F7F00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0xB473AA4A,0x0556A122,0x02519C1D,0x004F991D,0x005CA327,0x0087BF4A,0x005EA528,0x004D9B1A
    dd 0x0053A020,0x00529F1F,0x00519F1F,0x00539F1F,0x00529E1F,0x004E9B1B,0x0067AC2F,0x0083BD46,0x0084BD49,0x0068AC30,0x004C9A1A,0x00519E1E
    dd 0x00529F1F,0x00519F1F,0x00539F20,0x004E991B,0x0058A023,0x0084BF49,0x0068AD31,0x004F981B,0x02529A1E,0x0156A01F,0x3B69A73D,0xE76A9F3F
    dd 0xFD007F00,0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFE00FF00,0xF9AAAAD4,0x3767A43B,0x0053A11E,0x02529C1F
    dd 0x004F9A1C,0x0064A72C,0x0086BD48,0x0062A72C,0x004D9B1B,0x00529F1F,0x00529F1F,0x00529F1F,0x00529F1F,0x0053A020,0x004B9A19,0x0077B43D
    dd 0x007AB63F,0x004A9718,0x00529E1F,0x00529F1F,0x00519F1F,0x00539E1F,0x004E991B,0x005CA226,0x0084BC47,0x0069AB31,0x004F9A1C,0x00549C1F
    dd 0x01539A1E,0x02519C1C,0x02569D24,0xD476AB53,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFF7F,0xFF000000
    dd 0xCC78AA50,0x035B9F2A,0x03509B1D,0x00529C1F,0x00529C1F,0x004E991B,0x005EA428,0x0086BE48,0x006FB035,0x004E9B1C,0x00519C1E,0x00539E1F
    dd 0x00529F1F,0x0053A020,0x004E9C1B,0x0073B33A,0x0078B63E,0x004E9A1B,0x00529D1F,0x00529E1E,0x00529F1F,0x004D991A,0x0062A72D,0x0082BC48
    dd 0x005DA427,0x00489416,0x00529A1E,0x00539C1F,0x04519B1D,0x005AA824,0x9065A03E,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000,0x5E5F9F31,0x0057A720,0x05519B1E,0x00529C1F,0x00519C1F,0x004A9718,0x00519D1D
    dd 0x007DB840,0x0079B63F,0x00529D1F,0x004F9A1B,0x00539F1F,0x0053A020,0x004E9C1C,0x0073B339,0x0077B63D,0x004D9C1B,0x00529D1F,0x00529C1E
    dd 0x004D991A,0x0065A92D,0x008BC24D,0x007CB842,0x006AAD32,0x0070AF36,0x005B9F27,0x034F9B1C,0x0058A920,0x5E5B9C2D,0xFF000000,0xFC55AA00
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFE00FF00,0xF2B0C49C,0x2F5EA031,0x0056A51E
    dd 0x024F991D,0x005CA527,0x0076B53A,0x0075B53B,0x007CB943,0x0086BF4A,0x0080BC43,0x005EA528,0x004D991A,0x0053A020,0x004E9D1C,0x0075B53A
    dd 0x0078B83D,0x004E9C1C,0x00519C1D,0x004F9B1C,0x0073B33B,0x0080BC44,0x0064A82D,0x006CAD34,0x0074B33C,0x0071B237,0x02579D24,0x01509D1F
    dd 0x4A64A435,0xFBFFBFFF,0xFD007F00,0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F7F,0xFF000000,0xDF87AF6F,0x3561A532,0x0253A01F,0x0256A022,0x0066AB2E,0x0064A92D,0x005DA528,0x00519E1E,0x0065A92C,0x0084BD47
    dd 0x0070B137,0x00509C1D,0x004C9919,0x0077B63C,0x007AB940,0x004A9918,0x00559E20,0x007AB73F,0x0078B740,0x00549F20,0x004D991A,0x004E991B
    dd 0x004D991A,0x004E991B,0x044F9B1C,0x0158A324,0x5D66A03E,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFA669933,0xFF000000,0x9272A64F,0x005BA628,0x054F9A1B,0x004E991B,0x004E991B
    dd 0x00509A1D,0x00529C1E,0x004E9A1B,0x00569F21,0x007CB740,0x007EB941,0x00569F21,0x0073B33A,0x0078B53E,0x005AA226,0x0084BD47,0x006EAF34
    dd 0x004D9A19,0x00519C1D,0x00539D1F,0x00539C1F,0x00539D1F,0x02529C1F,0x02539E1E,0x0059A423,0x9957982D,0xFEFF00FF,0xFD007F00,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFD7F7F7F,0xA96AA047
    dd 0x005DA52B,0x00529E1C,0x03529A1F,0x00539C1F,0x00529C1F,0x00529D1E,0x00539D1F,0x00509B1C,0x004D9B1A,0x006DB035,0x0084BE47,0x007FBA44
    dd 0x0081BA45,0x0084BC47,0x0066AA2F,0x004D991A,0x00529D1F,0x00529C1E,0x00529C1E,0x00529C1E,0x02519B1E,0x00529E1D,0x0055A021,0x8F669F3D
    dd 0xFF000000,0xFD007F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000,0xB074A74D,0x0F59A128,0x0054A21D,0x04519B1D,0x00529D1E,0x00529D1E,0x00529D1E,0x00529D1E
    dd 0x00529D1F,0x004C9A1A,0x005CA327,0x0082BC47,0x0083BD47,0x0059A224,0x004D991A,0x00539D1F,0x00529C1E,0x00529C1E,0x00529B1F,0x04519B1E
    dd 0x0053A11D,0x0B59A027,0xA8639E3D,0xFF000000,0xFB3F7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA00,0xFF000000,0xD082AD67,0x2F5EA12E,0x0058A921
    dd 0x01519C1D,0x03509B1E,0x00529D1E,0x00519D1E,0x00529B1E,0x00539D20,0x004B9719,0x0077B53D,0x0079B83F,0x004C991A,0x00539C20,0x00529C1E
    dd 0x00529D1E,0x03509B1E,0x024F9B1D,0x0057A620,0x285EA42F,0xC87DAB58,0xFF000000,0xFB3F7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFB3F7F3F,0xFF000000,0xF1B6B6A3,0x6D68A73B,0x01579E23,0x0055A41E,0x01509B1D,0x03509B1E,0x01529B1E,0x00539C1F,0x004F9A1D,0x0079B63E
    dd 0x007BB840,0x004F9B1C,0x00529B1F,0x02519C1E,0x02509C1D,0x0054A31E,0x0057A125,0x6A66A63B,0xEFAFAF9F,0xFF000000,0xFB3F7F00,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xC075A550,0x4D5FA330,0x0058A025,0x0056A31E
    dd 0x00529B1C,0x04529C1E,0x024F9B1C,0x0079B73E,0x007BB740,0x024F9A1C,0x03519B1E,0x0054A11E,0x0057A323,0x3D5EA42F,0xBC79AB53,0xFF000000
    dd 0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFC55AA00
    dd 0xFF000000,0xFF000000,0xC572A24A,0x5A5E9C2F,0x0858A027,0x0059A721,0x00509E1B,0x007AB840,0x007DB942,0x00519D1A,0x005AA624,0x3360A330
    dd 0xAE71A648,0xFF000000,0xFF000000,0xFC55AA00,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFD007F00,0xFF000000,0xFF000000,0xD97FAE5D,0x81619F36,0x2C579B27,0x0282BB48
    dd 0x0185BD4B,0x365C9F2E,0xA56BA144,0xFAFFCCFF,0xFF000000,0xFE000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7FFF7F,0xFD007F00
    dd 0xFF000000,0xFF000000,0xFCFFFFFF,0x23B5A46F,0x24B29E68,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFB3F7F00,0xFF000000,0x2BC09871,0x23BE966F,0xFEFFFFFF,0xFC55AA55,0xFEFFFF00
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0x30BC986D
    dd 0x0AC19F76,0xF1DADAC8,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xF8DAFFFF,0x1EC09C73,0x0EBF9970,0xF0BBAA99,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xEFDFCFBF,0x0EC09B73,0x10BC976C,0xF1B6A37F,0xFF000000,0xFEFFFFFF
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xF0BBAA88,0x15BE986F
    dd 0x03C39D73,0xDBC6B89B,0xFF000000,0xFDFFFF7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xEEB4A587,0x17BE986D,0x02C5A073,0xD1C7B190,0xFF000000,0xFDFF7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xE3C8B69A,0x00C59E73,0x00CDA376,0xD5BC9D7F,0xFF000000,0xFDFF7F7F
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFCAAAAAA,0x72C3A27C
    dd 0x6FC2A17A,0xFACC9999,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAA55,0xFCAAAA55,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_green_20:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFD7F7F00,0xF77F9F3F,0xF6718D38,0xFD7F7F00
    dd 0xFE00FF00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFB3FBF3F,0xFF000000,0x6A579D25,0x66569C26,0xFF000000,0xFB3F7F00,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA00,0xFF000000
    dd 0xCD609E38,0x02539E20,0x00549E20,0xC1629C35,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA00,0xFF000000,0xD05C9D30,0x0B54A020,0x0159A224,0x0259A224,0x0355A021
    dd 0xB65A9D2D,0xFF000000,0xFB3F7F3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F00,0xFE00FF00,0xDA60A537,0x2656A024,0x005BA624,0x025CA327,0x015BA226,0x015BA325,0x0F57A223,0xBF5B9F2F,0xFF000000,0xFC55AA55
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFB3F7F00,0xFEFFFFFF,0x69589C27,0x0058AC20
    dd 0x0555A022,0x006BAD32,0x006BAD32,0x0457A022,0x0056A71F,0x42599F27,0xEF5F9F3F,0xFC55AA00,0xFE000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFC55AA55,0xFF000000,0xB95B9C2F,0x0457A322,0x055EA628,0x004D9C1B,0x0062A82B,0x0062A82C,0x004E9C1C
    dd 0x0560A62A,0x0059A822,0x9F5A9C2A,0xFF000000,0xFB3FBF3F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA55
    dd 0xFD7FFF7F,0x69589E28,0x0059A821,0x046CAD34,0x005EA629,0x0057A123,0x0057A223,0x0061A72B,0x036AAC31,0x0156A521,0x49569C25,0xFC55AA55
    dd 0xFD007F00,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xF97FAA7F,0x1A549E23,0x0058A422,0x0253A020
    dd 0x0060A72A,0x0066AB2E,0x0068AC30,0x005DA528,0x02529F1F,0x005AA625,0x18539C21,0xF45CA245,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000,0xD868A33A,0x0E53A020,0x015EA628,0x015AA325,0x004B9B19,0x0067AB2F,0x0066AA2F,0x004B9B19
    dd 0x005DA528,0x015DA327,0x06539E20,0xCE62A134,0xFF000000,0xFC55AA00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000
    dd 0xD868A33A,0x06539F20,0x015AA425,0x016FB037,0x0057A123,0x0058A224,0x0059A324,0x0058A224,0x016DAD35,0x005BA225,0x05539D20,0xDA609E37
    dd 0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFF000000,0xE06AA441,0x0B549E22,0x0156A121,0x01529F1F
    dd 0x0061A82B,0x0067AC30,0x0068AC30,0x005FA629,0x014F9B1C,0x0157A122,0x1A549D21,0xE968A239,0xFF000000,0xFE00FF00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F00,0xFD7F7F7F,0x39559B24,0x015FAA27,0x035DA427,0x004B9B19,0x0068AC30,0x0067AB2F,0x004C9B1A
    dd 0x0463A72D,0x0060AB27,0x58559B24,0xFF000000,0xFC55AA00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC55AA00
    dd 0xFF000000,0x9C5A9D2B,0x005AA723,0x066DAF34,0x0160A62A,0x005DA527,0x005EA628,0x0261A72B,0x036AAD31,0x0256A023,0xD05C9D2B,0xFE000000
    dd 0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD007F00,0xFF000000,0x45599D27,0x005AAC21
    dd 0x0057A022,0x036EAF35,0x036EAF35,0x0056A120,0x0057A81F,0x73579A26,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE00FF00,0xFC555500,0xF36AAA3F,0x6C58A127,0x094F9D1D,0x0063AE2B,0x0063AE2B,0x19529E1D
    dd 0x9A5DA12D,0xFF000000,0xFC55AA00,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xDA599E30,0x5E79A93F,0x647DA943,0xEB66993F,0xFF000000,0xFD7F7F00,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xF97FAA55
    dd 0xFF000000,0xB7D89886,0xB2D39884,0xFF000000,0xF9AAAA55,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFAAAA,0xFD7F7F00,0x99BB9B70,0x93BC9B71,0xFE00FF00
    dd 0xFBBF7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFEFFFF00,0xFF000000,0xE5C49C75,0xE4BCA07A,0xFF000000,0xFEFFFF00,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_monol_64:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFDFFFFFF,0xFF000000,0xC8A2A29D,0xD1A0A0A0,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFCFFFFFF,0xF9000000,0x23E3E0D8,0x38E1DED5,0xFD000000,0xFCFFFFFF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0x83C1C1B9,0x00FFFFFC
    dd 0x00FFFFF8,0x98BCB9B2,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF
    dd 0xFEFFFFFF,0xDC91918A,0x0AEDECE2,0x03FDFCF1,0x02FFFDF4,0x12E7E6DC,0xE8798579,0xFEFFFFFF,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0x53D4D2C9,0x00FFFFFE,0x03F8F6EA,0x04FAF7EB,0x00FFFFFF,0x6BCBCBC2,0xFF000000
    dd 0xFBFFBFBF,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFBFFFFFF,0xFF000000,0xC3AAAAA5,0x00F9F8EF,0x03FCFAEF,0x00F9F7EB
    dd 0x01F9F6EB,0x02FCFBEF,0x03F0EFE5,0xD2999993,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0x4BD7D5CD,0x01FFFFFC,0x03F8F6EA,0x00FCFAEE,0x00FCFAEE,0x04F9F7EB,0x00FFFFFD,0x5CD1D0C8,0xFF000000,0xED637171,0xFF000000,0xFEFFFF00
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000
    dd 0xFD7F7F7F,0xF36A6A6A,0x60C5C3BD,0xB29B9B98,0x02F3F1E7,0x01FBF9EE,0x00FAF8ED,0x00F2F0E4,0x00F2F1E5,0x01FAF8EC,0x00FCFBF0,0x0BEFEEE3
    dd 0xA29F9C99,0x31D7D6CE,0xEC787878,0xFDFFFFFF,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0x7FCBC9C3,0x00FFFFFD,0x16E2E0D7,0x00FDFBF0,0x00F7F5E9,0x00FFFFF7,0x00AFAEA7
    dd 0x00B9B7B0,0x00FFFFF7,0x00F8F4EA,0x00FCFAEE,0x09E5E3DA,0x00FFFFFF,0x5DCFCCC6,0xFF000000,0xFCFFFFFF,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFA999999,0xFDFFFFFF,0xDD878787,0x0BEFECE3,0x03FFFDF4,0x00FFFCF1
    dd 0x00F9F7EB,0x00F8F6EA,0x00FFFFF8,0x00AAA8A2,0x00B6B4AD,0x00FFFFF8,0x00F8F4EB,0x01F9F7EC,0x00FEFBF0,0x04FCF9F0,0x00F9F8F0,0xB8ACACA5
    dd 0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000
    dd 0x5ED1CFC9,0x00FFFFFF,0x04F9F6EC,0x01F9F7EC,0x00FAF8EC,0x00F8F6EA,0x00FFFFF8,0x00A9A8A2,0x00B5B4AE,0x00FFFFF8,0x00F8F5EA,0x00F9F7EC
    dd 0x01FAF7ED,0x03F9F6EB,0x01FFFFFB,0x32DCDAD2,0xFF000000,0xFB000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xB3A7A7A4,0xD17F7F7F,0x0DEEECE2,0x01FDFBF3,0x01F9F7EB,0x00F8F6E9,0x00FCFAEE,0x00F8F6EA,0x00FFFFF7,0x00A8A7A1
    dd 0x00B5B4AD,0x00FFFFF8,0x00F7F5EA,0x00FCF9EE,0x00F6F4E9,0x00F9F6EC,0x01FAF8ED,0x00F8F6EB,0x7EB1B1AD,0x51C8C5BF,0xFB000000,0xFEFFFFFF
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFEFFFFFF,0xE77F7F7F,0x0EE4E2D9,0x2AD3D2CA,0x00FAF7ED,0x00F9F6EB,0x00FFFEF3,0x00999994
    dd 0x00CFCEC6,0x00FDFDF2,0x00FFFFF6,0x00A8A7A0,0x00B5B4AE,0x00FFFFF8,0x00FBF9EE,0x00E7E5DC,0x00878784,0x00F3F1E6,0x00FBF9EE,0x00FBF9ED
    dd 0x00EFEDE3,0x00FFFFF9,0xA5C0C0BB,0xFF000000,0xFBBFBFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFBF,0xFF000000,0x7BCCCAC3,0x00FFFFFE,0x00FFFDF2
    dd 0x00FAF7EC,0x00F8F6EB,0x00FFFFF7,0x00B7B5AF,0x00878683,0x00FFFFF5,0x00FEFEF6,0x00A8A7A0,0x00B5B3AE,0x00FEFEF6,0x00FFFFF6,0x00979693
    dd 0x009E9C98,0x00FFFFF5,0x00F9F5EB,0x00F9F7EB,0x04FCF9EE,0x01FFFFFA,0x31DEDDD3,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFEFFFFFF
    dd 0xF0666666,0x15E8E5DD,0x01FFFDF5,0x03F8F5EA,0x00FAF7EC,0x00FAF7EC,0x00FBF8ED,0x00FAF8F0,0x0083827F,0x00C6C4BC,0x00FFFFFF,0x00A4A39E
    dd 0x00B2B0AB,0x00FFFFFF,0x00D1CFC7,0x00777675,0x00F3F2E9,0x00FCFAEF,0x00F9F5EC,0x00FAF6ED,0x01F9F6EB,0x02FCFAEE,0x02F6F4EA,0xCAB2ADAD
    dd 0xFEFFFFFF,0xFCFFFFAA,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0xA7BCBCB6,0x00FFFEF7,0x03FAF7EC,0x00F9F5ED,0x00F9F6ED,0x00FAF6ED,0x00F8F4EB,0x00FFFFF6
    dd 0x00D2D0C9,0x006D6E6B,0x00F8F7F1,0x00A8A7A1,0x00B7B5AF,0x00F8F8F2,0x006F6F6E,0x00CBCAC2,0x00FFFFF6,0x00F8F5EB,0x00FAF6ED,0x00FAF6ED
    dd 0x00F8F6EA,0x04F9F7EB,0x00FFFFFE,0x6CD3D0C9,0xFF000000,0xFC555555,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xF57F7F7F,0xF7000000,0x5BD9D8D0,0x01FFFFFD,0x04F9F7EC,0x00FBF8EE
    dd 0x00F9F5EC,0x00F9F6ED,0x00F9F6ED,0x00F9F5EB,0x00FFFFF6,0x00A1A09B,0x0092918D,0x00A3A29D,0x00B4B3AC,0x0091918C,0x00A09F9B,0x00FFFFF7
    dd 0x00F8F5EA,0x00FAF7ED,0x00FAF6ED,0x00FBF7ED,0x00FFFFF5,0x02F8F6EC,0x00FFFFFC,0x41DEDDD4,0x7EAFAFAA,0xA4C4C4BE,0xFF000000,0xFCAAAAAA
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBFBFBF,0xFF000000,0x9BC9C6C1,0x4CC3C1BC
    dd 0x2FE1E0D6,0x00FFFFF9,0x02F7F6EA,0x00F5F4E9,0x00FBF8EE,0x00FAF6ED,0x00F9F6ED,0x00F9F6EC,0x00FAF8ED,0x00FCFBF0,0x00908F8B,0x006B6B67
    dd 0x006C6C68,0x00979692,0x00FEFCF3,0x00F9F7EC,0x00FAF7EC,0x00FAF6ED,0x00FBF8ED,0x00F6F4EA,0x00BDBCB5,0x00F6F3E9,0x00FDFCF1,0x09EEECE0
    dd 0x00F2F1EC,0x5DDAD9D1,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFCFFFFFF,0xFF000000,0x4CDBD9D1,0x00FFFFFF,0x02F2F0E5,0x00FEFCF0,0x00F0EEE3,0x00888783,0x00EDEAE0,0x00FCFAEF,0x00F9F6EC,0x00FAF6ED
    dd 0x00F9F5EC,0x00FCF9EE,0x00F7F6ED,0x0081817D,0x008B8A86,0x00FBF9F1,0x00FBF8EE,0x00F9F7EB,0x00FAF8EC,0x00F8F5EA,0x00FFFFF7,0x00BDBBB5
    dd 0x007B7B7A,0x00FBFAF1,0x00F9F7EC,0x01FAF8EC,0x00FFFFFC,0x2DE3E0D8,0xFD000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xF6383838,0x1BE5E1D8,0x02FFFFF6,0x02FAF8EC,0x00F9F6EA,0x00FFFEF5,0x0093938E
    dd 0x00A3A29D,0x00FFFFF9,0x00F8F4EA,0x00FAF6ED,0x00FAF6ED,0x00F7F3EA,0x00FFFFFA,0x00A5A39D,0x00B5B2AD,0x00FFFFFA,0x00F7F4E9,0x00FAF8EC
    dd 0x00F9F7EC,0x00FBF9EF,0x00F5F3E9,0x00737371,0x00D4D2CA,0x00FEFEF4,0x00F8F5EA,0x01F8F5EB,0x00FDFCF0,0x07EAE8DE,0xE27B7B7B,0xFD7F7F7F
    dd 0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFD7F7F7F,0xCE91918C,0x01F1EEE5,0x01FDFBEE
    dd 0x00F9F7EB,0x00F9F6EB,0x00FCFBEF,0x00E7E5DC,0x006F6F6C,0x00E1DFD6,0x00FEFCF3,0x00F8F5EB,0x00FAF6ED,0x00F8F4EB,0x00FEFEF8,0x009F9E99
    dd 0x00ADABA5,0x00FEFEF8,0x00F8F6EA,0x00FAF7ED,0x00F8F5EA,0x00FFFFF9,0x00A09E9A,0x00979691,0x00FFFFF9,0x00FEFBF0,0x00FDF9EF,0x00F9F6EB
    dd 0x01FBF9ED,0x00F7F5E9,0xCFAFAFAA,0xFF000000,0xFCAAAAAA,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF
    dd 0xFF000000,0xB5BDBDB6,0x00FFFEF4,0x03FBF9ED,0x00FAF8EC,0x00FDFBEF,0x00FFFEF2,0x00FFFFFF,0x00C1C0BA,0x00898884,0x00FEFDF4,0x00F9F6EC
    dd 0x00FAF6EC,0x00F7F4EB,0x00FFFFF8,0x00A09F99,0x00AEADA6,0x00FFFFF8,0x00F8F6EA,0x00F7F5EA,0x00FFFFF5,0x00D3D1C9,0x007C7D7A,0x00F8F7EE
    dd 0x00F8F7ED,0x00E1DFD6,0x00EFEDE3,0x00FBF9ED,0x02FBF9ED,0x01F8F6EB,0xA09E9B96,0xC2A39E9E,0xFEFFFFFF,0xFD7F7F7F,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFEFFFFFF,0xFDFFFFFF,0xC5999995,0x90AEACA5,0x00FFFFF5,0x03F8F6EB,0x00FEFEF3,0x00B2B2AB,0x00868580,0x00A5A49E
    dd 0x00B1B0AA,0x00605F5E,0x00B1AFA8,0x00FFFFFB,0x00F7F4EA,0x00F7F4EB,0x00FFFFF8,0x00A09F99,0x00AEACA6,0x00FFFFF8,0x00F6F4E8,0x00FEFCF1
    dd 0x00F0EFE6,0x006C6C6A,0x0071716E,0x008B8B88,0x007D7D79,0x00777774,0x00CFCEC5,0x00FEFEF3,0x00FAF8EC,0x05F3F1E5,0x15DFDED9,0x5AE3E1D8
    dd 0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0x40D9D9D0,0x16D8D7D2,0x02F7F5EA,0x00FAF7EC
    dd 0x00FBF9EF,0x00E4E2D9,0x00C0BEB7,0x00A9A7A3,0x009E9B98,0x00A4A49F,0x00737370,0x00BFBEB7,0x00FFFFF9,0x00F5F2E8,0x00FFFFF9,0x00A09F99
    dd 0x00ADABA5,0x00FFFFF7,0x00FAF8ED,0x00F5F4EA,0x007F7E7B,0x00A09F9A,0x00C7C6C0,0x00C9C6BF,0x00DEDBD3,0x00F4F1E7,0x00FBF9ED,0x00F9F6EC
    dd 0x00FAF6ED,0x04F9F7EC,0x00FFFFFF,0x57E0DFD6,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFF000000,0xFD000000
    dd 0x2EE4E1DA,0x00FFFFFF,0x02F8F6EA,0x00FAF8ED,0x00F8F5EB,0x00FEFBF0,0x00FFFFF7,0x00FFFFF8,0x00FFFFF7,0x00FFFFFB,0x00DDDBD4,0x006B6A67
    dd 0x00C7C5BE,0x00FFFFF8,0x00FDFDF6,0x00A19E99,0x00ACA9A3,0x00FFFFF9,0x00FCFBF0,0x00858480,0x009D9D98,0x00FFFFF9,0x00FFFFF7,0x00FFFFF5
    dd 0x00FFFDF2,0x00FBF8ED,0x00FBF8EE,0x00FFFBF1,0x00FAF6ED,0x04F9F7EC,0x01FDFDFB,0x63EDEBE1,0xFD7F7F7F,0xFBFFFFFF,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFE000000,0xFF000000,0xFB000000,0x25DEDBD3,0x01FDFDF6,0x02F9F5EB,0x00FAF6EC,0x00FFFDF3,0x00FFFCF1,0x00F7F4E9,0x00F8F5EB
    dd 0x00F8F5EB,0x00F6F3E9,0x00FFFFF6,0x00D9D7D0,0x006D6C6A,0x00C4C3BB,0x00FFFFFF,0x009F9C98,0x00B0ACA7,0x00FFFFFE,0x008A8985,0x0094938E
    dd 0x00FFFFF7,0x00F9F6EC,0x00F8F4EB,0x00F8F5EB,0x00F8F6EB,0x00FBF8EE,0x00F4F1E6,0x00E5E3DA,0x00FBF9EF,0x04F8F6EB,0x00FFFFFE,0x69E3E0D9
    dd 0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0x3CE8E7DB,0x00FFFFFA,0x03F8F5EB,0x00FDFAF2
    dd 0x00D2D0C8,0x00DDDBD2,0x00FEFCF3,0x00F8F5EB,0x00F9F6ED,0x00F9F6ED,0x00F7F4EA,0x00FFFFF7,0x00DCDBD3,0x006C6C69,0x00C1C0BA,0x00A7A5A0
    dd 0x00A8A6A1,0x009B9A94,0x008B8A86,0x00FCFBF1,0x00FAF7EE,0x00F9F6EC,0x00FAF7ED,0x00FAF7ED,0x00F9F6EB,0x00FFFFF6,0x0092908E,0x00ACAAA4
    dd 0x00FFFFF7,0x03F7F4EA,0x00FEFEFA,0x71C0BEB7,0xDBA2A2A2,0xFCFFFFFF,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFFF,0xF5000000
    dd 0x55D6D5CC,0x00FFFFFD,0x04F7F4EA,0x00FFFFF6,0x00BEBCB6,0x00747470,0x00F8F7ED,0x00FAF8EE,0x00F8F5EC,0x00F9F6ED,0x00F9F6ED,0x00F7F4EA
    dd 0x00FFFFF5,0x00E8E7DE,0x007F7E7A,0x0071706E,0x00656563,0x009C9C96,0x00FFFEF3,0x00FBF7EE,0x00F9F5EC,0x00F9F6ED,0x00FAF6ED,0x00F7F4EA
    dd 0x00FFFFF8,0x00C3C1BA,0x00757573,0x00F7F6EC,0x00FBF9ED,0x00FAF7EC,0x03F8F6EA,0x0DE7E6E1,0x58D7D5CE,0xFF000000,0xFBFFFFFF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFEFFFFFF,0xFD7F7F7F,0x54C1C1BA,0x21DEDDD6,0x02FCFAF2,0x01F8F4EC,0x00F9F6EB,0x00FFFFF8,0x009C9B95,0x0096958F,0x00FFFFF8
    dd 0x00F8F4EB,0x00F9F6ED,0x00F9F6ED,0x00F9F6ED,0x00F8F4EB,0x00FFFDF2,0x00F3F2EA,0x007C7B78,0x0092928C,0x00FFFFF6,0x00FAF7ED,0x00F8F5EC
    dd 0x00F9F6ED,0x00F9F6ED,0x00F8F4EB,0x00FEFBF3,0x00E9E8DF,0x0071706F,0x00DBDBD1,0x00FFFEF4,0x00F8F6EB,0x00FAF7ED,0x04F9F6EB,0x00FFFFFF
    dd 0x6AD0CFC6,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0x48D7D7CE,0x00FFFFFF,0x03F7F4EA,0x00FAF6ED,0x00F9F6EC
    dd 0x00FBF8EE,0x00F6F5EC,0x00767573,0x00B8B6AF,0x00FFFFF9,0x00F7F4EA,0x00F9F6ED,0x00F9F6ED,0x00FAF6ED,0x00F6F3E9,0x00FFFFFB,0x00A2A19B
    dd 0x00A8A6A1,0x00FFFFF9,0x00F7F3EA,0x00F9F6ED,0x00FAF6ED,0x00F9F5EC,0x00FBF8EF,0x00F8F6EE,0x007C7B79,0x00ADACA7,0x00FFFFF7,0x00F6F4E8
    dd 0x00FAF7ED,0x00FAF6ED,0x04FAF7ED,0x01FFFFFA,0x91C7C5BE,0xFF000000,0xFBFFFFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFFF,0xFF000000,0x72D1CEC6
    dd 0x02FFFFFC,0x04F9F5EC,0x00FAF6ED,0x00FAF6ED,0x00F9F6EC,0x00FFFEF3,0x00EEECE3,0x00797875,0x00C9C8C0,0x00FFFFF8,0x00F7F3EA,0x00FAF6ED
    dd 0x00F9F6ED,0x00F8F4EB,0x00FEFEF7,0x009C9A95,0x00A3A19B,0x00FFFFF8,0x00F7F4EB,0x00FAF6ED,0x00F9F6EC,0x00FAF7ED,0x00FFFDF3,0x008A8885
    dd 0x009E9D99,0x00FFFFFF,0x00FFFFF7,0x00FFFFF5,0x00FAF6EC,0x00F9F6EC,0x01FCF9ED,0x00F6F4EA,0xCEABABAB,0xFF000000,0xFDFFFFFF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFBBFBFBF,0xFF000000,0x9FBCB9B1,0x00FFFFF9,0x03FAF6EC,0x00FAF6ED,0x00FAF7ED,0x00F7F5E9,0x00F1EEE4,0x00ECEAE1,0x00A5A49E
    dd 0x00585856,0x00D3D1C8,0x00FFFFF8,0x00F7F2EA,0x00FAF6ED,0x00F8F4EB,0x00FFFFF7,0x009C9A95,0x00A2A19B,0x00FFFFF8,0x00F8F4EB,0x00F9F6EC
    dd 0x00F9F7EC,0x00FFFFF6,0x009D9B97,0x00626160,0x00878683,0x00979592,0x0095938E,0x00B7B5AE,0x00FDFBF0,0x02F7F4EA,0x00FFFFFA,0x35DCDAD1
    dd 0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xF5191919,0x14EAE8DE,0x00FEFDF4,0x01F7F3EB,0x00FEFBF0
    dd 0x009E9D98,0x00767673,0x00797976,0x008D8C88,0x00A9A8A4,0x0072706E,0x00D3D2C9,0x00FFFFF9,0x00F7F4EA,0x00F8F5EB,0x00FFFFF7,0x009A9994
    dd 0x00A09F9A,0x00FFFFF9,0x00F7F3E9,0x00FAF7ED,0x00FFFFF8,0x009D9C98,0x0083827F,0x00E9E8DF,0x00CFCDC5,0x00BAB8B1,0x00AFADA6,0x00C5C2BB
    dd 0x00FDFBEF,0x01F8F5EA,0x03FCFAF2,0x1CE6E5E0,0x83C1BFB9,0xFEFFFFFF,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xAEADAAA6
    dd 0x30D7D6CE,0x01FFFDF8,0x02F8F4EB,0x00FBF8ED,0x00EAE8DE,0x00E1E0D7,0x00F0EEE4,0x00FEFBF1,0x00FFFFFC,0x00D0CFC7,0x006D6D6A,0x00C2C2BA
    dd 0x00FFFFF9,0x00F6F4E9,0x00FFFFF7,0x009A9993,0x00A09F99,0x00FEFEF7,0x00FAF8EC,0x00FEFCF2,0x0093928F,0x00878683,0x00F7F6EB,0x00FFFEF3
    dd 0x00FFFFF3,0x00FFFFF7,0x00FFFFF7,0x00FFFFF5,0x00FAF7EC,0x00FAF8ED,0x04FAF7EA,0x00FFFFFF,0x8ACACAC1,0xFF000000,0xFBFFFFFF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFBFFFFFF,0xFF000000,0x54CDCCC4,0x00FFFFFE,0x04F9F5EB,0x00FAF6ED,0x00FAF6ED,0x00FEFBF0,0x00FFFCF1,0x00FDFAEF,0x00F9F6EC
    dd 0x00F7F3E9,0x00FFFFF6,0x00DDDBD3,0x00706E6C,0x00AFAEA8,0x00FFFFF7,0x00FFFFF6,0x00979690,0x009D9C96,0x00FFFFFC,0x00F9F7EE,0x00888784
    dd 0x008D8C88,0x00FCFBF0,0x00FCFAEF,0x00F8F6EA,0x00F8F7EB,0x00F7F5E9,0x00F9F7EB,0x00F9F7EB,0x00FAF8EC,0x01F8F5EA,0x02FFFDF3,0x10EAE9DE
    dd 0xEB7F7F72,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFAA,0xFF000000,0xBBB7B4B0,0x00FBFAF2,0x03FBF8EE,0x00F9F6ED,0x00F9F6ED
    dd 0x00FBF8EE,0x00FCF8EF,0x00F8F4EB,0x00F9F6ED,0x00F9F6ED,0x00F7F4EA,0x00FFFFF5,0x00EAE8E0,0x00797875,0x00989792,0x00FFFFFC,0x00999793
    dd 0x00A4A19D,0x00F9F8F4,0x007D7C7A,0x00969591,0x00FFFEF4,0x00FBF9EE,0x00F9F5EB,0x00FAF7ED,0x00F9F6EA,0x00FFFDF1,0x00F7F5EB,0x00F9F6EB
    dd 0x00FBF8ED,0x04F9F7EB,0x00FFFFFF,0x6FCFCFC6,0xFF000000,0xFBFFFFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFC000000
    dd 0x30E1DED6,0x00FFFFFC,0x03F8F4EB,0x00FBF8EF,0x00F1EEE4,0x00EEEBE2,0x00FFFDF3,0x00F7F4EB,0x00F9F6ED,0x00FAF6ED,0x00F8F4EA,0x00FFFDF2
    dd 0x00F6F5EB,0x008B8A86,0x008A8984,0x008B8986,0x008A8986,0x007F7E7B,0x00A6A5A0,0x00FFFFF5,0x00FAF8EC,0x00F9F6EB,0x00FAF7ED,0x00F8F4EA
    dd 0x00FFFFF6,0x00DBD9D1,0x0082817D,0x00F1EFE5,0x02FBF8EE,0x00FEFEF6,0x34E5E3DA,0xF4737373,0xFDFFFFFF,0xFEFFFFFF,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0xB4C5C5BB,0x03FAF9F2,0x02F9F7ED,0x00FEFDF2,0x00D8D5CD,0x0070706D,0x00DEDCD3,0x00FFFFF8
    dd 0x00F7F3EA,0x00F9F6ED,0x00FAF6ED,0x00F8F5EB,0x00FCFAEF,0x00FFFFF6,0x00ACABA6,0x00686865,0x00696865,0x00BAB9B3,0x00FFFFF8,0x00F9F6EB
    dd 0x00F9F6EC,0x00FAF8EC,0x00F7F5E9,0x00FFFFF6,0x00E0DED6,0x006F6D6C,0x00C3C2BB,0x00FEFDF2,0x02F9F7EB,0x01FBF9F1,0x4DCBC8C2,0xDFAFA7A7
    dd 0xFDFFFFFF,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFDFFFFFF,0xEB595959,0x38CFCEC5,0x00FEFEF9,0x02F7F4EA
    dd 0x00FFFDF3,0x00C0BFB8,0x006E6E6B,0x00D3D2CA,0x00FFFFF9,0x00F8F5EC,0x00F8F5EC,0x00FAF6ED,0x00F9F6EC,0x00F8F6EC,0x00FFFFFE,0x008E8E89
    dd 0x009C9C96,0x00FFFFFD,0x00F7F4E9,0x00FAF7EC,0x00FAF7EC,0x00F8F6E9,0x00FFFFF7,0x00D6D5CD,0x006C6B69,0x00C0BFB8,0x00FFFFF8,0x00F9F7EB
    dd 0x01F8F6EA,0x01FFFDF4,0x0AEBEADF,0xE2959E95,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFF000000
    dd 0xB69D9D96,0x02EBE9E1,0x04FCFAF0,0x00F9F7EC,0x00F9F6EB,0x00FFFFF7,0x00CDCCC5,0x006B6A68,0x00B4B3AD,0x00FFFFF5,0x00FBF8EE,0x00F8F4EB
    dd 0x00FAF7ED,0x00F8F5EA,0x00FEFEF4,0x0091908B,0x009C9C96,0x00FEFEF6,0x00F8F5EA,0x00F9F6EC,0x00F8F5EA,0x00FFFFF8,0x00C8C7C0,0x007C7B78
    dd 0x00DAD9D1,0x00FFFFFF,0x00FCFAED,0x00F9F7EB,0x05FCFAF0,0x00FDFCF5,0xA3B9B9B1,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0x52DAD7CE,0x00FFFFFF,0x05F9F7EB,0x00FAF7EC,0x00FBF9EE,0x00FFFFFF,0x00EFEEE6
    dd 0x007E7D7B,0x0095948F,0x00FAF9EF,0x00FFFFF3,0x00F7F4EA,0x00F8F5EB,0x00FFFFF5,0x008F8D89,0x00999894,0x00FFFFF7,0x00F6F4E9,0x00FAF8EC
    dd 0x00FFFFF9,0x00BBB9B3,0x00575555,0x008B8A87,0x00B9B8B3,0x00A6A49F,0x00E0DED5,0x03FDFCF1,0x00FFFFFF,0x6ACFCDC6,0xFF000000,0xFCFFFFFF
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFDFFFFFF,0xEF5F5F4F,0x26E1E0D8,0x00FFFFFE
    dd 0x02FFFCF0,0x00D9D6CF,0x008F8E89,0x00989691,0x0084827F,0x006A6968,0x00817F7D,0x00DCDBD2,0x00FFFFF8,0x00F7F5EA,0x00FEFEF4,0x008E8B88
    dd 0x00989692,0x00FEFEF4,0x00FDFBEF,0x00FCFAF0,0x00989692,0x007B7A77,0x00C0BEB8,0x00AAA9A3,0x009C9A95,0x00A4A29D,0x02E4E2DA,0x01FCFCF7
    dd 0x59CFCDC6,0xFC000000,0xFCFFFFFF,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFDFFFFFF,0xFF000000,0xDC91918A,0x33E2E2DA,0x02FFFFF6,0x02E8E6DC,0x00BCBAB4,0x00C2C0B9,0x00D8D6CE,0x00F5F3EB,0x00BCBBB5,0x0070706D
    dd 0x00B1B1AA,0x00FFFFF4,0x00FFFFF9,0x008A8885,0x0094938F,0x00FFFFFF,0x00ECEBE2,0x0083827E,0x008F8D8A,0x00F3F2E8,0x00FFFFF8,0x00FFFFF5
    dd 0x00FFFFF7,0x00FFFFF8,0x03FFFCF0,0x00F7F7EF,0x5BB1B1AB,0xFC555555,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFFF,0xFF000000,0x80ACAAA4,0x00F7F6F0,0x04FFFDF0,0x00FFFFF7,0x00FFFFF6
    dd 0x00FFFFF2,0x00FBF9EE,0x00FFFFF7,0x00E6E6DC,0x0082817D,0x00878783,0x00EEEDE7,0x00908F8A,0x00999993,0x00DAD9D4,0x006E6D6B,0x00AEADA6
    dd 0x00FFFFF8,0x00FCFAEE,0x00F7F5E9,0x00F8F5EB,0x00F8F6EB,0x02F6F4E7,0x02FCFAEF,0x00F6F5EE,0xA3D5D2CA,0xFEFFFFFF,0xFDFFFFFF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFDFFFFFF,0xA2CDCAC5
    dd 0x00F5F4ED,0x00FEFDF2,0x03F6F4E8,0x00F8F5EB,0x00F8F5EC,0x00F9F5ED,0x00F7F4EA,0x00FFFCF2,0x00FDFBF1,0x00A1A09C,0x00767571,0x007A7976
    dd 0x0073726F,0x00767571,0x00C6C4BD,0x00FFFFF8,0x00F9F6EB,0x00F9F5EC,0x00FAF6ED,0x00FAF6ED,0x03F8F5EA,0x00FFFFF3,0x00F7F6EF,0x9EBDBDB2
    dd 0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0xADBDBDB4,0x0CEFEEE6,0x00FFFFFA,0x04F8F5EB,0x00F9F5EC,0x00F9F6ED,0x00F9F6ED,0x00F8F4EB
    dd 0x00FAF6ED,0x00FFFFF9,0x00D3D2CA,0x0071716E,0x00787775,0x00E4E3DB,0x00FFFFF7,0x00F7F5EA,0x00FAF6ED,0x00FAF6ED,0x00F9F5EC,0x04F9F5EB
    dd 0x00FFFFFB,0x0FEBEAE4,0xABBCB9B3,0xFF000000,0xFBFFFFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0xCEA6A19C,0x29E5E4DD,0x00FFFFFF
    dd 0x02FBF8EE,0x03F7F4EB,0x00F9F5ED,0x00FAF6ED,0x00F9F6ED,0x00F7F3EA,0x00FFFFFB,0x008B8A85,0x0093918D,0x00FFFFFA,0x00F6F3E9,0x00FAF6ED
    dd 0x00FAF6ED,0x03F8F4EB,0x01FBF8EE,0x00FFFFFF,0x32E4E3DD,0xD69B9B95,0xFF000000,0xFBFFBFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFBBFBFBF,0xFF000000,0xEF4F4F4F,0x68D4D4CC,0x00F5F4EB,0x00FFFFFD,0x01FBF7ED,0x03F8F4EB,0x01F9F5EC,0x00F9F5EC,0x00FDFDF1,0x00868581
    dd 0x008E8D89,0x00FEFEF4,0x00F8F5EB,0x02F8F5EA,0x02FAF7ED,0x00FFFFFD,0x01F1F0E7,0x73CDCDC8,0xF5191919,0xFF000000,0xFBBFBFBF,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xBFB7B3AF,0x46DFDFD8,0x00F6F4EB,0x00FFFFFC
    dd 0x00FDFAEF,0x04F8F6EB,0x02FFFDF2,0x00868581,0x008F8E89,0x03FFFFF3,0x03F9F7EC,0x00FFFFF9,0x00FBF9F0,0x44E1DFDA,0xC3AEAEA5,0xFF000000
    dd 0xFF000000,0xFDFFFF7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFCFFFFFF
    dd 0xFF000000,0xFF000000,0xC0AAAAA5,0x4FD9D7D2,0x04EFEEE5,0x00FFFFFC,0x00FFFFFD,0x0083827E,0x008A8A85,0x00FFFFFF,0x00FFFDF4,0x37E1E0DA
    dd 0xB6BCBCB5,0xFF000000,0xFF000000,0xFCFFFFFF,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFDFFFFFF,0xFF000000,0xFF000000,0xD39C9C96,0x78D1D1CA,0x26EBEBE3,0x017D7C79
    dd 0x04858481,0x3DE9E8E3,0xAABDBDB7,0xFE000000,0xFF000000,0xFDFFFFFF,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFDFFFFFF
    dd 0xFF000000,0xFF000000,0xF9000000,0x17D5D4CC,0x27D6D4CD,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFC555555,0xFBFFFFFF,0xFF000000,0x20F8F5EC,0x1EE8E6DD,0xFEFFFFFF,0xFCFFFFFF,0xFE000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xF5191933,0x13EEEBE3
    dd 0x14E3E1D9,0xF6000000,0xFF000000,0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xE6474751,0x04E9E7E0,0x17EEEEE4,0xF5191919,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xDE6C6C6C,0x00ECEBE2,0x16F2F1E9,0xF3556A6A,0xFF000000,0xFEFFFFFF
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFD7F7F7F,0xFF000000,0xDE929292,0x03F3F1E6
    dd 0x05E9E7DF,0xE1666666,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFD7F7F7F,0xFF000000,0xD8A3A39C,0x05F5F3E9,0x06EEEBE3,0xDC8A8A8A,0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0xD1959590,0x00FFFFF6,0x00FAF8ED,0xDF9FA79F,0xFF000000,0xFD7F7F7F
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xF9555555,0x70CECEC5
    dd 0x7CCACCC2,0xFB3F3F3F,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFFF,0xFBBFBFBF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000
logo_monol_20:
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFE000000,0xFDFFFF7F,0xFA666666,0xFA666666,0xFDFFFFFF
    dd 0xFE000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFBFFFFFF,0xFF000000,0x70EBE7DE,0x76EAE8DF,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFF000000
    dd 0xD3C5C5B9,0x02F8F7EB,0x05F6F4E9,0xCFC4BFB4,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCAAAAAA,0xFF000000,0xD3CAC5BF,0x11FAF9F4,0x01E6E5DA,0x01E6E4DA,0x0BFAF9F4
    dd 0xC4CFCFC2,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFDFFFFFF,0xFEFFFFFF,0xDED0D0C8,0x2BF0EFE9,0x00EAE9E4,0x02DAD8CF,0x02DEDCD3,0x00E4E3DD,0x16F4F4EE,0xCDDBD6D1,0xFF000000,0xFCFFFFAA
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBFFFFBF,0xFE000000,0x6BE6E5D9,0x00FFFFFF
    dd 0x05E8E5DC,0x00B5B3AD,0x00B7B5AF,0x04E6E4DB,0x00FFFFFF,0x4FECE9DD,0xF2B0B0B0,0xFCFFFFFF,0xFE000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF,0xFF000000,0xBBDDDDD5,0x05F9F8F1,0x05DBD9D0,0x00FFFFF9,0x00C7C5BE,0x00CBC9C1,0x00FFFFF7
    dd 0x05D2D0C6,0x00FFFFFB,0xACE0DDD3,0xFF000000,0xFBFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF
    dd 0xFD7F7F7F,0x6BEAE6DE,0x00FAF9F5,0x04ACABA5,0x00DBD8D0,0x00EBE8DF,0x00ECEADF,0x00CECCC4,0x03B3B1AC,0x01F9F9F4,0x53EBEADF,0xFF000000
    dd 0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xF9555555,0x1AF1EFE5,0x00F5F3E8,0x01EEEBE2
    dd 0x00CFCDC5,0x00C2C0B9,0x00BDBBB4,0x00D6D5CD,0x02F5F3E8,0x00EEEDE3,0x1FF5F3E9,0xF97F7F7F,0xFF000000,0xFE000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0xD7BFBFB8,0x0DFAF8F0,0x01DCDAD1,0x01E5E3DA,0x00FFFFFD,0x00BBB9B2,0x00C1BFB8,0x00FFFFFF
    dd 0x00D8D5CE,0x00DBD9D1,0x08FAF8EF,0xD5CECEC8,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000
    dd 0xD7CCCCC5,0x05F9F6ED,0x01E0DED6,0x01A6A5A0,0x00EEEBE3,0x00E7E4DB,0x00E7E4DB,0x00E6E4DC,0x01ABAAA4,0x00E4E2D9,0x08F8F5EB,0xE1C3C3BB
    dd 0xFF000000,0xFD7F7F7F,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFF7F7F,0xFF000000,0xDFC7BFBF,0x0BF7F3EA,0x01F0EEE5,0x01F4F2E8
    dd 0x00CECCC4,0x00BFBEB6,0x00BCBAB4,0x00D2D1C9,0x02FDFAEF,0x01F4F2E7,0x1EF5F3E8,0xEDC6C6B8,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFD7F7F7F,0x36F3F1E6,0x01EBE9E0,0x03DCDAD2,0x00FFFFFD,0x00BAB8B2,0x00C0BEB7,0x00FFFFFA
    dd 0x04C7C5BC,0x00F0EFE8,0x5FF2EFE5,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFCFFFFFF
    dd 0xFF000000,0x98EBE8DE,0x00F6F5EF,0x06A8A7A3,0x01D1D0C8,0x00DAD8CF,0x00D8D6CD,0x02CAC8C0,0x03B9B8B4,0x03EEEDE6,0xD2E2DDD7,0xFEFFFFFF
    dd 0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFDFFFFFF,0xFF000000,0x43EAE7DD,0x00FFFFFF
    dd 0x01E9E7DE,0x03AAA7A2,0x03ABAAA3,0x00F4F3EA,0x00FFFFFF,0x76E8E6D9,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFDFFFFFF,0xF2D7D7C4,0x6BEFEDE5,0x07FFFFFB,0x00DBD9D0,0x00DEDCD3,0x1AFFFFFA
    dd 0x9EE2DFD7,0xFF000000,0xFCFFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xD8E4E4DE,0x5BCBCAC2,0x65C6C5BE,0xECD6D6C9,0xFF000000,0xFDFFFFFF,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xF9FFFFFF
    dd 0xFF000000,0xAEE5E5DC,0xB1E8E4DE,0xFF000000,0xF9FFFFFF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFBBFBFBF,0xFDFFFFFF,0x91E3E3D9,0x95E4E2DA,0xFEFFFFFF
    dd 0xFBBFBFBF,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFEFFFFFF,0xFF000000,0xE5D7D7CD,0xE6D6D6D6,0xFF000000,0xFEFFFFFF,0xFF000000,0xFF000000,0xFF000000
    dd 0xFF000000,0xFF000000,0xFF000000,0xFF000000

; ---- end logos.inc


; ---- variables: kept apart from code (own pages) ----------------------------
times ((4096-((31744+$-$$)&4095))&4095) db 0
cur_fb    dq 0
cur_pitch dq 0
cur_surf  dd 0
cur_sptr  dq 0
g_uf      dq 0                      ; current proportional font
rr_mode db 0
scr_w     dd 1024
scr_h     dd 768
back_pitch dd 4096
rg_x0 dd 0
rg_y0 dd 0
rg_x1 dd 0
rg_y1 dd 0
dm_x0 dd 0
dm_y0 dd 0
dm_x1 dd 0
dm_y1 dd 0
dm_pend db 0
bs_ix0 dd 0
bs_iy0 dd 0
bs_ix1 dd 0
bs_iy1 dd 0
bs_sf  dq 0
zn     dd 0
zlist  times 16 db 0
mx     dd 512
my     dd 384
mx_old dd 512
my_old dd 384
tpl_ok db 0
bs_cnt dd 0
bs_sy dd 0
bs_fx0 dd 0
bs_fx1 dd 0
dith4 db 0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5
wg_top dd 0
wg_bot dd 0
wg_x   dd 0
wg_y   dd 0
wg_b   times 24*4 db 0
wg_wt  times 8 dd 0
wg_mw  dq 0
wg_mh  dq 0
wg_ty3 dd 0
ic_gl    dd 0
ic_sz    dd 0
ic_dst   dq 0
ic_style dd 0
f_half   dd 0.0
f_R      dd 0.0
f_hr     dd 0.0
f_S      dd 0.0
f_invS   dd 0.0
f_d      dd 0.0
f_cov    dd 0.0
f_t      dd 0.0
f_gs     dd 0.0
f_go     dd 0.0
f_sh     dd 0.0
f_ta     dd 1.0
f_mg     dd 0.0
f_ms     dd 0.0
f_tmp    dd 0.0
c_zero   dd 0.0
c_half   dd 0.5
c_one    dd 1.0
c_r225   dd 0.225
c_40     dd 40.0
c_64     dd 64.0
c_255    dd 255.0
c_inv255 dd 0.00392156862
c_gsz    dd 0.56
align 16
m_abs    dd 0x7FFFFFFF,0x7FFFFFFF,0x7FFFFFFF,0x7FFFFFFF
v_white  dd 255.0,255.0,255.0,0.0
v_black  dd 0.0,0.0,0.0,0.0
v_tint   dd 255.0,230.0,214.0,0.0        ; B,G,R : light blue-white
ic_top   dd 0.0,0.0,0.0,0.0
ic_bot   dd 0.0,0.0,0.0,0.0
ic_acc   dd 0.0,0.0,0.0,0.0
ic_col   dd 0.0,0.0,0.0,0.0
c_gl_sc  dd 0.96
c_gl_up  dd 0.0
c_gl_dy  dd 0.0
c_sh     dd 0.035
c_two    dd 2.0
c_a10    dd 0.06
c_a18    dd 0.30
c_a36    dd 0.36
c_a14    dd 0.14
c_a30    dd 0.30
c_a40    dd 0.38
c_a45    dd 0.42
c_a56    dd 0.55
c_a60    dd 0.62
c_m09    dd -0.9
c_m16    dd -1.7
c_m20    dd -2.0
c_t75    dd 0.75
align 16
v_dark   dd 40.0,34.0,30.0,0.0
v_255x   dd 255.0,255.0,255.0,255.0
task_cur dd 0
ntasks   dd 1
focus    dd 0
kq       times 64 db 0
kq_h     dd 0
kq_t     dd 0
k_shift  db 0
k_ctrl   db 0
k_alt    db 0
k_caps   db 0
k_e0     db 0
k_dead   db 0
lay_cur  db 0
lay_pend db 0
ms_i     db 0
ms_b0    db 0
ms_b1    db 0
m_btn    db 0
m_btn_old db 0
m_ev     dd 0
drag_s   dd -1
drag_gx  dd 0
drag_gy  dd 0launch_req dd 0
desk_click db 0
dk_x     dd 0
dk_y     dd 0
dk_w     dd 0
dk_h     dd 0
dk_x0    dd 0
dk_step  dd 1
dk_n     dd 0
dk_isz   dd 64
dk_y0    dd 0
top_click dd 0
pm_ev     db 0
pm_open   db 0
pm_kind   db 0
pm_cx     dd 0
pm_cy     dd 0
pm_n      dd 0
pm_hov    dd -1
pm_x      dd 0
pm_y      dd 0
pm_w      dd 0
pm_h      dd 0
pm_ent    times 16*16 db 0
dk_hov    dd -1
dk_hov_old dd -2
tb_lx1    dd 0
tb_ax0    dd 0
tb_ax1    dd 0
tb_wx0    dd 0
tb_wx1    dd 0
tb_kx0    dd 0
tb_kx1    dd 0
tb_cx0    dd 0
tb_cx1    dd 0
tb_min    dd -1
set_tab   dd 0
sh_tick   dd 0
last_mev  dd 0
dk_task_kind dd 1,2,3,4,5,6,7,1
clk_min  dd -1
dow_t    db 0,3,2,5,0,3,5,1,4,6,2,4
s_days   db "Sun",0,"Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0
s_months db "Jan",0,"Feb",0,"Mar",0,"Apr",0,"May",0,"Jun",0,"Jul",0,"Aug",0,"Sep",0,"Oct",0,"Nov",0,"Dec",0
s_am     db "AM",0
s_pm     db "PM",0
s_check db 0xD5,0
s_centtrix db "Centtrix",0
s_windows  db "Windows",0
s_lay_names db "EN",0,0,"RU",0,0,"ES",0,0
pm_rad dd 10
pm_tmp dd 0
s_m_about    db "About Centtrix",0
s_m_settings db "Settings",0
s_m_monitor  db "System Monitor",0
s_m_lock     db "Lock Screen",0
s_m_logout   db "Log Out",0
s_m_restart  db "Restart",0
s_m_shutdown db "Shut Down",0
s_m_min      db "Minimize",0
s_m_center   db "Center Window",0
s_m_close    db "Close Window",0
s_m_nextwp   db "Next Wallpaper",0
s_m_changelogo db "Next Logo",0
s_m_nowin    db "No open windows",0
pm_dyn times 16*10 db 0
want_lock  db 0
want_power db 0
dk_sx   dd 0
dk_sy   dd 0
dk_sw   dd 0
dk_sh   dd 0
dk_sig  dd 0
tb_focus dd 0
acc_tab dd 0x3584E4,0x9141AC,0xE0407A,0xE5483D,0xF08A24,0xD9A400,0x33A852,0x6B7280
dsz_tab dd 56,46,68
k_theme db "theme",0
k_accent db "accent",0
k_wall  db "wallpaper",0
k_logo  db "logo",0
k_icons db "icons",0
k_dock  db "dock",0
k_clock db "clock",0
k_bar   db "bar",0
k_lay2  db "layout2",0
n_theme  db "light",0,"dark",0,0
n_accent db "blue",0,"purple",0,"pink",0,"red",0,"orange",0,"yellow",0,"green",0,"graphite",0,0
n_wall   db "aurora",0,"dusk",0,"ocean",0,"graphite",0,"meadow",0,"blush",0,0
n_logo   db "rainbow",0,"mono",0,"green",0,0
n_icons  db "flat",0,"glass",0,"round",0,"outline",0,0
n_dock   db "medium",0,"small",0,"large",0,0
n_clock  db "24",0,"12",0,0
n_bar    db "glass",0,"solid",0,0
n_lay2   db "ru",0,"es",0,0
p_cfg    db "/home/settings.cfg",0
s_cfg_head db "# Centtrix settings. Edit and reboot, or change them in Settings.",10,0
s_dk_names db "Files",0,0,0,0,0,0,0
           db "Terminal",0,0,0,0
           db "Editor",0,0,0,0,0,0
           db "Browser",0,0,0,0,0
           db "Images",0,0,0,0,0,0
           db "Paint",0,0,0,0,0,0,0
           db "Settings",0,0,0,0
           db "Trash",0,0,0,0,0,0,0
s_br_t db "Browser",0
s_im_t db "Images",0
s_paint_t db "Paint",0
s_trash_t db "Trash",0
pm_hit_item dd 0
s_safe db "It is now safe to turn off the computer.",0
ds_sel  dd -1
ds_last dd -1
ds_lsec dd 0
ds_cnt  dd 0
ds_col dd 0
ds_ltr db 0,0
s_home_l db "Home",0
lk_flags times 16 dd 0
lk_focus dd 0
lk_dkw   dd 0
lk_bad   db 0
lg_sub dq 0
lg_len dd 0
pt_tool  dd 0
pt_col   dd 1
pt_dc    dd 1
pt_size  dd 1
pt_prev  db 0
pt_x0    dd 0
pt_y0    dd 0
pt_lx    dd 0
pt_ly    dd 0
pt_dx0   dd 0
pt_dy0   dd 0
pt_dx1   dd 0
pt_dy1   dd 0
pt_undo  db 0
pt_sizes db 0,1,2,4
pt_pal   dd 0xFFFFFF,0x000000,0x808080,0xC0C0C0,0xE53935,0xFB8C00,0xFDD835,0x43A047
         dd 0x00ACC1,0x1E88E5,0x3949AB,0x8E24AA,0xEC407A,0x6D4C41,0xC0CA33,0x81D4FA
pt_names db "Brush",0,"Eraser",0,"Line",0,"Rect",0,"Oval",0,"Fill",0
s_pt_undo db "Undo",0
s_pt_clr  db "Clear",0
s_pt_save db "Save as BMP",0
s_pt_info db "192 x 128 pixels, 16 colours.  Keys: u undo, c clear, s save",0
s_pt_ok1  db "Saved ",0
s_pt_ok2  db " (12406 bytes, 4-bit BMP)",0
s_pt_full db "Could not save: the disk has no free file slot",0
s_pt_pre  db "/home/paint",0
s_pt_ext  db ".bmp",0
hs_n     dd 0
st_tab   dd 0
st_prev  db 0
st_mon   dd -1
st_cur_surf dd 0
st_samples db 0,3,6
st_tab_icon db 6,14,4,16,10,9,11,8
s_th_l   db "Light",0
s_th_d   db "Dark",0
s_c24    db "24-hour",0
s_c12    db "12-hour",0
s_bar_g  db "Glass",0
s_bar_s  db "Solid",0
s_g_theme db "Theme",0
s_g_acc   db "Accent colour",0
s_g_clk   db "Clock",0
s_g_bar   db "Menu bar",0
s_g_cfg   db "Open settings.cfg",0
s_g_rst   db "Reset to defaults",0
s_g_note  db "Every setting is also stored as text in /home/settings.cfg",0
s_a_logo  db "System logo",0
s_a_icons db "Icon style",0
s_a_dock  db "Dock size",0
s_lg0 db "Rainbow",0
s_lg1 db "Monochrome",0
s_lg2 db "Green leaf",0
s_is0 db "Flat",0
s_is1 db "Glass",0
s_is2 db "Round",0
s_is3 db "Outline",0
s_ds0 db "Medium",0
s_ds1 db "Small",0
s_ds2 db "Large",0
wp_names db "Aurora",0,"Dusk",0,"Ocean",0,"Graphite",0,"Meadow",0,"Blush",0
res_tab dd 1024,768, 1280,720, 1280,800, 1366,768, 1440,900, 1600,900, 1920,1080
s_d_res  db "Resolution",0
s_d_n1   db "The chosen resolution is used",0
s_d_n1b  db "from the next start.",0
s_d_n2   db "If the graphics BIOS does not",0
s_d_n2b  db "offer it, 1024 x 768 is used.",0
s_d_now  db "Running now: ",0
s_d_rest db "Restart now",0
s_d_x    db " x ",0
s_k_l1  db "1   English (US)",0
s_k_l2  db "2   Second layout",0
s_k_ru  db "Russian",0
s_k_es  db "Spanish",0
s_k_n1  db "Shift + Alt switches between English and the second layout.",0
s_k_n2  db "The current layout is shown in the menu bar (EN / RU / ES).",0
s_k_n3  db "Spanish: n with tilde, inverted ? and !, accented vowels and u with diaeresis.",0
s_k_n4  db "Russian: full JCUKEN letters including the letters e with diaeresis.",0
s_m_mem   db "Memory",0
s_m_disk  db "Storage",0
s_m_up    db "Uptime",0
s_m_win   db "Running windows",0
s_m_tot   db "Total ",0
s_m_mb1   db " MB   reserved by Centtrix ",0
s_m_mb2   db " MB   free ",0
s_m_mb3   db " MB",0
s_m_f1    db "Files ",0
s_m_f2    db " of ",0
s_m_f3    db "    data ",0
s_m_f4    db " KB",0
s_m_none  db "No windows open",0
s_m_ram   db "No disk access here: files live in RAM and are lost on restart",0
s_m_net   db "Network",0
s_m_net0  db "Not started yet (it starts when the browser or ping needs it)",0
s_m_net1  db "No supported network card (Intel e1000 only)",0
s_m_neth  db "e1000, link up. ",0
s_m_nethd db "e1000, link DOWN. ",0
s_m_net2  db "no address yet",0
s_m_netg  db "  gateway ",0
s_m_netd  db "  dns ",0
s_u_name  db "User name",0
s_u_pw    db "Change password",0
s_u_lock  db "Lock screen",0
s_u_out   db "Log out (close all windows)",0
s_ab_ver  db "Version 3.5  -  64-bit",0
s_ab_1    db "Written in NASM assembler, one source file.",0
s_ab_2    db "x86-64 long mode, VBE linear framebuffer, PS/2 keyboard and mouse.",0
s_ab_3    db "Window manager with alpha-blended compositing and anti-aliased text.",0
s_ab_4    db "File system: 32 files of up to 16 KB on an ATA disk.",0
s_ab_5    db "Scripting language XPL (.xep), text editor, browser for local pages.",0
s_ab_6    db "Layouts: English, Russian, Spanish.",0
s_ab_7    db "Network: Intel e1000; http and https (server not verified).",0
net_tls  db 0                       ; 1 when the url is https://
e1k_ids  dw 0x1000, 0x1001, 0x1004, 0x1008, 0x1009, 0x100C, 0x100D, 0x100E, 0x100F
         dw 0x1010, 0x1011, 0x1012, 0x1013, 0x1014, 0x1015, 0x1016, 0x1017, 0x1018
         dw 0x1019, 0x101A, 0x101D, 0x101E, 0x1026, 0x1027, 0x1028, 0x1075, 0x1076
         dw 0x1077, 0x1078, 0x1079, 0x107A, 0x107B, 0x107C, 0x108A, 0x1099, 0x10B5
         dw 0x10D3, 0
bcast_mac db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
my_mac   db 0, 0, 0, 0, 0, 0, 0, 0
my_ip    dd 0
net_mask dd 0
net_gw   dd 0
net_dns  dd 0
e_io     dw 0
         dw 0
e_mmio   dq 0
e_status dd 0
net_ok   db 0
net_tried db 0
net_busy db 0
arp_rr   db 0
arp_tab  times 48 db 0
rx_idx   dd 0
tx_idx   dd 0
ip_id    dw 0
ip_tmp   dd 0
tmA      dd 0, 0
tmB      dd 0, 0
tmC      dd 0, 0
tmD      dd 0, 0
ps_hdr   times 12 db 0
dh_xid   dd 0
dh_yi    dd 0
dh_srv   dd 0
dh_mask  dd 0
dh_rt    dd 0
dh_dns   dd 0
dh_reqip dd 0
dh_reqsrv dd 0
dhcp_got dd 0
dns_got  dd 0
dns_res  dd 0
dns_idw  dw 0
dns_lpw  dw 0x5ACD                  ; source port 53722 in wire order
ping_seq dw 0
ping_wire dw 0
ping_got dd 0
ping_from dd 0
tc_state db 0
tc_fin   db 0
tc_rst   db 0
tc_trunc db 0
tc_ackd  db 0
tc_needack db 0
tc_lport dw 0
tc_rport dw 0
tc_rip   dd 0
tc_isn   dd 0
tc_snd_nxt dd 0
tc_snd_una dd 0
tc_rcv_nxt dd 0
tc_rlen  dd 0
tc_rmax  dd 0
tc_rbuf  dq 0
net_url  times 512 db 0
url_tmp  times 640 db 0
net_host times 128 db 0
net_path times 520 db 0
net_port dw 80
http_status dd 0
http_err dd 0
http_ip  dd 0
http_redirs dd 0
http_retx dd 0
req_len  dd 0
last_rlen dd 0
http_chunked db 0
http_class db 1
http_loc times 512 db 0
s_hget   db "GET ", 0
s_hhost  db " HTTP/1.0", 13, 10, "Host: ", 0
s_htail  db 13, 10, "User-Agent: Centtrix/3.5", 13, 10, "Accept: text/html, text/plain;q=0.9, */*;q=0.1", 13, 10, "Connection: close", 13, 10, 13, 10, 0
s_http   db "http:", 0
s_https  db "https:", 0
s_nethtm db "net.htm", 0
s_nettxt db "net.txt", 0
s_binary db "<h2>Not shown</h2><p>This address returned something that is not text or a web page (an image or a file). Centtrix can only show text and HTML.</p>", 0
h_ct     db "content-type:", 0
h_te     db "transfer-encoding:", 0
h_loc    db "location:", 0
w_html   db "html", 0
w_text   db "text/", 0
w_json   db "json", 0
w_xml    db "xml", 0
w_chunked db "chunked", 0
em_unknown db "Something went wrong.", 0
em_nonic db "No supported network card was found. Centtrix has a driver for Intel e1000 cards only (the default card of QEMU, VirtualBox and VMware).", 0
em_dhcp  db "The network gave no address (DHCP did not answer).", 0
em_dns   db "The name could not be looked up (DNS did not answer or the name does not exist).", 0
em_conn  db "Could not connect to the server (no answer, or the connection was refused).", 0
em_resp  db "The server answered with something that is not a web page.", 0
em_url   db "That address is not valid.", 0
em_redir db "Too many redirects.", 0
em_link  db "The network cable seems to be unplugged (no link).", 0
s_if_eth db "eth0  mac ", 0
s_if_up  db "  link up", 0
s_if_down db "  link DOWN", 0
s_if_ip  db "      ip ", 0
s_if_mask db "  mask ", 0
s_if_gw  db "      gateway ", 0
s_if_dns db "  dns ", 0
s_ping_use db "usage: ping host", 10, 0
s_ping_ok db "reply from ", 0
s_ping_no db "no reply", 0
s_ns_use db "usage: nslookup name", 10, 0
s_arrow  db "  ->  ", 0
aes_sr db 0,5,10,15,4,9,14,3,8,13,2,7,12,1,6,11
fe_a24    dq 121665, 0, 0, 0
fe_one    dq 1, 0, 0, 0
lbl_ms    db "master secret"
lbl_ke    db "key expansion"
lbl_cf    db "client finished"
lbl_sf    db "server finished"
x_base    db 9, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
em_tls    db "Secure connection (https) failed: ", 0
em_alert  db " (alert ", 0
tr_unknown db "unknown error", 0
tr_1 db "the server's hello was not understood", 0
tr_2 db "the server needs a cipher or curve Centtrix does not have (it speaks TLS 1.2 with X25519 and AES-128-GCM only)", 0
tr_3 db "the server's Finished message did not match", 0
tr_4 db "the server sent an alert", 0
tr_5 db "a record failed its integrity check", 0
tr_6 db "the server did not answer or closed the connection during the handshake", 0
tr_7 db "the key exchange failed", 0
tr_8 db "a TLS record was malformed or too large", 0
tr_9 db "handshake messages arrived in the wrong order", 0
tr_tab dq tr_1, tr_2, tr_3, tr_4, tr_5, tr_6, tr_7, tr_8, tr_9
br_slot  dq 0
br_tg    dq 0
br_rp    dq 0
br_end   dq 0
br_stat  dq 0
br_hn    dd 0
br_top   dd 0
br_sel   dd -1
br_nlk   dd 0
br_rows  dd 1
br_row   dd 0
br_col   dd 0
br_tl    dd 0
br_elen  dd 0
br_att   db 0
br_pend  db 0
br_pre   db 0
br_ttl   db 0
br_plain db 0
br_editing db 0
br_title times 64 db 0
br_loc   times 512 db 0
br_edit  times 512 db 0
br_msg   times 600 db 0
n_cmt    db "-->", 0
n_script db "</script", 0
n_style  db "</style", 0
n_noscript db "</noscript", 0
n_svg    db "</svg", 0
n_tpl    db "</template", 0
n_href   db "href", 0
n_alt    db "alt", 0
s_http_s db "http://", 0
s_br_loading db "Loading ", 0
s_br_http db "HTTP ", 0
s_br_trunc db "  (page was too big, cut off)", 0
s_br_go  db "Go to: ", 0
s_br_unsup db "This kind of link cannot be opened", 0
s_br_hint db "g: address   Tab: next link   Enter: open   Backspace: back   r: reload   Esc: close", 0
s_ep1    db "<h1>Cannot open this page</h1><p>", 0
s_ep2    db "</p><p>Address: ", 0
s_ep3    db "</p>", 0
s_nf1    db "<h1>Page not found</h1><p>", 0
lat1_tab db "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty"
cyr_tab  dd 'A', 'B', 'V', 'G', 'D', 'E', 'Zh', 'Z', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P'
         dd 'R', 'S', 'T', 'U', 'F', 'Kh', 'Ts', 'Ch', 'Sh', 'Shch', 0, 'Y', 0, 'E', 'Yu', 'Ya'
         dd 'a', 'b', 'v', 'g', 'd', 'e', 'zh', 'z', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p'
         dd 'r', 's', 't', 'u', 'f', 'kh', 'ts', 'ch', 'sh', 'shch', 0, 'y', 0, 'e', 'yu', 'ya'
misc_tab dw 0x2013, ms_dash-misc_str, 0x2014, ms_dd-misc_str, 0x2018, ms_sq-misc_str, 0x2019, ms_sq-misc_str
         dw 0x201C, ms_dq-misc_str, 0x201D, ms_dq-misc_str, 0x2022, ms_star-misc_str, 0x2026, ms_ell-misc_str
         dw 0xA9, ms_c-misc_str, 0xAE, ms_r-misc_str, 0xAB, ms_la-misc_str, 0xBB, ms_ra-misc_str
         dw 0xB7, ms_dot-misc_str, 0x2192, ms_rarr-misc_str, 0x2190, ms_larr-misc_str, 0x20AC, ms_eur-misc_str
         dw 0x2122, ms_tm-misc_str, 0xB0, ms_deg-misc_str, 0xB1, ms_pm-misc_str, 0xBD, ms_half-misc_str
         dw 0xD7, ms_x-misc_str, 0xA3, ms_gbp-misc_str, 0
ent_tab  db "lt", 0, "<", 0
         db "gt", 0, ">", 0
         db "amp", 0, "&", 0
         db "quot", 0, 34, 0
         db "apos", 0, "'", 0
         db "nbsp", 0, " ", 0
         db "copy", 0, "(c)", 0
         db "reg", 0, "(R)", 0
         db "mdash", 0, "--", 0
         db "ndash", 0, "-", 0
         db "hellip", 0, "...", 0
         db "laquo", 0, "<<", 0
         db "raquo", 0, ">>", 0
         db "middot", 0, ".", 0
         db "bull", 0, "*", 0
         db "rarr", 0, "->", 0
         db "larr", 0, "<-", 0
         db "times", 0, "x", 0
         db "trade", 0, "(TM)", 0
         db "euro", 0, "EUR", 0
         db "pound", 0, "GBP", 0
         db "deg", 0, "deg", 0
         db "plusmn", 0, "+-", 0
         db "frac12", 0, "1/2", 0
         db "lsquo", 0, "'", 0
         db "rsquo", 0, "'", 0
         db "ldquo", 0, 34, 0
         db "rdquo", 0, 34, 0
         db "aacute", 0, "a", 0
         db "eacute", 0, "e", 0
         db "iacute", 0, "i", 0
         db "oacute", 0, "o", 0
         db "uacute", 0, "u", 0
         db "agrave", 0, "a", 0
         db "egrave", 0, "e", 0
         db "ntilde", 0, "n", 0
         db "uuml", 0, "u", 0
         db "ouml", 0, "o", 0
         db "auml", 0, "a", 0
         db "ccedil", 0, "c", 0
         db "szlig", 0, "ss", 0
         db "Eacute", 0, "E", 0
         db "Uuml", 0, "U", 0
         db "Ouml", 0, "O", 0
         db "Auml", 0, "A", 0
         db 0
mo_last  dd 0
im_sel   dd 0
im_n     dd 0
vw_dw    dd 0
vw_dh    dd 0
vw_ox    dd 0
vw_oy    dd 0
p_www_idx db "/base/www/index.htm",0
p_www     db "/base/www/",0
p_sbmp    db "/home/sample.bmp",0
p_w_xpl   db "/base/www/xpl.htm",0
p_w_keys  db "/base/www/keys.htm",0
p_w_net   db "/base/www/net.htm",0
s_dothtm  db ".htm",0
s_bnofile  db "Page not found",0
s_untitled db "page",0
s_mon_t   db "Monitor",0
s_brw_t   db "Browser",0
s_img_t   db "Images",0
s_noimg   db "No .bmp files",0
s_badimg  db "Unsupported image (BMP 8/24/32 bit only)",0
s_mo_mem  db "Memory",0
s_mo_tot  db "total ",0
s_mo_used db " MB    used ",0
s_mo_free db " KB    free ",0
s_mo_mb   db " MB",0
s_mo_disk db "Disk",0
s_mo_files db "files ",0
s_mo_of   db " of ",0
s_mo_data db "    data ",0
s_mo_kb   db " KB",0
s_mo_up   db "Uptime",0
s_mo_win  db "Windows  1",0
th_acc    dd 0x3584E4
th_win    dd 0xFFFFFF
th_hdr    dd 0xEBEBEB
th_brd    dd 0xCCCCCC
th_txt    dd 0x2E3436
th_stat   dd 0xF6F5F4
th_dim    dd 0x77767B
th_card   dd 0xFFFFFF
pr_mask   db 0
sudo_on   db 0
lg_bad    db 0
calc_err  db 0
ed_mode   db 0
ed_pend   db 0
t_fs      db 0
lf_len    dd 0
sp_i      dd 0
rng       dd 12345
ata_ok    db 1
st_files  dd 0
st_bytes  dd 0
boot_tod  dd 0
set_sel   dd 0
t_cx      dd 0
t_cw      dd 0
t_ox      dd 0
t_oy      dd 0
t_fgc     dd 0
t_bgc     dd 0
lc_title  dq 0
iconcol   dd 0x3584E4, 0x3D3846, 0xE5A50A, 0x77767B, 0x9141AC
iconlet   db "F>ESi"
sitems    dq s_set0, s_set1, s_set2
g_fg      dd 0x2E3436
g_bg      dd 0xFFFFFF
g_tr      db 0
g_scale   dd 1
clk_sec   db 0xFF
home_sel  dd 0
home_pg   dd 0
hs_y      dd 0
hs_name   dq 0
scut_n    dd 0
sc_letter db 0
scpal     dd 0x3584E4,0xE5A50A,0x26A269,0x9141AC,0xE66100,0x2AA1B3,0xC64600,0x613583
f_dir     dd 3
f_sel     dd 0
f_cnt     dd 0
ed_slot   dq 0
ed_len    dd 0
ed_pos    dd 0
ed_top    dd 0
ed_mod    db 0
ed_warn   db 0
ed_cline  dd 0
ed_ccol   dd 0
xp_col    dd 0
xp_row    dd 0
xvars     times 26 dd 0
lp_sp     dd 0
lp_cnt    times 4 dd 0
lp_ptr    times 4 dq 0
t_row     dd 0
t_col     dd 0
t_cwd     dd 2
cd_len    dd 6
curdir    db "/home/",0
          times 56 db 0
tpath     db "/home/",0
          times 56 db 0
t_inlen   dd 0
t_pstart  dd 0
t_init    db 0
t_quit    db 0
t_scr     db 0
dirpfx:  db "/base/",0,0
         db "/dump/",0,0
         db "/home/",0,0
dirnm:   db "base",0,0,0,0
         db "dump",0,0,0,0
         db "home",0,0,0,0
s_activities db "Activities",0
s_topright   db "Centtrix  x64",0
s_title      db "Centtrix",0
s_sub        db "A tiny 64-bit operating system written in assembler",0
s_hint       db "Left / Right: choose     Enter: open     1-4: quick open",0
s_termico    db ">_ centtrix",0
s_files_t    db "Files",0
s_term_t     db "Terminal",0
s_ed_t       db "Editor",0
s_about_t    db "About Centtrix",0
s_xpl_t      db "XPL program",0
s_f_root     db "Folders",0
s_empty      db "(empty)",0
s_bytes      db " bytes",0
s_fhint0     db "Enter: open folder     Esc: home",0
s_fhint1     db "Enter: edit   r: run .xep   u: restore to /home   Del: delete forever   Backspace: up",0
s_fhint2     db "Enter: edit   r: run .xep   n: new file   Del: move to /dump   Backspace: up",0
s_pname      db "Name: ",0
s_openf     db "Open or create a file (name, Enter)",0
s_homef     db "Files in /home",0
s_warn       db "Unsaved changes!  Esc again = discard,  Ctrl+S = save",0
s_mod        db "  [modified]",0
s_ln         db "     Ln ",0
s_col        db ", Col ",0
s_keys       db "     Ctrl+S save   Ctrl+R run .xep   Esc close",0
s_running    db "running",0
s_xdone      db "done",0
s_xabort     db "stopped",0
s_xstop      db "error",0
s_xerr       db "error: unknown or bad command",0
s_term_hint  db 0
s_banner     db "Centtrix 3.5",10,10,0
s_ok         db "ok",10,0
s_nofile     db "no such file",10,0
s_notxep     db "only .xep files can be run",10,0
s_bad        db "invalid name / path, or no free space",10,0
s_unk        db "unknown command - try 'help'",10,0
s_rootls     db "base/",10,"dump/",10,"home/",10,0
s_ver        db "Centtrix OS 3.5  x86_64  |  XPL 1.0",10,0
s_help       db "files   ls [dir]  cd dir  cat f  edit f  new f  run f.xep  rm f  cp a b  mv a b  mkdir d  empty",10
             db "system  date  uptime  mem  ps  kill PID  whoami  sudo [-k]  sleep n  calc expr  reboot  shutdown",10
             db "screen  clear  cls  desktop (close this terminal)",10
             db "network ifconfig  ping host  nslookup name  dhcp",10
             db "fun     cowsay text   cmatrix (any key stops)   echo text",10
             db "folders: base (sudo only)  dump  home      'sudo' then 'ls 0' shows the hidden root",10,0
s_about_hint db 0
s_ab1        db "Version 3.1 - 64-bit long mode kernel, written in NASM assembler.",0
s_ab2        db "Display : VBE linear framebuffer 1024x768x32, BIOS 8x16 font",0
s_ab3        db "Disk    : ATA PIO, CNTX filesystem with /base, /dump and /home",0
s_ab4        db "Editor  : built-in text editor (.txt and .xep), Ctrl+S saves",0
s_ab5        db "Language: XPL - scripts are .xep files, run with Ctrl+R or 'run'",0
s_ab6        db "XPL: say print let add sub mul at color clear box wait repeat/next end",0
s_ab7        db "Colors 0-15 | variables a-z | # starts a comment",0
s_nil      db 0
p_desk     db "/home/desktop.cfg",0
s_rootp    db "/",0
s_pass     db "Password: ",0
s_newpw    db "New password: ",0
s_welcome  db "Create your account",0
s_l_user   db "Username",0
s_l_pass   db "Password",0
s_l_rep    db "Repeat password",0
s_wrong    db "Wrong password",0
s_set_t    db "Settings",0
s_set0     db "Theme",0
s_set1     db "Change password",0
s_set2     db "Log out",0
s_light    db "Light",0
s_dark     db "Dark",0
s_user_l   db "User     ",0
s_ram      db "Memory   ",0
s_unknown  db "unknown",0
s_mb_sys   db " MB total,  system ",0
s_kb_free2 db " KB,  free ",0
s_mb_free  db " MB",0
s_files_l  db "Files    ",0
s_files_n  db " files, ",0
s_normal   db "NORMAL   ",0
s_insert   db "INSERT   ",0
s_e37      db "E37: No write since last change (add ! to override)",0
s_sp4      db "    ",0
s_colon    db ":",0
s_up       db "up ",0
s_h        db "h ",0
s_m        db "m ",0
s_s        db "s",10,0
s_mem_t    db "memory  total ",0
s_mem_u    db " MB   system ",0
s_mem_f    db " KB   free ",0
s_mem_e    db " MB",10,0
s_bye      db "shutting down...",10,0
s_halt     db "power off is not supported here - system halted",10,0
s_ps       db "PID  NAME",10,0
s_2sp      db "    ",0
s_shellnm  db "desktop",0
s_kusage   db "usage: kill PID  (see ps)",10,0
s_kdeny    db "cannot kill the desktop or this terminal (use exit)",10,0
s_kbad     db "no such process",10,0
s_denied   db "permission denied (use sudo)",10,0
s_sorry    db "sorry, wrong password",10,0
s_pwp      db "[sudo] password: ",0
s_cerr     db "error",10,0
s_moo      db "Moo",0
s_cow      db "        \   ^__^",10,"         \  (oo)\_______",10,"            (__)\       )\/\",10,"                ||----w |",10,"                ||     ||",10,0
v_w        db "w",0
v_q        db "q",0
v_wq       db "wq",0
v_x        db "x",0
v_qb       db "q!",0
v_r        db "r",0
v_k        db "-k",0
c_calc     db "calc",0
c_cowsay   db "cowsay",0
c_cls      db "cls",0
c_date     db "date",0
c_uptime   db "uptime",0
c_mem      db "mem",0
c_sleep    db "sleep",0
c_shutdown db "shutdown",0
c_cmatrix  db "cmatrix",0
c_q        db "q",0
c_desktop  db "desktop",0
c_ps       db "ps",0
c_kill     db "kill",0
c_ifconfig db "ifconfig",0
c_ping     db "ping",0
c_nslookup db "nslookup",0
c_dhcp     db "dhcp",0
c_whoami   db "whoami",0
c_sudo     db "sudo",0
k_say    db "say",0
k_print  db "print",0
k_let    db "let",0
k_add    db "add",0
k_sub    db "sub",0
k_mul    db "mul",0
k_at     db "at",0
k_color  db "color",0
k_clear  db "clear",0
k_box    db "box",0
k_wait   db "wait",0
k_repeat db "repeat",0
k_next   db "next",0
k_end    db "end",0
c_help   db "help",0
c_ls     db "ls",0
c_cd     db "cd",0
c_cat    db "cat",0
c_edit   db "edit",0
c_run    db "run",0
c_new    db "new",0
c_rm     db "rm",0
c_cp     db "cp",0
c_mkdir  db "mkdir",0
s_homep  db "/home/",0
s_notempty db "folder is not empty",10,0
c_mv     db "mv",0
c_empty  db "empty",0
c_clear  db "clear",0
c_ver    db "ver",0
c_reboot db "reboot",0
c_exit   db "exit",0
c_echo   db "echo",0
p_readme  db "/base/readme.txt",0
p_sys     db "/base/system.txt",0
p_rainbow db "/base/rainbow.xep",0
p_hello   db "/home/hello.xep",0
p_notes   db "/home/notes.txt",0
d_readme  db "Welcome to Centtrix!",10,10
          db "base - system files (sudo)   dump - deleted files   home - your files",10,10
          db "Files are .txt (text) or .xep (XPL programs).",10
          db "Editor is vim-like: i insert, Esc normal, :w save, :q quit, :r run .xep",10,0
d_sys     db "Centtrix OS 3.5",10,"64-bit long mode, VBE 32bpp",10,"CNTX filesystem, XPL 1.0",10,0
d_rainbow db "# rainbow bars",10
          db "clear",10
          db "let c 0",10
          db "let y 1",10
          db "repeat 15",10
          db "  color c",10
          db "  box 5 y 60 1",10
          db "  add c 1",10
          db "  add y 2",10
          db "next",10
          db "color 0",10
          db "at 5 33",10
          db 'say "XPL rainbow"',10,0
d_hello   db "# Centtrix XPL demo",10
          db "color 4",10
          db 'say "Hello from XPL!"',10
          db "color 0",10
          db "let a 1",10
          db "repeat 5",10
          db "  print a",10
          db "  add a 1",10
          db "next",10
          db "color 2",10
          db "at 10 12",10
          db 'say "Done."',10
          db "box 10 14 30 2",10,0
d_notes   db "My first Centtrix note.",10,"Edit me!",10,0
dead_acute:  db "aeiouAEIOU",0
dead_acute_r: db 194,195,196,197,198,201,202,203,204,205
dead_diaer:  db "uU",0
dead_diaer_r: db 199,206
times ((4096-((31744+$-$$)&4095))&4095) db 0

times (KSECT+1)*512-($-$$) db 0
times (FS_LBA+1+MAXF*32+8)*512-($-$$) db 0