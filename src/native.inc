NATBUF   equ 0x10000000
nat_busy dd 0
nat_col  dd 0
nat_row  dd 0
nat_ttl  db "program",0

native_run_slot:
    PUSHA
    cmp dword [nat_busy], 0
    jne .out
    mov r12, rax
    mov eax, [r12+48]
    test eax, eax
    jz .out
    cmp eax, 16000
    ja .out
    lea rsi, [r12+64]
    mov rdi, NATBUF
    mov ecx, eax
    rep movsb
    mov dword [nat_busy], 1
    lea rax, [nat_task]
    mov ebx, NATBUF
    mov ecx, 12
    lea rsi, [nat_ttl]
    call spawn
.out:
    POPA
    ret

nat_task:
    mov r12, rax
    lea rsi, [nat_ttl]
    call draw_win
    mov dword [nat_col], 0
    mov dword [nat_row], 0
    mov byte [g_tr], 0
    mov eax, C_TXT
    mov [g_fg], eax
    SETC g_bg, C_WIN
    lea rdi, [nat_api]
    call r12
    mov dword [nat_busy], 0
    call task_exit

nat_print:
    push rsi
    mov rsi, rdi
.l: lodsb
    test al, al
    jz .d
    movzx edi, al
    push rsi
    call nat_putc
    pop rsi
    jmp .l
.d: pop rsi
    ret

nat_putc:
    PUSHA
    mov eax, edi
    cmp al, 10
    je .nl
    mov ebx, [nat_col]
    cmp ebx, COLS
    jb .ok
    call nat_nl
    xor ebx, ebx
.ok:
    mov ecx, [nat_row]
    shl ebx, 3
    add ebx, GX
    shl ecx, 4
    add ecx, GY
    mov eax, edi
    call glyph
    inc dword [nat_col]
    POPA
    ret
.nl:
    mov dword [nat_col], 0
    inc dword [nat_row]
    cmp dword [nat_row], ROWS
    jb .out
    mov dword [nat_row], 0
.out:
    POPA
    ret

nat_num:
    PUSHA
    mov eax, edi
    lea rdi, [TMPB]
    call u2s
    lea rdi, [TMPB]
    call nat_print
    POPA
    ret

nat_nl:
    mov edi, 10
    jmp nat_putc

nat_key:
    call pollkey
    movzx eax, al
    ret

nat_wait:
    call getkey
    movzx eax, al
    ret

nat_yield:
    call yield
    xor eax, eax
    ret

nat_exit:
    mov dword [nat_busy], 0
    call task_exit

nat_sleep:
    mov ecx, edi
    call anim_wait
    xor eax, eax
    ret

nat_api:
    dq nat_print
    dq nat_putc
    dq nat_num
    dq nat_nl
    dq nat_key
    dq nat_wait
    dq nat_yield
    dq nat_exit
    dq nat_sleep

native_seed:
    PUSHA
    lea rsi, [pkg_s_dir]
    call fs3_mk
    lea rbx, [nat_btab]
.l: mov rsi, [rbx]
    test rsi, rsi
    jz .o
    mov [nat_ptr], rbx
    call fs3_find
    mov rbx, [nat_ptr]
    test rax, rax
    jz .save
    mov ecx, [rbx+16]
    cmp [rax+48], ecx
    jne .save
    lea rsi, [rax+64]
    mov rdi, [rbx+8]
    repe cmpsb
    je .n
.save:
    mov rsi, [rbx]
    mov rdx, [rbx+8]
    mov ecx, [rbx+16]
    call fs3_bigsave
    mov rbx, [nat_ptr]
.n: add rbx, 24
    jmp .l
.o: POPA
    ret

nat_ptr dq 0

%include "build/native_tab.inc"
