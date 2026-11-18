ins_state   db 0
ins_prev    db 0
ins_quit    db 0
ins_n       dd 0
ins_sel     dd 0
ins_tgt     dd 0
ins_pct     dd 0
ins_drv     times 16 db 0
ins_sec     times 16 dq 0
ins_buf     times 64 db 0
set_hex     db "0123456789ABCDEF",0

s_setup_t    db "Setup",0
s_setup_run  db "setup: opening the disk installer",10,0
s_set_h      db "Install Centtrix 4.0",0
s_set_pick   db "Choose a disk. Everything on it will be replaced.",0
s_set_foot   db "Up/Down - select    Enter - continue    R - rescan    Esc - close",0
s_set_conf1  db "Install Centtrix to this disk?",0
s_set_conf2  db "All data on the disk will be erased.",0
s_set_conf3  db "Enter - install    Esc - back",0
s_set_copy   db "Copying the system to the disk...",0
s_set_done   db "Installation complete",0
s_set_done2  db "The disk is ready to boot in Legacy/CSM mode.",0
s_set_done3  db "Enter or R - reboot        Esc - close",0
s_set_fail   db "Installation failed",0
s_set_fail2  db "The disk could not be written. Your current system is unchanged.",0
s_set_fail3  db "Esc - back",0
s_set_none   db "No other disk found. Attach a disk and press R.",0
s_set_size   db " MB",0

set_utoa:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov ebx, 10
    xor ecx, ecx
.d: xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .d
.p: pop rax
    stosb
    dec ecx
    jnz .p
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

set_fmt:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov rdi, ins_buf
    mov byte [rdi], '0'
    mov byte [rdi+1], 'x'
    mov ecx, eax
    shr ecx, 4
    and ecx, 15
    lea rsi, [set_hex]
    mov dl, [rsi+rcx]
    mov [rdi+2], dl
    mov ecx, eax
    and ecx, 15
    mov dl, [rsi+rcx]
    mov [rdi+3], dl
    mov byte [rdi+4], ' '
    mov byte [rdi+5], ' '
    add rdi, 6
    mov eax, ebx
    shr eax, 11
    call set_utoa
    mov byte [rdi], ' '
    mov byte [rdi+1], 'M'
    mov byte [rdi+2], 'B'
    mov byte [rdi+3], 0
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

set_scan:
    PUSHA
    mov dword [ins_n], 0
    mov dword [ins_sel], 0
    mov r12d, 0x80
.s: cmp r12d, 0x88
    jae .done
    mov edx, r12d
    call bios_info
    test rax, rax
    jz .nx
    movzx ecx, byte [bootdrv]
    cmp r12d, ecx
    je .nx
    mov ecx, [ins_n]
    cmp ecx, 16
    jae .nx
    mov [ins_drv+rcx], r12b
    mov [ins_sec+rcx*8], rax
    inc dword [ins_n]
.nx: inc r12d
    jmp .s
.done:
    POPA
    ret

set_draw:
    PUSHA
    call clear_content
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_h]
    mov ebx, WX+28
    mov ecx, WY+HDRH+16
    call ui_text

    mov ebx, WX+28
    mov ecx, WY+HDRH+52
    mov esi, 220
    mov edx, 2
    mov eax, C_ACC
    call rect
    cmp byte [ins_state], 0
    jne near .conf

    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_pick]
    mov ebx, WX+28
    mov ecx, WY+HDRH+66
    call ui_text
    cmp dword [ins_n], 0
    jne near .rows
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_none]
    mov ebx, WX+40
    mov ecx, WY+HDRH+120
    call ui_text
    jmp .foot
.rows:
    xor r12d, r12d
.row:
    cmp r12d, [ins_n]
    jae near .rowsd
    mov eax, r12d
    imul eax, eax, 40
    lea r13d, [rax+WY+HDRH+92]
    cmp r12d, [ins_sel]
    jne near .nohi
    mov ebx, WX+20
    lea ecx, [r13d-8]
    mov esi, WW-40
    mov edx, 36
    mov eax, C_ACC
    call rect
.nohi:
    movzx eax, byte [ins_drv+r12]
    mov rbx, [ins_sec+r12*8]
    call set_fmt
    mov eax, C_TXT
    cmp r12d, [ins_sel]
    jne near .c1
    mov eax, 0x00FFFFFF
.c1: mov [g_fg], eax
    lea rsi, [ins_buf]
    mov ebx, WX+40
    mov ecx, r13d
    call ui_text
    inc r12d
    jmp .row
.rowsd:
.foot:
    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_foot]
    mov ebx, WX+28
    mov ecx, WY+WH-STH-40
    call ui_text
    jmp .out
.conf:
    cmp byte [ins_state], 1
    jne near .prog
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_conf1]
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text

    mov eax, [ins_sel]
    mov rbx, [ins_sec+rax*8]
    movzx eax, byte [ins_drv+rax]
    call set_fmt
    mov eax, 0x00FFFFFF
    mov [g_fg], eax
    lea rsi, [ins_buf]
    mov ebx, WX+28
    mov ecx, WY+HDRH+126
    call ui_text
    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_conf2]
    mov ebx, WX+28
    mov ecx, WY+HDRH+176
    call ui_text
    lea rsi, [s_set_conf3]
    mov ebx, WX+28
    mov ecx, WY+HDRH+226
    call ui_text
    jmp .out
.prog:
    cmp byte [ins_state], 2
    jne near .done3
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_copy]
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text
    call set_progress
    jmp .out
.done3:
    cmp byte [ins_state], 3
    jne near .err4
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_done]
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text
    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_done2]
    mov ebx, WX+28
    mov ecx, WY+HDRH+130
    call ui_text
    lea rsi, [s_set_done3]
    mov ebx, WX+28
    mov ecx, WY+HDRH+180
    call ui_text
    jmp .out
.err4:
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_fail]
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text
    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_fail2]
    mov ebx, WX+28
    mov ecx, WY+HDRH+130
    call ui_text
    lea rsi, [s_set_fail3]
    mov ebx, WX+28
    mov ecx, WY+HDRH+180
    call ui_text
.out:
    POPA
    ret

set_progress:
    PUSHA
    lea rax, [font_ui]
    mov [g_uf], rax

    mov ebx, WX+60
    mov ecx, WY+HDRH+150
    mov esi, WW-120
    mov edx, 22
    mov eax, C_STAT
    call rect

    mov eax, [ins_pct]
    mov ebx, WW-120
    imul eax, ebx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov esi, eax
    test esi, esi
    jz near .nofill
    mov ebx, WX+60
    mov ecx, WY+HDRH+150
    mov edx, 22
    mov eax, C_ACC
    call rect
.nofill:
    mov eax, [ins_pct]
    mov rdi, ins_buf
    call set_utoa
    mov byte [rdi], '%'
    mov byte [rdi+1], 0
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, 0x00FFFFFF
    mov [g_fg], eax
    lea rsi, [ins_buf]
    mov ebx, WX+WW/2
    mov ecx, WY+HDRH+182
    call ui_text_c
    POPA
    ret

set_install:
    PUSHA
    mov eax, [ins_sel]
    movzx eax, byte [ins_drv+rax]
    mov [ins_tgt], eax

    mov eax, [ins_sel]
    mov rbx, [ins_sec+rax*8]
    cmp rbx, IMG_FS
    jb near .small
    mov byte [ins_state], 2
    mov dword [ins_pct], 0
    call set_draw
    xor r12d, r12d
.cp:
    cmp r12d, IMG_FS
    jae near .ok
    mov ecx, IMG_FS
    sub ecx, r12d
    cmp ecx, 8
    jbe near .c1
    mov ecx, 8
.c1:
    mov r13d, ecx
    movzx edx, byte [bootdrv]
    mov eax, r12d
    mov rdi, IBUF
    call bios_rd
    jc near .fail
    mov rsi, IBUF
    mov edx, [ins_tgt]
    mov eax, r12d
    mov ecx, r13d
    call bios_wr
    jc near .fail
    add r12d, r13d

    mov eax, r12d
    imul rax, rax, 100
    xor edx, edx
    mov ecx, IMG_FS
    div rcx
    mov [ins_pct], eax
    call set_progress
    mov ecx, 6000
    call anim_wait
    call pollkey
    jmp .cp
.ok:
    mov dword [ins_pct], 100
    call set_progress
    mov byte [ins_state], 3
    call set_draw
    jmp .out
.small:
    mov byte [ins_state], 4
    call set_draw
    jmp .out
.fail:
    mov byte [ins_state], 4
    call set_draw
.out:
    POPA
    ret

set_key:
    cmp al, 27
    je near .esc
    cmp byte [ins_state], 0
    je near .list
    cmp byte [ins_state], 1
    je near .conf
    cmp byte [ins_state], 3
    je near .done

    mov byte [ins_state], 0
    call set_draw
    ret
.list:
    cmp al, K_UP
    je near .up
    cmp al, K_DN
    je near .dn
    cmp al, 13
    je near .go
    cmp al, 'r'
    je near .rescan
    ret
.up:
    cmp dword [ins_sel], 0
    je near .ret
    dec dword [ins_sel]
    call set_draw
    ret
.dn:
    mov eax, [ins_sel]
    inc eax
    cmp eax, [ins_n]
    jae near .ret
    mov [ins_sel], eax
    call set_draw
.ret: ret
.go:
    cmp dword [ins_n], 0
    je near .ret
    mov byte [ins_state], 1
    call set_draw
    ret
.rescan:
    call set_draw
    ret
.conf:
    cmp al, 13
    jne near .back
    call set_install
    ret
.back:
    cmp al, 27
    jne near .ret2
    mov byte [ins_state], 0
    call set_draw
.ret2: ret
.done:
    cmp al, 13
    je near .reboot
    cmp al, 'r'
    je near .reboot
    cmp al, 27
    jne near .ret2
    mov byte [ins_quit], 1
    ret
.reboot:
    mov al, 0xFE
    out 0x64, al
    hlt
    jmp $
.esc:
    cmp byte [ins_state], 1
    je near .back
    cmp byte [ins_state], 0
    je near .close
    cmp byte [ins_state], 3
    je near .close

    cmp byte [ins_state], 4
    je near .back
    ret
.close:
    mov byte [ins_quit], 1
    ret

set_click:
    cmp byte [ins_state], 0
    jne near .out
    mov ecx, ebx
    sub ecx, WY+HDRH+84
    jl near .out
    mov eax, ecx
    xor edx, edx
    mov ecx, 40
    div ecx
    cmp eax, [ins_n]
    jae near .out
    cmp eax, [ins_sel]
    jne near .sel
    mov byte [ins_state], 1
    call set_draw
    ret
.sel:
    mov [ins_sel], eax
    call set_draw
.out:
    ret

app_setup:
    lea rsi, [s_setup_t]
    call draw_win
    mov byte [ins_state], 0
    mov byte [ins_prev], 0
    mov byte [ins_quit], 0
    call set_scan
    call set_draw
.loop:
    call pollkey
    test al, al
    jz near .mouse
    call set_key
    cmp byte [ins_quit], 0
    jne near .exit
    jmp .loop
.mouse:
    mov eax, [task_cur]
    cmp eax, [focus]
    jne near .rel
    test byte [m_btn], 1
    jz near .rel
    cmp byte [ins_prev], 0
    jne near .loop
    mov byte [ins_prev], 1
    call mouse_virt
    call set_click
    jmp .loop
.rel:
    mov byte [ins_prev], 0
    jmp .loop
.exit:
    ret
