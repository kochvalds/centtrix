; =============================================================================
;  anim.inc  -  window animations for Centtrix
;    open     : window slides up into place (non-blocking, driven by wm_service)
;    close    : window slides down before it is removed (blocking, ~70 ms)
;    minimise : window slides toward the dock, then is hidden at its old place
;  Timing uses PIT channel 0 (latched counter, 1.193182 MHz).
;  Built and exercised in QEMU together with the rest of the kernel.
; =============================================================================
AN_STEPS    equ 8
AN_TICKS    equ 10000                   ; PIT ticks per frame (~8.4 ms)
AN_OFF0     equ 34                      ; start offset (pixels below final place)

; ---- anim_pit: latch and read PIT channel 0 -> ax (counts DOWN, 16 bit) ------
anim_pit:
    xor eax, eax
    out 0x43, al
    in al, 0x40
    mov ah, al
    in al, 0x40
    xchg al, ah
    ret

; ---- anim_wait: ecx = PIT ticks to wait (all registers kept) -----------------
anim_wait:
    push rax
    push rbx
    push rdx
    push r8
    call anim_pit
    movzx r8d, ax
    xor edx, edx
    mov ebx, 3000000                    ; safety cap if the PIT is not running
.l: call anim_pit
    movzx eax, ax
    push rax
    sub r8d, eax
    and r8d, 0xFFFF
    add edx, r8d
    pop r8
    cmp edx, ecx
    jae .d
    dec ebx
    jnz .l
.d: pop r8
    pop rdx
    pop rbx
    pop rax
    ret

anim_flush:                             ; wm_flush with every register kept
    PUSHA
    call wm_flush
    POPA
    ret

; ---- anim_open_start: esi = window surface index (all registers kept) --------
anim_open_start:
    PUSHA
    cmp dword [an_surf], 0
    je .go
    call anim_finish                    ; an older animation is still pending
.go:
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    mov eax, [r8+SF_SX]
    mov ebx, [r8+SF_SY]
    mov [an_x], eax
    mov [an_y], ebx
    mov [an_surf], esi
    mov dword [an_step], 0
    call anim_pit
    movzx eax, ax
    mov [an_last], eax
    mov eax, [an_x]
    mov ebx, [an_y]
    add ebx, AN_OFF0
    call win_move_to
    POPA
    ret

; ---- anim_finish: jump the pending window to its final place -----------------
anim_finish:
    PUSHA
    mov esi, [an_surf]
    test esi, esi
    jz .o
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jz .z
    mov eax, [an_x]
    mov ebx, [an_y]
    call win_move_to
.z: mov dword [an_surf], 0
.o: POPA
    ret

; ---- anim_tick: called from wm_service on every poll (all registers kept) ----
anim_tick:
    cmp dword [an_surf], 0
    jne .go
    ret
.go:
    PUSHA
    call anim_pit
    movzx eax, ax
    mov ecx, [an_last]
    sub ecx, eax
    and ecx, 0xFFFF
    cmp ecx, AN_TICKS
    jb .o
    mov [an_last], eax
    mov esi, [an_surf]
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jz .end
    mov ecx, [an_step]
    cmp ecx, AN_STEPS
    jae .end
    lea rdx, [an_otab]
    movzx edx, byte [rdx+rcx]
    inc dword [an_step]
    mov eax, [an_x]
    mov ebx, [an_y]
    add ebx, edx
    call win_move_to
    jmp .o
.end:
    mov dword [an_surf], 0
.o: POPA
    ret

; ---- anim_close: esi = window surface (blocking slide down) ------------------
anim_close:
    PUSHA
    mov r15d, esi
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jz .o
    cmp dword [an_surf], 0
    je .g
    call anim_finish
.g: mov r12d, [r8+SF_SX]
    mov r13d, [r8+SF_SY]
    xor r14d, r14d
.l: lea rdx, [an_ctab]
    movzx edx, byte [rdx+r14]
    mov eax, r12d
    lea ebx, [r13+rdx]
    mov esi, r15d
    call win_move_to
    call anim_flush
    mov ecx, AN_TICKS
    call anim_wait
    inc r14d
    cmp r14d, AN_STEPS
    jb .l
.o: POPA
    ret

; ---- anim_min: esi = window surface (slide toward the dock, hide, restore) ---
anim_min:
    PUSHA
    mov r15d, esi
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    test dword [r8+SF_FLG], SFF_VIS
    jz .o
    cmp dword [an_surf], 0
    je .g
    call anim_finish
.g: mov r12d, [r8+SF_SX]
    mov r13d, [r8+SF_SY]
    xor r14d, r14d
.l: lea rdx, [an_mtab]
    movzx edx, byte [rdx+r14]
    mov eax, r12d
    lea ebx, [r13+rdx]
    mov esi, r15d
    call win_move_to
    call anim_flush
    mov ecx, AN_TICKS
    call anim_wait
    inc r14d
    cmp r14d, AN_STEPS
    jb .l
    mov r8d, r15d
    shl r8d, 7
    add r8, SURFS
    and dword [r8+SF_FLG], ~SFF_VIS     ; hide it where it is now ...
    mov esi, r15d
    call surf_damage
    mov r8d, r15d
    shl r8d, 7
    add r8, SURFS
    mov [r8+SF_SX], r12d                ; ... and put it back for restoring
    mov [r8+SF_SY], r13d
.o: POPA
    ret

an_surf     dd 0
an_step     dd 0
an_x        dd 0
an_y        dd 0
an_last     dd 0
an_otab     db 26, 19, 13, 8, 4, 2, 1, 0            ; open  : ease-out
an_ctab     db 0, 1, 3, 6, 10, 15, 21, 28           ; close : ease-in
an_mtab     db 0, 6, 16, 32, 56, 88, 130, 180       ; minimise
