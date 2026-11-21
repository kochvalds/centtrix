iso_gate:
    cmp byte [boot+BOOT_ISO], 0
    je .no
    mov dword [launch_req], 9
.loop:
    call pollkey
    call shell_step
    call iso_alive
    test eax, eax
    jnz .loop
    mov al, 0xFE
    out 0x64, al
    hlt
    jmp $
.no:
    ret

iso_alive:
    push rbx
    push rcx
    mov ecx, 1
.l:
    cmp ecx, NTASK
    jae .no
    mov eax, ecx
    shl eax, 7
    lea rbx, [TASKS+rax]
    cmp dword [rbx+T_STATE], 1
    jne .n
    cmp dword [rbx+T_KIND], 9
    je .yes
.n:
    inc ecx
    jmp .l
.no:
    xor eax, eax
    jmp .o
.yes:
    mov eax, 1
.o:
    pop rcx
    pop rbx
    ret
