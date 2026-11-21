boot_menu:
    mov ax, 0x0003
    int 0x10
    mov si, bm_head
    call bm_puts
    mov si, bm_one
    call bm_puts
    mov si, bm_two
    call bm_puts
    mov ah, 0
    int 0x1A
    mov [bm_tick], dx
.bm_wait:
    mov ah, 1
    int 0x16
    jz .bm_nokey
    mov ah, 0
    int 0x16
    cmp al, '2'
    je .bm_chain
    cmp al, '1'
    je .bm_load
    cmp al, 13
    je .bm_load
    jmp .bm_wait
.bm_nokey:
    mov ah, 0
    int 0x1A
    sub dx, [bm_tick]
    cmp dx, 109
    jb .bm_wait
.bm_load:
    ret
.bm_chain:
    mov eax, [boot+BOOT_PART]
    add eax, IMG_FS
    mov [bm_lba], eax
    mov eax, [boot+BOOT_PART+4]
    adc eax, 0
    mov [bm_lba+4], eax
    mov si, bm_stub
    mov di, 0x7E00
    mov cx, bm_data_end-bm_stub
    rep movsb
    jmp 0x0000:0x7E00
bm_puts:
    lodsb
    test al, al
    jz .bm_pr
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp bm_puts
.bm_pr:
    ret
bm_stub:
    cli
    mov al, [bootdrv]
    mov [0x7E00+bm_drv-bm_stub], al
    mov dl, al
    sti
    mov ah, 0x42
    mov si, 0x7E00+bm_dap-bm_stub
    int 0x13
    jc .bm_halt
    mov dl, [0x7E00+bm_drv-bm_stub]
    jmp 0x0000:0x7C00
.bm_halt:
    hlt
    jmp .bm_halt
bm_stub_end:
bm_dap:  db 0x10, 0
         dw 1
         dw 0x7C00
         dw 0
bm_lba:  dq 0
bm_drv:  db 0
bm_data_end:
bm_tick: dw 0
bm_head:  db "Centtrix 4.0",13,10,13,10,0
bm_one:   db "1  Start Centtrix",13,10,0
bm_two:   db "2  Existing system",13,10,13,10,0
