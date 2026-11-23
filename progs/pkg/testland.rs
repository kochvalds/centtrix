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
        (api.print)(b"testland: starting the tiling session\0".as_ptr());
        (api.nl)();
        (api.wm)(1);
        (api.print)(b"testland: Super+Enter terminal, Super+E files, Super+Shift+Q leaves\0".as_ptr());
        (api.nl)();
        (api.exits)();
    }
    loop {}
}
