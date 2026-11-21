pkg_s_index  db "https://raw.githubusercontent.com/kochvalds/centtrix-packages/main/index.txt",0
pkg_s_base   db "https://raw.githubusercontent.com/kochvalds/centtrix-packages/main/pkgs/",0
pkg_s_ext    db ".xep",0
pkg_s_dir    db "/home/pkg/",0
pkg_k_list   db "list",0
pkg_k_install db "install",0
pkg_k_help   db "help",0
pkg_s_head   db "Packages:",0
pkg_s_unknown db "cenpkg: unknown command (try: cenpkg list)",0
pkg_s_use1   db "usage: cenpkg list",0
pkg_s_use2   db "       cenpkg install NAME",0
pkg_s_nf     db "cenpkg: package not found: ",0
pkg_s_http   db "cenpkg: server returned ",0
pkg_s_empty  db "cenpkg: empty response",0
pkg_s_ok     db "installed ",0
pkg_s_ok2    db " (",0
pkg_s_run    db "run: ",0
pkg_s_save   db "cenpkg: cannot write /home/pkg",0
pkg_s_prompt db "package name: ",0
pkg_name     times 40 db 0
pkg_path     times 96 db 0

pkg_index:
    PUSHA
    lea rsi, [pkg_s_index]
    lea rdi, [dl_url]
    call strcpy
    call dl_fetch
    test eax, eax
    jnz .nerr
    mov eax, [http_status]
    cmp eax, 400
    jb .stat
    lea rsi, [pkg_s_http]
    call tput_s
    mov eax, [http_status]
    call tput_dec
    call tnl
    jmp .fail
.stat:
    cmp dword [HTTPB+48], 0
    jne .ok
    lea rsi, [pkg_s_empty]
    call tput_s
    call tnl
    jmp .fail
.ok:
    POPA
    clc
    ret
.nerr:
    call tc_err
.fail:
    POPA
    stc
    ret

pkg_find:
    PUSHA
    mov r12, HTTPB+64
    mov r13d, [HTTPB+48]
    add r13, r12
.line:
    cmp r12, r13
    jae .no
    movzx eax, byte [r12]
    cmp al, ' '
    je .skipc
    cmp al, 9
    je .skipc
    cmp al, 13
    je .skipc
    cmp al, 10
    je .skipc
    jmp .try
.skipc:
    inc r12
    jmp .line
.try:
    lea rsi, [pkg_name]
    mov rdi, r12
.cmp:
    lodsb
    test al, al
    jz .tail
    cmp al, [rdi]
    jne .next
    inc rdi
    jmp .cmp
.tail:
    mov al, [rdi]
    cmp al, ' '
    je .yes
    cmp al, '.'
    je .yes
    cmp al, 9
    je .yes
    cmp al, 13
    je .yes
    cmp al, 10
    je .yes
.next:
    inc r12
.nl:
    cmp r12, r13
    jae .no
    mov al, [r12]
    inc r12
    cmp al, 10
    jne .nl
    jmp .line
.yes:
    mov rsi, r12
    lea rdi, [pkg_name]
    xor ecx, ecx
.tok:
    mov al, [rsi]
    test al, al
    jz .tokend
    cmp al, ' '
    je .tokend
    cmp al, 9
    je .tokend
    cmp al, 13
    je .tokend
    cmp al, 10
    je .tokend
    cmp ecx, 39
    jae .tokend
    mov [rdi+rcx], al
    inc ecx
    inc rsi
    jmp .tok
.tokend:
    mov byte [rdi+rcx], 0
    POPA
    clc
    ret
.no:
    POPA
    stc
    ret

pkg_ext:
    push rsi
    push rdi
    push rcx
    lea rsi, [pkg_name]
    xor ecx, ecx
.l: mov al, [rsi+rcx]
    test al, al
    jz .add
    cmp al, '.'
    je .out
    inc ecx
    jmp .l
.add:
    cmp ecx, 35
    jae .out
    lea rdi, [pkg_name+rcx]
    lea rsi, [pkg_s_ext]
    call sappend
.out: pop rcx
    pop rdi
    pop rsi
    ret

pkg_tail:
    cmp byte [rdi], 0
    je .d
    inc rdi
    jmp pkg_tail
.d: ret

term_pkg:
    PUSHA
    call skipsp
    cmp byte [rsi], 0
    je .usage
    lea rdi, [pkg_k_list]
    call match
    je .list
    lea rdi, [pkg_k_install]
    call match
    je .inst
    lea rdi, [pkg_k_help]
    call match
    je .usage
    lea rsi, [pkg_s_unknown]
    call tput_s
    call tnl
    jmp .out
.usage:
    lea rsi, [pkg_s_use1]
    call tput_s
    call tnl
    lea rsi, [pkg_s_use2]
    call tput_s
    call tnl
    jmp .out
.list:
    call pkg_index
    jc .out
    lea rsi, [pkg_s_head]
    call tput_s
    call tnl
    mov r12, HTTPB+64
    mov r13d, [HTTPB+48]
    add r13, r12
.l1:
    cmp r12, r13
    jae .ldone
    movzx eax, byte [r12]
    inc r12
    cmp al, 13
    je .l1
    cmp al, 10
    jne .l2
    call tnl
    jmp .l1
.l2:
    call tput_c
    jmp .l1
.ldone:
    call tnl
    jmp .out
.inst:
    call skipsp
    cmp byte [rsi], 0
    jne .named
    lea rsi, [pkg_s_prompt]
    call tput_s
    lea rdi, [TMPB]
    call term_getline
    jc .out
    lea rsi, [TMPB]
.named:
    lea rdi, [pkg_name]
    xor ecx, ecx
.cn:
    mov al, [rsi]
    test al, al
    jz .ce
    cmp ecx, 31
    jae .ce
    mov [rdi+rcx], al
    inc ecx
    inc rsi
    jmp .cn
.ce:
    mov byte [rdi+rcx], 0
    test ecx, ecx
    jz .usage
    call pkg_index
    jc .out
    call pkg_find
    jc .notfound
    call pkg_ext
    lea rdi, [dl_url]
    lea rsi, [pkg_s_base]
    call strcpy
    call pkg_tail
    lea rsi, [pkg_name]
    call sappend
    call dl_fetch
    test eax, eax
    jnz .neterr
    mov eax, [http_status]
    cmp eax, 400
    jae .http
    cmp dword [HTTPB+48], 0
    je .empty
    lea rsi, [pkg_s_dir]
    call fs3_mk
    lea rdi, [pkg_path]
    lea rsi, [pkg_s_dir]
    call strcpy
    call pkg_tail
    lea rsi, [pkg_name]
    call sappend
    lea rsi, [pkg_path]
    mov rdx, HTTPB+64
    mov ecx, [HTTPB+48]
    call fs3_bigsave
    test eax, eax
    jnz .saveerr
    lea rsi, [pkg_s_ok]
    call tput_s
    lea rsi, [pkg_name]
    call tput_s
    lea rsi, [pkg_s_ok2]
    call tput_s
    mov eax, [HTTPB+48]
    call tput_dec
    mov al, ')'
    call tput_c
    call tnl
    lea rsi, [pkg_s_run]
    call tput_s
    lea rsi, [pkg_path]
    call tput_s
    call tnl
    jmp .out
.neterr:
    call tc_err
    jmp .out
.http:
    lea rsi, [pkg_s_http]
    call tput_s
    mov eax, [http_status]
    call tput_dec
    call tnl
    jmp .out
.empty:
    lea rsi, [pkg_s_empty]
    call tput_s
    call tnl
    jmp .out
.saveerr:
    lea rsi, [pkg_s_save]
    call tput_s
    call tnl
    jmp .out
.notfound:
    lea rsi, [pkg_s_nf]
    call tput_s
    lea rsi, [pkg_name]
    call tput_s
    call tnl
.out:
    POPA
    ret
