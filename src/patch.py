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

inc = '%include "anim.inc"\n%include "' + ('bigfs_stub.inc' if lite else 'bigfs.inc') + '"\n%include "download.inc"\n%include "cntfs.inc"\n%include "testland.inc"\n%include "installer.inc"\n\n'
i = t.rfind("times ((4096-((31744")
if i < 0 or t.find("times (KSECT+1)*512", i) < 0:
    sys.exit("end-of-image anchor not found")
end = t.find("\n", i)
if end < 0:
    sys.exit("unterminated end-of-image padding")
t = t[:i] + inc + t[end+1:]


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
    '    db "testland  tiling window manager (Super+1..4 workspaces, off = stop)",10\n',
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

rep('c_testland db "testland",0\n',
    'c_testland db "testland",0\nc_setup    db "setup",0\n',
    "setup command name")
rep("    CMD c_testland, .testland\n    lea rsi, [s_unk]\n",
    "    CMD c_testland, .testland\n    CMD c_setup, .setup\n    lea rsi, [s_unk]\n",
    "setup command")
rep(".testland:\n    mov rsi, r14\n    call tl_cmd\n    jmp .out\n",
    ".testland:\n    mov rsi, r14\n    call tl_cmd\n    jmp .out\n"
    ".setup:\n    mov dword [launch_req], 9\n    lea rsi, [s_setup_run]\n    call tput_s\n    jmp .out\n",
    "setup handler")
rep('    db "testland  tiling window manager (Super+1..4 workspaces, off = stop)",10\n',
    '    db "testland  tiling window manager (Super+1..4 workspaces, off = stop)",10\n'
    '    db "setup     graphical installer: copy Centtrix to another disk",10\n',
    "setup help")
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

open(dst, "w", encoding="utf-8", errors="surrogateescape").write(t)
print("patch v3 (bigfs buffers in RAM%s) ->" % (", LITE: no bigfs" if lite else ""), dst)
