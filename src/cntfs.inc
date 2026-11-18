; =============================================================================
;  CNT3 FILESYSTEM  -  dynamic, FAT-style: "as many files as the disk holds"
; =============================================================================
;  Disk layout:
;    FS_LBA              superblock (CNT2 settings +0..+0x7F, CNT3 header +0x80..)
;    FS_LBA+1 .. +512    FAT: u32 next-cluster per cluster (65536 entries max)
;    FS_LBA+513 ..       cluster pool: cluster i -> sector FS_LBA+513+i*32
;  A cluster is 32 sectors = 16 KB.  The first cluster of a file stores the old
;  slot header (path tail / size / id, 64 bytes) and 16320 data bytes; later
;  clusters are raw data.  A file is a FAT chain, so a file can be as large as
;  the free space allows.  Directories are entries of a directory table that is
;  itself a chain of clusters; every entry is 96 bytes:
;    +0 id (u32, 0 = free)  +4 kind (0 file, 1 dir)  +5 flags  +8 parent id
;    +12 start cluster      +16 size                 +20 name (zstr, <= 75)
;  RAM: the whole directory table lives in DIRTAB; file data is cached in
;  CACHE_N slots of 16 KB (FSBUF, the old slot layout: path@0 size@48
;  cluster@52 id@56 flags@60 tick@62 data@64) with dirty/pinned flags and LRU
;  eviction.  The slot is byte-compatible with the old CNTX slot, so callers
;  keep working: [slot+48] is the size and [slot+64] the first 16320 bytes.
;  /dump is the trash, /base holds the system files, /home is the user area.
; =============================================================================

CL_SEC     equ 32                   ; sectors per cluster
CL_BYTES   equ 16384
FATSEC     equ 512                  ; FAT area, sectors (65536 u32 entries)
CLPOOL     equ FS_LBA+1+FATSEC      ; first sector of the cluster pool
NCLMAX     equ 65536
CL_EOF     equ 0xFFFFFFFF
DIR_E      equ 96                   ; directory entry size
DIRC_E     equ 170                  ; entries that fit in one dir cluster
DIRTAB     equ 0x6800000            ; directory table in RAM (4 MB)
DIRTAB_MAX equ 0x400000
DIRC_CLMAX equ DIRTAB_MAX/CL_BYTES  ; dir clusters tracked in RAM (256)
FATBUF     equ 0x6700000            ; FAT in RAM (256 KB)
VBMP       equ 0x6C00000            ; 3 MB buffer for the image viewer
CACHE_N    equ 64
NAME_MAX   equ 75                   ; longest file / folder name
PATH_MAX   equ 120                  ; longest absolute path
STUBS      equ 0x4E90000            ; Files app listing stubs, STUB_MAX*128
STUB_MAX   equ 256
FSB2       equ 0x4EA4200            ; 512 B staging for unaligned chain reads
FSBNC      equ 0x4EA8000            ; 16 KB bounce for chain writes (RAM, not image)

DE_ID    equ 0                      ; directory entry offsets
DE_KIND  equ 4
DE_FLG   equ 5
DE_PAR   equ 8
DE_START equ 12
DE_SIZE  equ 16
DE_NAME  equ 20

DE_FILE  equ 0
DE_DIR   equ 1

FL_DIRTY  equ 1
FL_PIN    equ 2
FL_VALID  equ 4
FL_KIND   equ 8                     ; the slot is a folder

SB3_MAGIC equ SBBUF+0x80
SB3_NCL   equ SBBUF+0x84
SB3_FREE  equ SBBUF+0x88
SB3_DH    equ SBBUF+0x8C
SB3_DT    equ SBBUF+0x90
SB3_DL    equ SBBUF+0x94
SB3_HINT  equ SBBUF+0x98
SB3_NID   equ SBBUF+0x9C
SIG2      equ 0x32544E43           ; 'CNT2'
SIG3      equ 0x46334E43           ; 'CN3F'

; ---------------------------------------------------------------- state ------
fs_res     dq 0                     ; scratch for register returns after PUSHA
fs_namep   dq 0
fs_pid     dd 0                     ; create: parent id
fs_pnm     dq 0                     ; create: name pointer
fs_pent    dq 0                     ; create: new DIRTAB entry
fs_sc1     dq 0                     ; general scratch
fs_sc2     dq 0
fs_tgt     dd 0                     ; drive the FS layer talks to (bootdrv normally)
fs_fresh   dd 0                     ; set by fs3_format -> seed default files
fs_mvbuf   times 128 db 0           ; trash-path scratch for fs3_del_slot
fs_tick    dd 0                     ; LRU clock
fs_dlen    dd 0                     ; capacity of the dir table in RAM (bytes)
fs_dptr    dq 0                     ; scratch: entry picked by fs3_dnew
fs_ncl     dd 0                     ; dir clusters in RAM
fs_dumpid  dd 0                     ; id of /dump
fs_rdepth  dd 0                     ; recursion guard for tree deletes
fs_nfiles  dd 0                     ; fs3_count results
fs_ndirs   dd 0
fs_nbytes  dq 0
fs_dirmap  times DIRC_CLMAX dd 0    ; dir cluster -> ordinal map
fs_ps      times 64 dq 0            ; path building stack (entry pointers)
fs_wa      times 96 db 0            ; walk scratch: one component
fs_wb      times 144 db 0           ; split scratch: whole path
s_dumpnm   db "dump",0
s_dump_pfx db "/dump/",0
s_catbig   db 10,"(large file: first 16320 bytes shown)",10,0
fs3_rootnm db "base",0,"dump",0,"home",0

; ================================================================ helpers ====

; fs3_ent: eax = entry id -> rax = pointer in DIRTAB or 0 (clobbers rcx, rdx)
fs3_ent:
    cmp eax, 2
    jb .no
    mov rdx, DIRTAB
    mov ecx, [fs_dlen]
.l: cmp ecx, DIR_E
    jb .no
    cmp [rdx+DE_ID], eax
    je .y
    add rdx, DIR_E
    sub ecx, DIR_E
    jmp .l
.no: xor eax, eax
    ret
.y: mov rax, rdx                     ; rax = entry pointer (was returning the id)
    ret

fs3_sb_write:                        ; write the superblock sector
    push rax
    mov eax, FS_LBA
    mov rsi, SBBUF
    call ata_write1
    pop rax
    ret

fs3_cl2sec:                          ; eax = cluster -> eax = first sector of it
    imul eax, eax, CL_SEC
    add eax, CLPOOL
    ret

fs3_wr:                              ; eax = LBA, rsi = source (keeps both)
    push rsi
    call ata_write1
    pop rsi
    ret

; fs3_wr_n: eax = LBA, ecx = sectors, rsi = source -> CF=1 on failure
;   ATA when the ports reach the disk, BIOS otherwise.
fs3_wr_n:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r11
    mov ebx, eax
    mov r11d, ecx
    cmp byte [ata_ok], 0
    je .bios
.l: test r11d, r11d
    jz .ok
    mov eax, ebx
    call ata_write1
    inc ebx
    dec r11d
    jmp .l
.bios:
    mov eax, ebx
    movzx edx, byte [fs_tgt]
    mov ecx, r11d
    call bios_wr
    jc .bad
.ok:
    pop r11
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.bad:
    pop r11
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; fs3_rd_n: eax = LBA, ecx = sectors, rdi = destination -> CF=1 on failure
fs3_rd_n:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r11
    mov ebx, eax
    mov r11d, ecx
    cmp byte [ata_ok], 0
    je .bios
.l: test r11d, r11d
    jz .ok
    mov eax, ebx
    call ata_read1
    inc ebx
    dec r11d
    jmp .l
.bios:
    mov eax, ebx
    movzx edx, byte [fs_tgt]
    mov ecx, r11d
    call bios_rd
    jc .bad
.ok:
    pop r11
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.bad:
    pop r11
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; fs3_rd: eax = LBA, rdi = dst (advances rdi by 512 on success) -> CF=1 failed
fs3_rd:
    push rax
    push rcx
    push rdx
    cmp byte [ata_ok], 0
    je .bios
    call ata_read1
    cmp byte [ata_ok], 0
    je .f
    clc
    jmp .o
.bios:
    cmp byte [SB_BIOS], 0
    je .f
    movzx edx, byte [fs_tgt]
    mov ecx, 1
    call bios_rd
    jc .o                            ; CF=1 -> failed, rdi untouched
    lea rdi, [rdi+512]               ; success: advance like the ATA path
    jmp .o
.f: stc
.o: pop rdx
    pop rcx
    pop rax
    ret

; fs3_wr_fat: write back the FAT sector that holds entry ebx (keeps ebx)
fs3_wr_fat:
    push rax
    push rsi
    mov eax, ebx
    shr eax, 7                       ; 128 entries per sector
    mov rsi, FATBUF
    shl eax, 9
    add rsi, rax
    shr eax, 9
    add eax, FS_LBA+1
    call fs3_wr
    pop rsi
    pop rax
    ret

; fs3_alloc1: -> ebx = new cluster (FAT[i] = EOF, written) or CF=1
;             cluster 0 stays reserved: FAT[0] = EOF forever
fs3_alloc1:
    push rax
    push rcx
    mov eax, [SB3_NCL]
    test eax, eax
    jz .nf
    mov ecx, eax
    mov ebx, [SB3_HINT]
    cmp ebx, eax
    jb .hok
    mov ebx, 1
.hok:
.l: cmp dword [FATBUF+rbx*4], 0
    je .got
    inc ebx
    cmp ebx, eax
    jb .l
    mov ebx, 1
.l2: cmp dword [FATBUF+rbx*4], 0
    je .got
    inc ebx
    cmp ebx, ecx
    jb .l2
.nf: stc
    jmp .o
.got:
    mov dword [FATBUF+rbx*4], CL_EOF
    push rbx
    call fs3_wr_fat
    pop rbx
    dec dword [SB3_FREE]
    lea eax, [rbx+1]
    cmp eax, ecx
    jbe .h1
    mov eax, 1
.h1: mov [SB3_HINT], eax
    call fs3_sb_write
    clc
.o: pop rcx
    pop rax
    ret

; fs3_chain_free: ebx = first cluster -> frees the whole chain (updates FREE)
fs3_chain_free:
    push rax
    push rcx
    push rbx
    push rdx
    xor eax, eax
.l: cmp ebx, CL_EOF
    je .d
    test ebx, ebx
    jz .d
    cmp ebx, [SB3_NCL]
    jae .d
    cmp eax, [SB3_NCL]               ; cycle guard
    jae .d
    mov ecx, ebx                     ; current
    mov r10d, [FATBUF+rcx*4]         ; next
    mov dword [FATBUF+rcx*4], 0
    mov ebx, ecx
    call fs3_wr_fat
    inc eax
    mov ebx, r10d
    jmp .l
.d: add [SB3_FREE], eax
    call fs3_sb_write
    pop rdx
    pop rbx
    pop rcx
    pop rax
    ret

; fs3_zero_cl: eax = cluster -> zero its 32 sectors on disk
fs3_zero_cl:
    PUSHA
    mov r15d, eax
    lea rdi, [FSBNC]
    xor eax, eax
    mov ecx, 2048
    rep stosq
    mov eax, r15d
    call fs3_cl2sec
    mov ecx, CL_SEC
    lea rsi, [FSBNC]
    call fs3_wr_n
    POPA
    ret

; fs3_dir_blk: rax = byte offset in DIRTAB -> writes back its 512 B block
fs3_dir_blk:
    PUSHA
    mov r10d, eax
    mov ecx, r10d
    shr ecx, 14                      ; dir cluster ordinal
    cmp ecx, [fs_ncl]
    jae .o
    mov eax, [fs_dirmap+rcx*4]
    call fs3_cl2sec
    mov r11d, eax
    mov eax, r10d
    shr eax, 9
    and eax, 0x1F                    ; 512 B block inside the cluster
    add r11d, eax
    mov eax, r10d
    and eax, 0xFFFFFE00              ; block start in DIRTAB
    lea rsi, [DIRTAB+rax]
    mov eax, r11d
    call fs3_wr
.o: POPA
    ret

; fs3_dir_grow: append one empty dir cluster to the chain (CF=1 on failure)
fs3_dir_grow:
    PUSHA
    cmp dword [fs_ncl], DIRC_CLMAX
    jae .full
    call fs3_alloc1
    jc .o
    mov r12d, ebx                    ; new cluster
    mov eax, r12d
    call fs3_zero_cl
    mov eax, [SB3_DT]
    test eax, eax
    jz .first
    mov [FATBUF+rax*4], r12d
    mov ebx, eax
    call fs3_wr_fat
    jmp .tail
.first:
    mov [SB3_DH], r12d
.tail:
    mov [SB3_DT], r12d
    mov ecx, [fs_ncl]
    mov [fs_dirmap+rcx*4], r12d
    inc dword [fs_ncl]
    call fs3_sb_write
    clc
    jmp .o
.full:
    stc
.o: POPA
    ret

; fs3_dirmap_build: rebuild fs_dirmap / fs_ncl / fs_dlen from SB3_DH via FATBUF
fs3_dirmap_build:
    PUSHA
    mov eax, [SB3_DH]
    xor ecx, ecx
.l: test eax, eax
    jz .d
    cmp eax, CL_EOF
    je .d
    cmp eax, [SB3_NCL]
    jae .d
    cmp ecx, DIRC_CLMAX
    jae .d
    mov [fs_dirmap+rcx*4], eax
    inc ecx
    mov eax, [FATBUF+rax*4]
    jmp .l
.d: mov [fs_ncl], ecx
    imul ecx, ecx, CL_BYTES
    mov [fs_dlen], ecx
    POPA
    ret

; fs3_dnew: -> rdi = free zeroed entry in DIRTAB (holes are reused) or 0
;   fs_dlen is the *capacity* of the table (ncl * CL_BYTES), so the whole
;   range is scanned for a free entry before the table is grown.
fs3_dnew:
    PUSHA
    mov ecx, [fs_dlen]
    mov rdx, DIRTAB
.sc: cmp ecx, DIR_E
    jb .grow
    cmp dword [rdx+DE_ID], 0
    je .zero
    add rdx, DIR_E
    sub ecx, DIR_E
    jmp .sc
.grow:
    call fs3_dir_grow
    jc .no
    mov eax, [fs_dlen]               ; the append point = old capacity
    cmp eax, DIRTAB_MAX-DIR_E
    ja .no
    lea rdx, [DIRTAB+rax]
    add dword [fs_dlen], CL_BYTES
.zero:
    mov [fs_dptr], rdx
    xor eax, eax
    mov rdi, rdx
    mov ecx, DIR_E/8
.z: mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .z
    POPA
    mov rdi, [fs_dptr]
    ret
.no:
    mov qword [fs_dptr], 0
    POPA
    mov rdi, [fs_dptr]
    ret

fs3_sanity:                          ; CF=1 when the superblock looks broken
    push rax
    mov eax, [SB3_NCL]
    test eax, eax
    jz .b
    cmp eax, NCLMAX
    ja .b
    cmp dword [SB3_DH], 0            ; the dir chain must exist
    je .b
    clc
    pop rax
    ret
.b: stc
    pop rax
    ret

fs3_freescan:                        ; recount SB3_FREE from the FAT, fix HINT
    push rax
    push rcx
    mov eax, 1
    mov ecx, 1                       ; cluster 0 is reserved
.l: cmp ecx, [SB3_NCL]
    jae .d
    cmp dword [FATBUF+rcx*4], 0
    jne .n
    inc eax
.n: inc ecx
    jmp .l
.d: dec eax                         ; cluster 0 does not count
    mov [SB3_FREE], eax
    mov ecx, [SB3_HINT]
    cmp ecx, [SB3_NCL]
    jb .h
    mov ecx, 1
    mov [SB3_HINT], ecx
.h: pop rcx
    pop rax
    ret

fs3_cache_zero:                      ; invalidate all cache slots
    push rax
    push rcx
    push rdi
    mov dword [fs_tick], 0
    mov rdi, FSBUF
    xor eax, eax
    mov ecx, CACHE_N
.l: mov [rdi+0], rax
    mov [rdi+8], rax
    mov [rdi+16], rax
    mov [rdi+24], rax
    mov [rdi+32], rax
    mov [rdi+40], rax
    mov [rdi+48], rax
    mov [rdi+56], rax
    add rdi, SLOT
    dec ecx
    jnz .l
    pop rdi
    pop rcx
    pop rax
    ret

; fs3_nametail: rsi = name -> rsi = pointer to its last <= 47 characters
fs3_nametail:
    push rcx
    push rdx
    mov rdx, rsi
    call strlen
    cmp eax, 47
    jbe .o
    sub eax, 47
    add rdx, rax
.o: mov rsi, rdx
    pop rdx
    pop rcx
    ret
; ================================================================ paths ======

; fs3_pathok: rsi = path -> ZF=1 if the path shape is acceptable
;   absolute, <= 119 chars, components 1..75 chars, no "." / "..", printable
fs3_pathok:
    PUSHA
    mov r13, rsi
    cmp byte [r13], '/'
    jne .bad
    mov rsi, r13
    call strlen
    cmp eax, PATH_MAX-1
    ja .bad
    mov r14, r13
.cl: inc r14
    cmp byte [r14], 0
    je .ok
    mov r15, r14
.cl2:
    movzx eax, byte [r15]
    test al, al
    jz .cend
    cmp al, '/'
    je .cend
    cmp al, 0x20
    jb .bad
    cmp al, 0x7F
    je .bad
    inc r15
    jmp .cl2
.cend:
    mov rax, r15
    sub rax, r14
    test rax, rax
    jz .bad                          ; empty component ("//")
    cmp rax, NAME_MAX
    ja .bad
    cmp rax, 1
    jne .c3
    cmp byte [r14], '.'
    je .bad
.c3: cmp rax, 2
    jne .c4
    cmp word [r14], 0x2E2E
    je .bad
.c4:
    cmp byte [r15], 0
    je .ok
    mov r14, r15                     ; points at '/'
    jmp .cl
.ok:
    POPA
    xor eax, eax                     ; ZF=1
    ret
.bad:
    POPA
    or eax, 1                        ; ZF=0
    ret

; fs3_child: eax = dir id, rsi = name -> rdi = entry ptr or 0
;   (clobbers rcx, rdx, rsi; keeps eax)
fs3_child:
    push rbx
    mov ebx, eax                     ; strcmp clobbers AL -> the id lives in EBX
    mov rdx, DIRTAB
    mov ecx, [fs_dlen]
.l: cmp ecx, DIR_E
    jb .no
    cmp dword [rdx+DE_ID], 0
    je .nx
    cmp [rdx+DE_PAR], ebx
    jne .nx
    lea rdi, [rdx+DE_NAME]
    call strcmp
    je .y
.nx: add rdx, DIR_E
    sub ecx, DIR_E
    jmp .l
.y: mov rdi, rdx
    mov eax, ebx
    pop rbx
    ret
.no: xor edi, edi
    mov eax, ebx
    pop rbx
    ret

; fs3_walk: rsi = absolute path -> eax = entry id, ZF unused
;   CF=1 when a component is missing or a file has children.  Keeps all regs
;   except eax and flags.  Trailing '/' allowed for directories.
fs3_walk:
    PUSHA
    mov r15d, 1                      ; current id = root
    cmp byte [rsi], '/'
    jne .bad
    mov r13, rsi
.l: inc r13
    cmp byte [r13], 0
    je .done
    mov r14, r13                     ; component start
.e: mov al, [r14]
    test al, al
    jz .end
    cmp al, '/'
    je .end
    inc r14
    jmp .e
.end:
    mov rax, r14
    sub rax, r13
    cmp rax, NAME_MAX
    ja .bad
    lea rdi, [fs_wa]
    mov rcx, rax
    mov rsi, r13
    push rsi
    rep movsb
    pop rsi
    mov byte [rdi], 0
    mov eax, r15d
    lea rsi, [fs_wa]
    call fs3_child
    test rdi, rdi
    jz .bad
    mov r15d, [rdi+DE_ID]
    cmp byte [rdi+DE_KIND], DE_DIR
    je .more
    ; a file must be the last component
    cmp byte [r14], 0
    jne .bad
    jmp .done
.more:
    mov r13, r14                     ; at '/' or at the NUL
    cmp byte [r13], 0
    je .done                         ; the string ends here
    jmp .l
.done:
    mov [fs_res], r15d               ; POPA would restore the old EAX
    POPA
    mov rax, [fs_res]
    clc
    ret
.bad:
    POPA
    stc
    ret

; fs3_split: rsi = absolute path -> eax = parent dir id, rsi = name pointer
;   (inside fs_wb).  Strips a trailing '/'.  CF=1 when bad.
fs3_split:
    PUSHA
    lea rdi, [fs_wb]
    call strcpy
    lea rsi, [fs_wb]
    call strlen
    test eax, eax
    jz .bad
    cmp byte [fs_wb+rax-1], '/'
    jne .nos
    dec eax
    mov byte [fs_wb+rax], 0
    test eax, eax
    jz .bad
.nos:
    ; find the last '/'
    mov r14d, eax                    ; length
.fs: dec r14d
    js .bad
    cmp byte [fs_wb+r14], '/'
    jne .fs
    cmp byte [fs_wb+r14+1], 0
    je .bad                          ; empty name
    mov byte [fs_wb+r14], 0          ; terminate the parent part
    lea rsi, [fs_wb+r14+1]
    call strlen
    cmp eax, NAME_MAX
    ja .bad
    ; walk the parent
    test r14d, r14d
    jne .w
    mov eax, 1                       ; parent is the root
    jmp .out
.w: lea rsi, [fs_wb]
    call fs3_walk
    jc .bad
.out:
    lea rsi, [fs_wb+r14+1]
    mov [fs_res], rax
    mov [fs_namep], rsi
    POPA
    mov rax, [fs_res]
    mov rsi, [fs_namep]
    clc
    ret
.bad:
    POPA
    stc
    ret

fs3_parenok:                         ; rsi -> ZF=1 if the parent folder exists
    PUSHA
    call fs3_split
    jc .bad
    POPA
    xor eax, eax
    ret
.bad:
    POPA
    or eax, 1
    ret

fs3_haskids:                         ; eax = dir id -> eax = 1/0 (clobbers rcx,rdx)
    push rdx
    push rcx
    mov rdx, DIRTAB
    mov ecx, [fs_dlen]
.l: cmp ecx, DIR_E
    jb .n
    cmp dword [rdx+DE_ID], 0
    je .nx
    cmp [rdx+DE_PAR], eax
    je .y
.nx: add rdx, DIR_E
    sub ecx, DIR_E
    jmp .l
.y: mov eax, 1
    pop rcx
    pop rdx
    ret
.n: xor eax, eax
    pop rcx
    pop rdx
    ret

fs3_firstkid:                        ; eax = dir id -> eax = child id or 0
    push rdx
    push rcx
    mov rdx, DIRTAB
    mov ecx, [fs_dlen]
.l: cmp ecx, DIR_E
    jb .n
    cmp dword [rdx+DE_ID], 0
    je .nx
    cmp [rdx+DE_PAR], eax
    je .y
.nx: add rdx, DIR_E
    sub ecx, DIR_E
    jmp .l
.y: mov eax, [rdx+DE_ID]
    pop rcx
    pop rdx
    ret
.n: xor eax, eax
    pop rcx
    pop rdx
    ret

fs3_indump:                          ; eax = id -> eax = 1 when inside /dump
    push r8
    push rbx
    mov ebx, [fs_dumpid]
    test ebx, ebx
    jz .n
    mov r8d, eax
.l: cmp r8d, ebx
    je .y
    test r8d, r8d
    jz .n
    mov eax, r8d
    call fs3_ent
    test rax, rax
    jz .n
    mov r8d, [rax+DE_PAR]
    jmp .l
.y: mov eax, 1
    pop rbx
    pop r8
    ret
.n: xor eax, eax
    pop rbx
    pop r8
    ret

fs3_isancestor:                      ; eax = node, ebx = candidate -> eax = 1/0
    push r8
    push rbx
.l: cmp eax, ebx
    je .y
    test eax, eax
    jz .n
    push rax
    call fs3_ent
    mov r8, rax
    pop rax
    test r8, r8
    jz .n
    mov eax, [r8+DE_PAR]
    jmp .l
.y: mov eax, 1
    pop rbx
    pop r8
    ret
.n: xor eax, eax
    pop rbx
    pop r8
    ret

; fs3_pathof: eax = id, rdi = buffer (>= 128) -> full path, CF=1 if unknown
fs3_pathof:
    PUSHA
    mov r15, rdi
    xor ecx, ecx
    mov r14d, eax
.up: test r14d, r14d
    jz .rev
    cmp ecx, 64
    jae .bad
    mov eax, r14d
    call fs3_ent
    test rax, rax
    jz .bad
    mov [fs_ps+rcx*8], rax
    inc ecx
    mov r14d, [rax+DE_PAR]
    jmp .up
.rev:
    test ecx, ecx
    jz .bad
    mov rdi, r15
    mov byte [rdi], 0
    mov r13d, ecx
.dn: dec r13d
    js .fin
    mov rax, [fs_ps+r13*8]
    cmp dword [rax+DE_PAR], 0
    jne .nm
    mov byte [rdi], '/'
    inc rdi
    mov byte [rdi], 0
    jmp .dn
.nm:
    lea rsi, [rax+DE_NAME]
    call sappend
    cmp byte [rax+DE_KIND], DE_DIR
    jne .dn
    mov byte [rdi], '/'
    inc rdi
    mov byte [rdi], 0
    jmp .dn
.fin:
    POPA
    clc
    ret
.bad:
    POPA
    stc
    ret

; ================================================================ cache ======

fs3_cfind:                           ; eax = entry id -> rax = slot or 0
    push rcx
    push rdx
    mov rdx, FSBUF
    mov ecx, CACHE_N
.l: cmp [rdx+56], eax
    jne .n
    test word [rdx+60], FL_VALID
    jz .n
    jmp .y
.n: add rdx, SLOT
    dec ecx
    jnz .l
    xor eax, eax
    pop rdx
    pop rcx
    ret
.y: mov rax, rdx
    pop rdx
    pop rcx
    ret

fs3_evict:                           ; -> rax = usable slot or 0
    push rcx
    push rdx
    push r8
    push r9
    mov rdx, FSBUF
    mov ecx, CACHE_N
.l1: cmp word [rdx+60], 0
    je .found
    add rdx, SLOT
    dec ecx
    jnz .l1
    xor r8d, r8d                     ; best tick so far
    xor r9d, r9d                     ; best slot
    mov rdx, FSBUF
    mov ecx, CACHE_N
.l2: test word [rdx+60], FL_DIRTY | FL_PIN
    jnz .n2
    test word [rdx+60], FL_VALID
    jz .n2
    movzx eax, word [rdx+62]
    test r8d, r8d
    jz .best
    cmp eax, r8d
    jae .n2
.best:
    mov r8d, eax
    mov r9, rdx
.n2: add rdx, SLOT
    dec ecx
    jnz .l2
    test r9, r9
    jz .no
    jmp .y
.found:
    mov r9, rdx
.y: mov rax, r9                     ; return the slot pointer (was returning garbage)
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret
.no: xor eax, eax
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret
; fs3_calloc: eax = entry id -> rax = loaded slot or 0
fs3_calloc:
    PUSHA
    call fs3_ent
    test rax, rax
    jz .no
    mov r14, rax                     ; entry
    call fs3_evict
    test rax, rax
    jz .no
    mov r15, rax                     ; slot
    ; load the first cluster for files first: it covers the whole slot image,
    ; the fresh header is written on top afterwards
    cmp byte [r14+DE_KIND], DE_DIR
    je .hdr
    mov eax, [r14+DE_START]
    test eax, eax
    jz .zdata
    call fs3_cl2sec
    mov ecx, CL_SEC
    mov rdi, r15
    call fs3_rd_n
    jnc .hdr
.zdata:
    lea rdi, [r15+64]
    xor eax, eax
    mov ecx, 16320/8
.z: mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .z
.hdr:
    lea rsi, [r14+DE_NAME]
    call fs3_nametail
    mov rdi, r15
    call strcpy
    mov eax, [r14+DE_SIZE]
    mov [r15+48], eax
    mov eax, [r14+DE_START]
    mov [r15+52], eax
    mov eax, [r14+DE_ID]
    mov [r15+56], eax
    and word [r15+60], 0
    cmp byte [r14+DE_KIND], DE_DIR
    jne .k1
    or word [r15+60], FL_KIND
.k1:
    or word [r15+60], FL_VALID
    inc dword [fs_tick]
    movzx eax, word [fs_tick]
    mov [r15+62], ax
    mov rax, r15
    jmp .out
.no:
    xor eax, eax
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

fs3_cdrop:                           ; eax = entry id: drop its cache slot
    push rcx
    push rdx
    mov rdx, FSBUF
    mov ecx, CACHE_N
.l: cmp [rdx+56], eax
    jne .n
    mov word [rdx+60], 0
.n: add rdx, SLOT
    dec ecx
    jnz .l
    pop rdx
    pop rcx
    ret

fs3_pin:                             ; rax = slot (keeps rax)
    test rax, rax
    jz .o
    or word [rax+60], FL_PIN
.o: ret

fs3_unpin:                           ; rax = slot (keeps rax)
    test rax, rax
    jz .o
    and word [rax+60], 0xFFFD
.o: ret

fs3_flush_all:                       ; write every dirty slot back to disk
    PUSHA
    mov rdx, FSBUF
    mov ecx, CACHE_N
.l: test word [rdx+60], FL_VALID
    jz .n
    test word [rdx+60], FL_DIRTY
    jz .n
    mov rax, rdx
    call fs3_save
.n: add rdx, SLOT
    dec ecx
    jnz .l
    call fs3_sb_write
    POPA
    ret

; ================================================================ API ========

fs3_find:                            ; rsi = path -> rax = slot or 0 (keeps rsi/rdi)
    PUSHA
    call fs3_walk
    jc .no
    call fs3_cfind
    test rax, rax
    jnz .out
    call fs3_calloc
    jmp .out
.no: xor eax, eax
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

fs3_save:                            ; rax = slot (keeps rax, rsi, rdi)
    PUSHA
    mov r13, rax
    test r13, r13
    jz .o
    movzx eax, word [r13+60]
    test ax, FL_VALID
    jz .o
    test ax, FL_KIND
    jz .file
    and word [r13+60], 0xFFFE        ; folders carry no data
    jmp .o
.file:
    mov eax, [r13+52]
    test eax, eax
    jz .o
    ; sync the directory entry size
    mov eax, [r13+56]
    call fs3_ent
    test rax, rax
    jz .noc
    mov r14, rax
    mov edx, [r13+48]
    cmp [r14+DE_SIZE], edx
    je .noc
    mov [r14+DE_SIZE], edx
    mov rax, r14
    sub rax, DIRTAB
    call fs3_dir_blk
.noc:
    mov eax, [r13+52]
    call fs3_cl2sec
    mov ecx, CL_SEC
    mov rsi, r13
    call fs3_wr_n
    and word [r13+60], 0xFFFE
.o: POPA
    ret

fs3_create:                          ; rsi = path -> rax = slot (existing or new) or 0
    PUSHA
    call fs3_pathok
    jne .fail
    call fs3_find
    test rax, rax
    jnz .out
    ; a trailing slash asks for a folder
    call strlen
    cmp byte [rsi+rax-1], '/'
    jne .file
    call fs3_mk
    jmp .out
.file:
    call fs3_split
    jc .fail
    mov [fs_pid], eax                ; parent id
    mov [fs_pnm], rsi                ; name
    mov eax, [fs_pid]
    call fs3_child
    test rdi, rdi
    jnz .fail                        ; the name is taken in this folder
    inc dword [SB3_NID]
    mov eax, [SB3_NID]
    call fs3_dnew
    test rdi, rdi
    jz .fail
    mov [fs_pent], rdi               ; new entry
    mov [rdi+DE_ID], eax
    mov byte [rdi+DE_KIND], DE_FILE
    mov byte [rdi+DE_FLG], 0
    mov eax, [fs_pid]
    mov [rdi+DE_PAR], eax
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov rsi, [fs_pnm]
    call fs3_nametail
    mov rdi, [fs_pent]
    add rdi, DE_NAME
    call strcpy
    mov r14, [fs_pent]
    call fs3_alloc1
    jc .free_e
    mov [r14+DE_START], ebx
    mov eax, ebx
    call fs3_zero_cl
    mov rax, [fs_pent]
    sub rax, DIRTAB
    call fs3_dir_blk
    mov r14, [fs_pent]
    mov eax, [r14+DE_ID]
    call fs3_calloc
    jmp .out
.free_e:
    mov r14, [fs_pent]
    mov dword [r14+DE_ID], 0
    mov rax, r14
    sub rax, DIRTAB
    call fs3_dir_blk
.fail:
    xor eax, eax
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

fs3_mk:                              ; rsi = path (trailing / optional) -> rax = slot or 0
    PUSHA
    call fs3_pathok
    jne .fail
    call fs3_find
    test rax, rax
    jnz .out
    call fs3_split
    jc .fail
    mov [fs_pid], eax                ; parent id
    mov [fs_pnm], rsi                ; name
    mov eax, [fs_pid]
    call fs3_child
    test rdi, rdi
    jnz .fail
    inc dword [SB3_NID]
    mov eax, [SB3_NID]
    call fs3_dnew
    test rdi, rdi
    jz .fail
    mov [fs_pent], rdi
    mov [rdi+DE_ID], eax
    mov byte [rdi+DE_KIND], DE_DIR
    mov byte [rdi+DE_FLG], 0
    mov eax, [fs_pid]
    mov [rdi+DE_PAR], eax
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov rsi, [fs_pnm]
    call fs3_nametail
    mov rdi, [fs_pent]
    add rdi, DE_NAME
    call strcpy
    mov rax, [fs_pent]
    sub rax, DIRTAB
    call fs3_dir_blk
    mov r14, [fs_pent]
    mov eax, [r14+DE_ID]
    call fs3_calloc
    jmp .out
.fail:
    xor eax, eax
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

fs3_move:                            ; rax = slot, rsi = new path -> rax = new slot or 0
    PUSHA
    mov r15, rax
    test r15, r15
    jz .fail
    mov [fs_sc2], rsi                ; target path
    mov eax, [r15+56]                ; source entry id
    test eax, eax
    jz .fail
    cmp eax, 4
    jbe .fail                        ; base/dump/home stay put
    mov [fs_sc1], eax
    ; flush the source data first: the slot may be evicted below
    call fs3_cfind
    test rax, rax
    jz .nf
    test word [rax+60], FL_DIRTY
    jz .nf
    call fs3_save
.nf:
    ; does the target exist? then it dies first
    mov rsi, [fs_sc2]
    call fs3_find
    test rax, rax
    jz .nt
    mov r14, rax                     ; target slot
    mov eax, [fs_sc1]                ; source id
    mov ebx, [r14+56]
    call fs3_isancestor
    test eax, eax
    jnz .fail                        ; moving into the own subtree
    mov eax, [r14+56]
    call fs3_del_id
    jc .fail
.nt:
    mov eax, [fs_sc1]
    call fs3_ent
    test rax, rax
    jz .fail
    mov r14, rax                     ; source entry
    mov rsi, [fs_sc2]
    call fs3_split
    jc .fail
    mov r12d, eax                    ; new parent id
    mov r13, rsi                     ; new name
    mov eax, r12d
    mov rsi, r13
    call fs3_child
    test rdi, rdi
    jz .ok
    cmp rdi, r14
    jne .fail                        ; another entry owns that name
.ok:
    lea rdi, [r14+DE_NAME]
    mov rsi, r13
    call strcpy
    mov [r14+DE_PAR], r12d
    mov rax, r14
    sub rax, DIRTAB
    call fs3_dir_blk
    ; refresh the cache slot: drop the stale one, load the fresh one
    mov eax, [r14+DE_ID]
    call fs3_cdrop
    mov eax, [r14+DE_ID]
    call fs3_calloc
    jmp .out
.fail:
    xor eax, eax
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

fs3_collect:                         ; fill ITEMS + f_cnt with curdir stubs (in STUBS)
    PUSHA
    mov dword [f_cnt], 0
    mov rsi, curdir
    call fs3_walk
    jc .out
    mov r12d, eax                    ; dir id
    mov r15, STUBS
    mov r13, DIRTAB
    mov r14d, [fs_dlen]
.cl: cmp r14d, DIR_E
    jb .out
    cmp dword [r13+DE_ID], 0
    je .n
    cmp [r13+DE_PAR], r12d
    jne .n
    cmp dword [f_cnt], 255
    jae .n
    mov rax, r15
    sub rax, STUBS
    cmp rax, STUB_MAX*128
    jae .n
    ; stub = curdir + name (+ '/' for a folder)
    mov rdi, r15
    lea rsi, [curdir]
    mov ecx, [cd_len]
    rep movsb
    lea rsi, [r13+DE_NAME]
.nm: lodsb
    stosb
    test al, al
    jnz .nm
    cmp byte [r13+DE_KIND], DE_DIR
    jne .reg
    mov byte [rdi-1], '/'
    mov byte [rdi], 0
    inc rdi
.reg:
    mov eax, [f_cnt]
    mov [ITEMS+rax*8], r15
    inc dword [f_cnt]
    add r15, 128
.n: add r13, DIR_E
    sub r14d, DIR_E
    jmp .cl
.out:
    POPA
    ret

fs3_folder_empty:                    ; rax = folder slot -> ZF=1 if no children
    push rbx
    mov ebx, eax
    mov eax, [rbx+56]
    call fs3_haskids
    test eax, eax                    ; ZF=1 when eax = 0 = empty
    pop rbx
    ret

; ================================================================ delete =====

; fs3_del_id: eax = entry id -> CF=1 if refused.  Files: free the chain.
;             Folders: only when empty (fs3_del_tree recurses first).
fs3_del_id:
    PUSHA
    mov r15d, eax
    test r15d, r15d
    jz .fail
    cmp r15d, 4
    jbe .fail                        ; root/base/dump/home are permanent
    call fs3_ent
    test rax, rax
    jz .fail
    mov r14, rax
    cmp byte [r14+DE_KIND], DE_DIR
    jne .file
    mov eax, r15d
    call fs3_haskids
    test eax, eax
    jnz .fail
    jmp .kill
.file:
    mov eax, [r14+DE_START]
    test eax, eax
    jz .kill
    mov ebx, eax
    call fs3_chain_free
.kill:
    mov eax, r15d
    call fs3_cdrop
    mov dword [r14+DE_ID], 0
    mov rax, r14
    sub rax, DIRTAB
    call fs3_dir_blk
    POPA
    clc
    ret
.fail:
    POPA
    stc
    ret

; fs3_del_slot: rax = slot -> CF=1 refused.  Inside /dump: really delete.
;               Otherwise: move the entry to /dump/<name> (the trash).
fs3_del_slot:
    PUSHA
    mov r15, rax
    test r15, r15
    jz .fail
    mov eax, [r15+56]
    call fs3_ent
    test rax, rax
    jz .fail
    mov r14, rax
    mov eax, [r14+DE_ID]
    call fs3_indump
    test eax, eax
    jz .move
    mov eax, [r14+DE_ID]
    call fs3_del_id
    jmp .out
.move:
    ; build /dump/<name> in fs_mvbuf (never in fs_wa: fs3_walk scribbles there)
    lea rdi, [fs_mvbuf]
    mov byte [rdi], 0
    lea rsi, [s_dump_pfx]
    call sappend
    lea rsi, [r14+DE_NAME]
    call sappend
    ; flush unsaved data: the slot gets reloaded by fs3_move
    mov eax, [r14+DE_ID]
    call fs3_cfind
    test rax, rax
    jz .mv
    test word [rax+60], FL_DIRTY
    jz .mv
    call fs3_save
.mv:
    mov rax, r15
    lea rsi, [fs_mvbuf]
    call fs3_move
    jmp .out
.fail:
    xor eax, eax
.out:
    POPA
    clc
    ret

; fs3_del_tree: eax = id -> delete recursively (CF=1 when something refused)
fs3_del_tree:
    PUSHA
    inc dword [fs_rdepth]
    cmp dword [fs_rdepth], 32
    ja .fail
    mov r15d, eax
    ; children first, so folders become empty for fs3_del_id
    mov r13, DIRTAB
    mov r14d, [fs_dlen]
.cl: cmp r14d, DIR_E
    jb .dn
    cmp dword [r13+DE_ID], 0
    je .n
    cmp [r13+DE_PAR], r15d
    jne .n
    mov eax, [r13+DE_ID]
    call fs3_del_tree
    jc .fail
.n: add r13, DIR_E
    sub r14d, DIR_E
    jmp .cl
.dn:
    mov eax, r15d
    call fs3_del_id
    dec dword [fs_rdepth]
    POPA
    ret
.fail:
    dec dword [fs_rdepth]
    POPA
    stc
    ret

; fs3_empty_trash: delete every child of /dump -> CF=1 when stuck
fs3_empty_trash:
    PUSHA
    mov r15d, [fs_dumpid]
    test r15d, r15d
    jz .fail
    mov r12d, [fs_dlen]
    shr r12d, 2                      ; pass budget: entries/4 + margin
    add r12d, 16
.cl: mov eax, r15d
    call fs3_firstkid
    test eax, eax
    jz .ok
    mov r14d, eax
    mov eax, r14d
    call fs3_ent
    test rax, rax
    jz .fail
    cmp byte [rax+DE_KIND], DE_DIR
    jne .f
    mov eax, r14d
    call fs3_del_tree
    jc .fail
    jmp .next
.f: mov eax, r14d
    call fs3_del_id
    jc .fail
.next:
    dec r12d
    jz .fail
    jmp .cl
.ok:
    POPA
    clc
    ret
.fail:
    POPA
    stc
    ret

; ================================================================ big files ==

; fs3_read_chain: ebx = first cluster, rdi = dst, ecx = max bytes
;                 -> rax = bytes read.  Walks the FAT: chains are not
;                 necessarily contiguous on disk.
fs3_read_chain:
    PUSHA
    mov r15, rdi                     ; dst cursor
    mov r14d, ecx                    ; bytes left
    xor r12d, r12d                   ; bytes copied
    xor ebp, ebp                     ; loop guard
.l: inc ebp
    cmp ebp, [SB3_NCL]
    ja .d
    test r14d, r14d
    jz .d
    cmp ebx, CL_EOF
    je .d
    test ebx, ebx
    jz .d
    cmp ebx, [SB3_NCL]
    jae .d
    mov ecx, r14d
    cmp ecx, CL_BYTES
    ja .tail
    ; a whole cluster straight into the destination
    mov eax, ebx
    call fs3_cl2sec
    mov ecx, CL_SEC
    mov rdi, r15
    call fs3_rd_n
    jc .d
    add r15, CL_BYTES
    sub r14d, CL_BYTES
    add r12d, CL_BYTES
    jmp .next
.tail:
    ; the last chunk: bounce, then copy only what is left
    mov eax, ebx
    call fs3_cl2sec
    mov ecx, CL_SEC
    lea rdi, [FSBNC]
    call fs3_rd_n
    jc .d
    lea rsi, [FSBNC]
    mov rdi, r15
    mov ecx, r14d
    rep movsb
    mov eax, r14d
    add r15, rax
    add r12d, r14d
    xor r14d, r14d
.next:
    mov ebx, [FATBUF+rbx*4]
    jmp .l
.d:
    mov [fs_res], r12
    POPA
    mov rax, [fs_res]
    ret

; fs3_chaincopy: rax = source slot, rsi = destination path -> rax = new slot or 0
;   Copies the slot data area plus every chain cluster through the FAT.
fs3_chaincopy:
    PUSHA
    mov r15, rax                     ; source slot
    test r15, r15
    jz .fail
    mov [fs_sc2], rsi                ; destination path
    mov rax, r15
    call fs3_pin
    mov eax, [r15+56]
    call fs3_ent
    test rax, rax
    jz .upin
    mov r14, rax                     ; source entry
    ; an existing destination dies first
    mov rsi, [fs_sc2]
    call fs3_find
    test rax, rax
    jz .new
    cmp rax, r15
    je .upin                        ; copying onto itself
    mov r13, rax
    mov eax, [r13+56]
    call fs3_del_id
    jc .upin
.new:
    mov rsi, [fs_sc2]
    call fs3_create
    test rax, rax
    jz .upin
    mov r13, rax                     ; destination slot
    mov eax, [r14+DE_SIZE]
    mov [r13+48], eax
    cmp eax, MAXSZ
    ja .big
    ; small: copy the data area, mark dirty, save
    lea rsi, [r15+64]
    lea rdi, [r13+64]
    mov ecx, [r13+48]
    rep movsb
    or word [r13+60], FL_DIRTY
    mov rax, r13
    call fs3_save
    xor r10d, r10d
    jmp .fin
.big:
    ; the first 16320 bytes travel through the slots
    lea rsi, [r15+64]
    lea rdi, [r13+64]
    mov ecx, MAXSZ
    rep movsb
    or word [r13+60], FL_DIRTY
    mov rax, r13
    call fs3_save
    mov eax, [r13+56]
    call fs3_ent
    test rax, rax
    jz .fail
    mov r9, rax                      ; destination entry
    mov r12d, [r15+52]               ; source first cluster
    test r12d, r12d
    jz .fail
    mov r12d, [FATBUF+r12*4]         ; source cluster 1
    xor r11d, r11d                   ; previous destination cluster
    mov eax, [r14+DE_SIZE]
    sub eax, MAXSZ
    mov r10d, eax                    ; bytes left
    xor ebp, ebp
.l2: inc ebp
    cmp ebp, [SB3_NCL]
    ja .fin
    test r10d, r10d
    jz .fin
    cmp r12d, CL_EOF
    je .fin
    test r12d, r12d
    jz .fin
    cmp r12d, [SB3_NCL]
    jae .fin
    call fs3_alloc1
    jc .fin                          ; keep whatever was copied
    mov r8d, ebx                     ; new destination cluster
    test r11d, r11d
    jnz .lnk
    mov [r9+DE_START], r8d
    jmp .lk2
.lnk:
    mov [FATBUF+r11*4], r8d
    mov ebx, r11d
    call fs3_wr_fat
.lk2:
    mov r11d, r8d
    mov r8d, r10d
    cmp r8d, CL_BYTES
    jbe .cp
    mov r8d, CL_BYTES
.cp:
    ; source cluster -> FSBNC -> destination cluster
    mov eax, r12d
    call fs3_cl2sec
    mov ecx, CL_SEC
    lea rdi, [FSBNC]
    call fs3_rd_n
    jc .fin
    mov eax, r11d
    call fs3_cl2sec
    mov ecx, CL_SEC
    lea rsi, [FSBNC]
    call fs3_wr_n
    jc .fin
    sub r10d, r8d
    mov r12d, [FATBUF+r12*4]
    jmp .l2
.fin:
    ; sync the destination size (short when a disk error stopped us)
    mov eax, [r14+DE_SIZE]
    sub eax, r10d
    mov [r13+48], eax
    mov eax, [r13+56]
    call fs3_ent
    test rax, rax
    jz .give
    mov r9, rax
    mov eax, [r13+48]
    mov [r9+DE_SIZE], eax
    mov rax, r9
    sub rax, DIRTAB
    call fs3_dir_blk
    mov rax, r13
    call fs3_save
.give:
    mov rax, r15
    call fs3_unpin
    mov rax, r13
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret
.upin:
    xor r13d, r13d
    jmp .out2
.fail:
    xor r13d, r13d
.out2:
    mov rax, r15
    call fs3_unpin
    mov rax, r13
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret

; ================================================================ info =======

; fs3_count: fills fs_nfiles / fs_ndirs / fs_nbytes from DIRTAB
fs3_count:
    PUSHA
    xor r12d, r12d                   ; files
    xor r13d, r13d                   ; folders
    xor r14, r14                     ; bytes
    mov r15, DIRTAB
    mov eax, [fs_dlen]
    add rax, DIRTAB                  ; end
    mov r9, rax
.l: cmp r15, r9
    jae .d
    cmp dword [r15+DE_ID], 0
    je .n
    cmp byte [r15+DE_KIND], DE_DIR
    jne .f
    inc r13d
    jmp .n
.f: inc r12d
    mov eax, [r15+DE_SIZE]
    add r14, rax
.n: add r15, DIR_E
    jmp .l
.d:
    mov [fs_nfiles], r12d
    mov [fs_ndirs], r13d
    mov [fs_nbytes], r14
    POPA
    ret

; fs3_rd_cl: eax = cluster, rdi = dst (16384 bytes) -> CF=1 failed
fs3_rd_cl:
    PUSHA
    call fs3_cl2sec
    mov r15d, eax                    ; first sector
    mov r14d, CL_SEC
.l: mov eax, r15d
    call fs3_rd
    jc .f
    inc r15d
    dec r14d
    jnz .l
    POPA
    clc
    ret
.f:
    POPA
    stc
    ret

; fs3_ata_load: load a CNT3 filesystem through the ATA ports -> CF=1 unreadable
fs3_ata_load:
    PUSHA
    ; superblock
    mov eax, FS_LBA
    mov rdi, SBBUF
    call fs3_rd
    jc .fail
    cmp dword [SB3_MAGIC], SIG3
    jne .fail
    call fs3_sanity
    jc .fail
    ; FAT: 512 sectors
    mov r15, FATBUF
    mov r12d, FATSEC
    mov r13d, FS_LBA+1
.fl: mov eax, r13d
    mov rdi, r15
    call fs3_rd
    jc .fail
    inc r13d
    add r15, 512
    dec r12d
    jnz .fl
    ; directory clusters -> DIRTAB
    call fs3_dirmap_build
    mov r14d, [fs_ncl]
    test r14d, r14d
    jz .fail
    xor r12d, r12d
.dl: cmp r12d, r14d
    jae .done
    mov eax, [fs_dirmap+r12*4]
    mov rdi, r12
    shl rdi, 14
    add rdi, DIRTAB
    call fs3_rd_cl
    jc .fail
    inc r12d
    jmp .dl
.done:
    call fs3_freescan
    POPA
    clc
    ret
.fail:
    POPA
    stc
    ret

; fs3_format: build a fresh CNT3 filesystem on the drive in fs_tgt.
;             Keeps the CNT2 settings block (+0..+0x7F) that is already in SBBUF.
FS3_IMGSEC equ 131072                   ; fallback disk size, 64 MB
fs3_format:
    PUSHA
    mov dword [fs_fresh], 1
    ; a clean slate in RAM
    mov rdi, FATBUF
    xor eax, eax
    mov ecx, 65536
    rep stosd
    mov dword [FATBUF], CL_EOF        ; cluster 0 stays reserved
    mov rdi, DIRTAB
    mov ecx, DIRTAB_MAX/8
    rep stosq
    mov dword [fs_ncl], 0
    mov dword [fs_dlen], 0
    mov dword [fs_dumpid], 3
    ; how many clusters fit?
    movzx edx, byte [fs_tgt]
    call bios_info
    test rax, rax
    jnz .have
    mov eax, FS3_IMGSEC
.have:
    sub rax, CLPOOL
    jbe .def
    shr rax, 5                      ; / 32 sectors per cluster
    cmp rax, NCLMAX
    jbe .ok
    mov eax, NCLMAX
    jmp .ok
.def: mov eax, 2048
.ok: mov [SB3_NCL], eax
    mov [SB3_FREE], eax
    mov dword [SB3_HINT], 0
    ; one directory cluster holds the built-in entries
    call fs3_alloc1
    jc .fail
    mov eax, ebx
    mov [SB3_DH], eax
    mov [SB3_DT], eax
    mov [fs_dirmap+0], eax
    mov dword [fs_ncl], 1
    mov dword [fs_dlen], CL_BYTES
    mov dword [SB3_NID], 4
    ; root + base + dump + home
    lea rdi, [DIRTAB+0*DIR_E]
    mov dword [rdi+DE_ID], 1
    mov byte [rdi+DE_KIND], DE_DIR
    mov byte [rdi+DE_FLG], 0
    mov dword [rdi+DE_PAR], 0
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov byte [rdi+DE_NAME], 0
    lea rdi, [DIRTAB+1*DIR_E]
    mov dword [rdi+DE_ID], 2
    mov byte [rdi+DE_KIND], DE_DIR
    mov byte [rdi+DE_FLG], 0
    mov dword [rdi+DE_PAR], 1
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov byte [rdi+DE_NAME+4], 0
    mov dword [rdi+DE_NAME], 'base'
    lea rdi, [DIRTAB+2*DIR_E]
    mov dword [rdi+DE_ID], 3
    mov byte [rdi+DE_KIND], DE_DIR
    mov byte [rdi+DE_FLG], 0
    mov dword [rdi+DE_PAR], 1
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov byte [rdi+DE_NAME+4], 0
    mov dword [rdi+DE_NAME], 'dump'
    lea rdi, [DIRTAB+3*DIR_E]
    mov dword [rdi+DE_ID], 4
    mov byte [rdi+DE_KIND], DE_DIR
    mov byte [rdi+DE_FLG], 0
    mov dword [rdi+DE_PAR], 1
    mov dword [rdi+DE_START], 0
    mov dword [rdi+DE_SIZE], 0
    mov byte [rdi+DE_NAME+4], 0
    mov dword [rdi+DE_NAME], 'home'
    ; write back the FAT sectors in use
    mov eax, [SB3_NCL]
    add eax, 127
    shr eax, 7
    mov r12d, eax
    xor r13d, r13d
.wl: cmp r13d, r12d
    jae .wd
    mov eax, r13d
    shl eax, 9
    add eax, FS_LBA+1
    mov rsi, r13
    shl rsi, 9
    add rsi, FATBUF
    call fs3_wr
    inc r13d
    jmp .wl
.wd:
    ; the directory cluster carries the four entries
    mov eax, [SB3_DH]
    call fs3_cl2sec
    mov ecx, CL_SEC
    mov rsi, DIRTAB
    call fs3_wr_n
    ; superblock: keep the settings, stamp the CNT3 signature
    mov dword [SBBUF+0], SIG2
    mov dword [SB3_MAGIC], SIG3
    call fs3_sb_write
    call fs3_cache_zero
    POPA
    clc
    ret
.fail:
    POPA
    stc
    ret

; fs3_seed: create the default files (skips the ones that already exist)
fs3_seed:
    PUSHA
    lea rbx, [fs3_dtab]
.l: mov rsi, [rbx]
    test rsi, rsi
    jz .o
    mov r12, rbx
    call fs3_find
    test rax, rax
    jnz .n
    mov rsi, [r12]
    call fs3_create
    test rax, rax
    jz .n
    mov r13, rax
    mov rsi, [r12+8]
    call strlen
    mov [r13+48], eax
    mov rsi, [r12+8]
    lea rdi, [r13+64]
    mov ecx, eax
    rep movsb
    or word [r13+60], FL_DIRTY
    mov rax, r13
    call fs3_save
.n: mov rbx, r12
    add rbx, 16
    jmp .l
.o: POPA
    ret

fs3_dtab:
    dq p_readme, d_readme
    dq p_sys,    d_sys
    dq p_rainbow, d_rainbow
    dq p_hello,  d_hello
    dq p_notes,  d_notes
    dq 0

; fs3_init: bring the filesystem up (called once at boot)
fs3_init:
    PUSHA
    movzx eax, byte [bootdrv]
    mov [fs_tgt], eax
    mov dword [fs_dumpid], 3
    mov dword [fs_fresh], 0
    cmp dword [bi_fsok], 0
    je .ata
    ; the 16-bit preload did the reading; is it really CNT3?
    cmp dword [SB3_MAGIC], SIG3
    jne .ata
    call fs3_sanity
    jc .ata
    call fs3_dirmap_build
    ; if the dir table made it, we are done
    cmp dword [DIRTAB+DE_ID], 1
    je .chek
.ata:
    cmp byte [ata_ok], 0
    je .fmt
    call fs3_ata_load
    jnc .chek
.fmt:
    call fs3_format
    call fs3_seed
.chek:
    ; remember the /dump entry id
    mov eax, 1
    lea rsi, [s_dumpnm]
    call fs3_child
    test rdi, rdi
    jz .o
    mov eax, [rdi+DE_ID]
    mov [fs_dumpid], eax
.o:
    POPA
    ret

; fs3_flushterm: write every dirty cache slot back to disk
fs3_flushterm:
    call fs3_flush_all
    ret

; fs3_bigsave: rsi = full path (PATHB), rdx = source data, ecx = size
;              -> rax = 0 ok / 1 failed.  Builds a complete FAT chain.
fs3_bigsave:
    PUSHA
    mov r15, rdx                     ; source cursor
    mov r14d, ecx                    ; size
    call fs3_find
    test rax, rax
    jz .new
    mov [fs_sc1], rax
    mov eax, [rax+56]
    call fs3_del_id
    jc .fail
.new:
    call fs3_create
    test rax, rax
    jz .fail
    mov r13, rax
    mov eax, r14d
    mov [r13+48], eax
    ; the first 16320 bytes travel through the slot
    mov r12d, r14d
    cmp r12d, MAXSZ
    jbe .h1
    mov r12d, MAXSZ
.h1: sub r14d, r12d
    mov rsi, r15
    lea rdi, [r13+64]
    mov ecx, r12d
    rep movsb
    or word [r13+60], FL_DIRTY
    mov rax, r13
    call fs3_save
    mov eax, r12d
    add r15, rax
    mov eax, [r13+56]
    call fs3_ent
    test rax, rax
    jz .fail
    mov r9, rax
    mov r11d, [r9+DE_START]
.l: test r14d, r14d
    jz .fin
    call fs3_alloc1
    jc .fail
    mov r10d, ebx
    mov [FATBUF+r11*4], r10d
    mov ebx, r11d
    call fs3_wr_fat
    mov r11d, r10d
    mov r8d, r14d
    cmp r8d, CL_BYTES
    jbe .tl
    mov r8d, CL_BYTES
    mov eax, r10d
    call fs3_cl2sec
    mov ecx, CL_SEC
    mov rsi, r15
    call fs3_wr_n
    jc .fail
    mov eax, r8d
    add r15, rax
    sub r14d, r8d
    jmp .l
.tl:
    ; the tail: stage through FSBNC so the write stays sector aligned
    lea rdi, [FSBNC]
    xor eax, eax
    mov ecx, 2048
.z: mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .z
    mov rsi, r15
    lea rdi, [FSBNC]
    mov ecx, r8d
    rep movsb
    mov eax, r8d
    add eax, 511
    shr eax, 9
    mov r12d, eax
    mov eax, r10d
    call fs3_cl2sec
    mov ecx, r12d
    lea rsi, [FSBNC]
    call fs3_wr_n
    jc .fail
    mov eax, r8d
    add r15, rax
    sub r14d, r8d
    jmp .l
.fin:
    mov rax, r13
    call fs3_save
    xor eax, eax
    jmp .out
.fail:
    mov eax, 1
.out:
    mov [fs_res], rax
    POPA
    mov rax, [fs_res]
    ret


