; =============================================================================
;  SYSTEM LAYOUT, CONFIG FILES AND SMALL SYSTEM COMMANDS
; =============================================================================

p_etc          db "/etc/",0
p_etc_hostname db "/etc/hostname",0
p_etc_release  db "/etc/os-release",0
p_etc_session  db "/etc/session.conf",0
p_etc_system   db "/etc/system.conf",0
p_etc_network  db "/etc/network.conf",0
p_etc_fstab    db "/etc/fstab",0
p_etc_motd     db "/etc/motd",0
p_usr          db "/usr/",0
p_usr_bin      db "/usr/bin/",0
p_usr_share    db "/usr/share/",0
p_var          db "/var/",0
p_var_log      db "/var/log/",0
p_tmp          db "/tmp/",0
p_opt          db "/opt/",0
p_src          db "/home/src/",0
p_src_c        db "/home/src/hello.c",0
p_src_rs       db "/home/src/hello.rs",0
p_src_py       db "/home/src/hello.py",0
p_src_conf     db "/home/src/example.conf",0
p_tl_pkg       db "/home/pkg/testland.rs",0
p_pkg_cache    db "/base/pkg/",0

d_nil          db 0
d_etc_hostname db "centtrix",0
d_etc_release  db "NAME=Centtrix",10,"VERSION=4.0",10,"ID=centtrix",10,"PRETTY_NAME=Centtrix 4.0",10,"HOME_URL=https://github.com/kochvalds/centtrix",10,0
d_etc_session  db "session=desktop",10,0
d_etc_system   db "hostname=centtrix",10,"theme=midnight",10,"resolution=1024x768",10,"timezone=local",10,0
d_etc_network  db "interface=ethernet",10,"dhcp=on",10,"dns=automatic",10,0
d_etc_fstab    db "/dev/ata0 / cnt3 defaults 0 0",10,"tmpfs /tmp ram defaults 0 0",10,0
d_etc_motd     db "Centtrix 4.0",10,"System files live in /etc, programs in /usr, your work in /home.",10,"Type help for the command list.",10,0
d_src_c        db "#include <centtrix.h>",10,10,"int main(void)",10,"{",10,`    print("Hello from C!\n");`,10,"    return 0;",10,"}",10,0
d_src_rs       db "#![no_std]",10,"#![no_main]",10,10,"use centtrix::*;",10,10,"#[no_mangle]",10,`pub extern "C" fn _start(api: &Api) -> !`,10,"{",10,`    api.print("Hello from Rust!\n");`,10,"    api.exits();",10,"    loop {}",10,"}",10,0
d_src_py       db "# Centtrix Python sample",10,"print('Hello from Python!')",10,"for n in range(1, 6):",10,"    print('line', n)",10,0
d_src_conf     db "# Example configuration: edit and reboot",10,"hostname=centtrix",10,"theme=midnight",10,"session=desktop",10,0

s_uname        db "Centtrix 4.0 x86_64 CNT3",10,0
s_host_pre     db "hostname: ",0
s_hostname     db "centtrix",0
s_user_def     db "user",0
s_usb_head     db "Disks and USB media reported by the firmware:",10,0
s_usb_boot     db "  (boot medium)",10,0
s_usb_hint     db "Use 'install' to write Centtrix to a disk or USB stick.",10,0
s_sess_tl      db "session=testland",10,0
s_sess_dt      db "session=desktop",10,0
s_sess_saved   db "session saved: ",0
s_tl_missing   db "testland is not installed - run: cenpkg install testland",10,0
s_tl_main      db "testland will start after login",10,0

sess_buf       times 512 db 0
sess_word      db "testland",0
sess_n         dd 0

c_uname        db "uname",0
c_hostname     db "hostname",0
c_usb          db "usb",0
c_sysinfo      db "sysinfo",0

is_py:
    push rsi
    push rcx
    call strlen
    xor ecx, ecx
    cmp eax, 3
    jb .no
    cmp word [rsi+rax-2], 0x7970
    jne .no
    cmp byte [rsi+rax-3], '.'
    jne .no
    mov ecx, 1
.no:
    mov eax, ecx
    pop rcx
    pop rsi
    ret

sys_write_file:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov r8, rsi
    mov r9, rdx
    mov r10d, ecx
    mov rsi, r8
    mov rdx, r9
    mov ecx, r10d
    call fs3_bigsave
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

sys_read_small:
    push rsi
    push rdi
    push rcx
    lea rdi, [sess_buf]
    call fs_find
    test rax, rax
    jz .no
    mov ecx, [rax+48]
    cmp ecx, 511
    jbe .got
    mov ecx, 511
.got:
    lea rsi, [rax+64]
    rep movsb
    mov byte [rdi], 0
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

session_apply:
    PUSHA
    lea rsi, [p_etc_session]
    call sys_read_small
    test eax, eax
    jz .out
    lea rsi, [sess_buf]
.scan:
    mov al, [rsi]
    test al, al
    jz .out
    cmp al, 't'
    jne .next
    lea rdi, [sess_word]
    mov rdx, rsi
.cmp:
    mov al, [rdi]
    test al, al
    jz .found
    cmp al, [rdx]
    jne .next
    inc rdi
    inc rdx
    jmp .cmp
.next:
    inc rsi
    jmp .scan
.found:
    lea rsi, [p_tl_pkg]
    call fs_find
    test rax, rax
    jz .out
    mov byte [tl_on], 1
    mov dword [tl_ws], 1
    mov byte [tl_req], 40
.out:
    POPA
    ret

sys_tl_installed:
    lea rsi, [p_tl_pkg]
    call fs_find
    test rax, rax
    setnz al
    movzx eax, al
    ret

term_uname:
    lea rsi, [s_uname]
    call tput_s
    ret

term_hostname:
    lea rsi, [s_host_pre]
    call tput_s
    lea rsi, [p_etc_hostname]
    call sys_read_small
    test eax, eax
    jz .def
    lea rsi, [sess_buf]
    call tput_s
    call tnl
    jmp .out
.def:
    lea rsi, [s_hostname]
    call tput_s
    call tnl
.out:
    ret

term_sysinfo:
    lea rsi, [s_uname]
    call tput_s
    lea rsi, [s_host_pre]
    call tput_s
    lea rsi, [p_etc_hostname]
    call sys_read_small
    test eax, eax
    jz .nil
    lea rsi, [sess_buf]
    call tput_s
    call tnl
    jmp .out
.nil:
    lea rsi, [s_hostname]
    call tput_s
    call tnl
.out:
    ret

term_usb:
    PUSHA
    lea rsi, [s_usb_head]
    call tput_s
    mov r12d, 0x80
.l:
    cmp r12d, 0x88
    jae .done
    mov edx, r12d
    call bios_info
    test rax, rax
    jz .n
    push rax
    mov al, ' '
    call tput_c
    mov al, '0'
    call tput_c
    mov al, 'x'
    call tput_c
    mov eax, r12d
    call tput_hex2
    mov al, ' '
    call tput_c
    mov al, ' '
    call tput_c
    pop rax
    mov rbx, rax
    shr rax, 11
    call tput_dec
    lea rsi, [s_set_size]
    call tput_s
    movzx eax, byte [bootdrv]
    cmp r12d, eax
    jne .n2
    lea rsi, [s_usb_boot]
    call tput_s
    jmp .n
.n2:
    call tnl
.n:
    inc r12d
    jmp .l
.done:
    lea rsi, [s_usb_hint]
    call tput_s
    POPA
    ret
