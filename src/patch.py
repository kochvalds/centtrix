#!/usr/bin/env python3
"""Apply the Centtrix upgrade to centtrix.asm.
usage: python3 patch.py centtrix.asm [out.asm]
Every anchor must match exactly once, otherwise nothing is written."""
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
lite = "--lite" in sys.argv
src = args[0]
dst = args[1] if len(args) > 1 else src.replace(".asm", "_plus.asm")
t = open(src, encoding="utf-8", errors="surrogateescape").read()

def rep(old, new, label):
    global t
    n = t.count(old)
    if n != 1:
        sys.exit(f"ANCHOR '{label}' matched {n} times (need 1) - file differs from the expected version")
    t = t.replace(old, new)

rep("    inc dword [ntasks]\n    mov eax, r13d\n    call focus_set\n    mov eax, r13d\n.out:\n",
    "    inc dword [ntasks]\n    lea esi, [r13+SI_WIN0-1]\n    call anim_open_start\n    mov eax, r13d\n    call focus_set\n    mov eax, r13d\n.out:\n",
    "spawn tail")
rep("    cmp esi, 0\n    jle .nosurf\n    call surf_damage\n    call z_remove\n",
    "    cmp esi, 0\n    jle .nosurf\n    call anim_close\n    call surf_damage\n    call z_remove\n",
    "task_free")
rep("    add r8, SURFS\n    and dword [r8+SF_FLG], ~SFF_VIS\n    call surf_damage\n    call top_task\n",
    "    add r8, SURFS\n    call anim_min\n    and dword [r8+SF_FLG], ~SFF_VIS\n    call surf_damage\n    call top_task\n",
    "wm_min_focused")
rep(".done:\n    call wm_flush\n    pop rax\n    ret\n",
    ".done:\n    call anim_tick\n    call wm_flush\n    pop rax\n    ret\n",
    "wm_service")

rep("    CMD c_py, .py\n    lea rsi, [s_unk]\n",
    "    CMD c_py, .py\n    CMD c_wget, .wget\n    CMD c_curl, .wget\n    CMD c_bigfs, .bigfs\n    lea rsi, [s_unk]\n",
    "term commands")
rep(".py:\n    call term_python\n    jmp .out\n",
    ".wget:\n    mov rsi, r14\n    call term_wget\n    jmp .out\n.bigfs:\n    mov rsi, r14\n    call term_bigfs\n    jmp .out\n.py:\n    call term_python\n    jmp .out\n",
    "term handlers")
rep('c_install  db "install",0\n',
    'c_install  db "install",0\nc_wget     db "wget",0\nc_curl     db "curl",0\nc_bigfs    db "bigfs",0\n',
    "command names")
rep('    db "disk    install (copy Centtrix to another disk)  battery  biossave",10\n',
    '    db "disk    install (copy Centtrix to another disk)  battery  biossave  df",10\n    db "wget    wget URL [name] download a file     bigfs  big-file store (bigfs info)",10\n',
    "help text")
rep("    cmp al, 'r'\n    je .reload\n    jmp .k\n.exit:\n",
    "    cmp al, 'r'\n    je .reload\n    cmp al, 's'\n    je .save\n    jmp .k\n.save:\n    call br_download\n    jmp .draw\n.exit:\n",
    "browser key s")
rep("\n.body:\n    ; destination slot\n",
    "\n.body:\n    cmp byte [http_dl], 0\n    je .dlno\n    mov byte [http_class], 2          ; downloads: keep the raw body\n.dlno:\n    ; destination slot\n",
    "http_parse body")

rep('Backspace back, Esc close", 0', 'Backspace back, s save file, Esc close", 0', "browser hint")

inc = '%include "anim.inc"\n%include "' + ('bigfs_stub.inc' if lite else 'bigfs.inc') + '"\n%include "download.inc"\n%include "cntfs.inc"\n%include "testland.inc"\n%include "installer.inc"\n%include "pkg.inc"\n%include "sys.inc"\n\n'
i = t.rfind("times ((4096-((31744")
if i < 0 or t.find("times (KSECT+1)*512", i) < 0:
    sys.exit("end-of-image anchor not found")
end = t.find("\n", i)
if end < 0:
    sys.exit("unterminated end-of-image padding")
t = t[:i] + inc.replace('%include "pkg.inc"\n', '%include "pkg.inc"\n%include "isomode.inc"\n%include "native.inc"\n') + t[end+1:]


rep("    CMD c_bigfs, .bigfs\n    lea rsi, [s_unk]\n",
    "    CMD c_bigfs, .bigfs\n    CMD c_testland, .testland\n    lea rsi, [s_unk]\n",
    "testland command")
rep(".py:\n    call term_python\n    jmp .out\n",
    ".testland:\n    mov rsi, r14\n    call tl_cmd\n    jmp .out\n.py:\n    call term_python\n    jmp .out\n",
    "testland handler")
rep('c_bigfs    db "bigfs",0\n',
    'c_bigfs    db "bigfs",0\nc_testland db "testland",0\n',
    "testland command name")
rep('    db "disk    install (copy Centtrix to another disk)  battery  biossave  df",10\n',
    '    db "disk    install (copy Centtrix to another disk)  battery  biossave  df",10\n'
    '    db "testland  tiling WM: testland on|off|main|default (Super+1..4)",10\n',
    "testland help")
rep(".su_x:\n    mov byte [su_req], 1\n    jmp .out\n.su_c:\n    mov byte [su_req], 2\n    jmp .out\n",
    ".su_x:\n    cmp byte [tl_on], 0\n    jne .out\n    mov byte [su_req], 1\n    jmp .out\n"
    ".su_c:\n    cmp byte [tl_on], 0\n    jne .out\n    mov byte [su_req], 2\n    jmp .out\n",
    "testland super keys")
rep("    cmp bl, 0x2E\n    je .su_c\n.nosu:\n",
    "    cmp bl, 0x2E\n    je .su_c\n.nosu:\n    call tl_key\n    jc .out\n",
    "testland keys")
rep(".ext:\n    cmp bl, 0x5B\n",
    ".ext:\n    call tl_key\n    jc .out\n    cmp bl, 0x5B\n",
    "testland arrow keys")
rep("    call ex_super\n    call ex_keys\n",
    "    call ex_super\n    call tl_service\n    call ex_keys\n",
    "testland service")
rep("mouse_press:\n    push rax\n    push rbx\n",
    "mouse_press:\n    call tl_mouse\n    jc .tlret\n    push rax\n    push rbx\n",
    "testland mouse")
rep("    pop rax\n    ret\n\n; ---- window helpers",
    "    pop rax\n    ret\n.tlret:\n    ret\n\n; ---- window helpers",
    "testland mouse ret")

rep("    mov r15, r14\n    mov rsi, r14\n.g: mov al, [rsi]\n",
    "    mov rsi, rbx\n    lea rdi, [c_pkg]\n    call strcmp\n    jne .nopkgfull\n"
    "    mov rsi, r14\n    call term_pkg\n    jmp .out\n.nopkgfull:\n"
    "    mov r15, r14\n    mov rsi, r14\n.g: mov al, [rsi]\n",
    "cenpkg full args")
rep('c_testland db "testland",0\n',
    'c_testland db "testland",0\nc_setup    db "setup",0\nc_pkg      db "cenpkg",0\n',
    "setup command name")
rep("    CMD c_testland, .testland\n    lea rsi, [s_unk]\n",
    "    CMD c_testland, .testland\n    CMD c_setup, .setup\n    CMD c_pkg, .pkg\n"
    "    CMD c_uname, .uname\n    CMD c_hostname, .hostname\n"
    "    CMD c_usb, .usb\n    CMD c_sysinfo, .sysinfo\n    lea rsi, [s_unk]\n",
    "setup command")
rep(".testland:\n    mov rsi, r14\n    call tl_cmd\n    jmp .out\n",
    ".testland:\n    mov rsi, r14\n    call tl_cmd\n    jmp .out\n"
    ".uname:\n    call term_uname\n    jmp .out\n"
    ".hostname:\n    call term_hostname\n    jmp .out\n"
    ".usb:\n    call term_usb\n    jmp .out\n"
    ".sysinfo:\n    call term_sysinfo\n    jmp .out\n"
    ".setup:\n    mov dword [launch_req], 9\n    lea rsi, [s_setup_run]\n    call tput_s\n    jmp .out\n"
    ".pkg:\n    mov rsi, r14\n    call term_pkg\n    jmp .out\n",
    "setup handler")
rep('    db "testland  tiling WM: testland on|off|main|default (Super+1..4)",10\n',
    '    db "testland  tiling WM: testland on|off|main|default (Super+1..4)",10\n'
    '    db "setup     graphical installer: copy Centtrix to another disk",10\n'
    '    db "cenpkg    packages: cenpkg list, cenpkg install NAME, cenpkg remove NAME",10\n'
    '    db "system    uname  hostname  sysinfo  usb (firmware disks and USB media)",10\n',
    "setup help")
rep('s_help       db "files   ls [dir]  cd dir  cat f  edit f  new f  run f.xep  rm f  cp a b  mv a b  mkdir d  empty",10\n',
    's_help       db "files   ls [dir]  cd dir  cat f  edit f  new f  run f(.c .py .rs .xep)  rm f  cp a b  mv a b",10\n',
    "files help")
rep('s_ver        db "Centtrix OS 4.0  x86_64  |  XPL 1.0",10,0\n',
    's_ver        db "Centtrix 4.0  x86_64  |  CNT3  |  XPL 1.0  |  C, Python, Rust",10,0\n',
    "version line")
rep('s_ps1        db "centtrix:",0\n',
    's_ps1        db "centtrix@centtrix:",0\n',
    "shell prompt")
rep('s_rootls     db "base/",10,"dump/",10,"home/",10,0\n',
    's_rootls     db "base/",10,"dump/",10,"etc/",10,"home/",10,"opt/",10,"tmp/",10,"usr/",10,"var/",10,0\n',
    "root listing")

rep(""".lsz:
    mov eax, [r13+48]
    mov rdi, TMPB
""",
""".lsz:
    mov rsi, r13
    call fs_find
    test rax, rax
    jz .lsz0
    mov eax, [rax+48]
    jmp .lsz1
.lsz0:
    xor eax, eax
.lsz1:
    mov rdi, TMPB
""",
    "ls size")

rep("""term_prompt:
    lea rsi, [s_ps1]
    call tput_s
    lea rsi, [tpath]
    call tput_s
    lea rsi, [s_ps2]
    call tput_s
    mov eax, [t_col]
    mov [t_pstart], eax
    mov dword [t_inlen], 0
    ret
""",
"""term_prompt:
    lea rsi, [SB_USER]
    cmp byte [rsi], 0
    jne .u
    lea rsi, [s_user_def]
.u: call tput_s
    mov al, '@'
    call tput_c
    lea rsi, [p_etc_hostname]
    call sys_read_small
    test eax, eax
    jz .hdef
    lea rsi, [sess_buf]
    call tput_s
    jmp .h
.hdef:
    lea rsi, [s_hostname]
    call tput_s
.h: mov al, ':'
    call tput_c
    lea rsi, [tpath]
    call tput_s
    lea rsi, [s_ps2]
    call tput_s
    mov eax, [t_col]
    mov [t_pstart], eax
    mov dword [t_inlen], 0
    ret
""",
    "dynamic prompt")


rep("    call desk_draw\n    call login_screen\n.idle:\n",
    "    call desk_draw\n    call login_screen\n    call session_apply\n.idle:\n",
    "session apply")


rep("    dq app_settings\n    dd 7, 0\n    dq s_set_t\n",
    "    dq app_settings\n    dd 7, 0\n    dq s_set_t\n"
    "    dq app_settings\n    dd 10, 0\n    dq s_set_t\n"
    "    dq app_setup\n    dd 9, 0\n    dq s_setup_t\n",
    "setup app")
rep("bw1:                                 ; eax = LBA, rsi = source (advances)\n"
    "    push rax\n    push rcx\n    push rdx\n    movzx edx, byte [bootdrv]\n",
    "bw1:                                 ; eax = LBA, rsi = source (advances)\n"
    "    push rax\n    push rcx\n    push rdx\n    movzx edx, byte [fs_tgt]\n",
    "bios write target")

rep("FS_LBA      equ 896                 ; filesystem superblock\n",
    "FS_LBA      equ 896                 ; filesystem superblock\n"
    "BOOT_ISO    equ 0x1B0\nBOOT_MENU   equ 0x1B1\nBOOT_PART   equ 0x1B2\n",
    "boot flags")
rep("    mov [bootdrv], dl\n    mov si, KSECT\n    mov dword [dap_lba], 1\n",
    "    mov [bootdrv], dl\n"
    "    cmp byte [boot+BOOT_MENU], 0\n"
    "    je .nomenu\n"
    "    call boot_menu\n"
    ".nomenu:\n"
    "    mov si, KSECT\n"
    "    mov eax, [boot+BOOT_PART]\n"
    "    mov [dap_lba], eax\n"
    "    mov eax, [boot+BOOT_PART+4]\n"
    "    mov [dap_lba+4], eax\n"
    "    add dword [dap_lba], 1\n"
    "    adc dword [dap_lba+4], 0\n",
    "stage1 offset and menu")
rep("bootdrv db 0\n", "bootdrv db 0\n%include \"bootmenu.inc\"\ntimes 0x1A0-($-$$) db 0\n", "boot menu code")
rep("dap_lba: dq 0\n\ntimes 510-($-$$) db 0\n", "dap_lba: dq 0\n\ntimes 0x1B0-($-$$) db 0\ndb 0, 0\ndd 0\n\ntimes 510-($-$$) db 0\n", "boot flags area")
rep("    ; requested resolution: read the superblock sector, fall back to 1024x768\n    mov dword [dap_lba], FS_LBA\n",
    "    ; requested resolution: read the superblock sector, fall back to 1024x768\n"
    "    mov eax, [boot+BOOT_PART]\n    add eax, FS_LBA\n    mov [dap_lba], eax\n"
    "    mov eax, [boot+BOOT_PART+4]\n    adc eax, 0\n    mov [dap_lba+4], eax\n",
    "stage2 superblock offset")
rep("fs_preload:\n    mov dword [bi_fsok], 0\n    mov dword [dap_lba], FS_LBA\n",
    "fs_preload:\n    mov dword [bi_fsok], 0\n"
    "    mov eax, [boot+BOOT_PART]\n    add eax, FS_LBA\n    mov [dap_lba], eax\n"
    "    mov eax, [boot+BOOT_PART+4]\n    adc eax, 0\n    mov [dap_lba+4], eax\n",
    "preload offset")
rep("bios_rd:\n    push rax\n    push rbx\n    push rcx\n    push rsi\n",
    "bios_rd:\n    push rax\n    push rbx\n    push rcx\n    push rsi\n    add eax, [boot+BOOT_PART]\n",
    "bios read offset")
rep("bios_wr:\n    push rax\n    push rbx\n    push rcx\n    push rdi\n",
    "bios_wr:\n    push rax\n    push rbx\n    push rcx\n    push rdi\n    add eax, [boot+BOOT_PART]\n",
    "bios write offset")
rep("launch_app:\n    PUSHA\n",
    "launch_app:\n"
    "    cmp byte [boot+BOOT_ISO], 0\n    je .lapp_ok\n"
    "    cmp eax, 8\n    je .lapp_ok\n    mov eax, 8\n.lapp_ok:\n    PUSHA\n",
    "iso launch guard")
rep("    call desk_draw\n    call login_screen\n",
    "    call desk_draw\n    call iso_gate\n    call login_screen\n",
    "iso gate")

rep("ata_read1:                          ; eax=LBA rdi=dest (advances) ; keeps eax\n    cmp byte [ata_ok], 0\n    je .skip\n    push rax\n    push rbx\n    push rcx\n    push rdx\n    mov ebx, eax\n",
    "ata_read1:                          ; eax=LBA rdi=dest (advances) ; keeps eax\n    cmp byte [ata_ok], 0\n    je .skip\n    push rax\n    push rbx\n    push rcx\n    push rdx\n    mov ebx, eax\n    add ebx, [boot+BOOT_PART]\n    mov eax, ebx\n",
    "ata read partition base")
rep("ata_write1:                         ; eax=LBA rsi=src (advances) ; keeps eax\n    cmp byte [ata_ok], 0\n    je .alt\n    push rax\n    push rbx\n    push rcx\n    push rdx\n    mov ebx, eax\n",
    "ata_write1:                         ; eax=LBA rsi=src (advances) ; keeps eax\n    cmp byte [ata_ok], 0\n    je .alt\n    push rax\n    push rbx\n    push rcx\n    push rdx\n    mov ebx, eax\n    add ebx, [boot+BOOT_PART]\n    mov eax, ebx\n",
    "ata write partition base")

rep("launch_slot:                        ; rax = slot\n    push rbx\n    push rsi\n    mov rbx, rax\n    mov rsi, rax\n    call ext4\n    cmp eax, 0x7065782E\n    je .xep\n",
    "launch_slot:                        ; rax = slot\n    push rbx\n    push rsi\n    mov rbx, rax\n    mov rsi, rax\n    call ext4\n    cmp eax, 0x6E69622E\n    je .bin\n    cmp eax, 0x7065782E\n    je .xep\n",
    "launch slot bin")
rep(".xep:\n    mov rax, rbx\n    call run_slot\n    jmp .o\n",
    ".bin:\n    mov rax, rbx\n    call native_run_slot\n    jmp .o\n.xep:\n    mov rax, rbx\n    call run_slot\n    jmp .o\n",
    "launch slot bin call")
rep("""    mov eax, [f_sel]
    mov rbx, [ITEMS+rax*8]
    mov rsi, rbx
    call is_xep
    test eax, eax
    jz .key
""",
"""    mov eax, [f_sel]
    mov rbx, [ITEMS+rax*8]
    mov rsi, rbx
    call is_bin
    test eax, eax
    jz .ibx
    mov rsi, rbx
    call fs_find
    test rax, rax
    jz .refresh
    call native_run_slot
    lea rsi, [s_files_t]
    call draw_win
    jmp .refresh
.ibx:
    mov rsi, rbx
    call is_xep
    test eax, eax
    jz .key
""",
    "files run bin")
rep("""    mov r13, rax
    mov rsi, rax
    call is_xep
    test eax, eax
    jz .notxep
""",
"""    mov r13, rax
    mov rsi, rax
    call is_bin
    test eax, eax
    jz .ixb
    mov rax, r13
    call native_run_slot
    call term_redraw
    jmp .out
.ixb:
    mov rsi, r13
    call is_py
    test eax, eax
    jz .ipy
    mov rsi, r15
    call term_python
    call term_redraw
    jmp .out
.ipy:
    mov rsi, r13
    call is_xep
    test eax, eax
    jz .notxep
""",
    "term run bin")
rep("""is_xep:                             ; rsi=name -> eax=1 if ends with .xep
""",
"""is_bin:                             ; rsi=name -> eax=1 if ends with .bin/.c/.rs
    push rsi
    push rcx
    call strlen
    xor ecx, ecx
    cmp eax, 2
    jb .no
    cmp word [rsi+rax-2], 0x632E
    je .yes
    cmp eax, 3
    jb .no
    cmp word [rsi+rax-2], 0x7372
    jne .bin
    cmp byte [rsi+rax-3], '.'
    je .yes
.bin:
    cmp eax, 4
    jb .no
    cmp dword [rsi+rax-4], 0x6E69622E
    jne .no
.yes:
    mov ecx, 1
.no:
    mov eax, ecx
    pop rcx
    pop rsi
    ret

is_xep:                             ; rsi=name -> eax=1 if ends with .xep
""",
    "is_bin")

open(dst, "w", encoding="utf-8", errors="surrogateescape").write(t)
print("patch v3 (bigfs buffers in RAM%s) ->" % (", LITE: no bigfs" if lite else ""), dst)
