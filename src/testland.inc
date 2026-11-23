; =============================================================================
;  TESTLAND - a tiling, keyboard-first window manager for Centtrix
; =============================================================================
;  Start it from the terminal:        testland
;  Leave it:                          testland off   (or Super+Shift+Q)
;
;  Super+Enter        open a Terminal
;  Super+E            open Files
;  Super+H / L        previous / next window in this workspace (also arrows)
;  Super+J / K        the same (down / up)
;  Super+Q            close the focused window
;  Super+1 .. 4       switch workspace 1..4       (the bar also takes clicks)
;  Super+Shift+1..4   send the focused window to that workspace
;  Super+Shift+Q      leave testland
;
;  The desktop is replaced by a flat dark workspace with a bar at the top:
;  workspace buttons on the left, the focused window title in the middle and
;  the clock on the right.  Windows are tiled one per screen; extra windows
;  in the same workspace live in a tabbed container (tabs under the bar), so
;  the layout never floats and never overlaps.
; =============================================================================

TLD_LEFT  equ 1
TLD_DOWN  equ 2
TLD_UP    equ 3
TLD_RIGHT equ 4

TL_BARH   equ TOPH                  ; bar height (reuses the top surface slot)
TL_TABH   equ 24                    ; tab strip under the bar
TL_OVL    equ 0x2500000             ; transparent full-screen overlay buffer

TL_C_BG   equ 0x0014101C            ; workspace background
TL_C_BAR  equ 0x0020182E            ; bar
TL_C_ON   equ 0x00C86A9A            ; focused workspace / tab
TL_C_BRD  equ 0x00C86A9A            ; focused window border
TL_C_FG   equ 0x00E8E0F0
TL_C_DIM  equ 0x009080A0
TL_C_TAB  equ 0x00161020
TL_C_HDR  equ 0x00261A36
TL_C_CYAN equ 0x005FD7D7
TL_C_PINK equ 0x00C86A9A

; ---- strings (first, so their offsets never depend on code size) ---
s_tl_on      db "testland: tiling session on",10
             db "  Super+Enter terminal        Super+E files     Super+Q close",10
             db "  Super+H/L or arrows         previous / next window",10
             db "  Super+1..4 workspace        Super+Shift+1..4 send window",10
             db "  Super+Shift+Q leaves        testland main = start after login",10,0
s_tl_off     db "testland: back to the desktop",10,0
s_tl_already db "testland is already running",10,0
s_tl_use     db "usage: testland [on|off|main|default]",10,0
s_tl_onw     db "on",0
s_tl_offw    db "off",0
s_tl_mainw   db "main",0
s_tl_defw    db "default",0
s_tl_default db "testland disabled for the next login",10,0
s_tl_pkg     db "testland: package missing",10,0
s_tl_logo    db "CENTTRIX",0
s_tl_ver     db "4.0",0

tl_on     db 0                      ; mode active
tl_ws     dd 1                      ; current workspace
tl_req    db 0                      ; pending action
tl_need   db 0                      ; a new window joined: rearrange
tl_dir    dd 0                      ; pending direction / workspace / task
tl_tag    times NTASK db 0          ; workspace of every task slot
tl_wsel   times 5 db 0              ; active tab (task id) of workspace 1..4
tl_nwin   dd 0                      ; windows on the current workspace
tl_min    db 0xFF                   ; last minute drawn on the bar (0xFF = redraw)
tl_num    db "1",0
tl_list   times NTASK db 0

; ---- key hook: bl = scancode, CF=1 -> the key is consumed by testland --------
tl_key:
    cmp byte [tl_on], 0
    je near .pass
    cmp byte [k_super], 0
    je near .pass
    cmp bl, 0x1C                      ; Enter
    je near .term
    cmp bl, 0x10                      ; Q
    je near .q
    cmp bl, 0x12                      ; E = Files
    je near .files
    cmp bl, 0x23                      ; H
    je near .prev
    cmp bl, 0x26                      ; L
    je near .next
    cmp bl, 0x24                      ; J
    je near .next
    cmp bl, 0x25                      ; K
    je near .prev
    cmp bl, 0x4B                      ; left arrow
    je near .prev
    cmp bl, 0x4D                      ; right arrow
    je near .next
    cmp bl, 0x50                      ; down arrow
    je near .next
    cmp bl, 0x48                      ; up arrow
    je near .prev
    cmp bl, 0x02                      ; 1..4
    jb near .no
    cmp bl, 0x05
    ja near .no
    movzx eax, bl
    sub eax, 1
    mov [tl_dir], eax
    mov byte [tl_req], 10
    cmp byte [k_shift], 0
    je near .yes
    mov byte [tl_req], 20
    stc
    ret
.prev:
    mov dword [tl_dir], -1
    mov byte [tl_req], 11
    jmp .yes
.next:
    mov dword [tl_dir], 1
    mov byte [tl_req], 12
    jmp .yes
.term:
    mov byte [tl_req], 5
    jmp .yes
.files:
    mov byte [tl_req], 8
    jmp .yes
.q:
    cmp byte [k_shift], 0
    je near .cl1
    mov byte [tl_req], 30             ; Super+Shift+Q leaves testland
    jmp .yes
.cl1:
    mov byte [tl_req], 6
    jmp .yes
.yes:
    stc
    ret
.no:
    ; a Super combination that testland does not use still belongs to testland:
    ; otherwise it reaches the desktop and opens the launcher or the panel
    stc
    ret
.pass:
    clc
    ret

; ---- mouse hook: CF=1 -> the click is consumed by testland -------------------
tl_mouse:
    cmp byte [tl_on], 0
    je near .off
    PUSHA
    mov eax, [mx]
    mov ebx, [my]
    cmp ebx, TL_BARH
    jl near .bar
    cmp ebx, TL_BARH+TL_TABH
    jge near .app
    cmp dword [tl_nwin], 1
    jbe near .app
    ; ---- click on a tab
    xor r13d, r13d                    ; x of the next tab
    mov r12d, 1
.t:
    cmp r12d, NTASK
    jae near .app
    mov r8d, r12d
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .tn
    mov eax, [r8+T_SURF]
    cmp eax, SI_WIN0
    jb near .tn
    lea rdi, [tl_tag+r12]
    movzx eax, byte [rdi]
    cmp eax, [tl_ws]
    jne near .tn
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, [r8+T_TITLE]
    test rsi, rsi
    jnz near .tt
    lea rsi, [s_centtrix]
.tt:
    call ui_width
    add eax, 20
    cmp eax, 60
    jae near .tw
    mov eax, 60
.tw:
    mov r14d, eax
    mov eax, [mx]
    cmp eax, r13d
    jl near .tn
    add r13d, r14d
    cmp eax, r13d
    jl near .hit
    cmp r13d, [scr_w]
    jae near .app
.tn:
    inc r12d
    jmp .t
.hit:
    mov [tl_dir], r12d
    mov byte [tl_req], 13
    jmp .yes
    ; ---- click on a workspace button
.bar:
    mov eax, [mx]
    xor edx, edx
    mov ecx, 40
    div ecx
    cmp eax, 4
    jae near .yes                     ; the whole bar belongs to testland
    inc eax
    mov [tl_dir], eax
    mov byte [tl_req], 10
    jmp .yes
    ; ---- the app area: only the content of the focused window gets clicks
.app:
    mov eax, [focus]
    test eax, eax
    jz near .yes
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .yes
    mov r9d, [r8+T_SURF]
    shl r9d, 7
    add r9, SURFS
    mov r10d, [r9+SF_SX]
    add r10d, SMX                     ; content x on screen
    mov r11d, [r9+SF_SY]
    add r11d, SMT                     ; content y on screen
    mov eax, [mx]
    cmp eax, r10d
    jl near .yes
    mov ecx, r10d
    add ecx, WW
    cmp eax, ecx
    jge near .yes
    mov ebx, [my]
    cmp ebx, r11d
    jl near .yes
    mov ecx, r11d
    add ecx, HDRH
    cmp ebx, ecx
    jl near .yes                      ; flat title bar
    mov ecx, r11d
    add ecx, WH
    cmp ebx, ecx
    jl near .no                       ; inside the app content -> deliver
    jmp .yes
.no:
    POPA
    clc
    ret
.yes:
    POPA
    stc
    ret
.off:
    clc
    ret

; ---- service: run pending actions (called on every shell pass) ---------------
tl_service:
    PUSHA
    cmp byte [tl_on], 0
    je near .out
    ; the clock on the bar follows the RTC
    mov al, 2                         ; minutes
    call rtc_get
    cmp al, [tl_min]
    je near .clk
    mov [tl_min], al
    call tl_bar
.clk:
    ; new windows join the current workspace and become its active tab
    mov ecx, 1
.ad:
    cmp ecx, NTASK
    jae near .adx
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .dead
    mov esi, [r8+T_SURF]
    cmp esi, SI_WIN0
    jb near .adn
    lea rdi, [tl_tag+rcx]
    cmp byte [rdi], 0
    jne near .adn
    mov eax, [tl_ws]
    mov [rdi], al
    lea rdi, [tl_wsel+rax]
    mov [rdi], cl
    mov byte [tl_need], 1
    jmp .adn
.dead:
    ; a closed task releases its slot: forget the workspace tag and the tab
    lea rdi, [tl_tag+rcx]
    cmp byte [rdi], 0
    je near .adn
    mov byte [rdi], 0
    mov byte [tl_need], 1
    xor edx, edx
.dw:
    lea rdi, [tl_wsel+rdx]
    cmp byte [rdi], cl
    jne near .dwn
    mov byte [rdi], 0
.dwn:
    inc edx
    cmp edx, 5
    jb near .dw
.adn:
    inc ecx
    jmp .ad
.adx:
    movzx eax, byte [tl_req]
    test eax, eax
    jz near .chk
    mov byte [tl_req], 0
    cmp eax, 1
    je near .focus
    cmp eax, 5
    je near .term
    cmp eax, 6
    je near .close
    cmp eax, 8
    je near .files
    cmp eax, 10
    je near .wsw
    cmp eax, 11
    je near .prev
    cmp eax, 12
    je near .next
    cmp eax, 13
    je near .tabf
    cmp eax, 20
    je near .wss
    cmp eax, 30
    je near .leave
    cmp eax, 40
    je near .enable
    cmp eax, 41
    je near .disable
    jmp .chk
.enable:
    call tl_on_now
    jmp .out
.disable:
    call tl_off
    jmp .out
    ; directional focus (legacy request): left/up = previous, right/down = next
.focus:
    mov eax, [tl_dir]
    cmp eax, TLD_LEFT
    je near .prev
    cmp eax, TLD_UP
    je near .prev
    jmp .next
.prev:
    mov eax, -1
    call tl_tab
    jmp .out
.next:
    mov eax, 1
    call tl_tab
    jmp .out
.term:
    mov dword [launch_req], 2
    jmp .out
.files:
    mov dword [launch_req], 1
    jmp .out
.close:
    call wm_close_focused
    call tl_fixsel
    call tl_arrange
    jmp .out
.wsw:
    mov eax, [tl_dir]
    mov [tl_ws], eax
    call tl_fixsel
    call tl_arrange
    jmp .out
.wss:
    mov eax, [tl_dir]
    call tl_ws_send
    call tl_fixsel
    call tl_arrange
    jmp .out
.tabf:
    mov eax, [tl_dir]
    mov ecx, [tl_ws]
    lea rdi, [tl_wsel+rcx]
    mov [rdi], al
    call tl_arrange
    jmp .out
.leave:
    call tl_off
    jmp .out
.chk:
    cmp byte [tl_need], 0
    je near .out
    mov byte [tl_need], 0
    call tl_arrange
.out:
    POPA
    ret

; ---- workspace selection: keep tl_wsel[ws] on a live window ------------------
tl_fixsel:
    PUSHA
    mov ecx, [tl_ws]
    lea rdi, [tl_wsel+rcx]
    movzx eax, byte [rdi]
    test eax, eax
    jz near .pick
    cmp eax, NTASK
    jae near .pick
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .pick
    lea rsi, [tl_tag+rax]
    movzx edx, byte [rsi]
    movzx esi, byte [tl_ws]
    cmp edx, esi
    je near .out
.pick:
    xor edx, edx
    mov ecx, 1
.l:
    cmp ecx, NTASK
    jae near .got
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .n
    mov eax, [r8+T_SURF]
    cmp eax, SI_WIN0
    jb near .n
    lea rsi, [tl_tag+rcx]
    movzx eax, byte [rsi]
    movzx esi, byte [tl_ws]
    cmp eax, esi
    jne near .n
    mov edx, ecx
    jmp .got
.n: inc ecx
    jmp .l
.got:
    mov ecx, [tl_ws]
    lea rdi, [tl_wsel+rcx]
    mov [rdi], dl
.out:
    POPA
    ret

; ---- arrange the current workspace: one tiled window, tabs for the rest ------
tl_arrange:
    PUSHA
    call anim_finish                 ; settle a pending open animation first
    mov r10d, [tl_ws]
    call tl_fixsel
    lea rdi, [tl_wsel+r10]
    movzx r9d, byte [rdi]             ; active tab (task id)
    xor r11d, r11d                    ; number of windows on this workspace
    xor r13d, r13d                    ; surface of the active window
    mov ecx, 1
.v:
    cmp ecx, NTASK
    jae near .vd
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .vn
    mov esi, [r8+T_SURF]
    cmp esi, SI_WIN0
    jb near .vn
    lea rdi, [tl_tag+rcx]
    movzx eax, byte [rdi]
    cmp eax, r10d
    jne near .hide
    inc r11d
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    cmp ecx, r9d
    jne near .hide
    or dword [r8+SF_FLG], SFF_VIS
    mov r13d, esi
    jmp .vn
.hide:
    mov r8d, esi
    shl r8d, 7
    add r8, SURFS
    and dword [r8+SF_FLG], ~SFF_VIS
.vn:
    inc ecx
    jmp .v
.vd:
    mov [tl_nwin], r11d
    ; tile the active window right under the bar (extra room for the tab strip)
    test r13d, r13d
    jz near .nopos
    mov eax, [scr_w]
    sub eax, WW
    shr eax, 1
    sub eax, SMX
    mov ebx, TOPH+4-SMT
    cmp r11d, 1
    jbe near .pos
    add ebx, TL_TABH
.pos:
    mov esi, r13d
    call win_move_to
.nopos:
    mov eax, r9d
    call focus_set
    call tl_bar
    call damage_all
    POPA
    ret

; ---- tab cycle: eax = -1 / +1 -----------------------------------------------
tl_tab:
    PUSHA
    mov r9d, eax
    mov r10d, [tl_ws]
    xor r11d, r11d                    ; count
    xor esi, esi                      ; position of the current tab
    mov ecx, [tl_ws]
    lea rdi, [tl_wsel+rcx]
    movzx edx, byte [rdi]
    mov ecx, 1
.l:
    cmp ecx, NTASK
    jae near .d
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .n
    mov eax, [r8+T_SURF]
    cmp eax, SI_WIN0
    jb near .n
    lea rdi, [tl_tag+rcx]
    movzx eax, byte [rdi]
    cmp eax, r10d
    jne near .n
    lea rdi, [tl_list+r11]
    mov [rdi], cl
    inc r11d
    cmp ecx, edx
    jne near .n
    mov esi, r11d
    dec esi
.n: inc ecx
    jmp .l
.d:
    test r11d, r11d
    jz near .out
    cmp esi, 0
    jge near .have
    xor esi, esi
.have:
    mov eax, esi
    add eax, r9d
    cmp eax, 0
    jge near .hi
    add eax, r11d
.hi:
    cmp eax, r11d
    jl near .ok
    sub eax, r11d
.ok:
    lea rdi, [tl_list+rax]
    movzx eax, byte [rdi]
    lea rdi, [tl_wsel+r10]
    mov [rdi], al
    call tl_arrange
.out:
    POPA
    ret

; ---- send the focused window to another workspace ---------------------------
tl_ws_send:                         ; eax = workspace
    PUSHA
    mov r9d, eax
    mov ecx, [focus]
    test ecx, ecx
    jz near .o
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .o
    lea rdi, [tl_tag+rcx]
    mov [rdi], r9b
.o:
    POPA
    ret

; ---- the top bar (drawn into the transparent SI_CARD overlay) ----------------
tl_bar:
    PUSHA
    mov esi, SI_CARD
    call gfx_target
    ; clear the whole overlay to fully transparent (0xFF = transparent here)
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, [scr_h]
    mov eax, 0xFF000000
    call rect
    ; bar background
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, TL_BARH
    mov eax, TL_C_BAR
    call rect
    ; workspace buttons
    mov r12d, 1
.ws:
    cmp r12d, 4
    ja near .wsd
    mov ebx, r12d
    dec ebx
    imul ebx, ebx, 40
    add ebx, 4
    mov eax, TL_C_BAR
    cmp r12d, [tl_ws]
    jne near .bg
    mov eax, TL_C_ON
.bg:
    mov ecx, 4
    mov esi, 32
    mov edx, TL_BARH-8
    mov r9d, 7
    call rrect
    mov eax, r12d
    add eax, '0'
    mov [tl_num], al
    lea rax, [font_ui]
    mov [g_uf], rax
    mov eax, TL_C_DIM
    cmp r12d, [tl_ws]
    jne near .fg
    mov eax, 0x00FFFFFF
.fg:
    mov [g_fg], eax
    lea rsi, [tl_num]
    mov ebx, r12d
    dec ebx
    imul ebx, ebx, 40
    add ebx, 20
    mov ecx, 9
    call ui_text_c
    inc r12d
    jmp .ws
.wsd:
    ; logo block after the workspace pills
    lea rax, [font_ui]
    mov [g_uf], rax
    mov dword [g_fg], TL_C_PINK
    lea rsi, [s_tl_logo]
    mov ebx, 170
    mov ecx, 9
    call ui_text
    mov dword [g_fg], TL_C_DIM
    lea rsi, [s_tl_ver]
    mov ebx, 244
    mov ecx, 9
    call ui_text
    ; subtle separator under the bar
    xor ebx, ebx
    mov ecx, TL_BARH-1
    mov esi, [scr_w]
    mov edx, 1
    mov eax, 0x00303030
    call rect
    ; window title in the middle of the bar
    lea rax, [font_ui]
    mov [g_uf], rax
    mov dword [g_fg], TL_C_FG
    call focus_title
    mov ebx, [scr_w]
    shr ebx, 1
    add ebx, 40
    mov ecx, 9
    call ui_text_c
    ; clock on the right
    call clock_text
    lea rax, [font_ui]
    mov [g_uf], rax
    mov dword [g_fg], TL_C_DIM
    mov ebx, [scr_w]
    sub ebx, 12
    mov ecx, 9
    lea rsi, [CLKB]
    call ui_text_r
    ; tab strip (only when the workspace has more than one window)
    cmp dword [tl_nwin], 1
    jbe near .ntab
    xor ebx, ebx
    mov ecx, TL_BARH
    mov esi, [scr_w]
    mov edx, TL_TABH
    mov eax, TL_C_TAB
    call rect
    xor r13d, r13d
    mov r12d, 1
.tb:
    cmp r12d, NTASK
    jae near .ntab
    mov r8d, r12d
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .tbn
    mov eax, [r8+T_SURF]
    cmp eax, SI_WIN0
    jb near .tbn
    lea rdi, [tl_tag+r12]
    movzx eax, byte [rdi]
    cmp eax, [tl_ws]
    jne near .tbn
    lea rax, [font_ui]
    mov [g_uf], rax
    mov rsi, [r8+T_TITLE]
    test rsi, rsi
    jnz near .ttl
    lea rsi, [s_centtrix]
.ttl:
    call ui_width
    add eax, 20
    cmp eax, 60
    jae near .tw
    mov eax, 60
.tw:
    mov r14d, eax
    mov eax, TL_C_TAB
    cmp r12d, [focus]
    jne near .tbg
    mov eax, TL_C_ON
.tbg:
    mov ebx, r13d
    mov ecx, TL_BARH
    mov esi, r14d
    mov edx, TL_TABH
    call rect
    ; rect used esi for the width, so fetch the title again
    mov rsi, [r8+T_TITLE]
    test rsi, rsi
    jnz near .ttl2
    lea rsi, [s_centtrix]
.ttl2:
    mov eax, TL_C_DIM
    cmp r12d, [focus]
    jne near .tfg
    mov eax, 0x00FFFFFF
.tfg:
    mov [g_fg], eax
    lea rax, [font_ui]
    mov [g_uf], rax
    mov ebx, r13d
    add ebx, 10
    mov ecx, TL_BARH+5
    call ui_text
    add r13d, r14d
    cmp r13d, [scr_w]
    jae near .ntab
.tbn:
    inc r12d
    jmp .tb
.ntab:
    ; flat title bar over the focused window + its border
    call tl_decore
    POPA
    ret

; ---- window decor: border and a flat title bar over the app chrome ----------
tl_decore:
    PUSHA
    mov eax, [focus]
    test eax, eax
    jz near .o
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .o
    ; the window draws into a virtual box: WX/WY are virtual, the screen
    ; position comes from the surface, so read the real content box from it
    mov r9d, [r8+T_SURF]
    shl r9d, 7
    add r9, SURFS
    mov r10d, [r9+SF_SX]
    add r10d, SMX                     ; content x on screen
    mov r11d, [r9+SF_SY]
    add r11d, SMT                     ; content y on screen
    ; border (2 px) around the content box
    mov ebx, r10d
    sub ebx, 2
    mov ecx, r11d
    sub ecx, 2
    mov esi, WW+4
    mov edx, 2
    mov eax, TL_C_BRD
    call rect
    mov ebx, r10d
    sub ebx, 2
    mov ecx, r11d
    add ecx, WH
    mov esi, WW+4
    mov edx, 2
    mov eax, TL_C_BRD
    call rect
    mov ebx, r10d
    sub ebx, 2
    mov ecx, r11d
    sub ecx, 2
    mov esi, 2
    mov edx, WH+4
    mov eax, TL_C_BRD
    call rect
    mov ebx, r10d
    add ebx, WW
    mov ecx, r11d
    sub ecx, 2
    mov esi, 2
    mov edx, WH+4
    mov eax, TL_C_BRD
    call rect
    ; flat title bar replaces the stock window header
    mov ebx, r10d
    mov ecx, r11d
    mov esi, WW
    mov edx, HDRH
    mov eax, TL_C_HDR
    call rect
    ; cyan underline separates the flat title bar from the application
    mov ebx, r10d
    mov ecx, r11d
    add ecx, HDRH-1
    mov esi, WW
    mov edx, 1
    mov eax, TL_C_CYAN
    call rect
    lea rax, [font_ui]
    mov [g_uf], rax
    mov dword [g_fg], TL_C_FG
    call focus_title
    mov ebx, r10d
    add ebx, 12
    mov ecx, r11d
    add ecx, 13
    call ui_text
.o:
    POPA
    ret

; ---- enable / disable --------------------------------------------------------
tl_on_now:
    mov byte [tl_on], 1
    mov dword [tl_ws], 1
    mov byte [tl_req], 0
    mov byte [tl_need], 0
    mov byte [tl_min], 0xFF
    push rax
    push rcx
    call pm_close
    xor ecx, ecx
.z:
    mov byte [tl_tag+rcx], 0
    inc ecx
    cmp ecx, NTASK
    jb near .z
    xor ecx, ecx
.zw:
    mov byte [tl_wsel+rcx], 0
    inc ecx
    cmp ecx, 5
    jb near .zw
    ; existing windows belong to workspace 1, free slots stay tagged 0 so
    ; tl_service can recognise tasks that appear later
    mov ecx, 1
.e:
    cmp ecx, NTASK
    jae near .ed
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .en
    mov eax, [r8+T_SURF]
    cmp eax, SI_WIN0
    jb near .en
    mov byte [tl_tag+rcx], 1
    lea rdi, [tl_wsel+1]
    mov [rdi], cl
.en:
    inc ecx
    jmp .e
.ed:
    ; the desktop chrome goes away
    and dword [SURFS+SI_DOCK*SURF_SZ+SF_FLG], ~SFF_VIS
    and dword [SURFS+SI_TOP*SURF_SZ+SF_FLG], ~SFF_VIS
    ; full-screen transparent overlay for the bar, tabs and borders
    mov esi, SI_CARD
    mov eax, [scr_w]
    mov edx, [scr_h]
    xor ebx, ebx
    xor ecx, ecx
    mov rdi, TL_OVL
    call surf_setup
    ; flat dark workspace
    mov esi, SI_BASE
    call gfx_target
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, [scr_h]
    mov eax, TL_C_BG
    call rect
    ; depth bands and the accent rails from the reference layout
    xor ebx, ebx
    xor ecx, ecx
    mov esi, [scr_w]
    mov edx, [scr_h]
    shr edx, 2
    mov eax, 0x001A142A
    call rect
    xor ebx, ebx
    mov ecx, [scr_h]
    shr ecx, 1
    mov esi, [scr_w]
    mov edx, [scr_h]
    sub edx, ecx
    mov eax, 0x00100C16
    call rect
    xor ebx, ebx
    xor ecx, ecx
    mov esi, 3
    mov edx, [scr_h]
    mov eax, TL_C_PINK
    call rect
    xor ebx, ebx
    mov ecx, [scr_h]
    sub ecx, 3
    mov esi, [scr_w]
    mov edx, 3
    mov eax, TL_C_CYAN
    call rect
    call tl_arrange
    call damage_all
    pop rcx
    pop rax
    ret

tl_off:
    mov byte [tl_on], 0
    mov byte [tl_req], 0
    mov byte [tl_need], 0
    PUSHA
    ; drop the overlay, bring the desktop chrome back
    and dword [SURFS+SI_CARD*SURF_SZ+SF_FLG], ~SFF_VIS
    or dword [SURFS+SI_TOP*SURF_SZ+SF_FLG], SFF_VIS
    call top_draw
    call dock_build
    call desk_draw
    ; every window is visible again
    mov ecx, 1
.l:
    cmp ecx, NTASK
    jae near .d
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .n
    mov r8d, [r8+T_SURF]
    shl r8d, 7
    add r8, SURFS
    or dword [r8+SF_FLG], SFF_VIS
.n:
    inc ecx
    jmp .l
.d:
    ; leave a live window focused (the dock and the bar come back)
    mov eax, [focus]
    test eax, eax
    jz near .pick
    mov r8d, eax
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    je near .hav
.pick:
    mov ecx, 1
.pf:
    cmp ecx, NTASK
    jae near .hav
    mov r8d, ecx
    shl r8d, 7
    add r8, TASKS
    cmp dword [r8+T_STATE], 1
    jne near .pn
    mov eax, ecx
    call focus_set
    jmp .hav
.pn:
    inc ecx
    jmp .pf
.hav:
    call top_task
    call damage_all
    POPA
    ret

; ---- terminal command: testland [off] ---------------------------------------
tl_cmd:                             ; rsi = arguments
    push rsi
    cmp byte [rsi], 0
    je near .on
    push rsi
    lea rdi, [s_tl_offw]
    call strcmp
    pop rsi
    je near .off
    push rsi
    lea rdi, [s_tl_onw]
    call strcmp
    pop rsi
    je near .on
    push rsi
    lea rdi, [s_tl_mainw]
    call strcmp
    pop rsi
    je near .main
    push rsi
    lea rdi, [s_tl_defw]
    call strcmp
    pop rsi
    je near .default
    lea rsi, [s_tl_use]
    call tput_s
    pop rsi
    ret
.main:
    pop rsi
    call sys_tl_installed
    test eax, eax
    jz near .missing
    lea rsi, [p_etc_session]
    lea rdx, [s_sess_tl]
    mov ecx, 17
    call sys_write_file
    mov byte [tl_on], 1
    mov dword [tl_ws], 1
    mov byte [tl_req], 40
    lea rsi, [s_tl_main]
    call tput_s
    ret
.default:
    pop rsi
    lea rsi, [p_etc_session]
    lea rdx, [s_sess_dt]
    mov ecx, 16
    call sys_write_file
    cmp byte [tl_on], 0
    je .defdone
    mov byte [tl_req], 41
.defdone:
    lea rsi, [s_tl_default]
    call tput_s
    ret
.on:
    pop rsi
    cmp byte [tl_on], 0
    jne near .already
    call sys_tl_installed
    test eax, eax
    jz near .missing
    lea rsi, [p_tl_pkg]
    call fs_find
    test rax, rax
    jz near .missing
    call native_run_slot
    ret
.missing:
    lea rsi, [s_tl_missing]
    call tput_s
    ret
.already:
    lea rsi, [s_tl_already]
    call tput_s
    ret
.off:
    pop rsi
    cmp byte [tl_on], 0
    je near .already
    mov byte [tl_req], 41
    lea rsi, [s_tl_off]
    call tput_s
    ret
