ins_state   db 0
ins_prev    db 0
ins_quit    db 0
ins_n       dd 0
ins_sel     dd 0
ins_tgt     dd 0
ins_pct     dd 0
ins_drv     times 16 db 0
ins_sec     times 16 dq 0
ins_buf     times 96 db 0
set_hex     db "0123456789ABCDEF",0
ins_along   db 0
ins_pslot   dd 0
ins_part    dd 0
ins_err     dd 0
ins_dsz     dd 0

s_setup_t    db "Setup",0
s_setup_run  db "setup: opening the disk installer",10,0
s_set_h      db "Install Centtrix 4.0",0
s_set_pick   db "Choose a disk. Everything on it will be replaced.",0
s_set_foot   db "Up/Down - select   A - alongside   Enter - continue   Esc - close",0
s_set_pick2  db "Choose a disk. The other systems stay in place.",0
s_set_free1  db "Installing next to the existing system.",0
s_set_free2  db "Free space starts at sector ",0
s_set_free3  db ", ",0
s_set_free4  db " MB available",0
s_set_nofree db "No free space on this disk for a second system.",0
s_set_gpt    db "This disk uses GPT. Choose a disk with an MBR table.",0
s_set_small2 db "The disk is too small for Centtrix.",0
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
    cmp byte [ins_along], 0
    je .pick
    lea rsi, [s_set_pick2]
.pick:
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
    cmp byte [ins_along], 0
    je .confp
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [s_set_free1]
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text
    lea rdi, [ins_buf]
    lea rsi, [s_set_free2]
    call sappend
    mov eax, [ins_part]
    call set_utoa
    lea rsi, [s_set_free3]
    call sappend
    mov eax, [ins_dsz]
    sub eax, [ins_part]
    shr eax, 11
    call set_utoa
    lea rsi, [s_set_free4]
    call sappend
    mov byte [rdi], 0
    mov eax, C_TXT
    mov [g_fg], eax
    lea rsi, [ins_buf]
    mov ebx, WX+28
    mov ecx, WY+HDRH+126
    call ui_text
    mov eax, C_DIM
    mov [g_fg], eax
    lea rsi, [s_set_conf3]
    mov ebx, WX+28
    mov ecx, WY+HDRH+226
    call ui_text
    jmp .out
.confp:
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
    cmp byte [ins_err], 1
    jne .e2
    lea rsi, [s_set_nofree]
    jmp .ehead
.e2:
    cmp byte [ins_err], 2
    jne .e3
    lea rsi, [s_set_gpt]
    jmp .ehead
.e3:
    cmp byte [ins_err], 3
    jne .ehead
    lea rsi, [s_set_small2]
.ehead:
    mov ebx, WX+28
    mov ecx, WY+HDRH+90
    call ui_text
    mov eax, C_DIM
    mov [g_fg], eax
    cmp byte [ins_err], 0
    jne .enof2
    lea rsi, [s_set_fail2]
    mov ebx, WX+28
    mov ecx, WY+HDRH+130
    call ui_text
.enof2:
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

io_abs_rd:
    push r11
    mov r11, [boot+BOOT_PART]
    mov qword [boot+BOOT_PART], 0
    call bios_rd
    mov [boot+BOOT_PART], r11
    pop r11
    ret

io_abs_wr:
    push r11
    mov r11, [boot+BOOT_PART]
    mov qword [boot+BOOT_PART], 0
    call bios_wr
    mov [boot+BOOT_PART], r11
    pop r11
    ret

set_free:
    PUSHA
    mov byte [ins_err], 0
    xor eax, eax
    mov edx, [ins_tgt]
    lea rdi, [IBUF2]
    mov ecx, 1
    call io_abs_rd
    jc .no
    cmp word [IBUF2+510], 0xAA55
    jne .no
    lea r14, [IBUF2+446]
    mov ecx, 4
.gpt:
    cmp byte [r14+4], 0xEE
    je .gptbad
    add r14, 16
    loop .gpt
    mov eax, [ins_sel]
    mov eax, [ins_sec+rax*8]
    mov [ins_dsz], eax
    mov r12d, 0x800
    xor r15d, r15d
    lea r14, [IBUF2+446]
    mov ecx, 4
.slot:
    cmp byte [r14+4], 0
    jne .sn
    test r15d, r15d
    jnz .sn
    mov rax, r14
    sub rax, IBUF2+446
    shr eax, 4
    inc eax
    mov r15d, eax
.sn:
    add r14, 16
    loop .slot
    mov r13d, 0
.iter:
    mov ebx, 0xFFFFFFFF
    lea r14, [IBUF2+446]
    mov ecx, 4
.chk:
    cmp byte [r14+4], 0
    je .cn
    mov eax, [r14+8]
    cmp eax, r12d
    jb .cn
    cmp eax, ebx
    jae .cn
    mov ebx, eax
.cn:
    add r14, 16
    loop .chk
    cmp ebx, 0xFFFFFFFF
    je .tail
    mov eax, ebx
    sub eax, r12d
    cmp eax, IMG_FS+1
    jae .found
    lea r14, [IBUF2+446]
    mov ecx, 4
.find:
    cmp byte [r14+4], 0
    je .fn
    mov eax, [r14+8]
    cmp eax, ebx
    jne .fn
    mov eax, [r14+12]
    add eax, ebx
    mov r12d, eax
.fn:
    add r14, 16
    loop .find
    jmp .adv
.tail:
    mov eax, [ins_dsz]
    sub eax, r12d
    cmp eax, IMG_FS+1
    jae .found
    jmp .no
.adv:
    inc r13d
    cmp r13d, 8
    jb .iter
    jmp .no
.found:
    test r15d, r15d
    jz .no
    mov eax, [ins_dsz]
    sub eax, r12d
    cmp eax, IMG_FS+1
    jb .no
    mov [ins_part], r12d
    mov [ins_pslot], r15d
    POPA
    clc
    ret
.gptbad:
    mov byte [ins_err], 2
    jmp .fail
.no:
    mov byte [ins_err], 1
.fail:
    POPA
    stc
    ret

set_install:
    PUSHA
    mov eax, [ins_sel]
    movzx eax, byte [ins_drv+rax]
    mov [ins_tgt], eax
    mov byte [ins_err], 0
    xor r14d, r14d
    cmp byte [ins_along], 0
    je .size
    call set_free
    jc .fail
    mov r14d, [ins_part]
.size:
    cmp byte [ins_along], 0
    jne .go
    mov eax, [ins_sel]
    mov rbx, [ins_sec+rax*8]
    cmp rbx, IMG_FS
    jb .toosmall
.go:
    mov byte [ins_state], 2
    mov dword [ins_pct], 0
    call set_draw
    cmp byte [ins_along], 0
    je .copy
    mov eax, r14d
    add eax, IMG_FS
    lea rsi, [IBUF2]
    mov edx, [ins_tgt]
    mov ecx, 1
    call io_abs_wr
    jc .fail
.copy:
    xor r12d, r12d
.cp:
    cmp r12d, IMG_FS
    jae .ok
    mov ecx, IMG_FS
    sub ecx, r12d
    cmp ecx, 8
    jbe .c1
    mov ecx, 8
.c1:
    mov r13d, ecx
    movzx edx, byte [bootdrv]
    mov eax, r12d
    mov rdi, IBUF
    call bios_rd
    jc .fail
    test r12d, r12d
    jnz .wr
    mov byte [IBUF+BOOT_ISO], 0
    cmp byte [ins_along], 0
    je .eraset
    mov byte [IBUF+BOOT_MENU], 1
    mov eax, r14d
    mov [IBUF+BOOT_PART], eax
    mov dword [IBUF+BOOT_PART+4], 0
    lea rsi, [IBUF2+440]
    lea rdi, [IBUF+440]
    mov ecx, 72
    rep movsb
    mov eax, [ins_pslot]
    dec eax
    imul eax, eax, 16
    lea rdi, [IBUF+446+rax]
    mov dword [rdi], 0
    mov word [rdi+4], 0x0C
    mov word [rdi+6], 0
    mov eax, r14d
    mov [rdi+8], eax
    mov dword [rdi+12], IMG_FS+1
    mov byte [IBUF+BOOT_ISO], 0
    mov byte [IBUF+BOOT_MENU], 1
    mov eax, r14d
    mov [IBUF+BOOT_PART], eax
    mov dword [IBUF+BOOT_PART+4], 0
    jmp .wr
.eraset:
    lea rdi, [IBUF+440]
    mov ecx, 70
    xor eax, eax
    rep stosb
    mov word [IBUF+510], 0xAA55
.wr:
    mov rsi, IBUF
    mov edx, [ins_tgt]
    mov eax, r12d
    add eax, r14d
    mov ecx, r13d
    call io_abs_wr
    jc .fail
    cmp byte [ins_along], 0
    je .noadd
    test r12d, r12d
    jnz .noadd
    mov rsi, IBUF
    mov edx, [ins_tgt]
    xor eax, eax
    mov ecx, 1
    call io_abs_wr
    jc .fail
.noadd:
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
.toosmall:
    mov byte [ins_err], 3
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
    cmp al, 'a'
    je near .along
    ret
.along:
    xor byte [ins_along], 1
    call set_draw
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
    cmp byte [ins_along], 0
    je near .go2
    mov eax, [ins_sel]
    movzx eax, byte [ins_drv+rax]
    mov [ins_tgt], eax
    call set_free
    jc near .goerr
.go2:
    mov byte [ins_state], 1
    call set_draw
    ret
.goerr:
    mov byte [ins_state], 4
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
