#![no_std]
#![no_main]

use core::panic::PanicInfo;

type FnPrint = extern "C" fn(*const u8);
type FnInt = extern "C" fn(i32);
type FnNum = extern "C" fn(u64);
type FnVoid = extern "C" fn();
type FnKey = extern "C" fn() -> i32;

#[repr(C)]
pub struct Api {
    print: FnPrint,
    putc: FnInt,
    num: FnNum,
    nl: FnVoid,
    key: FnKey,
    wait: FnKey,
    yieldv: FnVoid,
    exits: FnVoid,
    sleep: FnInt,
    wm: FnInt,
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}

#[no_mangle]
pub extern "C" fn memcpy(d: *mut u8, s: *const u8, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *d.add(i) = *s.add(i) };
        i += 1;
    }
    d
}

#[no_mangle]
pub extern "C" fn memset(d: *mut u8, v: i32, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *d.add(i) = v as u8 };
        i += 1;
    }
    d
}

#[no_mangle]
pub extern "C" fn _start(a: *const Api) -> ! {
    unsafe {
        let api = &*a;
        (api.print)(b"Centtrix 4.0 x86_64\0".as_ptr());
        (api.nl)();
        (api.print)(b"filesystem: CNT3 (dynamic, FAT chains)\0".as_ptr());
        (api.nl)();
        (api.print)(b"languages: C, Python, Rust, XPL\0".as_ptr());
        (api.nl)();
        (api.print)(b"configuration: /etc  programs: /usr  packages: /home/pkg\0".as_ptr());
        (api.nl)();
        (api.wait)();
        (api.exits)();
    }
    loop {}
}
