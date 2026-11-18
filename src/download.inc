; =============================================================================
;  download.inc  -  file downloads
;    terminal :  wget URL [name]     (also: curl URL [name])
;    browser  :  press  s  to save the current page / file to the current folder
;  Files up to MAXSZ (16320 bytes) go to the normal CNTX filesystem (/home when
;  you are in /base or /dump).  Bigger files go to BIGFS when it has been
;  formatted (bigfs format yes); otherwise the first MAXSZ bytes are kept.
;  The body is stored raw (binary types are NOT replaced by "[binary]").
;  Limit: one response buffer of ~1 MB (RAW_MAX).
;  Covered by test.sh (real HTTP GETs, small and large files).
; =============================================================================
DL_MAXNAME  equ 30

; ---- dl_basename: rsi = url -> dl_name (sanitised file name) ------------------
dl_basename:
    PUSHA
    mov rdi, rsi
.fs:
    mov al, [rdi]
    test al, al
    jz .hs
    cmp al, '/'
    je .hs
    cmp al, ':'
    jne .fn
    cmp byte [rdi+1], '/'
    jne .fn
    cmp byte [rdi+2], '/'
    jne .fn
    lea rsi, [rdi+3]
    jmp .hs
.fn:
    inc rdi
    jmp .fs
.hs:                                    ; rsi = start of the host (or whole url)
    mov al, [rsi]
    test al, al
    jz .none
    cmp al, '/'
    je .path
    inc rsi
    jmp .hs
.path:
    lea rbx, [rsi+1]                    ; start of the current component
    lea rdi, [rsi+1]
.pl:
    mov al, [rdi]
    test al, al
    jz .pe
    cmp al, '?'
    je .pe
    cmp al, '#'
    je .pe
    cmp al, ' '
    je .pe
    inc rdi
    cmp al, '/'
    jne .pl
    mov rbx, rdi
    jmp .pl
.pe:
    cmp rbx, rdi
    jae .none
    mov rsi, rbx
    mov rdx, rdi                        ; end of the name
    lea rdi, [dl_name]
    xor ecx, ecx
.cp:
    cmp rsi, rdx
    jae .cd
    cmp ecx, DL_MAXNAME
    jae .cd
    mov al, [rsi]
    inc rsi
    cmp al, '.'
    je .ok
    cmp al, '-'
    je .ok
    cmp al, '_'
    je .ok
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .ok
    cmp al, 'A'
    jb .bad
    cmp al, 'Z'
    jbe .ok
    cmp al, 'a'
    jb .bad
    cmp al, 'z'
    jbe .ok
.bad:
    mov al, '_'
.ok:
    mov [rdi+rcx], al
    inc ecx
    jmp .cp
.cd:
    mov byte [rdi+rcx], 0
    jmp .o
.none:
    lea rsi, [s_dl_index]
    lea rdi, [dl_name]
    call strcpy
.o: POPA
    ret

; ---- dl_save: dl_name + HTTPB (fetched body) -> eax result, TMPB = message ------
;      result 0 saved, 1 saved but cut at MAXSZ, 2 cannot create, 3 saved in BIGFS
;      CNT3 keeps big files as FAT chains, so nothing is cut anymore
dl_save:
    PUSHA
    mov r12d, [HTTPB+48]
    xor r13d, r13d                      ; result
    cmp r12d, MAXSZ
    jbe .small
    ; big: write a full CNT3 chain
    lea rsi, [dl_name]
    call mkpath_cur                     ; rsi = PATHB (full path)
    mov rdx, HTTPB+64
    mov ecx, r12d
    call fs3_bigsave
    test eax, eax
    jnz .bigfail
    mov rdi, TMPB
    lea rsi, [s_dl_saved]
    call sappend
    mov eax, r12d
    call u2s
    lea rsi, [s_dl_big]
    call sappend
    lea rsi, [dl_name]
    call sappend
    jmp .out
.bigfail:
    mov r13d, 2
    mov rdi, TMPB
    lea rsi, [s_dl_nocreate]
    call sappend
    jmp .out
.small:
    lea rsi, [dl_name]
    call mkpath_cur
    call fs_create
    test rax, rax
    jnz .mk
    mov r13d, 2
    mov rdi, TMPB
    lea rsi, [s_dl_nocreate]
    call sappend
    jmp .out
.mk:
    mov rbx, rax
    lea rdi, [rbx+64]
    mov rsi, HTTPB+64
    mov ecx, r12d
    rep movsb
    mov [rbx+48], r12d
    mov rax, rbx
    call fs_save
    mov rdi, TMPB
    lea rsi, [s_dl_saved]
    call sappend
    mov eax, r12d
    call u2s
    lea rsi, [s_dl_to]
    call sappend
    lea rsi, [rbx]
    call sappend
    cmp r13d, 1
    jne .out
    cmp r15d, 1
    je .cutfmt
    cmp r15d, 2
    je .cutfull
    lea rsi, [s_dl_bgerr]
    call sappend
    jmp .out
.cutfmt:
    lea rsi, [s_dl_cut]
    call sappend
    jmp .out
.cutfull:
    lea rsi, [s_dl_full]
    call sappend
.out:
    mov [dl_res], r13d
    POPA
    mov eax, [dl_res]
    ret

; ---- dl_fetch: dl_url -> http_fetch with raw body; eax = E_ code or 0 ---------
dl_fetch:
    mov byte [http_dl], 1
    lea rsi, [dl_url]
    call http_fetch
    mov byte [http_dl], 0
    ret

; ---- terminal: wget URL [name] --------------------------------------------------
term_wget:                              ; rsi = arguments
    PUSHA
    call skipsp
    cmp byte [rsi], 0
    jne .have
    lea rsi, [s_wg_use]
    call tput_s
    jmp .o
.have:
    lea rdi, [dl_url]
    xor ecx, ecx
.cu:
    mov al, [rsi]
    cmp al, ' '
    jbe .ue
    cmp ecx, 480
    jae .ue
    mov [rdi+rcx], al
    inc ecx
    inc rsi
    jmp .cu
.ue:
    mov byte [rdi+rcx], 0
    call skipsp
    cmp byte [rsi], 0
    je .auto
    lea rdi, [dl_name]
    xor ecx, ecx
.cn:
    mov al, [rsi]
    cmp al, ' '
    jbe .ne
    cmp ecx, DL_MAXNAME
    jae .ne
    mov [rdi+rcx], al
    inc ecx
    inc rsi
    jmp .cn
.ne:
    mov byte [rdi+rcx], 0
    jmp .fetch
.auto:
    lea rsi, [dl_url]
    call dl_basename
.fetch:
    lea rsi, [s_wg_get]
    call tput_s
    lea rsi, [dl_url]
    call tput_s
    call tnl
    call dl_fetch
    test eax, eax
    jz .got
    call tc_err
    jmp .o
.got:
    mov eax, [http_status]
    cmp eax, 400
    jb .save
    mov rdi, TMPB
    lea rsi, [s_wg_http]
    call sappend
    call u2s
    lea rsi, [s_wg_nosave]
    call sappend
    mov rsi, TMPB
    call tput_s
    call tnl
    jmp .o
.save:
    call dl_save
    mov rsi, TMPB
    call tput_s
    call tnl
.o: POPA
    ret

; ---- browser: s = save the current page / file ---------------------------------
br_download:
    PUSHA
    cmp byte [br_isweb], 0
    jne .web
    lea rsi, [s_dl_local]
    jmp .say
.web:
    lea rsi, [br_loc]
    lea rdi, [dl_url]
    call strcpy
    lea rsi, [dl_url]
    call dl_basename
    call dl_fetch
    test eax, eax
    jz .ok
    call net_errmsg
    jmp .say
.ok:
    mov eax, [http_status]
    cmp eax, 400
    jb .save
    mov rdi, TMPB
    lea rsi, [s_wg_http]
    call sappend
    call u2s
    lea rsi, [s_wg_nosave]
    call sappend
    mov rsi, TMPB
    jmp .say
.save:
    call dl_save
    mov rsi, TMPB
.say:
    lea rdi, [br_msg]
    call strcpy
    lea rax, [br_msg]
    mov [br_stat], rax
    POPA
    ret

http_dl     db 0
dl_res      dd 0
dl_name     times 48 db 0
dl_url      times 512 db 0
s_dl_index  db "index.html",0
s_dl_saved  db "Saved ",0
s_dl_to     db " bytes -> ",0
s_dl_big    db " bytes -> bigfs:",0
s_dl_cut    db "  (cut at 16 KB: run 'bigfs format yes' once to keep big files)",0
s_dl_full   db "  (cut at 16 KB: bigfs has no room left; run 'bigfs format yes' to reset)",0
s_dl_bgerr  db "  (cut at 16 KB: bigfs disk error)",0
s_dl_nocreate db "Cannot create the file (folder full or bad name).",0
s_dl_local  db "This is already a local file.",0
s_wg_use    db "usage: wget URL [name]",10,0
s_wg_get    db "Downloading ",0
s_wg_http   db "Server answered HTTP ",0
s_wg_nosave db ", nothing saved.",0
